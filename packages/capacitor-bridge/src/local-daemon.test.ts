import { expect, test } from "vitest"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import {
  attachAndroidLocalEnrollment,
  createAndroidRemoteAgentSettings,
  type LocalDaemonBridgePlugin,
  type PreparedEnrollment,
  type RemoteAgentSettingsBridgePlugin,
} from "./local-daemon.ts"

function createFakeCentral(initialServerUrl = "https://fleet.example"): {
  central: CentralApi
  calls: { teamId: string; payload: unknown }[]
} {
  const calls: { teamId: string; payload: unknown }[] = []
  const central = {
    async status() {
      return { serverUrl: initialServerUrl, siteAdmin: false }
    },
    async enrollHeadless(teamId: string, payload: unknown) {
      calls.push({ teamId, payload })
      return {
        machine: { id: "central-machine-42", teamId, name: "Phone", online: true, capabilities: {} },
        token: "secret-machine-token",
      }
    },
  } as unknown as CentralApi
  return { central, calls }
}

function createEnrollment(overrides: Partial<LocalEnrollment> = {}): LocalEnrollment {
  return {
    configured: false,
    connected: false,
    revoked: false,
    identity: { originId: "origin-1", machineId: "local-1" },
    machineName: "Pixel 9 Pro",
    ...overrides,
  }
}

test("attachAndroidLocalEnrollment exposes localEnrollment status from native plugin", async () => {
  const { central } = createFakeCentral()
  const expected: LocalMachineStatus = {
    machineName: "Pixel 9 Pro",
    registrations: [createEnrollment({ configured: true, connected: true, serverUrl: "https://fleet.example", teamId: "team-1", machineId: "m-1" })],
  }
  const plugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() { return expected },
    async localDaemonPrepareEnrollment() { throw new Error("unexpected prepare") },
    async localDaemonEnroll() { throw new Error("unexpected enroll") },
  }

  attachAndroidLocalEnrollment(central, plugin)
  expect(central.localEnrollment).toBeTypeOf("function")
  expect(await central.localEnrollment!()).toEqual(expected)
})

test("enrollLocal short-circuits when an active registration already exists for the server and team", async () => {
  const { central, calls } = createFakeCentral()
  const existing = createEnrollment({
    configured: true,
    connected: true,
    revoked: false,
    serverUrl: "https://fleet.example",
    teamId: "team-1",
    machineId: "m-1",
  })
  let prepared = false
  const plugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() { return { machineName: "Pixel 9 Pro", registrations: [existing] } },
    async localDaemonPrepareEnrollment() {
      prepared = true
      throw new Error("should not prepare")
    },
    async localDaemonEnroll() { throw new Error("should not enroll") },
  }

  attachAndroidLocalEnrollment(central, plugin)
  const result = await central.enrollLocal!("team-1", "My Phone")
  expect(result).toEqual(existing)
  expect(prepared).toBe(false)
  expect(calls).toHaveLength(0)
})

test("enrollLocal prepares daemon, registers with central, trims machine name, and enrolls daemon", async () => {
  const { central, calls } = createFakeCentral()
  const enrolledRecord = createEnrollment({
    configured: true,
    connected: true,
    serverUrl: "https://fleet.example",
    teamId: "team-1",
    machineId: "central-machine-42",
  })
  const prepareCalls: unknown[] = []
  const enrollCalls: unknown[] = []
  const plugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() {
      return {
        machineName: "Pixel 9 Pro",
        registrations: [createEnrollment({ configured: true, revoked: true, serverUrl: "https://fleet.example", teamId: "team-1" })],
      }
    },
    async localDaemonPrepareEnrollment(options): Promise<PreparedEnrollment> {
      prepareCalls.push(options)
      return {
        ...createEnrollment(),
        identityToken: "id-token-xyz",
      }
    },
    async localDaemonEnroll(options) {
      enrollCalls.push(options)
      return enrolledRecord
    },
  }

  attachAndroidLocalEnrollment(central, plugin)
  const result = await central.enrollLocal!("team-1", "  Lemon Phone  ")
  expect(result).toEqual(enrolledRecord)
  expect(prepareCalls).toEqual([{ serverUrl: "https://fleet.example", teamId: "team-1" }])
  expect(calls).toEqual([{
    teamId: "team-1",
    payload: {
      name: "Lemon Phone",
      originId: "origin-1",
      localMachineId: "local-1",
      identityToken: "id-token-xyz",
    },
  }])
  expect(enrollCalls).toEqual([{
    serverUrl: "https://fleet.example",
    machineId: "central-machine-42",
    teamId: "team-1",
    token: "secret-machine-token",
    originId: "origin-1",
  }])
})

test("enrollLocal falls back to daemon machineName on blank input and propagates errors", async () => {
  const { central, calls } = createFakeCentral()
  const plugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() { return { machineName: "Fallback Phone", registrations: [] } },
    async localDaemonPrepareEnrollment() {
      return { ...createEnrollment({ machineName: "Fallback Phone" }), identityToken: "tok" }
    },
    async localDaemonEnroll() {
      throw new Error("container enroll failed")
    },
  }

  attachAndroidLocalEnrollment(central, plugin)
  await expect(central.enrollLocal!("team-1", 123 as unknown as string)).rejects.toThrow(/Invalid machine name/)
  await expect(central.enrollLocal!("team-1", "   ")).rejects.toThrow(/container enroll failed/)
  expect(calls[0]?.payload).toEqual({
    name: "Fallback Phone",
    originId: "origin-1",
    localMachineId: "local-1",
    identityToken: "tok",
  })
})

test("onLocalEnrollmentOutput streams native logs and milestones without leaking secrets", async () => {
  const { central } = createFakeCentral()
  let emitLog: ((data: { chunk: string }) => void) | undefined
  let removed = 0
  const plugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() { return { machineName: "Pixel 9 Pro", registrations: [] } },
    async localDaemonPrepareEnrollment() {
      emitLog?.({ chunk: "Downloading Debian rootfs...\n" })
      emitLog?.({ chunk: "Setting up adb (34.0.5)...\n" })
      return { ...createEnrollment(), identityToken: "secret-id-token-never-log" }
    },
    async localDaemonEnroll() {
      emitLog?.({ chunk: "Imported machine credentials.\n" })
      return createEnrollment({
        configured: true,
        connected: true,
        serverUrl: "https://fleet.example",
        teamId: "team-1",
        machineId: "central-machine-42",
      })
    },
    async addListener(eventName, listenerFunc) {
      expect(eventName).toBe("localDaemonLog")
      emitLog = listenerFunc
      return {
        async remove() {
          removed += 1
          emitLog = undefined
        },
      }
    },
  }

  attachAndroidLocalEnrollment(central, plugin)
  const chunks: string[] = []
  const unsubscribe = central.onLocalEnrollmentOutput!(chunk => chunks.push(chunk))
  await central.enrollLocal!("team-1", "Phone")
  unsubscribe()
  const combined = chunks.join("")
  expect(combined).toContain("Checking local daemon status...")
  expect(combined).toContain("Downloading Debian rootfs...")
  expect(combined).toContain("Setting up adb (34.0.5)...")
  expect(combined).toContain('Registering "Phone" with https://fleet.example')
  expect(combined).toContain("Imported machine credentials.")
  expect(combined).toContain("Connected to team.")
  expect(combined).not.toContain("secret-id-token-never-log")
  expect(combined).not.toContain("secret-machine-token")
  expect(removed).toBe(1)

  const failingPlugin: LocalDaemonBridgePlugin = {
    async localDaemonStatus() { return { machineName: "Pixel 9 Pro", registrations: [] } },
    async localDaemonPrepareEnrollment() {
      emitLog?.({ chunk: "Extracting rootfs...\n" })
      throw new Error("rootfs download failed")
    },
    async localDaemonEnroll() { throw new Error("unexpected") },
    async addListener(_eventName, listenerFunc) {
      emitLog = listenerFunc
      return {
        async remove() {
          removed += 1
          emitLog = undefined
        },
      }
    },
  }
  const { central: failingCentral } = createFakeCentral()
  attachAndroidLocalEnrollment(failingCentral, failingPlugin)
  const failedChunks: string[] = []
  const stop = failingCentral.onLocalEnrollmentOutput!(chunk => failedChunks.push(chunk))
  await expect(failingCentral.enrollLocal!("team-1", "Phone")).rejects.toThrow(/rootfs download failed/)
  stop()
  expect(failedChunks.join("")).toContain("Extracting rootfs...")
  expect(failedChunks.join("")).toContain("rootfs download failed")
  expect(removed).toBe(2)
})

test("createAndroidRemoteAgentSettings reads, normalizes, and writes Remote Agent permissions", async () => {
  let stored = {
    allowRead: true,
    allowOperate: false,
    allowSessions: true,
    allowWorkspaces: false,
    allowSuperAgent: false,
    allowLocalCrossWorkspace: true,
  }
  const calls: unknown[] = []
  const plugin: RemoteAgentSettingsBridgePlugin = {
    async localDaemonGetRemoteAgentSettings() {
      return stored
    },
    async localDaemonSetRemoteAgentSettings(settings) {
      calls.push(settings)
      stored = {
        allowRead: settings.allowRead,
        allowOperate: settings.allowOperate,
        allowSessions: Boolean(settings.allowSessions),
        allowWorkspaces: Boolean(settings.allowWorkspaces),
        allowSuperAgent: Boolean(settings.allowSuperAgent),
        allowLocalCrossWorkspace: Boolean(settings.allowLocalCrossWorkspace),
      }
      return stored
    },
  }

  const settingsApi = createAndroidRemoteAgentSettings(plugin)
  expect(await settingsApi.getRemoteAgentSettings()).toEqual(stored)
  expect(await settingsApi.setRemoteAgentSettings({ allowRead: true, allowOperate: true })).toEqual({
    allowRead: true,
    allowOperate: true,
    allowSessions: false,
    allowWorkspaces: false,
    allowSuperAgent: false,
    allowLocalCrossWorkspace: false,
  })
  expect(calls).toEqual([
    {
      allowRead: true,
      allowOperate: true,
      allowSessions: false,
      allowWorkspaces: false,
      allowSuperAgent: false,
      allowLocalCrossWorkspace: false,
    },
  ])
})

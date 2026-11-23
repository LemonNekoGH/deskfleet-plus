import { expect, test } from "vitest"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import type { RemoteAgentSettings, WorktreePreferences } from "@deskfleet/client/settings"
import {
  attachLocalEnrollment,
  createLocalDaemonHostSettings,
  type LocalDaemonBridgePlugin,
  type LocalDaemonSettingsBridgePlugin,
  type PreparedEnrollment,
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

function defaultRemoteAgents(): Required<RemoteAgentSettings> {
  return {
    allowRead: false,
    allowOperate: false,
    allowSessions: false,
    allowWorkspaces: false,
    allowSuperAgent: false,
    allowLocalCrossWorkspace: false,
  }
}

function defaultWorktrees(): WorktreePreferences {
  return {
    branchNaming: "semantic",
    cleanup: {
      archived: true,
      merged: true,
      inactive: true,
      inactiveDays: 5,
      settled: true,
      settledDays: 6,
      unchanged: true,
      keepLocalChanges: "uncommitted",
    },
  }
}

test("attachLocalEnrollment exposes localEnrollment status from native plugin", async () => {
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

  attachLocalEnrollment(central, plugin)
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

  attachLocalEnrollment(central, plugin)
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

  attachLocalEnrollment(central, plugin)
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

  attachLocalEnrollment(central, plugin)
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

  attachLocalEnrollment(central, plugin)
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
  attachLocalEnrollment(failingCentral, failingPlugin)
  const failedChunks: string[] = []
  const stop = failingCentral.onLocalEnrollmentOutput!(chunk => failedChunks.push(chunk))
  await expect(failingCentral.enrollLocal!("team-1", "Phone")).rejects.toThrow(/rootfs download failed/)
  stop()
  expect(failedChunks.join("")).toContain("Extracting rootfs...")
  expect(failedChunks.join("")).toContain("rootfs download failed")
  expect(removed).toBe(2)
})

test("createLocalDaemonHostSettings probes via CLI, coalesces concurrent probes, and diffs updates", async () => {
  const remoteState = { ...defaultRemoteAgents(), allowRead: true }
  const worktreeState = defaultWorktrees()
  const cliCalls: string[][] = []

  const plugin: LocalDaemonSettingsBridgePlugin = {
    async localDaemonSettings({ args }) {
      cliCalls.push(args)
      const [action, key, value] = args
      if (action === "get") {
        if (key === "remoteAgents") return { ...remoteState }
        if (key === "worktrees") return { root: null, ...structuredClone(worktreeState) }
        return {
          remoteAgents: { ...remoteState },
          worktrees: { root: null, ...structuredClone(worktreeState) },
        }
      }
      if (action === "set" && key && value !== undefined) {
        if (key.startsWith("remoteAgents.")) {
          const field = key.slice("remoteAgents.".length) as keyof Required<RemoteAgentSettings>
          remoteState[field] = value === "true"
          return { ...remoteState }
        }
        if (key === "worktrees.branchNaming") {
          worktreeState.branchNaming = value as WorktreePreferences["branchNaming"]
          return structuredClone(worktreeState) as unknown as Record<string, unknown>
        }
        if (key.startsWith("worktrees.cleanup.")) {
          const field = key.slice("worktrees.cleanup.".length) as keyof WorktreePreferences["cleanup"]
          if (field === "inactiveDays" || field === "settledDays") {
            worktreeState.cleanup[field] = Number(value)
          } else if (field === "keepLocalChanges") {
            worktreeState.cleanup[field] = value as WorktreePreferences["cleanup"]["keepLocalChanges"]
          } else {
            worktreeState.cleanup[field] = value === "true"
          }
          return structuredClone(worktreeState) as unknown as Record<string, unknown>
        }
      }
      throw new Error(`Unexpected CLI args: ${args.join(" ")}`)
    },
  }

  const hostSettings = createLocalDaemonHostSettings(plugin)

  // Concurrent probes share one CLI invocation.
  const [firstProbe, secondProbe] = await Promise.all([
    hostSettings.probeLocalDaemonSettings(),
    hostSettings.probeLocalDaemonSettings(),
  ])
  expect(firstProbe).toBe(true)
  expect(secondProbe).toBe(true)
  expect(cliCalls).toEqual([["get"]])

  // Reads query the requested section directly from the daemon CLI.
  expect(await hostSettings.settings.getRemoteAgentSettings()).toEqual(remoteState)
  expect(await hostSettings.settings.getWorktreePreferences()).toEqual(worktreeState)
  expect(cliCalls).toEqual([["get"], ["get", "remoteAgents"], ["get", "worktrees"]])

  // Saving remote agent settings invokes `settings set` only for changed keys.
  cliCalls.length = 0
  const updatedRemote = await hostSettings.settings.setRemoteAgentSettings({
    ...remoteState,
    allowOperate: true,
    allowSuperAgent: true,
  })
  expect(updatedRemote).toEqual({
    ...defaultRemoteAgents(),
    allowRead: true,
    allowOperate: true,
    allowSuperAgent: true,
  })
  expect(cliCalls).toEqual([
    ["get", "remoteAgents"],
    ["set", "remoteAgents.allowOperate", "true"],
    ["set", "remoteAgents.allowSuperAgent", "true"],
  ])

  // Saving worktree preferences invokes `settings set` only for changed leaves.
  cliCalls.length = 0
  const nextWorktrees = structuredClone(worktreeState)
  nextWorktrees.branchNaming = "session"
  nextWorktrees.cleanup.archived = false
  nextWorktrees.cleanup.settledDays = 0
  const updatedWorktrees = await hostSettings.settings.setWorktreePreferences(nextWorktrees)
  expect(updatedWorktrees).toEqual(nextWorktrees)
  expect(cliCalls).toEqual([
    ["get", "worktrees"],
    ["set", "worktrees.branchNaming", "session"],
    ["set", "worktrees.cleanup.archived", "false"],
    ["set", "worktrees.cleanup.settledDays", "0"],
  ])
})

test("probeLocalDaemonSettings returns false when local daemon CLI is unavailable", async () => {
  const hostSettings = createLocalDaemonHostSettings({
    async localDaemonSettings() {
      throw new Error("Local daemon is not installed")
    },
  })

  expect(await hostSettings.probeLocalDaemonSettings()).toBe(false)
})

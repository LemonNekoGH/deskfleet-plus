import { expect, test } from "vitest"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import { attachAndroidLocalEnrollment, attachLocalEnrollment, type LocalDaemonBridgePlugin, type PreparedEnrollment } from "./local-daemon.ts"

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
  expect(attachLocalEnrollment).toBe(attachAndroidLocalEnrollment)
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

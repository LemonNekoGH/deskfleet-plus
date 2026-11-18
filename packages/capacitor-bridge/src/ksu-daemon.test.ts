import assert from "node:assert/strict"
import { test } from "vitest"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import { attachAndroidLocalEnrollment, type KsuDaemonBridgePlugin, type PreparedEnrollment } from "./ksu-daemon.ts"

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
  const plugin: KsuDaemonBridgePlugin = {
    async ksuDaemonStatus() { return expected },
    async ksuDaemonPrepareEnrollment() { throw new Error("unexpected prepare") },
    async ksuDaemonEnroll() { throw new Error("unexpected enroll") },
  }

  attachAndroidLocalEnrollment(central, plugin)
  assert.ok(central.localEnrollment)
  assert.deepEqual(await central.localEnrollment(), expected)
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
  const plugin: KsuDaemonBridgePlugin = {
    async ksuDaemonStatus() { return { machineName: "Pixel 9 Pro", registrations: [existing] } },
    async ksuDaemonPrepareEnrollment() {
      prepared = true
      throw new Error("should not prepare")
    },
    async ksuDaemonEnroll() { throw new Error("should not enroll") },
  }

  attachAndroidLocalEnrollment(central, plugin)
  const result = await central.enrollLocal!("team-1", "My Phone")
  assert.deepEqual(result, existing)
  assert.equal(prepared, false)
  assert.equal(calls.length, 0)
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
  const plugin: KsuDaemonBridgePlugin = {
    async ksuDaemonStatus() {
      return {
        machineName: "Pixel 9 Pro",
        registrations: [createEnrollment({ configured: true, revoked: true, serverUrl: "https://fleet.example", teamId: "team-1" })],
      }
    },
    async ksuDaemonPrepareEnrollment(options): Promise<PreparedEnrollment> {
      prepareCalls.push(options)
      return {
        ...createEnrollment(),
        identityToken: "id-token-xyz",
      }
    },
    async ksuDaemonEnroll(options) {
      enrollCalls.push(options)
      return enrolledRecord
    },
  }

  attachAndroidLocalEnrollment(central, plugin)
  const result = await central.enrollLocal!("team-1", "  Lemon Phone  ")
  assert.deepEqual(result, enrolledRecord)
  assert.deepEqual(prepareCalls, [{ serverUrl: "https://fleet.example", teamId: "team-1" }])
  assert.deepEqual(calls, [{
    teamId: "team-1",
    payload: {
      name: "Lemon Phone",
      originId: "origin-1",
      localMachineId: "local-1",
      identityToken: "id-token-xyz",
    },
  }])
  assert.deepEqual(enrollCalls, [{
    serverUrl: "https://fleet.example",
    machineId: "central-machine-42",
    teamId: "team-1",
    token: "secret-machine-token",
    originId: "origin-1",
  }])
})

test("enrollLocal falls back to daemon machineName on blank input and propagates errors", async () => {
  const { central, calls } = createFakeCentral()
  const plugin: KsuDaemonBridgePlugin = {
    async ksuDaemonStatus() { return { machineName: "Fallback Phone", registrations: [] } },
    async ksuDaemonPrepareEnrollment() {
      return { ...createEnrollment({ machineName: "Fallback Phone" }), identityToken: "tok" }
    },
    async ksuDaemonEnroll() {
      throw new Error("chroot enroll failed")
    },
  }

  attachAndroidLocalEnrollment(central, plugin)
  await assert.rejects(() => central.enrollLocal!("team-1", 123 as unknown as string), /Invalid machine name/)
  await assert.rejects(() => central.enrollLocal!("team-1", "   "), /chroot enroll failed/)
  assert.deepEqual(calls[0]?.payload, {
    name: "Fallback Phone",
    originId: "origin-1",
    localMachineId: "local-1",
    identityToken: "tok",
  })
})

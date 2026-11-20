import { expect, test, vi } from "vitest"
import type { WirelessAdbState } from "@deskfleet/client/wireless-adb"
import { createCapacitorWirelessAdbApi, type WirelessAdbBridgePlugin } from "./wireless-adb.ts"

const baseState: WirelessAdbState = {
  state: "disconnected",
  tcpip5555Active: false,
  keepAliveTcpip5555: false,
  pairingDiscoveryActive: false,
}

test("createCapacitorWirelessAdbApi validates inputs and forwards bridge calls", async () => {
  let emitState: ((state: WirelessAdbState) => void) | undefined
  const remove = vi.fn(async () => {
    emitState = undefined
  })
  const plugin: WirelessAdbBridgePlugin = {
    wirelessAdbStatus: vi.fn(async () => baseState),
    wirelessAdbStartPairing: vi.fn(async () => ({ ...baseState, pairingDiscoveryActive: true })),
    wirelessAdbStopPairing: vi.fn(async () => baseState),
    wirelessAdbPair: vi.fn(async () => ({ ...baseState, state: "connected", endpoint: "127.0.0.1:41234" })),
    wirelessAdbConnect: vi.fn(async () => ({ ...baseState, state: "connected", endpoint: "127.0.0.1:5555", tcpip5555Active: true })),
    wirelessAdbSetKeepAlive: vi.fn(async ({ enabled }) => ({ ...baseState, keepAliveTcpip5555: enabled })),
    wirelessAdbOpenDeveloperSettings: vi.fn(async () => {}),
    addListener: vi.fn(async (_eventName, listenerFunc) => {
      emitState = listenerFunc
      return { remove }
    }),
  }

  const api = createCapacitorWirelessAdbApi(plugin)
  await expect(api.status(true)).resolves.toEqual(baseState)
  expect(plugin.wirelessAdbStatus).toHaveBeenCalledWith({ refresh: true })

  await expect(api.startPairing()).resolves.toMatchObject({ pairingDiscoveryActive: true })
  await expect(api.stopPairing()).resolves.toEqual(baseState)

  expect(() => api.pair(0, "123456")).toThrow(/port/)
  expect(() => api.pair(37123, "abc")).toThrow(/pairing code/)
  await expect(api.pair(37123, "482 910")).resolves.toMatchObject({ state: "connected" })
  expect(plugin.wirelessAdbPair).toHaveBeenCalledWith({ port: 37123, code: "482910" })

  expect(() => api.connect(70000)).toThrow(/port/)
  await api.connect()
  expect(plugin.wirelessAdbConnect).toHaveBeenCalledWith({})
  await api.connect(41234)
  expect(plugin.wirelessAdbConnect).toHaveBeenCalledWith({ port: 41234 })

  await expect(api.setKeepAlive(true)).resolves.toMatchObject({ keepAliveTcpip5555: true })
  await api.openDeveloperSettings()
  expect(plugin.wirelessAdbOpenDeveloperSettings).toHaveBeenCalledOnce()

  const received: WirelessAdbState[] = []
  const unsubscribe = api.onStateChanged(state => received.push(state))
  await Promise.resolve()
  emitState?.({ ...baseState, state: "pairing", pairingPort: 39001 })
  expect(received).toHaveLength(1)

  unsubscribe()
  emitState?.({ ...baseState, state: "connected", endpoint: "127.0.0.1:5555" })
  expect(received).toHaveLength(1)
  await Promise.resolve()
  expect(remove).toHaveBeenCalledOnce()
})

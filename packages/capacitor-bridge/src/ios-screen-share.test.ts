import type { IosScreenShareState } from "@deskfleet/client/ios-screen-share"
import { expect, test, vi } from "vitest"
import { createCapacitorIosScreenShareApi, type IosScreenShareBridgePlugin } from "./ios-screen-share.ts"

const sampleState: IosScreenShareState = {
  mode: "coredevice",
  available: true,
  control: true,
  pasteboard: true,
  pairingFilePresent: true,
  localDevVpnReachable: true,
  coreDeviceAvailable: true,
  replayKitActive: false,
  width: 1179,
  height: 2556,
  codecs: ["h265"],
}

test("bridges iOS screen share methods and stops delivering events after unsubscribe", async () => {
  let nativeListener: ((state: IosScreenShareState) => void) | undefined
  const remove = vi.fn(async () => {})
  const plugin: IosScreenShareBridgePlugin = {
    iosScreenShareStatus: vi.fn(async () => sampleState),
    iosScreenShareProbeCoreDevice: vi.fn(async () => sampleState),
    iosScreenShareStartBroadcast: vi.fn(async () => ({ ...sampleState, mode: "replaykit", control: false, replayKitActive: true })),
    iosScreenShareStopBroadcast: vi.fn(async () => ({ ...sampleState, mode: "unavailable", available: false, control: false })),
    iosScreenShareOpenLocalDevVpn: vi.fn(async () => {}),
    addListener: vi.fn(async (_event, fn) => {
      nativeListener = fn
      return { remove }
    }),
  }

  const api = createCapacitorIosScreenShareApi(plugin)
  expect(await api.status(true)).toEqual(sampleState)
  expect(plugin.iosScreenShareStatus).toHaveBeenCalledWith({ probeCoreDevice: true })

  expect(await api.probeCoreDevice()).toEqual(sampleState)
  expect((await api.startBroadcast()).mode).toBe("replaykit")
  expect((await api.stopBroadcast()).mode).toBe("unavailable")
  await api.openLocalDevVpn()
  expect(plugin.iosScreenShareOpenLocalDevVpn).toHaveBeenCalledOnce()

  const received: IosScreenShareState[] = []
  const unsubscribe = api.onStateChanged(state => received.push(state))
  await Promise.resolve()
  nativeListener?.(sampleState)
  expect(received).toHaveLength(1)

  unsubscribe()
  nativeListener?.(sampleState)
  expect(received).toHaveLength(1)
  await Promise.resolve()
  expect(remove).toHaveBeenCalledOnce()
})

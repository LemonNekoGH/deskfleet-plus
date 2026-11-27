import { configureClient, getClient } from "@deskfleet/client/platform"
import type { IosScreenShareApi, IosScreenShareState } from "@deskfleet/client/ios-screen-share"
import { flushPromises, mount, type VueWrapper } from "@vue/test-utils"
import { afterEach, expect, test, vi } from "vitest"
import { i18n } from "../../i18n/index.ts"
import IosScreenShareSettings from "./IosScreenShareSettings.vue"

const host = getClient()
let wrapper: VueWrapper | undefined

afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
  i18n.global.locale.value = "en-US"
  configureClient(host)
})

function makeState(overrides: Partial<IosScreenShareState> = {}): IosScreenShareState {
  return {
    mode: "unavailable",
    available: false,
    control: false,
    pasteboard: false,
    pairingFilePresent: true,
    localDevVpnReachable: false,
    coreDeviceAvailable: false,
    replayKitActive: false,
    width: 1179,
    height: 2556,
    codecs: [],
    ...overrides,
  }
}

test("renders iOS screen share controls, probes CoreDevice, and toggles ReplayKit broadcast", async () => {
  let listener: ((state: IosScreenShareState) => void) | undefined
  const unsubscribe = vi.fn()
  const iosScreenShare: IosScreenShareApi = {
    status: vi.fn(async () => makeState()),
    probeCoreDevice: vi.fn(async () =>
      makeState({
        mode: "coredevice",
        available: true,
        control: true,
        pasteboard: true,
        localDevVpnReachable: true,
        coreDeviceAvailable: true,
        codecs: ["h265"],
      }),
    ),
    startBroadcast: vi.fn(async () =>
      makeState({
        mode: "replaykit",
        available: true,
        control: false,
        replayKitActive: true,
        codecs: ["h264", "h265"],
      }),
    ),
    stopBroadcast: vi.fn(async () => makeState()),
    openLocalDevVpn: vi.fn(async () => {}),
    onStateChanged: fn => {
      listener = fn
      return unsubscribe
    },
  }

  configureClient({ ...host, platform: "web", mobile: true, iosScreenShare })
  wrapper = mount(IosScreenShareSettings, { global: { plugins: [i18n] } })
  await flushPromises()

  expect(iosScreenShare.status).toHaveBeenCalledWith(true)
  expect(wrapper.get("[data-ios-screen-share-status]").text()).toBe("Inactive")
  expect(wrapper.get("[data-ios-screen-share-coredevice-status]").text()).toBe("LocalDevVPN inactive")

  await wrapper.get("[data-ios-screen-share-open-vpn]").trigger("click")
  expect(iosScreenShare.openLocalDevVpn).toHaveBeenCalledOnce()

  await wrapper.get("[data-ios-screen-share-probe]").trigger("click")
  await flushPromises()
  expect(iosScreenShare.probeCoreDevice).toHaveBeenCalledOnce()
  expect(wrapper.get("[data-ios-screen-share-status]").text()).toBe("CoreDevice (Screen + Remote Control)")

  listener?.(makeState({ mode: "unavailable" }))
  await flushPromises()
  expect(wrapper.get("[data-ios-screen-share-status]").text()).toBe("Inactive")

  await wrapper.get("[data-ios-screen-share-toggle-broadcast]").trigger("click")
  await flushPromises()
  expect(iosScreenShare.startBroadcast).toHaveBeenCalledOnce()
  expect(wrapper.get("[data-ios-screen-share-status]").text()).toBe("ReplayKit Broadcast (View-only)")

  await wrapper.get("[data-ios-screen-share-toggle-broadcast]").trigger("click")
  await flushPromises()
  expect(iosScreenShare.stopBroadcast).toHaveBeenCalledOnce()
  expect(wrapper.get("[data-ios-screen-share-status]").text()).toBe("Inactive")

  wrapper.unmount()
  wrapper = undefined
  expect(unsubscribe).toHaveBeenCalledOnce()
})

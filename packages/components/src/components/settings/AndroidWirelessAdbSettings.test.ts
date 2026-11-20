import { configureClient, getClient } from "@deskfleet/client/platform"
import type { WirelessAdbApi, WirelessAdbState } from "@deskfleet/client/wireless-adb"
import { flushPromises, mount, type VueWrapper } from "@vue/test-utils"
import { afterEach, expect, test, vi } from "vitest"
import { i18n } from "../../i18n/index.ts"
import AndroidWirelessAdbSettings from "./AndroidWirelessAdbSettings.vue"

const host = getClient()
let wrapper: VueWrapper | undefined

afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
  i18n.global.locale.value = "en-US"
  configureClient(host)
})

function makeState(overrides: Partial<WirelessAdbState> = {}): WirelessAdbState {
  return {
    state: "disconnected",
    tcpip5555Active: false,
    keepAliveTcpip5555: false,
    pairingDiscoveryActive: false,
    ...overrides,
  }
}

test("renders Wireless ADB controls, reacts to live state events, and pairs manually", async () => {
  let listener: ((state: WirelessAdbState) => void) | undefined
  const unsubscribe = vi.fn()
  const wirelessAdb: WirelessAdbApi = {
    status: vi.fn(async () => makeState()),
    startPairing: vi.fn(async () => makeState({ pairingDiscoveryActive: true })),
    stopPairing: vi.fn(async () => makeState({ pairingDiscoveryActive: false })),
    pair: vi.fn(async () => makeState({ state: "connected", endpoint: "127.0.0.1:41234" })),
    connect: vi.fn(async () => makeState({ state: "connected", endpoint: "127.0.0.1:5555", tcpip5555Active: true })),
    setKeepAlive: vi.fn(async enabled => makeState({ keepAliveTcpip5555: enabled })),
    openDeveloperSettings: vi.fn(async () => {}),
    onStateChanged: fn => {
      listener = fn
      return unsubscribe
    },
  }

  configureClient({ ...host, platform: "web", mobile: true, wirelessAdb })
  wrapper = mount(AndroidWirelessAdbSettings, { global: { plugins: [i18n] } })
  await flushPromises()

  expect(wirelessAdb.status).toHaveBeenCalledWith(true)
  expect(wrapper.get("[data-wireless-adb-status]").text()).toBe("Disconnected")

  await wrapper.get("[data-wireless-adb-toggle-pairing]").trigger("click")
  await flushPromises()
  expect(wirelessAdb.startPairing).toHaveBeenCalledOnce()
  expect(wrapper.find("[data-wireless-adb-pair-form]").exists()).toBe(true)

  listener?.(makeState({ pairingDiscoveryActive: true, pairingPort: 37123 }))
  await flushPromises()
  expect((wrapper.get("[data-wireless-adb-port-input]").element as HTMLInputElement).value).toBe("37123")

  // Rejects invalid code before calling native bridge.
  await wrapper.get("[data-wireless-adb-code-input]").setValue("abc")
  await wrapper.get("[data-wireless-adb-pair-form]").trigger("submit")
  expect(wrapper.get('[role="alert"]').text()).toContain("Enter a valid port")
  expect(wirelessAdb.pair).not.toHaveBeenCalled()

  await wrapper.get("[data-wireless-adb-code-input]").setValue("482910")
  await wrapper.get("[data-wireless-adb-pair-form]").trigger("submit")
  await flushPromises()
  expect(wirelessAdb.pair).toHaveBeenCalledWith(37123, "482910")
  expect(wrapper.get("[data-wireless-adb-status]").text()).toBe("Connected (127.0.0.1:41234)")

  await wrapper.get("[data-wireless-adb-keep-alive]").trigger("click")
  await flushPromises()
  expect(wirelessAdb.setKeepAlive).toHaveBeenCalledWith(true)

  await wrapper.get("[data-wireless-adb-dev-options]").trigger("click")
  expect(wirelessAdb.openDeveloperSettings).toHaveBeenCalledOnce()

  await wrapper.get("[data-wireless-adb-reconnect]").trigger("click")
  await flushPromises()
  expect(wirelessAdb.connect).toHaveBeenCalledOnce()
  expect(wrapper.get("[data-wireless-adb-status]").text()).toBe("Connected (127.0.0.1:5555)")

  wrapper.unmount()
  wrapper = undefined
  expect(unsubscribe).toHaveBeenCalledOnce()
})

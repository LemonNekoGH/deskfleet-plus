import { configureClient, getClient } from "@deskfleet/client/platform"
import { flushPromises, mount, type VueWrapper } from "@vue/test-utils"
import { ref } from "vue"
import { afterEach, expect, test, vi } from "vitest"
import { i18n } from "../../i18n/index.ts"
import { setUserTelemetryConsent, userTelemetryConsent } from "../../services/analytics.ts"
import PreferencesSettings from "./PreferencesSettings.vue"

const mockSession = ref<{
  account: { value: { user?: { id: string; name: string } } }
  site: { value?: { telemetryEnabled: boolean } }
  central: { updateTelemetryConsent: ReturnType<typeof vi.fn> }
} | undefined>()

vi.mock("../../composables/useAccountSession.ts", () => ({
  useAccountSession: () => mockSession.value,
}))

const host = getClient()
let wrapper: VueWrapper | undefined

afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
  mockSession.value = undefined
  setUserTelemetryConsent(false)
  configureClient(host)
})

const stubUpdates = {
  get: async () => ({ status: "idle" as const }),
  check: async () => ({ status: "idle" as const }),
  install: async () => {},
  onChanged: () => () => {},
}

test("shows the Updates section on Web hosts installed from Google Play", async () => {
  configureClient({
    ...host,
    platform: "web",
    updates: stubUpdates,
    settings: {
      ...host.settings,
      getAutoDownloadUpdates: vi.fn(async () => ({ enabled: true, pauseOnMetered: true, installSource: "google_play" as const })),
    },
  })
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(wrapper.find("#updates-heading").exists()).toBe(true)
  expect(wrapper.find('[role="switch"]').exists()).toBe(true)
})

test("hides the Updates section on Web hosts installed from a sideloaded APK", async () => {
  configureClient({
    ...host,
    platform: "web",
    updates: stubUpdates,
    settings: {
      ...host.settings,
      getAutoDownloadUpdates: vi.fn(async () => ({ enabled: false, pauseOnMetered: true, installSource: "apk" as const })),
    },
  })
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(wrapper.find("#updates-heading").exists()).toBe(false)
})

test("shows telemetry consent switch only when site telemetry is enabled and syncs changes to central", async () => {
  const updateTelemetryConsent = vi.fn(async () => {})
  mockSession.value = {
    account: { value: { user: { id: "user-1", name: "Ada" } } },
    site: { value: { telemetryEnabled: true } },
    central: { updateTelemetryConsent },
  }
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(wrapper.find("#privacy-settings-heading").exists()).toBe(true)
  const toggle = wrapper.get('[aria-labelledby="telemetry-consent-label"]')
  await toggle.trigger("click")
  expect(userTelemetryConsent.value).toBe(true)
  expect(updateTelemetryConsent).toHaveBeenCalledWith(expect.objectContaining({ consented: true }))
})

test("hides Remote Agents and Wireless ADB on pure Web hosts and shows them only after probing a local mobile daemon", async () => {
  configureClient({ ...host, platform: "web", probeLocalDaemonSettings: undefined, wirelessAdb: undefined, iosScreenShare: undefined, localDaemon: undefined })
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(wrapper.find("#local-daemon-heading").exists()).toBe(false)
  expect(wrapper.find("#remote-agents-heading").exists()).toBe(false)
  expect(wrapper.find("#wireless-adb-heading").exists()).toBe(false)
  expect(wrapper.find("#ios-screen-share-heading").exists()).toBe(false)
  wrapper.unmount()

  // Mobile host where the local daemon has not been provisioned yet stays hidden.
  const getUnavailable = vi.fn(async () => ({ allowRead: false, allowOperate: false }))
  configureClient({
    ...host,
    platform: "web",
    mobile: true,
    probeLocalDaemonSettings: vi.fn(async () => false),
    wirelessAdb: undefined,
    settings: {
      ...host.settings,
      getRemoteAgentSettings: getUnavailable,
    },
  })
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(wrapper.find("#remote-agents-heading").exists()).toBe(false)
  expect(getUnavailable).not.toHaveBeenCalled()
  wrapper.unmount()

  const getRemoteAgentSettings = vi.fn(async () => ({ allowRead: true, allowOperate: false, allowSessions: false, allowWorkspaces: false }))
  const setRemoteAgentSettings = vi.fn(async (settings: { allowRead: boolean; allowOperate: boolean; allowSessions?: boolean; allowWorkspaces?: boolean }) => settings)
  const probeLocalDaemonSettings = vi.fn(async () => true)
  configureClient({
    ...host,
    platform: "web",
    mobile: true,
    probeLocalDaemonSettings,
    updates: stubUpdates,
    wirelessAdb: {
      status: vi.fn(async () => ({
        state: "connected" as const,
        endpoint: "127.0.0.1:5555",
        tcpip5555Active: true,
        keepAliveTcpip5555: true,
        pairingDiscoveryActive: false,
      })),
      startPairing: vi.fn(),
      stopPairing: vi.fn(),
      pair: vi.fn(),
      connect: vi.fn(),
      setKeepAlive: vi.fn(),
      openDeveloperSettings: vi.fn(),
      onStateChanged: () => () => {},
    },
    settings: {
      ...host.settings,
      getAutoDownloadUpdates: vi.fn(async () => ({ enabled: true, pauseOnMetered: true, installSource: "google_play" as const })),
      getRemoteAgentSettings,
      setRemoteAgentSettings,
    },
  })
  wrapper = mount(PreferencesSettings, { global: { plugins: [i18n] } })
  await flushPromises()
  expect(probeLocalDaemonSettings).toHaveBeenCalledOnce()
  expect(wrapper.find("#wireless-adb-heading").exists()).toBe(true)
  expect(wrapper.find("#remote-agents-heading").exists()).toBe(true)
  expect(wrapper.find("#updates-heading").exists()).toBe(true)
  expect(getRemoteAgentSettings).toHaveBeenCalledOnce()

  const remoteToggle = wrapper.get('[aria-labelledby="remote-agents-allowOperate-label"]')
  await remoteToggle.trigger("click")
  await flushPromises()
  expect(setRemoteAgentSettings).toHaveBeenCalledWith({
    allowRead: true,
    allowOperate: true,
    allowSessions: false,
    allowWorkspaces: false,
  })
})

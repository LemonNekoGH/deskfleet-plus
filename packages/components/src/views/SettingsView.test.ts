import { configureClient, getClient } from "@deskfleet/client/platform"
import { flushPromises, mount, type VueWrapper } from "@vue/test-utils"
import { ref } from "vue"
import { createMemoryHistory, createRouter } from "vue-router"
import { afterEach, expect, test, vi } from "vitest"
import { i18n } from "../i18n/index.ts"
import SettingsView from "./SettingsView.vue"

const mockLocalMachineId = ref<string | undefined>(undefined)

vi.mock("../composables/useAccountSession.ts", () => ({
  useAccountSession: () => ({
    machine: ref(undefined),
    localMachineId: mockLocalMachineId,
  }),
}))

const host = getClient()
let wrapper: VueWrapper | undefined

afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
  mockLocalMachineId.value = undefined
  configureClient(host)
})

async function mountSettingsView() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: "/", name: "new-session", component: { template: "<div />" } },
      { path: "/settings/preferences", name: "settings-preferences", component: { template: "<div />" } },
      { path: "/settings/worktrees", name: "settings-worktrees", component: { template: "<div />" } },
      { path: "/settings/appearance", name: "settings-appearance", component: { template: "<div />" } },
      { path: "/settings/notifications", name: "settings-notifications", component: { template: "<div />" } },
      { path: "/settings/github", name: "settings-github", component: { template: "<div />" } },
      { path: "/settings/permissions", name: "settings-permissions", component: { template: "<div />" } },
      { path: "/settings/agents", name: "settings-agents", component: { template: "<div />" } },
      { path: "/settings/mcp-servers", name: "settings-mcp-servers", component: { template: "<div />" } },
      { path: "/settings/developer", name: "settings-developer", component: { template: "<div />" } },
      { path: "/settings/about", name: "settings-about", component: { template: "<div />" } },
    ],
  })
  await router.push("/settings/preferences")
  await router.isReady()
  wrapper = mount(SettingsView, {
    global: {
      plugins: [i18n, router],
    },
  })
  await flushPromises()
  return wrapper
}

test("shows Worktrees sidebar link on mobile only when local daemon probe succeeds and re-probes after local enrollment", async () => {
  let daemonAvailable = false
  const probeLocalDaemonSettings = vi.fn(async () => daemonAvailable)
  configureClient({
    ...host,
    platform: "web",
    mobile: true,
    probeLocalDaemonSettings,
  })

  const view = await mountSettingsView()
  expect(probeLocalDaemonSettings).toHaveBeenCalledTimes(1)
  expect(view.find('a[href="/settings/worktrees"]').exists()).toBe(false)

  daemonAvailable = true
  mockLocalMachineId.value = "mobile-machine-87"
  await flushPromises()
  expect(probeLocalDaemonSettings).toHaveBeenCalledTimes(2)
  expect(view.find('a[href="/settings/worktrees"]').exists()).toBe(true)
})

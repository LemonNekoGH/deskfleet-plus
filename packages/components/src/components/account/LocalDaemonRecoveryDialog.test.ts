import { configureClient, getClient } from "@deskfleet/client/platform"
import { flushPromises, mount, type VueWrapper } from "@vue/test-utils"
import { afterEach, expect, test, vi } from "vitest"
import { i18n } from "../../i18n/index.ts"
import LocalDaemonRecoveryDialog from "./LocalDaemonRecoveryDialog.vue"

const mockRefreshMachines = vi.fn(async () => {})
vi.mock("../../composables/useAccountSession.ts", () => ({
  useAccountSession: () => ({
    refreshMachines: mockRefreshMachines,
  }),
}))

const host = getClient()
let wrapper: VueWrapper | undefined

afterEach(() => {
  wrapper?.unmount()
  wrapper = undefined
  mockRefreshMachines.mockClear()
  configureClient(host)
})

test("streams startup logs, starts local daemon without re-pairing, and closes on success", async () => {
  let emitLog: ((chunk: string) => void) | undefined
  const probeLocalDaemonSettings = vi.fn(async () => true)
  const start = vi.fn(async () => {
    emitLog?.("==> Booting embedded RISC-V 64-bit Linux VM...\n")
    return { enabled: true, status: "running" as const }
  })

  configureClient({
    ...host,
    platform: "web",
    mobile: true,
    probeLocalDaemonSettings,
    localDaemon: {
      start,
      recentOutput: vi.fn(async () => "Previous auto-start failed: LocalDevVPN offline\n"),
      onOutput: listener => {
        emitLog = listener
        return () => { emitLog = undefined }
      },
    },
  })

  wrapper = mount(LocalDaemonRecoveryDialog, {
    props: { initialError: "LocalDevVPN (10.7.0.1) is not active." },
    global: {
      plugins: [i18n],
      stubs: {
        UiDialog: { template: "<div><slot /></div>", methods: { close() { this.$emit("close") } } },
        DialogTitle: { template: "<h2><slot /></h2>" },
        DialogDescription: { template: "<p><slot /></p>" },
        TerminalSurface: { template: "<div data-terminal-stub />", methods: { write() {}, reset() {} } },
      },
    },
  })
  await flushPromises()

  expect(wrapper.text()).toContain("LocalDevVPN (10.7.0.1) is not active.")
  expect(wrapper.find("[data-local-daemon-recovery-terminal]").exists()).toBe(true)

  await wrapper.get("[data-local-daemon-start]").trigger("click")
  await flushPromises()

  expect(start).toHaveBeenCalledOnce()
  expect(mockRefreshMachines).toHaveBeenCalledOnce()
  expect(probeLocalDaemonSettings).toHaveBeenCalledOnce()
  expect(wrapper.emitted("started")).toHaveLength(1)
  expect(wrapper.emitted("close")).toHaveLength(1)
})

test("shows error message when manual start fails without closing dialog", async () => {
  configureClient({
    ...host,
    platform: "web",
    mobile: true,
    localDaemon: {
      start: vi.fn(async () => ({ enabled: true, status: "error" as const, error: "Pure JIT activation cancelled" })),
      recentOutput: vi.fn(async () => ""),
    },
  })

  wrapper = mount(LocalDaemonRecoveryDialog, {
    global: {
      plugins: [i18n],
      stubs: {
        UiDialog: { template: "<div><slot /></div>", methods: { close() { this.$emit("close") } } },
        DialogTitle: { template: "<h2><slot /></h2>" },
        DialogDescription: { template: "<p><slot /></p>" },
        TerminalSurface: { template: "<div data-terminal-stub />", methods: { write() {}, reset() {} } },
      },
    },
  })
  await flushPromises()

  await wrapper.get("[data-local-daemon-start]").trigger("click")
  await flushPromises()

  expect(wrapper.text()).toContain("Pure JIT activation cancelled")
  expect(wrapper.emitted("started")).toBeUndefined()
  expect(wrapper.emitted("close")).toBeUndefined()
})

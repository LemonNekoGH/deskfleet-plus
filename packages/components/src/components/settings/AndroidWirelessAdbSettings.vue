<script setup lang="ts">
import type { WirelessAdbState } from "@deskfleet/client/wireless-adb"
import { useEventListener } from "@vueuse/core"
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { useI18n } from "vue-i18n"
import { usePlatformClient } from "../../composables/usePlatformClient.ts"
import UiButton from "../common/UiButton.vue"
import UiField from "../common/UiField.vue"
import UiSwitch from "../common/UiSwitch.vue"
import SettingsRow from "./SettingsRow.vue"

const wirelessAdb = usePlatformClient().wirelessAdb
const { t } = useI18n()

const state = ref<WirelessAdbState | null>(null)
const loading = ref(true)
const busyAction = ref<"status" | "pair" | "connect" | "keepAlive" | "pairingMode" | null>(null)
const requestError = ref<string | null>(null)
const showManualPair = ref(false)
const pairingPortInput = ref("")
const pairingCodeInput = ref("")

const busy = computed(() => loading.value || busyAction.value !== null)
const unprovisioned = computed(() => state.value?.state === "unprovisioned")

const statusColor = computed(() => {
  switch (state.value?.state) {
    case "connected":
      return "ui-status-live text-ui-success"
    case "error":
      return "text-ui-danger"
    default:
      return "text-ui-text-faint"
  }
})

const statusText = computed(() => {
  if (loading.value && !state.value) return t("settings.loading")
  const current = state.value
  if (!current) return t("settings.unavailable")
  const label = t(`settings.wirelessAdb.phase.${current.state}`)
  return current.endpoint ? `${label} (${current.endpoint})` : label
})

let unsubscribe: (() => void) | undefined

async function loadStatus(refresh = false) {
  if (!wirelessAdb) return
  if (!state.value) loading.value = true
  requestError.value = null
  try {
    state.value = await wirelessAdb.status(refresh)
  } catch (error) {
    requestError.value = error instanceof Error ? error.message : String(error)
  } finally {
    loading.value = false
  }
}

async function runAction<T>(
  kind: NonNullable<typeof busyAction.value>,
  action: () => Promise<T>,
  apply?: (result: T) => void,
) {
  if (busy.value) return
  busyAction.value = kind
  requestError.value = null
  try {
    const result = await action()
    apply?.(result)
  } catch (error) {
    requestError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busyAction.value = null
  }
}

function togglePairing() {
  if (!wirelessAdb || !state.value) return
  const stop = state.value.pairingDiscoveryActive
  if (!stop) showManualPair.value = true
  void runAction(
    "pairingMode",
    () => (stop ? wirelessAdb.stopPairing() : wirelessAdb.startPairing()),
    next => { state.value = next },
  )
}

function reconnect() {
  if (!wirelessAdb) return
  void runAction("connect", () => wirelessAdb.connect(), next => { state.value = next })
}

function toggleKeepAlive(enabled: boolean) {
  if (!wirelessAdb) return
  void runAction("keepAlive", () => wirelessAdb.setKeepAlive(enabled), next => { state.value = next })
}

function openDeveloperOptions() {
  if (!wirelessAdb) return
  requestError.value = null
  void wirelessAdb.openDeveloperSettings().catch(error => {
    requestError.value = error instanceof Error ? error.message : String(error)
  })
}

function submitPair() {
  if (!wirelessAdb || busy.value) return
  const parsedPort = Number.parseInt(pairingPortInput.value.trim(), 10)
  const trimmedCode = pairingCodeInput.value.replace(/[\s-]/gu, "")
  if (!Number.isSafeInteger(parsedPort) || parsedPort < 1 || parsedPort > 65535 || !/^\d{4,12}$/u.test(trimmedCode)) {
    requestError.value = t("settings.wirelessAdb.invalidPairInput")
    return
  }
  void runAction(
    "pair",
    () => wirelessAdb.pair(parsedPort, trimmedCode),
    next => {
      state.value = next
      pairingCodeInput.value = ""
      showManualPair.value = false
    },
  )
}

watch(
  () => state.value?.pairingPort,
  port => {
    if (typeof port === "number" && port >= 1 && port <= 65535) {
      pairingPortInput.value = String(port)
      showManualPair.value = true
    }
  },
)

if (wirelessAdb) {
  unsubscribe = wirelessAdb.onStateChanged(next => {
    state.value = next
  })
  useEventListener(window, "focus", () => {
    if (!busy.value) void loadStatus(false)
  })
  onMounted(() => {
    void loadStatus(true)
  })
  onBeforeUnmount(() => {
    unsubscribe?.()
  })
}
</script>

<template>
  <template v-if="wirelessAdb">
    <h2 id="wireless-adb-heading" class="ui-section-title mb-2">{{ t("settings.wirelessAdb.title") }}</h2>
    <div class="ui-card">
      <SettingsRow
        :label="t('settings.wirelessAdb.statusLabel')"
        label-id="wireless-adb-status-label"
        description-id="wireless-adb-status-description"
      >
        <template #description>{{ t("settings.wirelessAdb.statusDescription") }}</template>
        <span class="flex items-center gap-1.5 text-[13px] text-ui-text-muted">
          <span class="ui-status-dot" :class="statusColor" aria-hidden="true" />
          <span role="status" data-wireless-adb-status>{{ statusText }}</span>
        </span>
        <UiButton
          type="button"
          :disabled="busy || unprovisioned"
          :loading="busyAction === 'pairingMode'"
          data-wireless-adb-toggle-pairing
          @click="togglePairing"
        >
          {{ t(state?.pairingDiscoveryActive ? "settings.wirelessAdb.stopPairing" : "settings.wirelessAdb.startPairing") }}
        </UiButton>
        <UiButton type="button" data-wireless-adb-dev-options @click="openDeveloperOptions">
          {{ t("settings.wirelessAdb.openDeveloperOptions") }}
        </UiButton>
        <UiButton
          type="button"
          :disabled="busy || unprovisioned"
          :loading="busyAction === 'connect'"
          data-wireless-adb-reconnect
          @click="reconnect"
        >
          {{ t("settings.wirelessAdb.reconnect") }}
        </UiButton>
        <UiButton
          type="button"
          variant="ghost"
          :disabled="busy || unprovisioned"
          data-wireless-adb-manual-toggle
          @click="showManualPair = !showManualPair"
        >
          {{ t("settings.wirelessAdb.manualPairToggle") }}
        </UiButton>
      </SettingsRow>

      <SettingsRow
        :label="t('settings.wirelessAdb.keepAliveLabel')"
        label-id="wireless-adb-keep-alive-label"
        description-id="wireless-adb-keep-alive-description"
      >
        <template #description>{{ t("settings.wirelessAdb.keepAliveDescription") }}</template>
        <UiSwitch
          aria-labelledby="wireless-adb-keep-alive-label"
          aria-describedby="wireless-adb-keep-alive-description"
          :model-value="state?.keepAliveTcpip5555 ?? false"
          :disabled="busy || !state"
          data-wireless-adb-keep-alive
          @update:model-value="toggleKeepAlive"
        />
      </SettingsRow>

      <form
        v-if="showManualPair"
        class="border-t border-ui-border px-4 py-3"
        data-wireless-adb-pair-form
        @submit.prevent="submitPair"
      >
        <p class="m-0 mb-3 text-[13px] leading-relaxed text-ui-text-muted">
          {{ t("settings.wirelessAdb.pairingHint") }}
        </p>
        <div class="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
          <UiField
            v-model="pairingPortInput"
            :label="t('settings.wirelessAdb.pairingPortLabel')"
            inputmode="numeric"
            placeholder="37123"
            data-wireless-adb-port-input
          />
          <UiField
            v-model="pairingCodeInput"
            :label="t('settings.wirelessAdb.pairingCodeLabel')"
            inputmode="numeric"
            placeholder="123456"
            data-wireless-adb-code-input
          />
          <UiButton
            type="submit"
            variant="primary"
            :disabled="busy || unprovisioned"
            :loading="busyAction === 'pair'"
            data-wireless-adb-pair-submit
          >
            {{ t("settings.wirelessAdb.pairAction") }}
          </UiButton>
        </div>
      </form>

      <p v-if="state?.detail" class="m-0 break-words px-4 pb-3 text-[13px] text-ui-text-muted" data-wireless-adb-detail>
        {{ state.detail }}
      </p>
      <p v-if="requestError" role="alert" class="m-0 break-words px-4 pb-3 text-[13px] text-ui-danger">
        {{ requestError }}
      </p>
    </div>
  </template>
</template>

<script setup lang="ts">
import type { IosScreenShareState } from "@deskfleet/client/ios-screen-share"
import { useEventListener } from "@vueuse/core"
import { computed, onBeforeUnmount, onMounted, ref } from "vue"
import { useI18n } from "vue-i18n"
import { usePlatformClient } from "../../composables/usePlatformClient.ts"
import UiButton from "../common/UiButton.vue"
import SettingsRow from "./SettingsRow.vue"

const iosScreenShare = usePlatformClient().iosScreenShare
const { t } = useI18n()

const state = ref<IosScreenShareState | null>(null)
const loading = ref(true)
const busyAction = ref<"probe" | "broadcast" | null>(null)
const requestError = ref<string | null>(null)

const busy = computed(() => loading.value || busyAction.value !== null)

const statusColor = computed(() => {
  const current = state.value
  if (!current) return "text-ui-text-faint"
  if (current.mode === "coredevice") return "ui-status-live text-ui-success"
  if (current.mode === "replaykit") return "ui-status-live text-ui-accent"
  return "text-ui-text-faint"
})

const statusText = computed(() => {
  if (loading.value && !state.value) return t("settings.loading")
  const current = state.value
  if (!current) return t("settings.unavailable")
  if (current.mode === "coredevice") {
    return current.control
      ? t("settings.iosScreenShare.mode.coredeviceControl")
      : t("settings.iosScreenShare.mode.coredeviceViewOnly")
  }
  if (current.mode === "replaykit") {
    return t("settings.iosScreenShare.mode.replaykit")
  }
  return t("settings.iosScreenShare.mode.unavailable")
})

const coreDeviceStatusText = computed(() => {
  const current = state.value
  if (!current) return t("settings.loading")
  if (current.coreDeviceAvailable) {
    return current.control
      ? t("settings.iosScreenShare.coreDevice.readyControl")
      : t("settings.iosScreenShare.coreDevice.readyViewOnly")
  }
  if (!current.pairingFilePresent) {
    return t("settings.iosScreenShare.coreDevice.missingPairing")
  }
  if (!current.localDevVpnReachable) {
    return t("settings.iosScreenShare.coreDevice.vpnInactive")
  }
  return t("settings.iosScreenShare.coreDevice.unavailable")
})

let unsubscribe: (() => void) | undefined

async function loadStatus(probeCoreDevice = false) {
  if (!iosScreenShare) return
  if (!state.value) loading.value = true
  requestError.value = null
  try {
    state.value = await iosScreenShare.status(probeCoreDevice)
  } catch (error) {
    requestError.value = error instanceof Error ? error.message : String(error)
  } finally {
    loading.value = false
  }
}

async function runAction(
  kind: NonNullable<typeof busyAction.value>,
  action: () => Promise<IosScreenShareState>,
) {
  if (busy.value) return
  busyAction.value = kind
  requestError.value = null
  try {
    state.value = await action()
  } catch (error) {
    requestError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busyAction.value = null
  }
}

function probeCoreDevice() {
  if (!iosScreenShare) return
  void runAction("probe", () => iosScreenShare.probeCoreDevice())
}

function toggleBroadcast() {
  if (!iosScreenShare) return
  const stop = state.value?.replayKitActive ?? false
  void runAction("broadcast", () => (stop ? iosScreenShare.stopBroadcast() : iosScreenShare.startBroadcast()))
}

function openLocalDevVpn() {
  if (!iosScreenShare) return
  requestError.value = null
  void iosScreenShare.openLocalDevVpn().catch(error => {
    requestError.value = error instanceof Error ? error.message : String(error)
  })
}

if (iosScreenShare) {
  unsubscribe = iosScreenShare.onStateChanged(next => {
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
  <template v-if="iosScreenShare">
    <h2 id="ios-screen-share-heading" class="ui-section-title mb-2">{{ t("settings.iosScreenShare.title") }}</h2>
    <div class="ui-card">
      <SettingsRow
        :label="t('settings.iosScreenShare.statusLabel')"
        label-id="ios-screen-share-status-label"
        description-id="ios-screen-share-status-description"
      >
        <template #description>{{ t("settings.iosScreenShare.statusDescription") }}</template>
        <span class="flex items-center gap-1.5 text-[13px] text-ui-text-muted">
          <span class="ui-status-dot" :class="statusColor" aria-hidden="true" />
          <span role="status" data-ios-screen-share-status>{{ statusText }}</span>
        </span>
      </SettingsRow>

      <SettingsRow
        :label="t('settings.iosScreenShare.coreDeviceLabel')"
        label-id="ios-screen-share-coredevice-label"
        description-id="ios-screen-share-coredevice-description"
      >
        <template #description>{{ t("settings.iosScreenShare.coreDeviceDescription") }}</template>
        <span class="text-[13px] text-ui-text-muted" data-ios-screen-share-coredevice-status>
          {{ coreDeviceStatusText }}
        </span>
        <UiButton
          type="button"
          :disabled="busy"
          :loading="busyAction === 'probe'"
          data-ios-screen-share-probe
          @click="probeCoreDevice"
        >
          {{ t("settings.iosScreenShare.probeCoreDevice") }}
        </UiButton>
        <UiButton type="button" data-ios-screen-share-open-vpn @click="openLocalDevVpn">
          {{ t("settings.iosScreenShare.openLocalDevVpn") }}
        </UiButton>
      </SettingsRow>

      <SettingsRow
        :label="t('settings.iosScreenShare.replayKitLabel')"
        label-id="ios-screen-share-replaykit-label"
        description-id="ios-screen-share-replaykit-description"
      >
        <template #description>{{ t("settings.iosScreenShare.replayKitDescription") }}</template>
        <UiButton
          type="button"
          :variant="state?.replayKitActive ? 'ghost' : 'primary'"
          :disabled="busy"
          :loading="busyAction === 'broadcast'"
          data-ios-screen-share-toggle-broadcast
          @click="toggleBroadcast"
        >
          {{ t(state?.replayKitActive ? "settings.iosScreenShare.stopBroadcast" : "settings.iosScreenShare.startBroadcast") }}
        </UiButton>
      </SettingsRow>

      <p v-if="state?.detail" class="m-0 break-words px-4 pb-3 text-[13px] text-ui-text-muted" data-ios-screen-share-detail>
        {{ state.detail }}
      </p>
      <p v-if="requestError" role="alert" class="m-0 break-words px-4 pb-3 text-[13px] text-ui-danger">
        {{ requestError }}
      </p>
    </div>
  </template>
</template>

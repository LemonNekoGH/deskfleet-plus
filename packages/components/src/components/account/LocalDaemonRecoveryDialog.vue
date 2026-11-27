<script setup lang="ts">
import { LoaderCircle, Terminal } from "@lucide/vue"
import { watchImmediate } from "@vueuse/core"
import { DialogDescription, DialogTitle } from "reka-ui"
import { computed, onBeforeUnmount, onMounted, ref, useTemplateRef } from "vue"
import { useI18n } from "vue-i18n"
import { useAccountSession } from "../../composables/useAccountSession.ts"
import { usePlatformClient } from "../../composables/usePlatformClient.ts"
import UiButton from "../common/UiButton.vue"
import UiDialog from "../common/UiDialog.vue"
import TerminalSurface from "../terminal/TerminalSurface.vue"

const props = defineProps<{ initialError?: string }>()
const emit = defineEmits<{ close: []; started: [] }>()

const client = usePlatformClient()
const account = useAccountSession()
const { t } = useI18n()

const dialog = useTemplateRef<InstanceType<typeof UiDialog>>("dialog")
const localTerminal = useTemplateRef<InstanceType<typeof TerminalSurface>>("localTerminal")

const pending = ref(false)
const error = ref<string | undefined>(props.initialError)
const localOutput = ref("")
const textEncoder = new TextEncoder()
let renderedLocalOutput = ""
let stopOutput: (() => void) | undefined

const showTerminal = computed(() => pending.value || localOutput.value.length > 0)

watchImmediate([localTerminal, localOutput], ([surface, output], [previousSurface]) => {
  if (!surface) {
    renderedLocalOutput = ""
    return
  }
  if (surface !== previousSurface) renderedLocalOutput = ""
  if (!output.startsWith(renderedLocalOutput)) {
    surface.reset()
    renderedLocalOutput = ""
  }
  if (output.length > renderedLocalOutput.length) {
    surface.write(textEncoder.encode(output.slice(renderedLocalOutput.length)))
  }
  renderedLocalOutput = output
}, { flush: "post" })

function close(): void {
  if (!pending.value) dialog.value?.close()
}

async function startDaemon(): Promise<void> {
  const control = client.localDaemon
  if (!control || pending.value) return
  pending.value = true
  error.value = undefined
  localOutput.value = ""
  renderedLocalOutput = ""
  localTerminal.value?.reset()
  stopOutput?.()
  stopOutput = control.onOutput?.(chunk => {
    localOutput.value += chunk
  })
  try {
    const next = await control.start()
    if (next.status === "running") {
      await Promise.allSettled([
        account?.refreshMachines(),
        client.probeLocalDaemonSettings?.(),
      ])
      emit("started")
      dialog.value?.close()
    } else if (next.error) {
      error.value = next.error
    } else {
      error.value = t("localDaemon.startFailed")
    }
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : String(reason)
  } finally {
    stopOutput?.()
    stopOutput = undefined
    pending.value = false
  }
}

onMounted(async () => {
  try {
    const previous = await client.localDaemon?.recentOutput?.()
    if (previous && !localOutput.value) {
      localOutput.value = previous
    }
  } catch {
    // Ignore transient log-read errors; fresh output will stream on start.
  }
})

onBeforeUnmount(() => {
  stopOutput?.()
  stopOutput = undefined
})
</script>

<template>
  <UiDialog
    ref="dialog"
    :class="showTerminal ? 'w-[min(48rem,calc(100vw-2rem))]' : 'w-[34rem]'"
    described
    :prevent-close="pending"
    @close="emit('close')"
  >
    <DialogTitle class="ui-dialog-title">{{ t("localDaemon.recoveryTitle") }}</DialogTitle>
    <DialogDescription class="ui-dialog-description mb-5">{{ t("localDaemon.recoveryDescription") }}</DialogDescription>

    <div class="flex flex-col gap-5" data-local-daemon-recovery>
      <section
        v-if="showTerminal"
        class="flex flex-col overflow-hidden rounded-xl border border-ui-border text-sm"
        data-local-daemon-recovery-setup
      >
        <div class="flex items-center gap-2 border-b border-ui-border px-3 py-2 text-xs text-ui-text-muted">
          <LoaderCircle v-if="pending" :size="14" :stroke-width="2" class="shrink-0 animate-spin" aria-hidden="true" />
          <Terminal v-else :size="14" :stroke-width="1.75" class="shrink-0" aria-hidden="true" />
          <span role="status" class="min-w-0 flex-1 truncate">{{ t(pending ? "addMachine.localProgress" : "addMachine.localOutput") }}</span>
        </div>
        <div class="flex h-64 min-h-0 bg-ui-terminal sm:h-80" data-local-daemon-recovery-terminal>
          <TerminalSurface ref="localTerminal" tools convert-eol />
        </div>
      </section>

      <p v-if="error" role="alert" class="m-0 text-sm text-ui-danger">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <UiButton type="button" :disabled="pending" @click="close">{{ t("catalog.cancel") }}</UiButton>
        <UiButton
          variant="primary"
          type="button"
          :loading="pending"
          :disabled="pending || !client.localDaemon"
          data-local-daemon-start
          @click="startDaemon"
        >
          {{ pending ? t("localDaemon.starting") : t("localDaemon.startAction") }}
        </UiButton>
      </div>
    </div>
  </UiDialog>
</template>

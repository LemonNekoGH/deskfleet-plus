import { computed, onBeforeUnmount, onMounted, ref, watch, type ComputedRef } from "vue"
import { useAccountSession } from "./useAccountSession.ts"
import { usePlatformClient } from "./usePlatformClient.ts"

/**
 * Reports whether this host currently exposes local daemon host settings
 * (`remoteAgents`, `worktrees`, etc.). Desktop hosts always do; mobile hosts
 * with an embedded daemon probe the local daemon CLI on demand.
 */
export function useLocalDaemonSettings(): ComputedRef<boolean> {
  const client = usePlatformClient()
  const session = useAccountSession()
  const probed = ref(false)
  let revision = 0

  async function probe(): Promise<void> {
    const check = client.probeLocalDaemonSettings
    if (client.platform !== "web" || !check) return
    const current = ++revision
    let available = false
    try {
      available = await check()
    } catch {
      available = false
    }
    if (revision === current) probed.value = available
  }

  if (client.platform === "web" && client.probeLocalDaemonSettings) {
    onMounted(() => { void probe() })
    watch(() => session?.localMachineId?.value, () => { void probe() })
    if (client.localDaemon) {
      const stop = client.settings.onChanged(state => {
        if (state.status === "running" || state.status === "stopped") {
          void probe()
        }
      })
      onBeforeUnmount(stop)
    }
  }

  return computed(() => client.platform !== "web" || (Boolean(client.probeLocalDaemonSettings) && probed.value))
}

import type { PluginListenerHandle } from "@capacitor/core"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import type { RemoteAgentSettings, SettingsApi } from "@deskfleet/client/settings"

export type PreparedEnrollment = LocalEnrollment & { identityToken: string }

export interface LocalDaemonBridgePlugin {
  localDaemonStatus(): Promise<LocalMachineStatus>
  localDaemonPrepareEnrollment(options: { serverUrl: string; teamId: string }): Promise<PreparedEnrollment>
  localDaemonEnroll(options: {
    serverUrl: string
    machineId: string
    teamId: string
    token: string
    originId: string
  }): Promise<LocalEnrollment>
  addListener?(
    eventName: "localDaemonLog",
    listenerFunc: (data: { chunk: string }) => void,
  ): Promise<PluginListenerHandle>
}

export interface RemoteAgentSettingsBridgePlugin {
  localDaemonGetRemoteAgentSettings(): Promise<RemoteAgentSettings>
  localDaemonSetRemoteAgentSettings(settings: RemoteAgentSettings): Promise<RemoteAgentSettings>
}

function normalizeRemoteAgentSettings(value: RemoteAgentSettings): RemoteAgentSettings {
  return {
    allowRead: Boolean(value.allowRead),
    allowOperate: Boolean(value.allowOperate),
    allowSessions: Boolean(value.allowSessions),
    allowWorkspaces: Boolean(value.allowWorkspaces),
    allowSuperAgent: Boolean(value.allowSuperAgent),
    allowLocalCrossWorkspace: Boolean(value.allowLocalCrossWorkspace),
  }
}

export function createAndroidRemoteAgentSettings(
  plugin: RemoteAgentSettingsBridgePlugin,
): Pick<SettingsApi, "getRemoteAgentSettings" | "setRemoteAgentSettings"> {
  return {
    async getRemoteAgentSettings(): Promise<RemoteAgentSettings> {
      return normalizeRemoteAgentSettings(await plugin.localDaemonGetRemoteAgentSettings())
    },
    async setRemoteAgentSettings(settings: RemoteAgentSettings): Promise<RemoteAgentSettings> {
      const normalized = normalizeRemoteAgentSettings(settings)
      return normalizeRemoteAgentSettings(await plugin.localDaemonSetRemoteAgentSettings(normalized))
    },
  }
}

/**
 * Attach local-machine enrollment to an Android CentralApi using the embedded
 * proot Linux container managed by the native Capacitor bridge.
 */
export function attachAndroidLocalEnrollment(
  central: CentralApi,
  plugin: LocalDaemonBridgePlugin,
): void {
  const outputListeners = new Set<(chunk: string) => void>()
  const emitOutput = (chunk: string) => {
    if (!chunk) return
    for (const listener of outputListeners) listener(chunk)
  }

  const localEnrollment = (): Promise<LocalMachineStatus> => plugin.localDaemonStatus()

  const enrollLocal = async (teamId: string, name?: string): Promise<LocalEnrollment> => {
    const chosen = typeof name === "string" ? name.trim() : undefined
    if (name !== undefined && chosen === undefined) {
      throw new Error("Invalid machine name")
    }
    const logListener = await plugin.addListener?.("localDaemonLog", ({ chunk }) => emitOutput(chunk))
    try {
      emitOutput("\u001b[1;36m==> Checking local daemon status...\u001b[0m\n")
      const { serverUrl } = await central.status()
      const current = (await localEnrollment()).registrations.find(
        value => value.serverUrl === serverUrl && value.teamId === teamId,
      )
      if (current?.configured && !current.revoked) {
        emitOutput("\u001b[1;32m✓ Local daemon is already enrolled for this team.\u001b[0m\n")
        return current
      }
      const prepared = await plugin.localDaemonPrepareEnrollment({ serverUrl, teamId })
      const machineName = chosen || prepared.machineName
      emitOutput(`\u001b[1;36m==> Registering "${machineName}" with ${serverUrl}...\u001b[0m\n`)
      const result = await central.enrollHeadless(teamId, {
        name: machineName,
        originId: prepared.identity.originId,
        localMachineId: prepared.identity.machineId,
        identityToken: prepared.identityToken,
      })
      const enrolled = await plugin.localDaemonEnroll({
        serverUrl,
        machineId: result.machine.id,
        teamId,
        token: result.token,
        originId: prepared.identity.originId,
      })
      emitOutput("\u001b[1;32m✓ Connected to team.\u001b[0m\n")
      return enrolled
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error)
      emitOutput(`\u001b[1;31m✗ ${detail}\u001b[0m\n`)
      throw error
    } finally {
      await logListener?.remove().catch(() => {})
    }
  }

  central.localEnrollment = localEnrollment
  central.enrollLocal = enrollLocal
  central.onLocalEnrollmentOutput = listener => {
    outputListeners.add(listener)
    return () => { outputListeners.delete(listener) }
  }
}

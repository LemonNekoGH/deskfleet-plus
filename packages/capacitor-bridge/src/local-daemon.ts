import type { PluginListenerHandle } from "@capacitor/core"
import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"
import type { SettingsApi } from "@deskfleet/client/settings"
import { remoteAgentSettings } from "@deskfleet/protocol/remote-agent-settings"
import { validateWorktreePreferences } from "@deskfleet/protocol/worktree-preferences"

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

export interface LocalDaemonSettingsBridgePlugin {
  /** Runs `deskfleet-daemon settings <...args>` and returns its parsed JSON object output. */
  localDaemonSettings(options: { args: string[] }): Promise<Record<string, unknown>>
}

export interface LocalDaemonHostSettings {
  probeLocalDaemonSettings(): Promise<boolean>
  settings: Pick<
    SettingsApi,
    "getRemoteAgentSettings" | "setRemoteAgentSettings" | "getWorktreePreferences" | "setWorktreePreferences"
  >
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}

function diffLeaves(prefix: string, prev: Record<string, unknown>, next: Record<string, unknown>): [string, string][] {
  const updates: [string, string][] = []
  for (const [key, value] of Object.entries(next)) {
    const path = `${prefix}.${key}`
    if (isPlainRecord(value) && isPlainRecord(prev[key])) {
      updates.push(...diffLeaves(path, prev[key], value))
    } else if (value !== prev[key]) {
      updates.push([path, String(value)])
    }
  }
  return updates
}

/**
 * Exposes CLI-backed local daemon host settings (`deskfleet-daemon settings`)
 * across mobile hosts (Android proot, iOS RVVM) via a single native bridge call.
 */
export function createLocalDaemonHostSettings(
  plugin: LocalDaemonSettingsBridgePlugin,
): LocalDaemonHostSettings {
  let inFlightProbe: Promise<boolean> | undefined

  const readSection = async <T>(section: string, parse: (value: unknown) => T): Promise<T> =>
    parse(await plugin.localDaemonSettings({ args: ["get", section] }))

  const writeSection = async <T extends object>(section: string, next: T, parse: (value: unknown) => T): Promise<T> => {
    const target = parse(next)
    const current: T = await readSection(section, parse)
    const updates = diffLeaves(section, current as Record<string, unknown>, target as Record<string, unknown>)
    let latest: T = current
    for (const [key, value] of updates) {
      latest = parse(await plugin.localDaemonSettings({ args: ["set", key, value] }))
    }
    return latest
  }

  return {
    probeLocalDaemonSettings(): Promise<boolean> {
      return (inFlightProbe ??= plugin
        .localDaemonSettings({ args: ["get"] })
        .then(snapshot => {
          remoteAgentSettings(snapshot.remoteAgents)
          validateWorktreePreferences(snapshot.worktrees)
          return true
        })
        .catch(() => false)
        .finally(() => { inFlightProbe = undefined }))
    },
    settings: {
      getRemoteAgentSettings: () => readSection("remoteAgents", remoteAgentSettings),
      setRemoteAgentSettings: next => writeSection("remoteAgents", next, remoteAgentSettings),
      getWorktreePreferences: () => readSection("worktrees", validateWorktreePreferences),
      setWorktreePreferences: next => writeSection("worktrees", next, validateWorktreePreferences),
    },
  }
}

/**
 * Attach local-machine enrollment to a mobile CentralApi using the embedded
 * Linux runtime managed by the native Capacitor bridge (proot on Android,
 * librvvm on iOS).
 */
export function attachLocalEnrollment(
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

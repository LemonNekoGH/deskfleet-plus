import type { CentralApi, LocalEnrollment, LocalMachineStatus } from "@deskfleet/client/central"

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
}

/**
 * Attach local-machine enrollment to an Android CentralApi using the embedded
 * proot Linux container managed by the native Capacitor bridge.
 */
export function attachAndroidLocalEnrollment(
  central: CentralApi,
  plugin: LocalDaemonBridgePlugin,
): void {
  const localEnrollment = (): Promise<LocalMachineStatus> => plugin.localDaemonStatus()

  const enrollLocal = async (teamId: string, name?: string): Promise<LocalEnrollment> => {
    const chosen = typeof name === "string" ? name.trim() : undefined
    if (name !== undefined && chosen === undefined) {
      throw new Error("Invalid machine name")
    }
    const { serverUrl } = await central.status()
    const current = (await localEnrollment()).registrations.find(
      value => value.serverUrl === serverUrl && value.teamId === teamId,
    )
    if (current?.configured && !current.revoked) {
      return current
    }
    const prepared = await plugin.localDaemonPrepareEnrollment({ serverUrl, teamId })
    const result = await central.enrollHeadless(teamId, {
      name: chosen || prepared.machineName,
      originId: prepared.identity.originId,
      localMachineId: prepared.identity.machineId,
      identityToken: prepared.identityToken,
    })
    return plugin.localDaemonEnroll({
      serverUrl,
      machineId: result.machine.id,
      teamId,
      token: result.token,
      originId: prepared.identity.originId,
    })
  }

  central.localEnrollment = localEnrollment
  central.enrollLocal = enrollLocal
}

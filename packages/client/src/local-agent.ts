import type { DesktopPermissionsState } from "@deskfleet/protocol/control"

export type { DesktopPermission, DesktopPermissionKind, DesktopPermissionsState } from "@deskfleet/protocol/control"

export interface LocalAgentState extends Partial<DesktopPermissionsState> {
  enabled: boolean
  status: "stopped" | "starting" | "running" | "stopping" | "error"
  error?: string
}

export interface LocalAgentSettingsApi {
  get(): Promise<LocalAgentState>
  setLocalAgentEnabled(enabled: boolean): Promise<LocalAgentState>
  onChanged(listener: (state: LocalAgentState) => void): () => void
}

export interface LocalDaemonControlApi {
  /** Starts or retries the embedded local daemon without re-pairing the machine. */
  start(): Promise<LocalAgentState>
  /** Returns buffered ANSI startup output from the most recent startup attempt. */
  recentOutput?(): Promise<string>
  /** Subscribes to live ANSI startup output chunks from the embedded local daemon. */
  onOutput?: (listener: (chunk: string) => void) => () => void
}

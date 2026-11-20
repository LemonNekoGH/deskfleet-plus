export type WirelessAdbPhase =
  | "unprovisioned"
  | "disconnected"
  | "pairing"
  | "connecting"
  | "connected"
  | "error"

export interface WirelessAdbState {
  state: WirelessAdbPhase
  endpoint?: string
  tcpip5555Active: boolean
  keepAliveTcpip5555: boolean
  pairingDiscoveryActive: boolean
  pairingPort?: number
  connectPort?: number
  detail?: string
}

export interface WirelessAdbApi {
  status(refresh?: boolean): Promise<WirelessAdbState>
  startPairing(): Promise<WirelessAdbState>
  stopPairing(): Promise<WirelessAdbState>
  pair(port: number, code: string): Promise<WirelessAdbState>
  connect(port?: number): Promise<WirelessAdbState>
  setKeepAlive(enabled: boolean): Promise<WirelessAdbState>
  openDeveloperSettings(): Promise<void>
  onStateChanged(listener: (state: WirelessAdbState) => void): () => void
}

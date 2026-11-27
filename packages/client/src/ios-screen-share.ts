export type IosScreenShareMode = "coredevice" | "replaykit" | "unavailable"

export interface IosScreenShareState {
  mode: IosScreenShareMode
  available: boolean
  control: boolean
  pasteboard: boolean
  pairingFilePresent: boolean
  localDevVpnReachable: boolean
  coreDeviceAvailable: boolean
  replayKitActive: boolean
  width: number
  height: number
  codecs: string[]
  detail?: string
}

export interface IosScreenShareApi {
  status(probeCoreDevice?: boolean): Promise<IosScreenShareState>
  probeCoreDevice(): Promise<IosScreenShareState>
  startBroadcast(): Promise<IosScreenShareState>
  stopBroadcast(): Promise<IosScreenShareState>
  openLocalDevVpn(): Promise<void>
  onStateChanged(listener: (state: IosScreenShareState) => void): () => void
}

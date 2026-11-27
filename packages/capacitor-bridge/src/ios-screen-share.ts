import type { PluginListenerHandle } from "@capacitor/core"
import type { IosScreenShareApi, IosScreenShareState } from "@deskfleet/client/ios-screen-share"

export interface IosScreenShareBridgePlugin {
  iosScreenShareStatus(options?: { probeCoreDevice?: boolean }): Promise<IosScreenShareState>
  iosScreenShareProbeCoreDevice(): Promise<IosScreenShareState>
  iosScreenShareStartBroadcast(): Promise<IosScreenShareState>
  iosScreenShareStopBroadcast(): Promise<IosScreenShareState>
  iosScreenShareOpenLocalDevVpn(): Promise<void>
  addListener(
    eventName: "iosScreenShareState",
    listenerFunc: (state: IosScreenShareState) => void,
  ): Promise<PluginListenerHandle>
}

export function createCapacitorIosScreenShareApi(
  plugin: IosScreenShareBridgePlugin,
): IosScreenShareApi {
  return {
    status: (probeCoreDevice = false) => plugin.iosScreenShareStatus({ probeCoreDevice }),
    probeCoreDevice: () => plugin.iosScreenShareProbeCoreDevice(),
    startBroadcast: () => plugin.iosScreenShareStartBroadcast(),
    stopBroadcast: () => plugin.iosScreenShareStopBroadcast(),
    openLocalDevVpn: () => plugin.iosScreenShareOpenLocalDevVpn(),
    onStateChanged(listener: (state: IosScreenShareState) => void): () => void {
      let subscribed = true
      const handle = plugin.addListener("iosScreenShareState", state => {
        if (subscribed) listener(state)
      })
      return () => {
        subscribed = false
        void handle.then(item => item.remove()).catch(() => {})
      }
    },
  }
}

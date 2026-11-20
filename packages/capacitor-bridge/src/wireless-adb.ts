import type { PluginListenerHandle } from "@capacitor/core"
import type { WirelessAdbApi, WirelessAdbState } from "@deskfleet/client/wireless-adb"

export interface WirelessAdbBridgePlugin {
  wirelessAdbStatus(options?: { refresh?: boolean }): Promise<WirelessAdbState>
  wirelessAdbStartPairing(): Promise<WirelessAdbState>
  wirelessAdbStopPairing(): Promise<WirelessAdbState>
  wirelessAdbPair(options: { port: number; code: string }): Promise<WirelessAdbState>
  wirelessAdbConnect(options?: { port?: number }): Promise<WirelessAdbState>
  wirelessAdbSetKeepAlive(options: { enabled: boolean }): Promise<WirelessAdbState>
  wirelessAdbOpenDeveloperSettings(): Promise<void>
  addListener(
    eventName: "wirelessAdbState",
    listenerFunc: (state: WirelessAdbState) => void,
  ): Promise<PluginListenerHandle>
}

function validatePort(port: number): number {
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new Error("Wireless ADB port must be between 1 and 65535")
  }
  return port
}

function validatePairingCode(code: string): string {
  const digits = code.replace(/[\s-]/gu, "")
  if (!/^\d{4,12}$/u.test(digits)) {
    throw new Error("Wireless ADB pairing code must be numeric")
  }
  return digits
}

export function createCapacitorWirelessAdbApi(plugin: WirelessAdbBridgePlugin): WirelessAdbApi {
  return {
    status: (refresh = false) => plugin.wirelessAdbStatus({ refresh }),
    startPairing: () => plugin.wirelessAdbStartPairing(),
    stopPairing: () => plugin.wirelessAdbStopPairing(),
    pair: (port: number, code: string) =>
      plugin.wirelessAdbPair({ port: validatePort(port), code: validatePairingCode(code) }),
    connect: (port?: number) =>
      plugin.wirelessAdbConnect(port === undefined ? {} : { port: validatePort(port) }),
    setKeepAlive: (enabled: boolean) => plugin.wirelessAdbSetKeepAlive({ enabled }),
    openDeveloperSettings: () => plugin.wirelessAdbOpenDeveloperSettings(),
    onStateChanged(listener: (state: WirelessAdbState) => void): () => void {
      let subscribed = true
      const handle = plugin.addListener("wirelessAdbState", state => {
        if (subscribed) listener(state)
      })
      return () => {
        subscribed = false
        void handle.then(item => item.remove()).catch(() => {})
      }
    },
  }
}

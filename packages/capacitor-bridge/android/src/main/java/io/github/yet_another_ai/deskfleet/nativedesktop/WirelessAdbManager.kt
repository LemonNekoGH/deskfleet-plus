package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

internal data class AdbDevice(
    val serial: String,
    val state: String,
)

internal enum class WirelessAdbPhase(val wireValue: String) {
    UNPROVISIONED("unprovisioned"),
    DISCONNECTED("disconnected"),
    PAIRING("pairing"),
    CONNECTING("connecting"),
    CONNECTED("connected"),
    ERROR("error"),
}

internal data class WirelessAdbState(
    val phase: WirelessAdbPhase,
    val endpoint: String? = null,
    val tcpip5555Active: Boolean = false,
    val keepAliveTcpip5555: Boolean = false,
    val pairingDiscoveryActive: Boolean = false,
    val pairingPort: Int? = null,
    val connectPort: Int? = null,
    val detail: String? = null,
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
            .put("state", phase.wireValue)
            .put("tcpip5555Active", tcpip5555Active)
            .put("keepAliveTcpip5555", keepAliveTcpip5555)
            .put("pairingDiscoveryActive", pairingDiscoveryActive)
        if (endpoint != null) json.put("endpoint", endpoint)
        if (pairingPort != null) json.put("pairingPort", pairingPort)
        if (connectPort != null) json.put("connectPort", connectPort)
        if (detail != null) json.put("detail", detail)
        return json
    }
}

internal interface WirelessAdbCommandRunner {
    fun isAdbAvailable(): Boolean
    fun runAdb(vararg args: String): ShellResult
    fun refreshDaemonCapabilities()
}

internal interface WirelessAdbNotifier {
    fun showSearchingPairingNotification()
    fun showPairingCodePrompt(port: Int)
    fun showPairingProgress(port: Int)
    fun showPairingSucceeded(endpoint: String?)
    fun showPairingFailed(message: String)
    fun dismissPairingNotification()
}

/**
 * Coordinates wireless ADB pairing, TLS reconnection, optional `tcpip 5555` keep-alive,
 * and stale `offline` device cleanup inside the embedded Linux container.
 */
internal class WirelessAdbManager(
    filesDir: File,
    private val commandRunner: WirelessAdbCommandRunner,
    private val notifier: WirelessAdbNotifier,
    private val sleepMillis: (Long) -> Unit = Thread::sleep,
) {
    private val baseDir = File(filesDir, "linux")
    private val configFile = File(baseDir, CONFIG_FILENAME)
    private val operationLock = Any()
    private val listeners = CopyOnWriteArrayList<(WirelessAdbState) -> Unit>()

    @Volatile
    private var state: WirelessAdbState = WirelessAdbState(
        phase = if (commandRunner.isAdbAvailable()) WirelessAdbPhase.DISCONNECTED else WirelessAdbPhase.UNPROVISIONED,
        keepAliveTcpip5555 = loadKeepAlivePreference(),
    )

    fun currentState(): WirelessAdbState = state

    fun addStateListener(listener: (WirelessAdbState) -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    fun setKeepAliveTcpip5555(enabled: Boolean): WirelessAdbState = synchronized(operationLock) {
        saveKeepAlivePreference(enabled)
        updateState { it.copy(keepAliveTcpip5555 = enabled) }
        reconcileLocked(forceCapabilityRefresh = false)
    }

    fun setPairingDiscoveryActive(active: Boolean): WirelessAdbState = synchronized(operationLock) {
        val next = updateState {
            it.copy(
                pairingDiscoveryActive = active,
                pairingPort = if (active) it.pairingPort else null,
            )
        }
        if (active) {
            val port = next.pairingPort
            if (port != null) notifier.showPairingCodePrompt(port)
            else notifier.showSearchingPairingNotification()
        } else {
            notifier.dismissPairingNotification()
        }
        next
    }

    fun onPairingServiceFound(port: Int): WirelessAdbState = synchronized(operationLock) {
        val validPort = sanitizePort(port)
        val next = updateState { it.copy(pairingPort = validPort) }
        if (next.pairingDiscoveryActive || commandRunner.isAdbAvailable()) {
            notifier.showPairingCodePrompt(validPort)
        }
        next
    }

    fun onPairingServiceLost(port: Int?): WirelessAdbState = synchronized(operationLock) {
        val current = state
        if (port != null && current.pairingPort != port) {
            return current
        }
        val next = updateState { it.copy(pairingPort = null) }
        if (next.pairingDiscoveryActive) {
            notifier.showSearchingPairingNotification()
        } else {
            notifier.dismissPairingNotification()
        }
        next
    }

    fun onConnectServiceFound(port: Int): WirelessAdbState = synchronized(operationLock) {
        val validPort = sanitizePort(port)
        updateState { it.copy(connectPort = validPort) }
        reconcileLocked(forceCapabilityRefresh = false)
    }

    fun onConnectServiceLost(port: Int?): WirelessAdbState = synchronized(operationLock) {
        val current = state
        if (port != null && current.connectPort != port) {
            return current
        }
        updateState { it.copy(connectPort = null) }
        reconcileLocked(forceCapabilityRefresh = false)
    }

    fun onNetworkChanged(): WirelessAdbState = synchronized(operationLock) {
        reconcileLocked(forceCapabilityRefresh = false)
    }

    fun pair(port: Int, code: String): WirelessAdbState = synchronized(operationLock) {
        val validPort = sanitizePort(port)
        val cleanCode = sanitizePairingCode(code)
        if (!commandRunner.isAdbAvailable()) {
            val message = "Local Linux container is not provisioned yet. Add this device as a machine first."
            updateState { it.copy(phase = WirelessAdbPhase.UNPROVISIONED, detail = message) }
            notifier.showPairingFailed(message)
            throw IllegalStateException(message)
        }

        updateState {
            it.copy(
                phase = WirelessAdbPhase.PAIRING,
                pairingPort = validPort,
                detail = null,
            )
        }
        notifier.showPairingProgress(validPort)

        val result = commandRunner.runAdb("pair", "127.0.0.1:$validPort", cleanCode)
        val combined = listOf(result.stdout, result.stderr)
            .filter { it.isNotBlank() }
            .joinToString("\n")
            .trim()
        val failed = result.exitCode != 0 ||
            combined.contains("failed:", ignoreCase = true) ||
            combined.isEmpty()

        if (failed) {
            val rawMessage = combined.ifEmpty { "ADB pairing failed (exit code ${result.exitCode})" }
            val safeMessage = redactCode(rawMessage, cleanCode)
            updateState {
                it.copy(
                    phase = WirelessAdbPhase.ERROR,
                    detail = safeMessage,
                )
            }
            notifier.showPairingFailed(safeMessage)
            throw IllegalStateException(safeMessage)
        }

        updateState {
            it.copy(
                pairingDiscoveryActive = false,
                pairingPort = null,
                detail = null,
            )
        }
        val reconciled = reconcileLocked(forceCapabilityRefresh = true)
        notifier.showPairingSucceeded(reconciled.endpoint)
        reconciled
    }

    fun connect(port: Int? = null): WirelessAdbState = synchronized(operationLock) {
        if (!commandRunner.isAdbAvailable()) {
            val message = "Local Linux container is not provisioned yet. Add this device as a machine first."
            return updateState {
                it.copy(
                    phase = WirelessAdbPhase.UNPROVISIONED,
                    endpoint = null,
                    tcpip5555Active = false,
                    detail = message,
                )
            }
        }

        if (port != null) {
            val validPort = sanitizePort(port)
            val endpoint = "127.0.0.1:$validPort"
            updateState {
                it.copy(
                    phase = WirelessAdbPhase.CONNECTING,
                    connectPort = validPort,
                    endpoint = endpoint,
                    detail = null,
                )
            }
            val attempt = connectAndVerify(endpoint)
            if (attempt.connectedSerial == null) {
                val message = attempt.error ?: "Failed to connect to $endpoint"
                updateState {
                    it.copy(
                        phase = WirelessAdbPhase.ERROR,
                        endpoint = null,
                        tcpip5555Active = false,
                        detail = message,
                    )
                }
                throw IllegalStateException(message)
            }
            return completeConnection(attempt.connectedSerial, forceCapabilityRefresh = true)
        }

        reconcileLocked(forceCapabilityRefresh = true)
    }

    fun reconcile(forceCapabilityRefresh: Boolean = false): WirelessAdbState = synchronized(operationLock) {
        reconcileLocked(forceCapabilityRefresh)
    }

    private fun reconcileLocked(forceCapabilityRefresh: Boolean): WirelessAdbState {
        val previous = state
        if (!commandRunner.isAdbAvailable()) {
            return updateState {
                it.copy(
                    phase = WirelessAdbPhase.UNPROVISIONED,
                    endpoint = null,
                    tcpip5555Active = false,
                )
            }
        }

        val currentDevices = listAdbDevices()
        val healthySerial = findSingleHealthyDevice(currentDevices)
        if (healthySerial != null) {
            return if (previous.keepAliveTcpip5555 && healthySerial != TCPIP_ENDPOINT) {
                completeConnection(healthySerial, forceCapabilityRefresh = forceCapabilityRefresh || previous.phase != WirelessAdbPhase.CONNECTED)
            } else {
                val next = updateState {
                    it.copy(
                        phase = WirelessAdbPhase.CONNECTED,
                        endpoint = healthySerial,
                        tcpip5555Active = healthySerial == TCPIP_ENDPOINT,
                        detail = null,
                    )
                }
                if (previous.phase != WirelessAdbPhase.CONNECTED || forceCapabilityRefresh) {
                    commandRunner.refreshDaemonCapabilities()
                }
                next
            }
        }

        if (currentDevices.isNotEmpty()) {
            // Clear stale offline/duplicate entries so android_scrcpy.rs sees one target.
            commandRunner.runAdb("disconnect")
        }

        var failureDetail: String? = null
        val connectPort = state.connectPort
        if (state.keepAliveTcpip5555 || connectPort == null) {
            updateState {
                it.copy(
                    phase = WirelessAdbPhase.CONNECTING,
                    endpoint = TCPIP_ENDPOINT,
                    tcpip5555Active = false,
                )
            }
            val tcpipAttempt = connectAndVerify(TCPIP_ENDPOINT)
            if (tcpipAttempt.connectedSerial != null) {
                return completeConnection(tcpipAttempt.connectedSerial, forceCapabilityRefresh = true)
            }
            if (state.keepAliveTcpip5555) {
                failureDetail = tcpipAttempt.error
            }
        }

        if (connectPort != null) {
            val tlsEndpoint = "127.0.0.1:$connectPort"
            updateState {
                it.copy(
                    phase = WirelessAdbPhase.CONNECTING,
                    endpoint = tlsEndpoint,
                    tcpip5555Active = false,
                )
            }
            val tlsAttempt = connectAndVerify(tlsEndpoint)
            if (tlsAttempt.connectedSerial != null) {
                return completeConnection(tlsAttempt.connectedSerial, forceCapabilityRefresh = true)
            }
            failureDetail = tlsAttempt.error ?: failureDetail
        }

        val next = updateState {
            it.copy(
                phase = WirelessAdbPhase.DISCONNECTED,
                endpoint = null,
                tcpip5555Active = false,
                detail = failureDetail,
            )
        }
        if (previous.phase == WirelessAdbPhase.CONNECTED || forceCapabilityRefresh) {
            commandRunner.refreshDaemonCapabilities()
        }
        return next
    }

    private fun completeConnection(serial: String, forceCapabilityRefresh: Boolean): WirelessAdbState {
        val previous = state
        if (previous.keepAliveTcpip5555 && serial != TCPIP_ENDPOINT) {
            val upgrade = upgradeToTcpip5555(serial)
            if (upgrade.upgraded) {
                val next = updateState {
                    it.copy(
                        phase = WirelessAdbPhase.CONNECTED,
                        endpoint = TCPIP_ENDPOINT,
                        tcpip5555Active = true,
                        detail = null,
                    )
                }
                if (previous.phase != WirelessAdbPhase.CONNECTED || previous.endpoint != TCPIP_ENDPOINT || forceCapabilityRefresh) {
                    commandRunner.refreshDaemonCapabilities()
                }
                return next
            }
            val reconnected = connectAndVerify(serial)
            if (reconnected.connectedSerial != null) {
                val next = updateState {
                    it.copy(
                        phase = WirelessAdbPhase.CONNECTED,
                        endpoint = reconnected.connectedSerial,
                        tcpip5555Active = reconnected.connectedSerial == TCPIP_ENDPOINT,
                        detail = upgrade.detail,
                    )
                }
                if (previous.phase != WirelessAdbPhase.CONNECTED || forceCapabilityRefresh) {
                    commandRunner.refreshDaemonCapabilities()
                }
                return next
            }
        }

        val next = updateState {
            it.copy(
                phase = WirelessAdbPhase.CONNECTED,
                endpoint = serial,
                tcpip5555Active = serial == TCPIP_ENDPOINT,
                detail = null,
            )
        }
        if (previous.phase != WirelessAdbPhase.CONNECTED || previous.endpoint != serial || forceCapabilityRefresh) {
            commandRunner.refreshDaemonCapabilities()
        }
        return next
    }

    private data class ConnectAttempt(
        val connectedSerial: String?,
        val error: String?,
    )

    private data class TcpipUpgradeResult(
        val upgraded: Boolean,
        val detail: String?,
    )

    private fun connectAndVerify(endpoint: String): ConnectAttempt {
        commandRunner.runAdb("disconnect")
        val result = commandRunner.runAdb("connect", endpoint)
        val combined = listOf(result.stdout, result.stderr)
            .filter { it.isNotBlank() }
            .joinToString("\n")
            .trim()
        val devices = listAdbDevices()
        val serial = findSingleHealthyDevice(devices)
        if (serial != null) {
            return ConnectAttempt(connectedSerial = serial, error = null)
        }
        if (devices.isNotEmpty()) {
            commandRunner.runAdb("disconnect")
        }
        return ConnectAttempt(
            connectedSerial = null,
            error = combined.ifEmpty { "Could not connect to $endpoint" },
        )
    }

    private fun upgradeToTcpip5555(sourceSerial: String): TcpipUpgradeResult {
        val switchResult = commandRunner.runAdb("-s", sourceSerial, "tcpip", TCPIP_PORT.toString())
        val switchMsg = listOf(switchResult.stdout, switchResult.stderr)
            .filter { it.isNotBlank() }
            .joinToString("\n")
            .trim()
        if (switchResult.exitCode != 0) {
            return TcpipUpgradeResult(
                upgraded = false,
                detail = "Connected over wireless debugging; adb tcpip 5555 failed (${switchMsg.ifEmpty { "exit code ${switchResult.exitCode}" }})",
            )
        }

        sleepMillis(TCPIP_SWITCH_DELAY_MS)
        repeat(TCPIP_CONNECT_RETRIES) { attempt ->
            val attemptResult = connectAndVerify(TCPIP_ENDPOINT)
            if (attemptResult.connectedSerial == TCPIP_ENDPOINT) {
                return TcpipUpgradeResult(upgraded = true, detail = null)
            }
            if (attempt + 1 < TCPIP_CONNECT_RETRIES) {
                sleepMillis(TCPIP_RETRY_DELAY_MS)
            }
        }
        return TcpipUpgradeResult(
            upgraded = false,
            detail = "Switched adbd to TCP/IP mode, but 127.0.0.1:5555 did not answer; kept $sourceSerial",
        )
    }

    private fun listAdbDevices(): List<AdbDevice> {
        val result = commandRunner.runAdb("devices")
        if (result.exitCode != 0) {
            return emptyList()
        }
        return parseAdbDevices(result.stdout)
    }

    private fun findSingleHealthyDevice(devices: List<AdbDevice>): String? {
        if (devices.size != 1) return null
        val device = devices.single()
        if (device.state != "device") return null
        val stateResult = commandRunner.runAdb("-s", device.serial, "get-state")
        return if (stateResult.exitCode == 0 && stateResult.stdout.trim() == "device") {
            device.serial
        } else {
            null
        }
    }

    private fun loadKeepAlivePreference(): Boolean {
        if (!configFile.isFile) return false
        return runCatching {
            JSONObject(configFile.readText(Charsets.UTF_8)).optBoolean("keepAliveTcpip5555", false)
        }.getOrDefault(false)
    }

    private fun saveKeepAlivePreference(enabled: Boolean) {
        baseDir.mkdirs()
        val temp = File(baseDir, "$CONFIG_FILENAME.${UUID.randomUUID()}.tmp")
        try {
            temp.writeText(
                JSONObject().put("keepAliveTcpip5555", enabled).toString(2) + "\n",
                Charsets.UTF_8,
            )
            if (!temp.renameTo(configFile)) {
                temp.copyTo(configFile, overwrite = true)
            }
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    private fun updateState(transform: (WirelessAdbState) -> WirelessAdbState): WirelessAdbState {
        val previous = state
        val next = transform(previous)
        state = next
        if (next != previous) {
            for (listener in listeners) {
                listener(next)
            }
        }
        return next
    }

    companion object {
        const val CONFIG_FILENAME = "wireless-adb.json"
        const val TCPIP_PORT = 5555
        const val TCPIP_ENDPOINT = "127.0.0.1:$TCPIP_PORT"
        const val SERVICE_TYPE_PAIRING = "_adb-tls-pairing._tcp"
        const val SERVICE_TYPE_CONNECT = "_adb-tls-connect._tcp"
        private const val TCPIP_SWITCH_DELAY_MS = 1_200L
        private const val TCPIP_CONNECT_RETRIES = 3
        private const val TCPIP_RETRY_DELAY_MS = 500L

        internal fun parseAdbDevices(stdout: String): List<AdbDevice> = stdout
            .lineSequence()
            .map { it.trim() }
            .filter {
                it.isNotEmpty() &&
                    !it.startsWith("List of devices attached") &&
                    !it.startsWith("* daemon")
            }
            .mapNotNull { line ->
                val parts = line.split(Regex("\\s+"))
                if (parts.size >= 2) AdbDevice(serial = parts[0], state = parts[1]) else null
            }
            .toList()

        internal fun isLocalServiceAddress(
            resolvedHosts: List<InetAddress>,
            localAddresses: Set<InetAddress>,
        ): Boolean {
            if (resolvedHosts.isEmpty()) return false
            val localBytes = localAddresses.map { it.address.toList() }.toSet()
            return resolvedHosts.any { host ->
                host.isLoopbackAddress || host.address.toList() in localBytes
            }
        }

        internal fun sanitizePort(port: Int): Int {
            require(port in 1..65535) { "Wireless ADB port must be between 1 and 65535" }
            return port
        }

        internal fun sanitizePairingCode(code: String): String {
            val digits = code.replace(Regex("[\\s-]"), "")
            require(digits.length in 4..12 && digits.all { it in '0'..'9' }) {
                "Wireless ADB pairing code must be numeric"
            }
            return digits
        }

        internal fun redactCode(text: String, code: String): String {
            if (code.isBlank()) return text
            return text.replace(code, "[redacted]")
        }
    }
}

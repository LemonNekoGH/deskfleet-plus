package io.github.yet_another_ai.deskfleet.nativedesktop

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.nio.file.Files

class WirelessAdbManagerTest {
    private val tempDir = Files.createTempDirectory("deskfleet-wireless-adb-test").toFile()

    @After
    fun cleanup() {
        tempDir.deleteRecursively()
    }

    private class RecordingNotifier : WirelessAdbNotifier {
        val events = mutableListOf<String>()

        override fun showSearchingPairingNotification() {
            events += "searching"
        }

        override fun showPairingCodePrompt(port: Int) {
            events += "prompt:$port"
        }

        override fun showPairingProgress(port: Int) {
            events += "progress:$port"
        }

        override fun showPairingSucceeded(endpoint: String?) {
            events += "succeeded:${endpoint ?: "none"}"
        }

        override fun showPairingFailed(message: String) {
            events += "failed:$message"
        }

        override fun dismissPairingNotification() {
            events += "dismiss"
        }
    }

    @Test
    fun parseAdbDevicesAndLocalAddressFilterHandleRealOutputs() {
        val output = """
            * daemon not running; starting now at tcp:5037
            * daemon started successfully
            List of devices attached
            10.100.0.246:38407    offline
            127.0.0.1:5555        device

        """.trimIndent()
        assertEquals(
            listOf(
                AdbDevice("10.100.0.246:38407", "offline"),
                AdbDevice("127.0.0.1:5555", "device"),
            ),
            WirelessAdbManager.parseAdbDevices(output),
        )

        val myLan = InetAddress.getByName("192.168.1.42")
        val otherPhone = InetAddress.getByName("192.168.1.99")
        val loopback = InetAddress.getByName("127.0.0.1")
        assertTrue(WirelessAdbManager.isLocalServiceAddress(listOf(myLan), setOf(myLan)))
        assertTrue(WirelessAdbManager.isLocalServiceAddress(listOf(loopback), setOf(myLan)))
        assertFalse(WirelessAdbManager.isLocalServiceAddress(listOf(otherPhone), setOf(myLan)))
        assertFalse(WirelessAdbManager.isLocalServiceAddress(emptyList(), setOf(myLan)))
    }

    @Test
    fun reconcileDisconnectsStaleOfflineEntriesAndRefreshesCapabilitiesOnce() {
        val commands = mutableListOf<List<String>>()
        var devices = listOf(AdbDevice("127.0.0.1:38407", "offline"))
        var refreshes = 0
        val notifier = RecordingNotifier()

        val manager = WirelessAdbManager(
            filesDir = tempDir,
            commandRunner = object : WirelessAdbCommandRunner {
                override fun isAdbAvailable(): Boolean = true

                override fun runAdb(vararg args: String): ShellResult {
                    val list = args.toList()
                    commands += list
                    return when {
                        list == listOf("devices") -> ShellResult(
                            0,
                            buildString {
                                appendLine("List of devices attached")
                                devices.forEach { appendLine("${it.serial}\t${it.state}") }
                            },
                            "",
                        )
                        list == listOf("disconnect") -> {
                            devices = emptyList()
                            ShellResult(0, "disconnected everything", "")
                        }
                        list == listOf("connect", "127.0.0.1:5555") -> ShellResult(1, "", "connection refused")
                        list == listOf("connect", "127.0.0.1:41234") -> {
                            devices = listOf(AdbDevice("127.0.0.1:41234", "device"))
                            ShellResult(0, "connected to 127.0.0.1:41234", "")
                        }
                        list == listOf("-s", "127.0.0.1:41234", "get-state") -> {
                            val online = devices.any { it.serial == "127.0.0.1:41234" && it.state == "device" }
                            if (online) ShellResult(0, "device\n", "") else ShellResult(1, "", "offline")
                        }
                        else -> ShellResult(1, "", "unexpected: $list")
                    }
                }

                override fun refreshDaemonCapabilities() {
                    refreshes += 1
                }
            },
            notifier = notifier,
            sleepMillis = {},
        )

        val connected = manager.onConnectServiceFound(41234)
        assertEquals(WirelessAdbPhase.CONNECTED, connected.phase)
        assertEquals("127.0.0.1:41234", connected.endpoint)
        assertEquals(false, connected.tcpip5555Active)
        assertEquals(1, refreshes)
        assertTrue(commands.contains(listOf("disconnect")))

        val again = manager.reconcile()
        assertEquals(WirelessAdbPhase.CONNECTED, again.phase)
        assertEquals("127.0.0.1:41234", again.endpoint)
        assertEquals(1, refreshes)
        assertFalse(commands.takeLast(2).contains(listOf("disconnect")))
    }

    @Test
    fun keepAliveTcpip5555UpgradesTlsConnectionPersistsPreferenceAndProbes5555FirstOnRestart() {
        var devices = emptyList<AdbDevice>()
        var tcpip5555Listening = false
        var refreshes = 0
        val notifier = RecordingNotifier()

        val runner = object : WirelessAdbCommandRunner {
            override fun isAdbAvailable(): Boolean = true

            override fun runAdb(vararg args: String): ShellResult {
                val list = args.toList()
                return when {
                    list == listOf("devices") -> ShellResult(
                        0,
                        buildString {
                            appendLine("List of devices attached")
                            devices.forEach { appendLine("${it.serial}\t${it.state}") }
                        },
                        "",
                    )
                    list == listOf("disconnect") -> {
                        devices = emptyList()
                        ShellResult(0, "disconnected everything", "")
                    }
                    list == listOf("connect", "127.0.0.1:5555") -> {
                        if (tcpip5555Listening) {
                            devices = listOf(AdbDevice("127.0.0.1:5555", "device"))
                            ShellResult(0, "connected to 127.0.0.1:5555", "")
                        } else {
                            ShellResult(0, "failed to connect to '127.0.0.1:5555': Connection refused", "")
                        }
                    }
                    list == listOf("connect", "127.0.0.1:37890") -> {
                        devices = listOf(AdbDevice("127.0.0.1:37890", "device"))
                        ShellResult(0, "connected to 127.0.0.1:37890", "")
                    }
                    list == listOf("-s", "127.0.0.1:37890", "tcpip", "5555") -> {
                        tcpip5555Listening = true
                        devices = emptyList()
                        ShellResult(0, "restarting in TCP mode port: 5555", "")
                    }
                    list.size == 3 && list[0] == "-s" && list[2] == "get-state" -> {
                        val online = devices.any { it.serial == list[1] && it.state == "device" }
                        if (online) ShellResult(0, "device\n", "") else ShellResult(1, "", "offline")
                    }
                    else -> ShellResult(1, "", "unexpected: $list")
                }
            }

            override fun refreshDaemonCapabilities() {
                refreshes += 1
            }
        }

        val manager = WirelessAdbManager(tempDir, runner, notifier, sleepMillis = {})
        manager.onConnectServiceFound(37890)
        assertEquals("127.0.0.1:37890", manager.currentState().endpoint)

        val upgraded = manager.setKeepAliveTcpip5555(true)
        assertEquals(WirelessAdbPhase.CONNECTED, upgraded.phase)
        assertEquals("127.0.0.1:5555", upgraded.endpoint)
        assertTrue(upgraded.tcpip5555Active)
        assertTrue(upgraded.keepAliveTcpip5555)
        assertEquals(2, refreshes)

        // Simulate process restart with adb daemon reset, while tcpip 5555 stays active until reboot.
        devices = emptyList()
        val restarted = WirelessAdbManager(tempDir, runner, notifier, sleepMillis = {})
        assertTrue(restarted.currentState().keepAliveTcpip5555)
        val reconnected = restarted.reconcile()
        assertEquals(WirelessAdbPhase.CONNECTED, reconnected.phase)
        assertEquals("127.0.0.1:5555", reconnected.endpoint)
        assertTrue(reconnected.tcpip5555Active)
    }

    @Test
    fun keepAliveFallsBackToTlsWhenTcpip5555IsRejectedByDevice() {
        var devices = emptyList<AdbDevice>()
        val manager = WirelessAdbManager(
            filesDir = tempDir,
            commandRunner = object : WirelessAdbCommandRunner {
                override fun isAdbAvailable(): Boolean = true

                override fun runAdb(vararg args: String): ShellResult {
                    val list = args.toList()
                    return when {
                        list == listOf("devices") -> ShellResult(
                            0,
                            buildString {
                                appendLine("List of devices attached")
                                devices.forEach { appendLine("${it.serial}\t${it.state}") }
                            },
                            "",
                        )
                        list == listOf("disconnect") -> {
                            devices = emptyList()
                            ShellResult(0, "", "")
                        }
                        list == listOf("connect", "127.0.0.1:5555") -> ShellResult(1, "", "Connection refused")
                        list == listOf("connect", "127.0.0.1:40111") -> {
                            devices = listOf(AdbDevice("127.0.0.1:40111", "device"))
                            ShellResult(0, "connected to 127.0.0.1:40111", "")
                        }
                        list == listOf("-s", "127.0.0.1:40111", "tcpip", "5555") -> {
                            ShellResult(1, "", "error: closed")
                        }
                        list == listOf("-s", "127.0.0.1:40111", "get-state") -> ShellResult(0, "device\n", "")
                        else -> ShellResult(1, "", "unexpected: $list")
                    }
                }

                override fun refreshDaemonCapabilities() {}
            },
            notifier = RecordingNotifier(),
            sleepMillis = {},
        )

        manager.setKeepAliveTcpip5555(true)
        val state = manager.onConnectServiceFound(40111)
        assertEquals(WirelessAdbPhase.CONNECTED, state.phase)
        assertEquals("127.0.0.1:40111", state.endpoint)
        assertFalse(state.tcpip5555Active)
        assertTrue(state.detail.orEmpty().contains("adb tcpip 5555 failed"))
    }

    @Test
    fun pairValidatesInputRedactsSecretsAndReconnectsOnSuccess() {
        val notifier = RecordingNotifier()
        var devices = emptyList<AdbDevice>()
        var paired = false
        val manager = WirelessAdbManager(
            filesDir = tempDir,
            commandRunner = object : WirelessAdbCommandRunner {
                override fun isAdbAvailable(): Boolean = true

                override fun runAdb(vararg args: String): ShellResult {
                    val list = args.toList()
                    return when {
                        list == listOf("pair", "127.0.0.1:37123", "111222") -> {
                            ShellResult(0, "Failed: Wrong password 111222", "")
                        }
                        list == listOf("pair", "127.0.0.1:37123", "482910") -> {
                            paired = true
                            ShellResult(0, "Successfully paired to 127.0.0.1:37123", "")
                        }
                        list == listOf("devices") -> ShellResult(
                            0,
                            buildString {
                                appendLine("List of devices attached")
                                devices.forEach { appendLine("${it.serial}\t${it.state}") }
                            },
                            "",
                        )
                        list == listOf("disconnect") -> {
                            devices = emptyList()
                            ShellResult(0, "", "")
                        }
                        list == listOf("connect", "127.0.0.1:5555") -> {
                            if (paired) {
                                devices = listOf(AdbDevice("127.0.0.1:5555", "device"))
                                ShellResult(0, "connected to 127.0.0.1:5555", "")
                            } else {
                                ShellResult(1, "", "refused")
                            }
                        }
                        list == listOf("-s", "127.0.0.1:5555", "get-state") -> ShellResult(0, "device\n", "")
                        else -> ShellResult(1, "", "unexpected: $list")
                    }
                }

                override fun refreshDaemonCapabilities() {}
            },
            notifier = notifier,
            sleepMillis = {},
        )

        manager.onPairingServiceFound(37123)
        assertTrue(notifier.events.contains("prompt:37123"))

        assertThrows(IllegalArgumentException::class.java) {
            manager.pair(37123, "abc")
        }

        val error = assertThrows(IllegalStateException::class.java) {
            manager.pair(37123, "111-222")
        }
        assertFalse(error.message.orEmpty().contains("111222"))
        assertTrue(error.message.orEmpty().contains("[redacted]"))
        assertEquals(WirelessAdbPhase.ERROR, manager.currentState().phase)

        val ok = manager.pair(37123, "482 910")
        assertEquals(WirelessAdbPhase.CONNECTED, ok.phase)
        assertEquals("127.0.0.1:5555", ok.endpoint)
        assertFalse(ok.pairingDiscoveryActive)
        assertNull(ok.pairingPort)
        assertTrue(notifier.events.contains("succeeded:127.0.0.1:5555"))
    }

    @Test
    fun unprovisionedStateReportedWhenAdbIsMissing() {
        val manager = WirelessAdbManager(
            filesDir = tempDir,
            commandRunner = object : WirelessAdbCommandRunner {
                override fun isAdbAvailable(): Boolean = false
                override fun runAdb(vararg args: String): ShellResult = throw AssertionError("runAdb should not be called")
                override fun refreshDaemonCapabilities() = fail("refreshDaemonCapabilities should not be called")
            },
            notifier = RecordingNotifier(),
        )

        assertEquals(WirelessAdbPhase.UNPROVISIONED, manager.currentState().phase)
        assertEquals(WirelessAdbPhase.UNPROVISIONED, manager.reconcile().phase)
    }
}

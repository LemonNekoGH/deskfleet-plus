package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ProotDaemonManagerTest {
    private val tempDir = Files.createTempDirectory("deskfleet-proot-test").toFile()
    private val filesDir = File(tempDir, "files")
    private val cacheDir = File(tempDir, "cache")
    private val nativeDir = File(tempDir, "native")

    @After
    fun cleanup() {
        tempDir.deleteRecursively()
    }

    @Test
    fun buildProotInvocationSetsLoaderEnvFlagsAndDataBindMount() {
        val baseDir = File(filesDir, "linux")
        val invocation = ProotDaemonManager.buildProotInvocation(
            nativeLibraryDir = nativeDir,
            baseDir = baseDir,
            commandArgs = listOf("/opt/deskfleet/deskfleet-daemon", "--port", "8081"),
        )

        assertEquals(File(nativeDir, "libproot.so").absolutePath, invocation.executable)
        assertEquals(nativeDir.absolutePath, invocation.env["LD_LIBRARY_PATH"])
        assertEquals(File(nativeDir, "libproot_loader.so").absolutePath, invocation.env["PROOT_LOADER"])
        assertEquals(File(baseDir, "proot-tmp").absolutePath, invocation.env["PROOT_TMP_DIR"])
        assertEquals("1", invocation.env["PROOT_NO_SECCOMP"])
        assertEquals("/root", invocation.env["HOME"])

        assertTrue(invocation.args.contains("--kill-on-exit"))
        assertTrue(invocation.args.contains("--link2symlink"))
        assertTrue(invocation.args.contains("-0"))
        assertTrue(invocation.args.contains(File(baseDir, "rootfs").absolutePath))
        assertTrue(invocation.args.contains("${File(baseDir, "data").absolutePath}:/var/lib/deskfleet"))
        assertTrue(invocation.args.contains("DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet"))
        assertEquals(
            listOf("/opt/deskfleet/deskfleet-daemon", "--port", "8081"),
            invocation.args.takeLast(3),
        )
    }

    @Test
    fun statusFallsBackToMachineModelWhenContainerIsNotProvisioned() {
        var invoked = false
        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.18.2",
            fallbackMachineName = "Pixel 9",
            runner = object : ProotRunner {
                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    invoked = true
                    return ShellResult(1, "", "not found")
                }
            },
        )

        val parsed = JSONObject(manager.status())
        assertFalse(invoked)
        assertEquals("Pixel 9", parsed.getString("machineName"))
        assertEquals(0, parsed.getJSONArray("registrations").length())
    }

    @Test
    fun enrollPipesCredentialsViaStdinAndNeverPassesSecretsInArgv() {
        val captured = mutableListOf<Pair<ProotInvocation, String?>>()
        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.18.2",
            fallbackMachineName = "Phone",
            runner = object : ProotRunner {
                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    captured += invocation to stdin
                    return ShellResult(
                        0,
                        """{"configured":true,"connected":true,"revoked":false,"serverUrl":"https://fleet.example","machineId":"m1","teamId":"t1","identity":{"originId":"o1","machineId":"1"},"machineName":"Phone"}""",
                        "",
                    )
                }
            },
        )

        val secretPayload = """{"machineId":"m1","teamId":"t1","token":"top-secret","originId":"o1"}"""
        val result = JSONObject(manager.enroll("https://fleet.example", secretPayload))
        assertTrue(result.getBoolean("configured"))
        assertEquals("m1", result.getString("machineId"))

        assertEquals(1, captured.size)
        val (invocation, stdin) = captured.single()
        assertFalse(invocation.args.any { it.contains("top-secret") })
        assertEquals(secretPayload, stdin)
    }

    @Test
    fun prepareEnrollmentStartsForegroundServiceWhenDaemonIsNotYetReady() {
        val baseDir = File(filesDir, "linux")
        val rootfs = File(baseDir, "rootfs")
        File(rootfs, "bin").mkdirs()
        File(rootfs, "bin/sh").writeText("#!/bin/sh\n")
        File(rootfs, "opt/deskfleet").mkdirs()
        File(rootfs, "opt/deskfleet/deskfleet-daemon").writeText("elf")
        File(baseDir, "version").writeText("0.18.2")

        var serviceStarts = 0
        var ready = false
        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.18.2",
            fallbackMachineName = "Phone",
            runner = object : ProotRunner {
                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    val cmd = invocation.args
                    return when {
                        cmd.last() == "status" && !ready -> ShellResult(1, "", "not running")
                        cmd.last() == "status" && ready -> ShellResult(0, """{"machineName":"Phone","registrations":[]}""", "")
                        cmd.contains("prepare-enrollment") -> ShellResult(
                            0,
                            """{"configured":false,"connected":false,"revoked":false,"identity":{"originId":"o1","machineId":"1"},"machineName":"Phone","identityToken":"id-tok"}""",
                            "",
                        )
                        else -> ShellResult(1, "", "unexpected: $cmd")
                    }
                }
            },
            downloader = object : AssetDownloader {
                override fun download(url: String, destination: File, gunzip: Boolean) {
                    fail("unexpected download: $url")
                }
            },
            sleepMillis = { },
        )

        val prepared = JSONObject(
            manager.prepareEnrollment("https://fleet.example", "team-1") {
                serviceStarts += 1
                ready = true
            },
        )
        assertEquals(1, serviceStarts)
        assertEquals("id-tok", prepared.getString("identityToken"))
    }
}

package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

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
        assertTrue(invocation.args.contains("${File(baseDir, "workspace").absolutePath}:/root/workspace"))
        assertTrue(invocation.args.contains("DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet"))
        assertTrue(invocation.args.contains("DESKFLEET_ANDROID_SCRCPY_SERVER=/opt/deskfleet/scrcpy-server.jar"))
        assertTrue(invocation.args.contains("DESKFLEET_ANDROID_SCRCPY_VERSION=3.1"))
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
        File(rootfs, "opt/deskfleet/scrcpy-server.jar").writeText("jar")
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

    @Test
    fun ensureProvisionedFallsBackWhenPrimaryRootfsFailsAndReplacesDanglingResolvSymlink() {
        val baseDir = File(filesDir, "linux")
        val rootfs = File(baseDir, "rootfs")
        val downloadedUrls = mutableListOf<String>()
        val commands = mutableListOf<List<String>>()

        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.18.2",
            fallbackMachineName = "Phone",
            runner = object : ProotRunner {
                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    commands += invocation.args
                    return when {
                        invocation.args.contains("/system/bin/tar") -> {
                            File(rootfs, "bin").mkdirs()
                            File(rootfs, "bin/sh").writeText("#!/bin/sh\n")
                            File(rootfs, "etc").mkdirs()
                            val resolvPath = File(rootfs, "etc/resolv.conf").toPath()
                            runCatching {
                                Files.createSymbolicLink(
                                    resolvPath,
                                    Paths.get("../run/systemd/resolve/stub-resolv.conf"),
                                )
                            }
                            ShellResult(1, "", "tar: dev/null: Operation not permitted")
                        }
                        invocation.args.any { it.contains("deskfleet-linux-arm64.tar.gz") } -> {
                            File(rootfs, "opt/deskfleet").mkdirs()
                            File(rootfs, "opt/deskfleet/deskfleet-daemon").writeText("elf")
                            ShellResult(0, "", "")
                        }
                        else -> ShellResult(0, "", "")
                    }
                }
            },
            downloader = object : AssetDownloader {
                override fun download(url: String, destination: File, gunzip: Boolean) {
                    downloadedUrls += url
                    if (url == ProotDaemonManager.DEBIAN_ROOTFS_URL) {
                        throw IllegalStateException("Download failed (404) for $url")
                    }
                    destination.parentFile?.mkdirs()
                    destination.writeText("mock-archive")
                }
            },
        )

        manager.ensureProvisioned()

        assertEquals(
            listOf(
                ProotDaemonManager.DEBIAN_ROOTFS_URL,
                ProotDaemonManager.DEBIAN_ROOTFS_FALLBACK_URL,
                "https://github.com/yet-another-ai/deskfleet/releases/download/v0.18.2/deskfleet-linux-arm64.tar.gz",
                ProotDaemonManager.SCRCPY_SERVER_URL,
            ),
            downloadedUrls,
        )
        assertFalse(commands.any { it.firstOrNull() == "-xf" })
        val resolvFile = File(rootfs, "etc/resolv.conf")
        assertFalse(Files.isSymbolicLink(resolvFile.toPath()))
        assertTrue(resolvFile.isFile)
        assertEquals("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", resolvFile.readText())
    }

    @Test
    fun ensureProvisionedUsesBundledDaemonAndScrcpyAssetsWhileDownloadingRootfs() {
        val baseDir = File(filesDir, "linux")
        val rootfs = File(baseDir, "rootfs")
        val downloadedUrls = mutableListOf<String>()
        val invokedCommands = mutableListOf<List<String>>()
        val openedAssets = mutableListOf<String>()
        var aptGetRan = false

        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.18.2",
            fallbackMachineName = "Phone",
            runner = object : ProotRunner {
                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    invokedCommands += invocation.args
                    return when {
                        invocation.args.contains("/system/bin/tar") -> {
                            File(rootfs, "bin").mkdirs()
                            File(rootfs, "bin/sh").writeText("#!/bin/sh\n")
                            ShellResult(0, "", "")
                        }
                        invocation.args.any { it.contains("apt-get") } -> {
                            aptGetRan = true
                            ShellResult(0, "", "")
                        }
                        invocation.args.any { it.contains("tar -xzf /tmp/deskfleet-linux-arm64.tar.gz") } -> {
                            assertEquals(
                                "mock-daemon-tgz",
                                File(rootfs, "tmp/deskfleet-linux-arm64.tar.gz").readText(),
                            )
                            File(rootfs, "opt/deskfleet").mkdirs()
                            File(rootfs, "opt/deskfleet/deskfleet-daemon").writeText("elf")
                            ShellResult(0, "", "")
                        }
                        else -> {
                            fail("Unexpected container command: ${invocation.args}")
                            ShellResult(1, "", "")
                        }
                    }
                }
            },
            downloader = object : AssetDownloader {
                override fun download(url: String, destination: File, gunzip: Boolean) {
                    downloadedUrls += url
                    assertEquals(ProotDaemonManager.DEBIAN_ROOTFS_URL, url)
                    destination.parentFile?.mkdirs()
                    destination.writeText("mock-debian-rootfs")
                }
            },
            assetOpener = EmbeddedAssetOpener { assetName ->
                openedAssets += assetName
                when (assetName) {
                    ProotDaemonManager.EMBEDDED_DAEMON_ASSET -> ByteArrayInputStream("mock-daemon-tgz".toByteArray())
                    ProotDaemonManager.EMBEDDED_SCRCPY_ASSET -> ByteArrayInputStream("mock-scrcpy-jar".toByteArray())
                    else -> null
                }
            },
        )

        manager.ensureProvisioned()

        assertEquals(listOf(ProotDaemonManager.DEBIAN_ROOTFS_URL), downloadedUrls)
        assertEquals(
            listOf(ProotDaemonManager.EMBEDDED_DAEMON_ASSET, ProotDaemonManager.EMBEDDED_SCRCPY_ASSET),
            openedAssets,
        )
        assertTrue(aptGetRan)
        assertEquals("mock-scrcpy-jar", File(rootfs, "opt/deskfleet/scrcpy-server.jar").readText())
        assertTrue(File(rootfs, "etc/hosts").isFile)
        assertTrue(File(baseDir, "workspace").isDirectory)
        assertEquals("0.18.2", File(baseDir, "version").readText())
        assertFalse(File(cacheDir, "debian-rootfs.tar").exists())
    }

    @Test
    fun enrollmentStreamsDownloadProgressCommandsAndDaemonLogWithoutLeakingSecrets() {
        val baseDir = File(filesDir, "linux")
        val rootfs = File(baseDir, "rootfs")
        val logs = StringBuilder()

        val manager = ProotDaemonManager(
            filesDir = filesDir,
            cacheDir = cacheDir,
            nativeLibraryDir = nativeDir,
            versionName = "0.19.0",
            fallbackMachineName = "Phone",
            runner = object : ProotRunner {
                private var polls = 0

                override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
                    val cmd = invocation.args
                    return when {
                        cmd.last() == "status" -> {
                            polls += 1
                            when (polls) {
                                1 -> ShellResult(1, "", "not running")
                                2 -> {
                                    File(baseDir, "daemon.log").appendText("Listening for DeskFleet central\n")
                                    ShellResult(1, "", "starting")
                                }
                                else -> {
                                    File(baseDir, "daemon.log").appendText("Daemon control server ready\n")
                                    ShellResult(0, """{"machineName":"Phone","registrations":[]}""", "")
                                }
                            }
                        }
                        cmd.contains("prepare-enrollment") -> ShellResult(
                            0,
                            """{"configured":false,"connected":false,"revoked":false,"identity":{"originId":"o1","machineId":"1"},"machineName":"Phone","identityToken":"super-secret-id-token"}""",
                            "",
                        )
                        cmd.contains("enroll") -> ShellResult(
                            0,
                            """{"configured":true,"connected":true,"revoked":false,"serverUrl":"https://fleet.example","machineId":"m1","teamId":"t1","identity":{"originId":"o1","machineId":"1"},"machineName":"Phone"}""",
                            "",
                        )
                        else -> ShellResult(1, "", "unexpected: $cmd")
                    }
                }

                override fun runStreaming(
                    invocation: ProotInvocation,
                    stdin: String?,
                    onOutput: (String) -> Unit,
                ): ShellResult {
                    val cmd = invocation.args
                    return when {
                        cmd.contains("/system/bin/tar") -> {
                            onOutput("tar: extracting usr/bin/env\n")
                            File(rootfs, "bin").mkdirs()
                            File(rootfs, "bin/sh").writeText("#!/bin/sh\n")
                            ShellResult(0, "tar: extracting usr/bin/env\n", "")
                        }
                        cmd.any { it.contains("apt-get") } -> {
                            onOutput("Setting up adb (34.0.5)...\n")
                            ShellResult(0, "Setting up adb (34.0.5)...\n", "")
                        }
                        cmd.any { it.contains("tar -xzf /tmp/deskfleet-linux-arm64.tar.gz") } -> {
                            onOutput("deskfleet-daemon unpacked\n")
                            File(rootfs, "opt/deskfleet").mkdirs()
                            File(rootfs, "opt/deskfleet/deskfleet-daemon").writeText("elf")
                            ShellResult(0, "deskfleet-daemon unpacked\n", "")
                        }
                        else -> run(invocation, stdin)
                    }
                }
            },
            downloader = object : AssetDownloader {
                override fun download(url: String, destination: File, gunzip: Boolean) {
                    download(url, destination, gunzip, null)
                }

                override fun download(
                    url: String,
                    destination: File,
                    gunzip: Boolean,
                    onProgress: ((downloadedBytes: Long, totalBytes: Long) -> Unit)?,
                ) {
                    onProgress?.invoke(512L * 1024L, 1024L * 1024L)
                    onProgress?.invoke(1024L * 1024L, 1024L * 1024L)
                    destination.parentFile?.mkdirs()
                    destination.writeText("mock-debian")
                }
            },
            sleepMillis = { },
            assetOpener = EmbeddedAssetOpener { assetName ->
                when (assetName) {
                    ProotDaemonManager.EMBEDDED_DAEMON_ASSET -> ByteArrayInputStream("daemon".toByteArray())
                    ProotDaemonManager.EMBEDDED_SCRCPY_ASSET -> ByteArrayInputStream("scrcpy".toByteArray())
                    else -> null
                }
            },
            onLog = { chunk -> logs.append(chunk) },
        )

        val prepared = manager.prepareEnrollment("https://fleet.example", "team-1") {
            baseDir.mkdirs()
            File(baseDir, "daemon.log").writeText("Starting proot daemon container\n")
        }
        assertTrue(prepared.contains("super-secret-id-token"))
        manager.enroll("https://fleet.example", """{"machineId":"m1","teamId":"t1","token":"super-secret-machine-token","originId":"o1"}""")

        val output = logs.toString()
        assertTrue(output.contains("Downloading Debian rootfs..."))
        assertTrue(output.contains("Downloaded 512.0 KiB / 1.0 MiB (50%)"))
        assertTrue(output.contains("Downloaded 1.0 MiB / 1.0 MiB (100%)"))
        assertTrue(output.contains("tar: extracting usr/bin/env"))
        assertTrue(output.contains("Setting up adb (34.0.5)..."))
        assertTrue(output.contains("Starting proot daemon container"))
        assertTrue(output.contains("Listening for DeskFleet central"))
        assertTrue(output.contains("Daemon control server ready"))
        assertTrue(output.contains("Local daemon enrolled."))
        assertFalse(output.contains("super-secret-id-token"))
        assertFalse(output.contains("super-secret-machine-token"))
    }
}

package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipInputStream

class KernelSuDaemonManagerTest {
    private val tempDir = Files.createTempDirectory("deskfleet-ksu-test").toFile()

    @After
    fun cleanup() {
        tempDir.deleteRecursively()
    }

    @Test
    fun buildModuleZipContainsKernelSuModuleMetadataAndChrootScripts() {
        val manager = KernelSuDaemonManager(
            cacheDir = tempDir,
            versionName = "0.18.2",
            versionCode = 1802,
            fallbackMachineName = "Pixel 9",
        )
        val out = ByteArrayOutputStream()
        manager.buildModuleZip(out)

        val entries = mutableMapOf<String, String>()
        ZipInputStream(ByteArrayInputStream(out.toByteArray())).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                entries[entry.name] = zip.readBytes().toString(Charsets.UTF_8)
                zip.closeEntry()
            }
        }

        assertEquals(
            setOf("module.prop", "customize.sh", "service.sh", "action.sh", "uninstall.sh"),
            entries.keys,
        )
        val prop = entries.getValue("module.prop")
        assertTrue(prop.contains("id=deskfleet_daemon"))
        assertTrue(prop.contains("version=v0.18.2"))
        assertTrue(prop.contains("versionCode=1802"))

        val service = entries.getValue("service.sh")
        assertTrue(service.contains("sys.boot_completed"))
        assertTrue(service.contains("echo deskfleet_daemon > /sys/power/wake_lock"))
        assertTrue(service.contains("chroot \"\$ROOTFS\""))
        assertTrue(service.contains("DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet"))
        assertTrue(service.contains("DESKFLEET_ANDROID_SCRCPY_SERVER=/opt/deskfleet/scrcpy-server.jar"))
        assertTrue(service.contains("DESKFLEET_ANDROID_SHELL=\"nsenter -t 1 -m -u -i -- /system/bin/sh -c\""))

        assertTrue(entries.getValue("action.sh").contains("deskfleet-ctl status"))
        assertTrue(entries.getValue("uninstall.sh").contains("/sys/power/wake_unlock"))
    }

    @Test
    fun statusFallsBackToMachineModelWhenDaemonIsNotInstalled() {
        val shell = object : RootShell {
            override fun run(script: String, stdin: String?) = ShellResult(1, "", "permission denied")
        }
        val manager = KernelSuDaemonManager(
            cacheDir = tempDir,
            versionName = "0.18.2",
            versionCode = 1802,
            fallbackMachineName = "Xiaomi 14",
            shell = shell,
        )

        val parsed = JSONObject(manager.status())
        assertEquals("Xiaomi 14", parsed.getString("machineName"))
        assertEquals(0, parsed.getJSONArray("registrations").length())
    }

    @Test
    fun enrollPipesCredentialsViaStdinAndNeverIncludesSecretsInShellCommand() {
        val calls = mutableListOf<Pair<String, String?>>()
        val shell = object : RootShell {
            override fun run(script: String, stdin: String?): ShellResult {
                calls += script to stdin
                return when {
                    script == "id -u" -> ShellResult(0, "0\n", "")
                    script.contains("enroll --server-url") -> ShellResult(
                        0,
                        """{"configured":true,"connected":true,"revoked":false,"serverUrl":"https://fleet.example","machineId":"m1","teamId":"t1","identity":{"originId":"o1","machineId":"1"},"machineName":"Phone"}""",
                        "",
                    )
                    else -> ShellResult(1, "", "unexpected script: $script")
                }
            }
        }
        val manager = KernelSuDaemonManager(
            cacheDir = tempDir,
            versionName = "0.18.2",
            versionCode = 1802,
            fallbackMachineName = "Phone",
            shell = shell,
        )

        val secretPayload = """{"machineId":"m1","teamId":"t1","token":"top-secret","originId":"o1"}"""
        val result = JSONObject(manager.enroll("https://fleet.example", secretPayload))
        assertTrue(result.getBoolean("configured"))
        assertEquals("m1", result.getString("machineId"))

        val enrollCall = calls.last()
        assertFalse(enrollCall.first.contains("top-secret"))
        assertEquals(secretPayload, enrollCall.second)
    }

    @Test
    fun prepareEnrollmentRejectsMissingRootAccessWithActionableError() {
        val shell = object : RootShell {
            override fun run(script: String, stdin: String?) = ShellResult(1, "", "su denied")
        }
        val manager = KernelSuDaemonManager(
            cacheDir = tempDir,
            versionName = "0.18.2",
            versionCode = 1802,
            fallbackMachineName = "Phone",
            shell = shell,
            downloader = object : AssetDownloader {
                override fun download(url: String, destination: File, gunzip: Boolean) {
                    fail("should not download without root")
                }
            },
        )

        val error = assertThrows(IllegalStateException::class.java) {
            manager.prepareEnrollment("https://fleet.example", "team-1")
        }
        assertTrue(error.message!!.contains("KernelSU Manager"))
    }
}

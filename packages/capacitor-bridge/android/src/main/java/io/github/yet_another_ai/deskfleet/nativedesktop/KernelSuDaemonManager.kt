package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal data class ShellResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
)

internal interface RootShell {
    fun run(script: String, stdin: String? = null): ShellResult
}

internal interface AssetDownloader {
    fun download(url: String, destination: File, gunzip: Boolean = false)
}

internal object ProcessRootShell : RootShell {
    override fun run(script: String, stdin: String?): ShellResult {
        val process = ProcessBuilder("su", "-c", script).start()
        if (stdin != null) {
            process.outputStream.bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(stdin)
            }
        } else {
            process.outputStream.close()
        }
        var stdout = ""
        var stderr = ""
        val outThread = Thread {
            stdout = process.inputStream.bufferedReader(Charsets.UTF_8).readText()
        }
        val errThread = Thread {
            stderr = process.errorStream.bufferedReader(Charsets.UTF_8).readText()
        }
        outThread.start()
        errThread.start()
        val exitCode = process.waitFor()
        outThread.join()
        errThread.join()
        return ShellResult(exitCode, stdout, stderr)
    }
}

internal object HttpAssetDownloader : AssetDownloader {
    override fun download(url: String, destination: File, gunzip: Boolean) {
        destination.parentFile?.mkdirs()
        val part = File(destination.parentFile, "${destination.name}.part")
        var current = url
        var connection: HttpURLConnection? = null
        try {
            repeat(8) {
                val conn = (URL(current).openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    connectTimeout = 20_000
                    readTimeout = 120_000
                    setRequestProperty("User-Agent", "DeskFleet-KSU")
                }
                val code = conn.responseCode
                if (code in 300..399) {
                    val next = conn.getHeaderField("Location")
                        ?: throw IllegalStateException("Redirect missing Location from $current")
                    conn.disconnect()
                    current = URL(URL(current), next).toString()
                } else {
                    connection = conn
                    if (code !in 200..299) {
                        throw IllegalStateException("Download failed ($code) for $current")
                    }
                    val input: InputStream = if (gunzip) GZIPInputStream(conn.inputStream) else conn.inputStream
                    input.use { src ->
                        FileOutputStream(part).use { out ->
                            src.copyTo(out)
                        }
                    }
                    if (!part.renameTo(destination)) {
                        part.copyTo(destination, overwrite = true)
                        part.delete()
                    }
                    return
                }
            }
            throw IllegalStateException("Too many redirects downloading $url")
        } finally {
            connection?.disconnect()
            if (part.exists()) part.delete()
        }
    }
}

/**
 * Provisions and manages the linux-arm64 deskfleet-daemon inside a native
 * KernelSU chroot environment without requiring Termux or proot-distro.
 */
internal class KernelSuDaemonManager(
    private val cacheDir: File,
    private val versionName: String,
    private val versionCode: Int,
    private val fallbackMachineName: String,
    private val shell: RootShell = ProcessRootShell,
    private val downloader: AssetDownloader = HttpAssetDownloader,
    private val sleepMillis: (Long) -> Unit = Thread::sleep,
) {
    fun buildModuleZip(output: OutputStream) {
        ZipOutputStream(output).use { zip ->
            writeZipEntry(zip, "module.prop", buildModuleProp())
            writeZipEntry(zip, "customize.sh", customizeScript())
            writeZipEntry(zip, "service.sh", serviceScript())
            writeZipEntry(zip, "action.sh", actionScript())
            writeZipEntry(zip, "uninstall.sh", uninstallScript())
        }
    }

    fun status(): String {
        val result = runCatching {
            shell.run("if [ -x $CTL_PATH ]; then $CTL_PATH status; fi")
        }.getOrNull()
        val trimmed = result?.stdout?.trim().orEmpty()
        if (result?.exitCode == 0 && trimmed.startsWith("{")) {
            val parsed = runCatching { JSONObject(trimmed) }.getOrNull()
            if (parsed != null && parsed.has("registrations")) {
                return parsed.toString()
            }
        }
        return JSONObject()
            .put("machineName", fallbackMachineName)
            .put("registrations", JSONArray())
            .toString()
    }

    fun prepareEnrollment(serverUrl: String, teamId: String): String {
        ensureProvisionedAndRunning()
        val result = runChecked(
            "$CTL_PATH prepare-enrollment --server-url ${shellQuote(serverUrl)} --team-id ${shellQuote(teamId)}",
        )
        return extractJsonObject(result.stdout, "prepare-enrollment")
    }

    fun enroll(serverUrl: String, credentialsJson: String): String {
        requireRoot()
        val result = runChecked(
            "$CTL_PATH enroll --server-url ${shellQuote(serverUrl)}",
            stdin = credentialsJson,
        )
        return extractJsonObject(result.stdout, "enroll")
    }

    fun ensureProvisionedAndRunning() {
        requireRoot()
        cacheDir.mkdirs()

        runChecked(
            """
            mkdir -p $BASE_DIR/bin $BASE_DIR/data $ROOTFS_DIR
            cat <<'EOF' > $CTL_PATH
            ${deskfleetCtlScript().trimEnd()}
            EOF
            chmod 0755 $CTL_PATH
            """.trimIndent(),
        )

        val hasRootfs = shell.run("[ -x $ROOTFS_DIR/bin/sh ]").exitCode == 0
        if (!hasRootfs) {
            val rootfsTar = File(cacheDir, "ubuntu-rootfs.tar")
            try {
                downloader.download(UBUNTU_ROOTFS_URL, rootfsTar, gunzip = true)
                runChecked(
                    """
                    tar -xf ${shellQuote(rootfsTar.absolutePath)} -C $ROOTFS_DIR
                    mkdir -p $ROOTFS_DIR/tmp $ROOTFS_DIR/opt/deskfleet $ROOTFS_DIR/var/lib/deskfleet $ROOTFS_DIR/etc $ROOTFS_DIR/dev/pts $ROOTFS_DIR/dev/shm $ROOTFS_DIR/proc $ROOTFS_DIR/sys $ROOTFS_DIR/sdcard
                    chmod 1777 $ROOTFS_DIR/tmp
                    ${mountChrootSnippet()}
                    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > $ROOTFS_DIR/etc/resolv.conf
                    chroot $ROOTFS_DIR /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive /bin/sh -c 'apt-get -o APT::Sandbox::User=root update && apt-get -o APT::Sandbox::User=root install -y --no-install-recommends ca-certificates git curl && rm -rf /var/lib/apt/lists/*'
                    """.trimIndent(),
                )
            } finally {
                rootfsTar.delete()
            }
        }

        val installedVersion = shell.run("cat $BASE_DIR/version 2>/dev/null || true").stdout.trim()
        val hasDaemon = shell.run("[ -x $ROOTFS_DIR/opt/deskfleet/deskfleet-daemon ]").exitCode == 0
        if (!hasDaemon || installedVersion != versionName) {
            val daemonArchive = File(cacheDir, "deskfleet-linux-arm64.tar.gz")
            try {
                downloadDaemonRelease(daemonArchive)
                runChecked(
                    """
                    mkdir -p $ROOTFS_DIR/opt/deskfleet $ROOTFS_DIR/tmp
                    cp ${shellQuote(daemonArchive.absolutePath)} $ROOTFS_DIR/tmp/deskfleet-linux-arm64.tar.gz
                    chroot $ROOTFS_DIR /bin/tar -xzf /tmp/deskfleet-linux-arm64.tar.gz -C /opt/deskfleet
                    rm -f $ROOTFS_DIR/tmp/deskfleet-linux-arm64.tar.gz
                    chmod 0755 $ROOTFS_DIR/opt/deskfleet/deskfleet-daemon
                    printf '%s' ${shellQuote(versionName)} > $BASE_DIR/version
                    """.trimIndent(),
                )
            } finally {
                daemonArchive.delete()
            }
        }

        val hasScrcpy = shell.run("[ -f $ROOTFS_DIR/opt/deskfleet/scrcpy-server.jar ]").exitCode == 0
        if (!hasScrcpy) {
            val scrcpyFile = File(cacheDir, "scrcpy-server.jar")
            try {
                downloader.download(SCRCPY_SERVER_URL, scrcpyFile, gunzip = false)
                runChecked(
                    """
                    mkdir -p $ROOTFS_DIR/opt/deskfleet
                    cp ${shellQuote(scrcpyFile.absolutePath)} $ROOTFS_DIR/opt/deskfleet/scrcpy-server.jar
                    chmod 0644 $ROOTFS_DIR/opt/deskfleet/scrcpy-server.jar
                    """.trimIndent(),
                )
            } finally {
                scrcpyFile.delete()
            }
        }

        val moduleZip = File(cacheDir, "deskfleet-ksu-module.zip")
        try {
            FileOutputStream(moduleZip).use { buildModuleZip(it) }
            runChecked(
                """
                cp ${shellQuote(moduleZip.absolutePath)} $TMP_MODULE_ZIP
                chmod 0644 $TMP_MODULE_ZIP
                if [ -x /data/adb/ksud ]; then
                  /data/adb/ksud module install $TMP_MODULE_ZIP
                fi
                mkdir -p $MODULE_DIR
                cat <<'EOF' > $MODULE_DIR/module.prop
                ${buildModuleProp().trimEnd()}
                EOF
                cat <<'EOF' > $MODULE_DIR/customize.sh
                ${customizeScript().trimEnd()}
                EOF
                cat <<'EOF' > $MODULE_DIR/service.sh
                ${serviceScript().trimEnd()}
                EOF
                cat <<'EOF' > $MODULE_DIR/action.sh
                ${actionScript().trimEnd()}
                EOF
                cat <<'EOF' > $MODULE_DIR/uninstall.sh
                ${uninstallScript().trimEnd()}
                EOF
                chmod 0755 $MODULE_DIR/service.sh $MODULE_DIR/action.sh $MODULE_DIR/uninstall.sh
                rm -f $TMP_MODULE_ZIP $MODULE_DIR/disable
                """.trimIndent(),
            )
        } finally {
            moduleZip.delete()
        }

        if (!isDaemonReady()) {
            runChecked("nohup $MODULE_DIR/service.sh >/dev/null 2>&1 &")
            repeat(60) {
                if (isDaemonReady()) return
                sleepMillis(500)
            }
            val tailLog = shell.run("tail -n 40 $BASE_DIR/daemon.log 2>/dev/null || true").stdout.trim()
            throw IllegalStateException(
                if (tailLog.isNotEmpty()) "DeskFleet daemon did not become ready: $tailLog"
                else "DeskFleet daemon did not become ready in time.",
            )
        }
    }

    private fun downloadDaemonRelease(destination: File) {
        val versionedUrl = "https://github.com/yet-another-ai/deskfleet/releases/download/v$versionName/deskfleet-linux-arm64.tar.gz"
        val primary = runCatching { downloader.download(versionedUrl, destination, gunzip = false) }
        if (primary.isSuccess) return
        val latestUrl = "https://github.com/yet-another-ai/deskfleet/releases/latest/download/deskfleet-linux-arm64.tar.gz"
        downloader.download(latestUrl, destination, gunzip = false)
    }

    private fun isDaemonReady(): Boolean {
        val result = shell.run("$CTL_PATH status 2>/dev/null")
        return result.exitCode == 0 && result.stdout.trim().startsWith("{")
    }

    private fun requireRoot() {
        val result = try {
            shell.run("id -u")
        } catch (error: Exception) {
            throw IllegalStateException(ROOT_ERROR_MESSAGE, error)
        }
        if (result.exitCode != 0 || result.stdout.trim() != "0") {
            throw IllegalStateException(ROOT_ERROR_MESSAGE)
        }
    }

    private fun runChecked(script: String, stdin: String? = null): ShellResult {
        val result = shell.run(script, stdin)
        if (result.exitCode != 0) {
            val detail = result.stderr.trim().ifEmpty { result.stdout.trim() }.ifEmpty { "exit code ${result.exitCode}" }
            throw IllegalStateException("Root command failed: $detail")
        }
        return result
    }

    private fun extractJsonObject(raw: String, command: String): String {
        val trimmed = raw.trim()
        val start = trimmed.indexOf('{')
        if (start < 0) {
            throw IllegalStateException("Unexpected output from $command: $trimmed")
        }
        return JSONObject(trimmed.substring(start)).toString()
    }

    private fun buildModuleProp(): String = """
        id=$MODULE_ID
        name=DeskFleet Daemon (chroot)
        version=v$versionName
        versionCode=$versionCode
        author=DeskFleet
        description=Runs the linux-arm64 deskfleet-daemon inside a native kernel chroot with wake lock and scrcpy-server bridge.
    """.trimIndent() + "\n"

    private fun customizeScript(): String = """
        #!/system/bin/sh
        chmod 0755 "${'$'}MODPATH/service.sh" "${'$'}MODPATH/action.sh" "${'$'}MODPATH/uninstall.sh"
        mkdir -p $BASE_DIR/data
    """.trimIndent() + "\n"

    private fun serviceScript(): String = """
        #!/system/bin/sh
        BASE="$BASE_DIR"
        ROOTFS="$ROOTFS_DIR"
        PIDFILE="${'$'}BASE/service.pid"

        while [ "${'$'}(getprop sys.boot_completed)" != "1" ]; do
          sleep 2
        done

        if [ -f "${'$'}PIDFILE" ]; then
          OLD_PID="${'$'}(cat "${'$'}PIDFILE" 2>/dev/null || true)"
          if [ -n "${'$'}OLD_PID" ] && kill -0 "${'$'}OLD_PID" 2>/dev/null; then
            exit 0
          fi
        fi
        echo "${'$'}${'$'}" > "${'$'}PIDFILE"

        if [ -w /sys/power/wake_lock ]; then
          echo deskfleet_daemon > /sys/power/wake_lock 2>/dev/null || true
        fi

        mkdir -p "${'$'}BASE/data" "${'$'}ROOTFS/tmp" "${'$'}ROOTFS/var/lib/deskfleet" "${'$'}ROOTFS/dev/pts" "${'$'}ROOTFS/dev/shm" "${'$'}ROOTFS/proc" "${'$'}ROOTFS/sys" "${'$'}ROOTFS/sdcard"
        chmod 1777 "${'$'}ROOTFS/tmp"
        ${mountChrootSnippet()}

        if [ ! -s "${'$'}ROOTFS/etc/resolv.conf" ]; then
          printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "${'$'}ROOTFS/etc/resolv.conf"
        fi

        while true; do
          if [ -f "$MODULE_DIR/disable" ] || [ -f "$MODULE_DIR/remove" ]; then
            sleep 5
            continue
          fi
          chroot "${'$'}ROOTFS" /usr/bin/env -i \
            HOME=/root \
            TMPDIR=/tmp \
            SHELL=/bin/bash \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet \
            DESKFLEET_ANDROID_SCRCPY_SERVER=/opt/deskfleet/scrcpy-server.jar \
            DESKFLEET_ANDROID_SCRCPY_VERSION=3.1 \
            DESKFLEET_ANDROID_SHELL="nsenter -t 1 -m -u -i -- /system/bin/sh -c" \
            /opt/deskfleet/deskfleet-daemon >> "${'$'}BASE/daemon.log" 2>&1
          sleep 3
        done
    """.trimIndent() + "\n"

    private fun actionScript(): String = """
        #!/system/bin/sh
        exec $CTL_PATH status
    """.trimIndent() + "\n"

    private fun uninstallScript(): String = """
        #!/system/bin/sh
        BASE="$BASE_DIR"
        ROOTFS="$ROOTFS_DIR"
        if [ -f "${'$'}BASE/service.pid" ]; then
          kill "${'$'}(cat "${'$'}BASE/service.pid" 2>/dev/null)" 2>/dev/null || true
          rm -f "${'$'}BASE/service.pid"
        fi
        pkill -f "/opt/deskfleet/deskfleet-daemon" 2>/dev/null || true
        for TARGET in \
          "${'$'}ROOTFS/sdcard" \
          "${'$'}ROOTFS/var/lib/deskfleet" \
          "${'$'}ROOTFS/dev/shm" \
          "${'$'}ROOTFS/dev/pts" \
          "${'$'}ROOTFS/dev" \
          "${'$'}ROOTFS/sys" \
          "${'$'}ROOTFS/proc"; do
          if grep -qs " ${'$'}TARGET " /proc/mounts; then
            umount "${'$'}TARGET" 2>/dev/null || umount -l "${'$'}TARGET" 2>/dev/null || true
          fi
        done
        if [ -w /sys/power/wake_unlock ]; then
          echo deskfleet_daemon > /sys/power/wake_unlock 2>/dev/null || true
        fi
    """.trimIndent() + "\n"

    private fun deskfleetCtlScript(): String = """
        #!/system/bin/sh
        exec chroot $ROOTFS_DIR /usr/bin/env -i \
          HOME=/root \
          TMPDIR=/tmp \
          SHELL=/bin/bash \
          PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
          DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet \
          DESKFLEET_ANDROID_SCRCPY_SERVER=/opt/deskfleet/scrcpy-server.jar \
          DESKFLEET_ANDROID_SCRCPY_VERSION=3.1 \
          DESKFLEET_ANDROID_SHELL="nsenter -t 1 -m -u -i -- /system/bin/sh -c" \
          /opt/deskfleet/deskfleet-daemon "${'$'}@"
    """.trimIndent() + "\n"

    private fun mountChrootSnippet(): String = """
        grep -qs " $ROOTFS_DIR/proc " /proc/mounts || mount -t proc proc $ROOTFS_DIR/proc
        grep -qs " $ROOTFS_DIR/sys " /proc/mounts || mount -t sysfs sysfs $ROOTFS_DIR/sys
        grep -qs " $ROOTFS_DIR/dev " /proc/mounts || mount -o bind /dev $ROOTFS_DIR/dev
        mkdir -p $ROOTFS_DIR/dev/pts $ROOTFS_DIR/dev/shm 2>/dev/null || true
        grep -qs " $ROOTFS_DIR/dev/pts " /proc/mounts || mount -o bind /dev/pts $ROOTFS_DIR/dev/pts
        grep -qs " $ROOTFS_DIR/dev/shm " /proc/mounts || mount -t tmpfs -o mode=1777 tmpfs $ROOTFS_DIR/dev/shm
        grep -qs " $ROOTFS_DIR/var/lib/deskfleet " /proc/mounts || mount -o bind $BASE_DIR/data $ROOTFS_DIR/var/lib/deskfleet
        if [ -d /sdcard ]; then
          grep -qs " $ROOTFS_DIR/sdcard " /proc/mounts || mount -o bind /sdcard $ROOTFS_DIR/sdcard
        fi
    """.trimIndent()

    private fun writeZipEntry(zip: ZipOutputStream, name: String, content: String) {
        zip.putNextEntry(ZipEntry(name))
        zip.write(content.toByteArray(Charsets.UTF_8))
        zip.closeEntry()
    }

    private fun shellQuote(value: String): String = "'" + value.replace("'", "'\"'\"'") + "'"

    companion object {
        const val MODULE_ID = "deskfleet_daemon"
        const val BASE_DIR = "/data/adb/deskfleet"
        const val ROOTFS_DIR = "$BASE_DIR/rootfs"
        const val CTL_PATH = "$BASE_DIR/bin/deskfleet-ctl"
        const val MODULE_DIR = "/data/adb/modules/$MODULE_ID"
        const val TMP_MODULE_ZIP = "/data/local/tmp/deskfleet-ksu-module.zip"
        const val UBUNTU_ROOTFS_URL = "https://partner-images.canonical.com/core/noble/current/ubuntu-noble-core-cloudimg-arm64-root.tar.gz"
        const val SCRCPY_SERVER_URL = "https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-server-v3.1"
        const val ROOT_ERROR_MESSAGE = "Root access is required. Grant Superuser permission to DeskFleet (KSU) in KernelSU Manager."
    }
}

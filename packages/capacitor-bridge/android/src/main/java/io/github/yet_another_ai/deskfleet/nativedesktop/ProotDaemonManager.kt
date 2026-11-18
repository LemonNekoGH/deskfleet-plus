package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream

internal data class ShellResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
)

internal data class ProotInvocation(
    val executable: String,
    val args: List<String>,
    val env: Map<String, String>,
)

internal interface ProotRunner {
    fun run(invocation: ProotInvocation, stdin: String? = null): ShellResult
}

internal interface AssetDownloader {
    fun download(url: String, destination: File, gunzip: Boolean = false)
}

internal object ProcessProotRunner : ProotRunner {
    override fun run(invocation: ProotInvocation, stdin: String?): ShellResult {
        val builder = ProcessBuilder(listOf(invocation.executable) + invocation.args)
        builder.environment().putAll(invocation.env)
        val process = builder.start()
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
                    setRequestProperty("User-Agent", "DeskFleet-Plus")
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
 * Provisions and manages an unprivileged Ubuntu Linux container using the
 * bundled Termux proot runtime inside the Android app sandbox.
 */
internal class ProotDaemonManager(
    filesDir: File,
    private val cacheDir: File,
    private val nativeLibraryDir: File,
    private val versionName: String,
    private val fallbackMachineName: String,
    private val runner: ProotRunner = ProcessProotRunner,
    private val downloader: AssetDownloader = HttpAssetDownloader,
    private val sleepMillis: (Long) -> Unit = Thread::sleep,
) {
    private val baseDir = File(filesDir, "linux")
    private val rootfsDir = File(baseDir, "rootfs")
    private val dataDir = File(baseDir, "data")
    private val prootTmpDir = File(baseDir, "proot-tmp")
    private val workspaceDir = File(rootfsDir, "root/workspace")
    private val daemonBin = File(rootfsDir, "opt/deskfleet/deskfleet-daemon")
    private val versionFile = File(baseDir, "version")

    fun status(): String {
        if (daemonBin.exists()) {
            val result = runCatching {
                runInProot(listOf("/opt/deskfleet/deskfleet-daemon", "status"))
            }.getOrNull()
            val trimmed = result?.stdout?.trim().orEmpty()
            if (result?.exitCode == 0 && trimmed.startsWith("{")) {
                val parsed = runCatching { JSONObject(trimmed) }.getOrNull()
                if (parsed != null && parsed.has("registrations")) {
                    return parsed.toString()
                }
            }
        }
        return JSONObject()
            .put("machineName", fallbackMachineName)
            .put("registrations", JSONArray())
            .toString()
    }

    fun prepareEnrollment(
        serverUrl: String,
        teamId: String,
        startService: () -> Unit,
    ): String {
        ensureRunning(startService)
        val result = runCheckedInProot(
            listOf(
                "/opt/deskfleet/deskfleet-daemon",
                "prepare-enrollment",
                "--server-url",
                serverUrl,
                "--team-id",
                teamId,
            ),
        )
        return extractJsonObject(result.stdout, "prepare-enrollment")
    }

    fun enroll(serverUrl: String, credentialsJson: String): String {
        val result = runCheckedInProot(
            listOf("/opt/deskfleet/deskfleet-daemon", "enroll", "--server-url", serverUrl),
            stdin = credentialsJson,
        )
        return extractJsonObject(result.stdout, "enroll")
    }

    fun ensureProvisioned() {
        cacheDir.mkdirs()
        rootfsDir.mkdirs()
        dataDir.mkdirs()
        prootTmpDir.mkdirs()

        val shellBin = File(rootfsDir, "bin/sh")
        if (!shellBin.exists()) {
            val rootfsTar = File(cacheDir, "ubuntu-rootfs.tar")
            try {
                downloader.download(UBUNTU_ROOTFS_URL, rootfsTar, gunzip = true)
                val tarArgs = listOf(
                    "--no-same-owner",
                    "--exclude=dev/*",
                    "-xf",
                    rootfsTar.absolutePath,
                    "-C",
                    rootfsDir.absolutePath,
                )
                val prootExtract = runner.run(
                    ProotInvocation(
                        executable = File(nativeLibraryDir, "libproot.so").absolutePath,
                        args = listOf("--link2symlink", "-0", "-w", "/", "/system/bin/tar") + tarArgs,
                        env = prootBaseEnv(nativeLibraryDir, baseDir),
                    ),
                )
                if (prootExtract.exitCode != 0 || !shellBin.exists()) {
                    val directExtract = runner.run(
                        ProotInvocation(
                            executable = "/system/bin/tar",
                            args = tarArgs,
                            env = emptyMap(),
                        ),
                    )
                    if (directExtract.exitCode != 0 || !shellBin.exists()) {
                        val detail = directExtract.stderr.trim()
                            .ifEmpty { prootExtract.stderr.trim() }
                            .ifEmpty { "exit code ${directExtract.exitCode}" }
                        throw IllegalStateException("Failed to extract Ubuntu rootfs: $detail")
                    }
                }
                prepareRootfsDirectories()
                runCheckedInProot(
                    listOf(
                        "/bin/sh",
                        "-c",
                        "apt-get -o APT::Sandbox::User=root update && DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root install -y --no-install-recommends ca-certificates git curl && rm -rf /var/lib/apt/lists/*",
                    ),
                )
            } finally {
                rootfsTar.delete()
            }
        } else {
            prepareRootfsDirectories()
        }

        val installedVersion = if (versionFile.isFile) versionFile.readText().trim() else ""
        if (!daemonBin.exists() || installedVersion != versionName) {
            val tmpArchive = File(rootfsDir, "tmp/deskfleet-linux-arm64.tar.gz")
            try {
                downloadDaemonRelease(tmpArchive)
                runCheckedInProot(
                    listOf(
                        "/bin/sh",
                        "-c",
                        "tar -xzf /tmp/deskfleet-linux-arm64.tar.gz -C /opt/deskfleet && rm -f /tmp/deskfleet-linux-arm64.tar.gz && chmod 0755 /opt/deskfleet/deskfleet-daemon",
                    ),
                )
                versionFile.writeText(versionName, Charsets.UTF_8)
            } finally {
                if (tmpArchive.exists()) tmpArchive.delete()
            }
        }
    }

    fun ensureRunning(startService: () -> Unit) {
        ensureProvisioned()
        if (isDaemonReady()) return

        startService()
        repeat(60) {
            if (isDaemonReady()) return
            sleepMillis(500)
        }
        val logFile = File(baseDir, "daemon.log")
        val tailLog = if (logFile.isFile) {
            logFile.readLines().takeLast(40).joinToString("\n").trim()
        } else {
            ""
        }
        throw IllegalStateException(
            if (tailLog.isNotEmpty()) "DeskFleet daemon did not become ready: $tailLog"
            else "DeskFleet daemon did not become ready in time.",
        )
    }

    private fun prepareRootfsDirectories() {
        val tmpDir = File(rootfsDir, "tmp").apply { mkdirs() }
        tmpDir.setWritable(true, false)
        File(rootfsDir, "opt/deskfleet").mkdirs()
        File(rootfsDir, "var/lib/deskfleet").mkdirs()
        workspaceDir.mkdirs()
        val etcDir = File(rootfsDir, "etc").apply { mkdirs() }
        val resolv = File(etcDir, "resolv.conf")
        if (!resolv.isFile || resolv.length() == 0L) {
            resolv.writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", Charsets.UTF_8)
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
        if (!daemonBin.exists()) return false
        val result = runCatching {
            runInProot(listOf("/opt/deskfleet/deskfleet-daemon", "status"))
        }.getOrNull() ?: return false
        return result.exitCode == 0 && result.stdout.trim().startsWith("{")
    }

    private fun runInProot(commandArgs: List<String>, stdin: String? = null): ShellResult =
        runner.run(buildProotInvocation(nativeLibraryDir, baseDir, commandArgs), stdin)

    private fun runCheckedInProot(commandArgs: List<String>, stdin: String? = null): ShellResult {
        val result = runInProot(commandArgs, stdin)
        if (result.exitCode != 0) {
            val detail = result.stderr.trim().ifEmpty { result.stdout.trim() }.ifEmpty { "exit code ${result.exitCode}" }
            throw IllegalStateException("Container command failed: $detail")
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

    companion object {
        const val UBUNTU_ROOTFS_URL = "https://partner-images.canonical.com/core/noble/current/ubuntu-noble-core-cloudimg-arm64-root.tar.gz"

        internal fun prootBaseEnv(nativeLibraryDir: File, baseDir: File): Map<String, String> = mapOf(
            "LD_LIBRARY_PATH" to nativeLibraryDir.absolutePath,
            "PROOT_LOADER" to File(nativeLibraryDir, "libproot_loader.so").absolutePath,
            "PROOT_TMP_DIR" to File(baseDir, "proot-tmp").absolutePath,
            "PROOT_NO_SECCOMP" to "1",
            "HOME" to "/root",
        )

        internal fun buildProotInvocation(
            nativeLibraryDir: File,
            baseDir: File,
            commandArgs: List<String>,
        ): ProotInvocation {
            val rootfsDir = File(baseDir, "rootfs")
            val dataDir = File(baseDir, "data")
            return ProotInvocation(
                executable = File(nativeLibraryDir, "libproot.so").absolutePath,
                args = listOf(
                    "--kill-on-exit",
                    "--link2symlink",
                    "-0",
                    "-r",
                    rootfsDir.absolutePath,
                    "-b",
                    "/dev",
                    "-b",
                    "/proc",
                    "-b",
                    "/sys",
                    "-b",
                    "${dataDir.absolutePath}:/var/lib/deskfleet",
                    "-w",
                    "/root",
                    "/usr/bin/env",
                    "-i",
                    "HOME=/root",
                    "USER=root",
                    "TERM=xterm-256color",
                    "TMPDIR=/tmp",
                    "SHELL=/bin/bash",
                    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "DESKFLEET_DAEMON_DIRECTORY=/var/lib/deskfleet",
                ) + commandArgs,
                env = prootBaseEnv(nativeLibraryDir, baseDir),
            )
        }
    }
}

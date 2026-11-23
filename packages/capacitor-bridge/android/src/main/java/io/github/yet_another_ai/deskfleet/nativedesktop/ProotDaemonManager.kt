package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
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

    fun runStreaming(
        invocation: ProotInvocation,
        stdin: String? = null,
        onOutput: (String) -> Unit,
    ): ShellResult = run(invocation, stdin)
}

internal interface AssetDownloader {
    fun download(url: String, destination: File, gunzip: Boolean = false)

    fun download(
        url: String,
        destination: File,
        gunzip: Boolean = false,
        onProgress: ((downloadedBytes: Long, totalBytes: Long) -> Unit)?,
    ) = download(url, destination, gunzip)
}

internal fun interface EmbeddedAssetOpener {
    fun open(assetName: String): InputStream?
}

internal object ProcessProotRunner : ProotRunner {
    override fun run(invocation: ProotInvocation, stdin: String?): ShellResult =
        execute(invocation, stdin, onOutput = null)

    override fun runStreaming(
        invocation: ProotInvocation,
        stdin: String?,
        onOutput: (String) -> Unit,
    ): ShellResult = execute(invocation, stdin, onOutput = onOutput)

    private fun execute(
        invocation: ProotInvocation,
        stdin: String?,
        onOutput: ((String) -> Unit)?,
    ): ShellResult {
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
        val stdoutBuilder = StringBuilder()
        val stderrBuilder = StringBuilder()
        val outputLock = Any()
        fun drain(stream: InputStream, sink: StringBuilder) {
            InputStreamReader(stream, Charsets.UTF_8).use { reader ->
                val buffer = CharArray(1024)
                while (true) {
                    val count = reader.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    val chunk = String(buffer, 0, count)
                    sink.append(chunk)
                    if (onOutput != null) {
                        synchronized(outputLock) {
                            onOutput(chunk)
                        }
                    }
                }
            }
        }
        val outThread = Thread { drain(process.inputStream, stdoutBuilder) }
        val errThread = Thread { drain(process.errorStream, stderrBuilder) }
        outThread.start()
        errThread.start()
        val exitCode = process.waitFor()
        outThread.join()
        errThread.join()
        return ShellResult(exitCode, stdoutBuilder.toString(), stderrBuilder.toString())
    }
}

private class CountingInputStream(
    delegate: InputStream,
    private val onBytesRead: (Long) -> Unit,
) : FilterInputStream(delegate) {
    private var totalRead = 0L

    override fun read(): Int {
        val value = super.read()
        if (value != -1) {
            totalRead += 1
            onBytesRead(totalRead)
        }
        return value
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val count = super.read(b, off, len)
        if (count > 0) {
            totalRead += count
            onBytesRead(totalRead)
        }
        return count
    }
}

internal object HttpAssetDownloader : AssetDownloader {
    private const val PROGRESS_INTERVAL_MS = 250L
    private const val PROGRESS_BYTES_STEP = 256L * 1024L

    override fun download(url: String, destination: File, gunzip: Boolean) {
        download(url, destination, gunzip, onProgress = null)
    }

    override fun download(
        url: String,
        destination: File,
        gunzip: Boolean,
        onProgress: ((downloadedBytes: Long, totalBytes: Long) -> Unit)?,
    ) {
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
                    val totalBytes = conn.contentLengthLong
                    val progressLock = Any()
                    var lastEmitMs = 0L
                    var lastEmitBytes = -1L
                    var finalBytes = 0L
                    val counted = CountingInputStream(conn.inputStream) { bytesRead ->
                        finalBytes = bytesRead
                        if (onProgress != null) {
                            val now = System.currentTimeMillis()
                            if (lastEmitBytes < 0L || bytesRead - lastEmitBytes >= PROGRESS_BYTES_STEP || now - lastEmitMs >= PROGRESS_INTERVAL_MS) {
                                synchronized(progressLock) {
                                    lastEmitBytes = bytesRead
                                    lastEmitMs = now
                                    onProgress(bytesRead, totalBytes)
                                }
                            }
                        }
                    }
                    val input: InputStream = if (gunzip) GZIPInputStream(counted) else counted
                    input.use { src ->
                        FileOutputStream(part).use { out ->
                            src.copyTo(out)
                        }
                    }
                    if (onProgress != null && (finalBytes != lastEmitBytes || finalBytes == 0L)) {
                        onProgress(finalBytes, totalBytes)
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
 * Provisions and manages an unprivileged Debian Linux container using the
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
    private val assetOpener: EmbeddedAssetOpener = EmbeddedAssetOpener { null },
    private val onLog: (String) -> Unit = {},
) {
    private val baseDir = File(filesDir, "linux")
    private val rootfsDir = File(baseDir, "rootfs")
    private val dataDir = File(baseDir, "data")
    private val prootTmpDir = File(baseDir, "proot-tmp")
    private val workspaceDir = File(baseDir, "workspace")
    private val daemonBin = File(rootfsDir, "opt/deskfleet/deskfleet-daemon")
    private val scrcpyJar = File(rootfsDir, "opt/deskfleet/scrcpy-server.jar")
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
        emitStep("Preparing machine identity for $serverUrl...")
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
        emitSuccess("Machine identity prepared.")
        return extractJsonObject(result.stdout, "prepare-enrollment")
    }

    fun enroll(serverUrl: String, credentialsJson: String): String {
        emitStep("Saving machine credentials into local daemon...")
        val result = runCheckedInProot(
            listOf("/opt/deskfleet/deskfleet-daemon", "enroll", "--server-url", serverUrl),
            stdin = credentialsJson,
        )
        emitSuccess("Local daemon enrolled.")
        return extractJsonObject(result.stdout, "enroll")
    }

    fun settings(args: List<String>): String {
        if (!daemonBin.exists()) {
            throw IllegalStateException("Local daemon is not installed")
        }
        val result = runInProot(listOf("/opt/deskfleet/deskfleet-daemon", "settings") + args)
        if (result.exitCode != 0) {
            val detail = result.stderr.trim().ifEmpty { result.stdout.trim() }.ifEmpty { "exit code ${result.exitCode}" }
            throw IllegalStateException("Local daemon settings failed: $detail")
        }
        return extractJsonObject(result.stdout, "settings")
    }

    fun installedBinaryVersion(): String? {
        if (!daemonBin.exists()) return null
        val result = runCatching {
            runInProot(listOf("/opt/deskfleet/deskfleet-daemon", "--info"))
        }.getOrNull() ?: return null
        if (result.exitCode != 0) return null
        return runCatching {
            JSONObject(extractJsonObject(result.stdout, "--info"))
                .optJSONObject("native")
                ?.optString("version")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        }.getOrNull()
    }

    private fun installedDaemonVersion(): String =
        installedBinaryVersion()
            ?: if (versionFile.isFile) versionFile.readText().trim() else ""

    fun upgradeDaemonIfNeeded(): Boolean {
        val shellBin = File(rootfsDir, "bin/sh")
        if (!shellBin.exists()) return false
        if (daemonBin.exists() && installedDaemonVersion() == versionName) return false
        prepareRootfsDirectories()
        installDaemonBinary()
        return true
    }

    fun ensureProvisioned() {
        cacheDir.mkdirs()
        rootfsDir.mkdirs()
        dataDir.mkdirs()
        prootTmpDir.mkdirs()
        workspaceDir.mkdirs()

        val shellBin = File(rootfsDir, "bin/sh")
        val installedVersion = if (shellBin.exists()) installedDaemonVersion() else ""
        if (shellBin.exists() && daemonBin.exists() && scrcpyJar.isFile && installedVersion == versionName) {
            prepareRootfsDirectories()
            emitSuccess("Embedded Debian container already provisioned (v$versionName).")
            return
        }

        if (!shellBin.exists()) {
            val rootfsTar = File(cacheDir, "debian-rootfs.tar")
            try {
                downloadDebianRootfs(rootfsTar)
                extractRootfsTar(rootfsTar, shellBin)
                prepareRootfsDirectories()
                emitInfo("Configured /etc/resolv.conf and /etc/hosts.")
                emitStep("$ apt-get update && apt-get install ca-certificates git curl adb")
                runCheckedInProot(
                    listOf(
                        "/bin/sh",
                        "-c",
                        "apt-get -o APT::Sandbox::User=root update && DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root install -y --no-install-recommends ca-certificates git curl adb && rm -rf /var/lib/apt/lists/*",
                    ),
                    streamOutput = true,
                )
            } finally {
                rootfsTar.delete()
            }
        } else {
            prepareRootfsDirectories()
        }

        if (!daemonBin.exists() || installedVersion != versionName) {
            installDaemonBinary()
        }

        if (!scrcpyJar.isFile) {
            val bundledScrcpy = assetOpener.open(EMBEDDED_SCRCPY_ASSET)
            if (bundledScrcpy != null) {
                emitStep("Staging bundled scrcpy-server.jar...")
                scrcpyJar.parentFile?.mkdirs()
                bundledScrcpy.use { src ->
                    FileOutputStream(scrcpyJar).use { out ->
                        src.copyTo(out)
                    }
                }
            } else {
                downloadWithProgress("scrcpy-server.jar", SCRCPY_SERVER_URL, scrcpyJar, gunzip = false)
            }
            scrcpyJar.setReadable(true, false)
        }
        emitSuccess("Embedded Debian container provisioned.")
    }

    private fun installDaemonBinary() {
        val tmpArchive = File(rootfsDir, "tmp/deskfleet-linux-arm64.tar.gz")
        try {
            val bundledDaemon = assetOpener.open(EMBEDDED_DAEMON_ASSET)
            if (bundledDaemon != null) {
                emitStep("Extracting bundled DeskFleet daemon (v$versionName)...")
                tmpArchive.parentFile?.mkdirs()
                bundledDaemon.use { src ->
                    FileOutputStream(tmpArchive).use { out ->
                        src.copyTo(out)
                    }
                }
            } else {
                downloadDaemonRelease(tmpArchive)
            }
            emitInfo("Unpacking /opt/deskfleet/deskfleet-daemon...")
            runCheckedInProot(
                listOf(
                    "/bin/sh",
                    "-c",
                    "rm -rf /opt/deskfleet/dsh && rm -f /opt/deskfleet/deskfleet-daemon && tar -xzf /tmp/deskfleet-linux-arm64.tar.gz -C /opt/deskfleet && rm -f /opt/deskfleet/deskfleet-server /tmp/deskfleet-linux-arm64.tar.gz && chmod 0755 /opt/deskfleet/deskfleet-daemon",
                ),
                streamOutput = true,
            )
            versionFile.writeText(versionName, Charsets.UTF_8)
        } finally {
            if (tmpArchive.exists()) tmpArchive.delete()
        }
    }

    private fun extractRootfsTar(rootfsTar: File, shellBin: File) {
        emitStep("Extracting Debian rootfs...")
        rootfsDir.deleteRecursively()
        rootfsDir.mkdirs()
        val prootExtract = runner.runStreaming(
            ProotInvocation(
                executable = File(nativeLibraryDir, "libproot.so").absolutePath,
                args = listOf(
                    "--link2symlink",
                    "-0",
                    "-w",
                    "/",
                    "/system/bin/tar",
                    "--no-same-owner",
                    "--exclude=dev",
                    "-xf",
                    rootfsTar.absolutePath,
                    "-C",
                    rootfsDir.absolutePath,
                ),
                env = prootBaseEnv(nativeLibraryDir, baseDir),
            ),
            onOutput = onLog,
        )
        if (!shellBin.exists()) {
            emitWarning("Proot tar did not finish cleanly; retrying extraction with /system/bin/tar...")
            val directExtract = runner.runStreaming(
                ProotInvocation(
                    executable = "/system/bin/tar",
                    args = listOf(
                        "-xf",
                        rootfsTar.absolutePath,
                        "-C",
                        rootfsDir.absolutePath,
                    ),
                    env = emptyMap(),
                ),
                onOutput = onLog,
            )
            if (!shellBin.exists()) {
                val detail = directExtract.stderr.trim()
                    .ifEmpty { prootExtract.stderr.trim() }
                    .ifEmpty { "exit code ${directExtract.exitCode}" }
                emitError("Failed to extract Debian rootfs: $detail")
                throw IllegalStateException("Failed to extract Debian rootfs: $detail")
            }
        }
    }

    fun ensureRunning(startService: () -> Unit) {
        ensureProvisioned()
        if (isDaemonReady()) {
            emitSuccess("Local deskfleet-daemon is already running.")
            return
        }

        val logFile = File(baseDir, "daemon.log")
        var logOffset = if (logFile.isFile) logFile.length() else 0L
        emitStep("Starting local deskfleet-daemon service...")
        startService()
        repeat(60) {
            logOffset = drainDaemonLog(logFile, logOffset)
            if (isDaemonReady()) {
                drainDaemonLog(logFile, logOffset)
                emitSuccess("Local deskfleet-daemon is ready.")
                return
            }
            sleepMillis(500)
        }
        drainDaemonLog(logFile, logOffset)
        val tailLog = if (logFile.isFile) {
            logFile.readLines().takeLast(40).joinToString("\n").trim()
        } else {
            ""
        }
        val errorMessage = if (tailLog.isNotEmpty()) "DeskFleet daemon did not become ready: $tailLog"
        else "DeskFleet daemon did not become ready in time."
        emitError(errorMessage)
        throw IllegalStateException(errorMessage)
    }

    private fun prepareRootfsDirectories() {
        val tmpDir = File(rootfsDir, "tmp").apply { mkdirs() }
        tmpDir.setWritable(true, false)
        File(rootfsDir, "opt/deskfleet").mkdirs()
        File(rootfsDir, "var/lib/deskfleet").mkdirs()
        File(rootfsDir, "root/workspace").mkdirs()
        workspaceDir.mkdirs()
        val etcDir = File(rootfsDir, "etc").apply { mkdirs() }
        val resolv = File(etcDir, "resolv.conf")
        if (!resolv.isFile || resolv.length() == 0L) {
            resolv.delete()
            resolv.writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", Charsets.UTF_8)
        }
        val hosts = File(etcDir, "hosts")
        if (!hosts.isFile || hosts.length() == 0L) {
            hosts.delete()
            hosts.writeText("127.0.0.1 localhost\n::1 localhost\n", Charsets.UTF_8)
        }
    }

    private fun downloadDebianRootfs(destination: File) {
        val primary = runCatching {
            downloadWithProgress("Debian rootfs", DEBIAN_ROOTFS_URL, destination, gunzip = true)
        }
        if (primary.isSuccess) return
        emitWarning("Primary Debian rootfs mirror unavailable; trying fallback...")
        downloadWithProgress("Debian rootfs (fallback)", DEBIAN_ROOTFS_FALLBACK_URL, destination, gunzip = true)
    }

    private fun downloadDaemonRelease(destination: File) {
        val versionedUrl = "https://github.com/yet-another-ai/deskfleet/releases/download/v$versionName/deskfleet-linux-arm64.tar.gz"
        val primary = runCatching {
            downloadWithProgress("DeskFleet daemon (v$versionName)", versionedUrl, destination, gunzip = false)
        }
        if (primary.isSuccess) return
        emitWarning("Release v$versionName daemon archive unavailable; trying latest release...")
        val latestUrl = "https://github.com/yet-another-ai/deskfleet/releases/latest/download/deskfleet-linux-arm64.tar.gz"
        downloadWithProgress("DeskFleet daemon (latest)", latestUrl, destination, gunzip = false)
    }

    private fun downloadWithProgress(label: String, url: String, destination: File, gunzip: Boolean) {
        emitStep("Downloading $label...")
        var sawProgress = false
        try {
            downloader.download(url, destination, gunzip) { downloaded, total ->
                sawProgress = true
                val line = if (total > 0L) {
                    val pct = ((downloaded * 100L) / total).coerceIn(0L, 100L)
                    "Downloaded ${formatByteCount(downloaded)} / ${formatByteCount(total)} ($pct%)"
                } else {
                    "Downloaded ${formatByteCount(downloaded)}"
                }
                onLog("\r\u001b[2K  $line")
            }
        } finally {
            if (sawProgress) onLog("\n")
        }
    }

    private fun drainDaemonLog(logFile: File, offset: Long): Long {
        if (!logFile.isFile) return offset
        val length = logFile.length()
        if (length == offset) return offset
        val start = if (length < offset) 0L else offset
        return runCatching {
            RandomAccessFile(logFile, "r").use { raf ->
                raf.seek(start)
                val buf = ByteArray(8192)
                var pos = start
                while (pos < length) {
                    val maxRead = (length - pos).coerceAtMost(buf.size.toLong()).toInt()
                    val read = raf.read(buf, 0, maxRead)
                    if (read <= 0) break
                    onLog(String(buf, 0, read, Charsets.UTF_8))
                    pos += read
                }
                pos
            }
        }.getOrDefault(start)
    }

    private fun formatByteCount(bytes: Long): String {
        if (bytes < 1024L) return "$bytes B"
        val kib = bytes / 1024.0
        if (kib < 1024.0) return String.format(Locale.US, "%.1f KiB", kib)
        return String.format(Locale.US, "%.1f MiB", kib / 1024.0)
    }

    private fun emitStep(text: String) = onLog("\u001b[1;36m==> $text\u001b[0m\n")

    private fun emitInfo(text: String) = onLog("  $text\n")

    private fun emitSuccess(text: String) = onLog("\u001b[1;32m✓ $text\u001b[0m\n")

    private fun emitWarning(text: String) = onLog("\u001b[33m! $text\u001b[0m\n")

    private fun emitError(text: String) = onLog("\u001b[1;31m✗ $text\u001b[0m\n")

    private fun isDaemonReady(): Boolean {
        if (!daemonBin.exists()) return false
        val result = runCatching {
            runInProot(listOf("/opt/deskfleet/deskfleet-daemon", "status"))
        }.getOrNull() ?: return false
        return result.exitCode == 0 && result.stdout.trim().startsWith("{")
    }

    private fun runInProot(commandArgs: List<String>, stdin: String? = null): ShellResult =
        runner.run(buildProotInvocation(nativeLibraryDir, baseDir, commandArgs), stdin)

    private fun runCheckedInProot(
        commandArgs: List<String>,
        stdin: String? = null,
        streamOutput: Boolean = false,
    ): ShellResult {
        val invocation = buildProotInvocation(nativeLibraryDir, baseDir, commandArgs)
        val result = if (streamOutput) {
            runner.runStreaming(invocation, stdin, onLog)
        } else {
            runner.run(invocation, stdin)
        }
        if (result.exitCode != 0) {
            val detail = result.stderr.trim().ifEmpty { result.stdout.trim() }.ifEmpty { "exit code ${result.exitCode}" }
            if (!streamOutput && result.stderr.isNotBlank()) {
                emitError(result.stderr.trim())
            }
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
        const val EMBEDDED_DAEMON_ASSET = "deskfleet-daemon-linux-arm64.tgz"
        const val EMBEDDED_SCRCPY_ASSET = "scrcpy-server.jar"
        const val DEBIAN_ROOTFS_URL = "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-arm64v8/trixie/slim/oci/blobs/rootfs.tar.gz"
        const val DEBIAN_ROOTFS_FALLBACK_URL = "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-arm64v8/trixie/oci/blobs/rootfs.tar.gz"
        const val SCRCPY_SERVER_URL = "https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-server-v3.1"

        internal fun hasSavedRegistrations(filesDir: File): Boolean {
            val baseDir = File(filesDir, "linux")
            val daemonBin = File(baseDir, "rootfs/opt/deskfleet/deskfleet-daemon")
            val registrationsFile = File(baseDir, "data/machine-registrations.json")
            if (!daemonBin.exists() || !registrationsFile.isFile) {
                return false
            }
            return runCatching {
                JSONArray(registrationsFile.readText(Charsets.UTF_8)).length() > 0
            }.getOrDefault(false)
        }

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
            val workspaceDir = File(baseDir, "workspace")
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
                    "-b",
                    "${workspaceDir.absolutePath}:/root/workspace",
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
                    "DESKFLEET_ANDROID_SCRCPY_SERVER=/opt/deskfleet/scrcpy-server.jar",
                    "DESKFLEET_ANDROID_SCRCPY_VERSION=3.1",
                ) + commandArgs,
                env = prootBaseEnv(nativeLibraryDir, baseDir),
            )
        }
    }
}

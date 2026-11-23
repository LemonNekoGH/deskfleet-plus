package io.github.yet_another_ai.deskfleet.nativedesktop

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Supervises the embedded proot Linux container and deskfleet-daemon process
 * inside a special-use Android foreground service with a partial wake lock.
 */
class LocalDaemonService : Service() {
    @Volatile private var supervisorThread: Thread? = null
    @Volatile private var activeProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopDaemonLoop(callStopSelf = true)
            return START_NOT_STICKY
        }

        startForegroundNotification()
        acquireWakeLock()
        startDaemonLoopIfNeeded()
        WirelessAdbController.get(applicationContext).startBackgroundMonitoring()
        return START_STICKY
    }

    override fun onDestroy() {
        stopDaemonLoop(callStopSelf = false)
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(PowerManager::class.java) ?: return
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { lock ->
            wakeLock = null
            if (lock.isHeld) {
                runCatching { lock.release() }
            }
        }
    }

    private fun startDaemonLoopIfNeeded() {
        if (isActive && supervisorThread?.isAlive == true) return
        isActive = true

        val nativeLibDir = File(applicationInfo.nativeLibraryDir)
        val baseDir = File(filesDir, "linux")
        val logFile = File(baseDir, "daemon.log")
        val appVersion = runCatching {
            packageManager.getPackageInfo(packageName, 0).versionName
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: "0.0.0"

        supervisorThread = Thread({
            baseDir.mkdirs()
            File(baseDir, "proot-tmp").mkdirs()
            runCatching {
                ProotDaemonManager(
                    filesDir = filesDir,
                    cacheDir = File(cacheDir, "deskfleet-proot"),
                    nativeLibraryDir = nativeLibDir,
                    versionName = appVersion,
                    fallbackMachineName = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android",
                    assetOpener = EmbeddedAssetOpener { name -> runCatching { assets.open(name) }.getOrNull() },
                    onLog = { chunk -> runCatching { logFile.appendText(chunk) } },
                ).upgradeDaemonIfNeeded()
            }.onFailure { error ->
                runCatching {
                    logFile.appendText("LocalDaemonService upgrade check failed: ${error.message}\n")
                }
            }
            while (isActive && !Thread.currentThread().isInterrupted) {
                try {
                    baseDir.mkdirs()
                    File(baseDir, "proot-tmp").mkdirs()
                    val invocation = ProotDaemonManager.buildProotInvocation(
                        nativeLibraryDir = nativeLibDir,
                        baseDir = baseDir,
                        commandArgs = listOf("/opt/deskfleet/deskfleet-daemon"),
                    )
                    val builder = ProcessBuilder(listOf(invocation.executable) + invocation.args)
                        .redirectErrorStream(true)
                        .redirectOutput(ProcessBuilder.Redirect.appendTo(logFile))
                    builder.environment().putAll(invocation.env)
                    val process = builder.start()
                    activeProcess = process
                    process.waitFor()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                } catch (error: Throwable) {
                    runCatching {
                        logFile.appendText("LocalDaemonService error: ${error.message}\n")
                    }
                } finally {
                    activeProcess = null
                }

                if (!isActive || Thread.currentThread().isInterrupted) break
                try {
                    Thread.sleep(RESTART_DELAY_MS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
        }, "deskfleet-local-daemon").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopDaemonLoop(callStopSelf: Boolean) {
        isActive = false
        WirelessAdbController.get(applicationContext).stopBackgroundMonitoring()
        activeProcess?.let { process ->
            activeProcess = null
            runCatching { process.destroy() }
            runCatching { process.destroyForcibly() }
        }
        supervisorThread?.let { thread ->
            supervisorThread = null
            thread.interrupt()
            try {
                thread.join(500)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        releaseWakeLock()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (callStopSelf) stopSelf()
    }

    private fun startForegroundNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager != null && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Local machine daemon", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                },
            )
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_media_play)
            .setContentTitle("DeskFleet Plus")
            .setContentText("Local Linux container and daemon running")
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
    }

    companion object {
        private const val CHANNEL_ID = "deskfleet_local_daemon"
        private const val NOTIFICATION_ID = 47702
        private const val WAKE_LOCK_TAG = "DeskFleetPlus:LocalDaemon"
        private const val ACTION_STOP = "io.github.yet_another_ai.deskfleet.action.STOP_LOCAL_DAEMON"
        private const val RESTART_DELAY_MS = 3_000L

        @Volatile var isActive: Boolean = false
            private set

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, LocalDaemonService::class.java))
        }

        fun stop(context: Context) {
            if (isActive) {
                context.startService(Intent(context, LocalDaemonService::class.java).setAction(ACTION_STOP))
            }
        }
    }
}

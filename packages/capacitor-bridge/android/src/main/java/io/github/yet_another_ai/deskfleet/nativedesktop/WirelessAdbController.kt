package io.github.yet_another_ai.deskfleet.nativedesktop

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Android runtime coordinator for [WirelessAdbManager]. Bridges NSD wireless ADB
 * discovery, inline RemoteInput pairing notifications, network transitions,
 * and proot ADB execution.
 */
internal class WirelessAdbController private constructor(
    private val appContext: Context,
) {
    private val filesDir = appContext.filesDir
    private val nativeLibraryDir = File(appContext.applicationInfo.nativeLibraryDir)
    private val baseDir = File(filesDir, "linux")
    private val adbBin = File(baseDir, "rootfs/usr/bin/adb")
    private val daemonBin = File(baseDir, "rootfs/opt/deskfleet/deskfleet-daemon")

    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "deskfleet-wireless-adb").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val nsdManager: NsdManager? = appContext.getSystemService(NsdManager::class.java)
    private val connectivityManager: ConnectivityManager? = appContext.getSystemService(ConnectivityManager::class.java)

    private var monitoring = false
    private var networkCallbackRegistered = false
    private var pendingReconcile: ScheduledFuture<*>? = null
    private var delayedStartReconcile: ScheduledFuture<*>? = null

    private var connectDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var pairingDiscoveryListener: NsdManager.DiscoveryListener? = null
    private val activeInfoCallbacks = ConcurrentHashMap<String, NsdManager.ServiceInfoCallback>()
    private val localServicePorts = ConcurrentHashMap<String, Int>()

    private val commandRunner = object : WirelessAdbCommandRunner {
        override fun isAdbAvailable(): Boolean = adbBin.exists()

        override fun runAdb(vararg args: String): ShellResult {
            val invocation = ProotDaemonManager.buildProotInvocation(
                nativeLibraryDir = nativeLibraryDir,
                baseDir = baseDir,
                commandArgs = listOf("/usr/bin/adb") + args.toList(),
            )
            return ProcessProotRunner.run(invocation)
        }

        override fun refreshDaemonCapabilities() {
            if (!daemonBin.exists()) return
            runCatching {
                val invocation = ProotDaemonManager.buildProotInvocation(
                    nativeLibraryDir = nativeLibraryDir,
                    baseDir = baseDir,
                    commandArgs = listOf("/opt/deskfleet/deskfleet-daemon", "status"),
                )
                ProcessProotRunner.run(invocation)
            }
        }
    }

    private val notifier = object : WirelessAdbNotifier {
        override fun showSearchingPairingNotification() {
            postPairingNotification(
                title = "Wireless ADB pairing ready",
                text = "Open Developer options > Wireless debugging > Pair device with pairing code.",
                port = null,
                ongoing = true,
            )
        }

        override fun showPairingCodePrompt(port: Int) {
            postPairingNotification(
                title = "Wireless ADB pairing port $port",
                text = "Enter the 6-digit pairing code shown on your screen.",
                port = port,
                ongoing = true,
            )
        }

        override fun showPairingProgress(port: Int) {
            postPairingNotification(
                title = "Pairing Wireless ADB ($port)...",
                text = "Running adb pair inside the local Linux container.",
                port = null,
                ongoing = true,
            )
        }

        override fun showPairingSucceeded(endpoint: String?) {
            val text = if (endpoint != null) {
                "Connected to $endpoint."
            } else {
                "Paired. Enable Wireless debugging to complete connection."
            }
            postPairingNotification(
                title = "Wireless ADB paired",
                text = text,
                port = null,
                ongoing = false,
            )
        }

        override fun showPairingFailed(message: String) {
            postPairingNotification(
                title = "Wireless ADB pairing failed",
                text = message,
                port = manager.currentState().pairingPort,
                ongoing = false,
            )
        }

        override fun dismissPairingNotification() {
            NotificationManagerCompat.from(appContext).cancel(PAIRING_NOTIFICATION_ID)
        }
    }

    val manager = WirelessAdbManager(
        filesDir = filesDir,
        commandRunner = commandRunner,
        notifier = notifier,
    )

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            handleConnectivityChange()
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            handleConnectivityChange()
        }

        override fun onLost(network: Network) {
            handleConnectivityChange()
        }
    }

    fun addStateListener(listener: (WirelessAdbState) -> Unit): () -> Unit =
        manager.addStateListener(listener)

    fun startBackgroundMonitoring() {
        executor.execute {
            if (!monitoring) {
                monitoring = true
                registerNetworkCallback()
                startServiceDiscovery(WirelessAdbManager.SERVICE_TYPE_CONNECT)
                startServiceDiscovery(WirelessAdbManager.SERVICE_TYPE_PAIRING)
                delayedStartReconcile?.cancel(false)
                delayedStartReconcile = executor.schedule(
                    { manager.reconcile(forceCapabilityRefresh = false) },
                    2_000L,
                    TimeUnit.MILLISECONDS,
                )
            }
            manager.reconcile(forceCapabilityRefresh = false)
        }
    }

    fun stopBackgroundMonitoring() {
        executor.execute {
            monitoring = false
            pendingReconcile?.cancel(false)
            pendingReconcile = null
            delayedStartReconcile?.cancel(false)
            delayedStartReconcile = null
            unregisterNetworkCallback()
            stopAllDiscovery()
            notifier.dismissPairingNotification()
        }
    }

    private fun <T> runOnWorker(block: () -> T): T {
        return try {
            executor.submit(block).get()
        } catch (error: ExecutionException) {
            throw (error.cause ?: error)
        }
    }

    fun getStatus(refresh: Boolean): WirelessAdbState {
        return if (refresh) {
            runOnWorker {
                manager.reconcile(forceCapabilityRefresh = true)
            }
        } else {
            manager.currentState()
        }
    }

    fun startPairingDiscovery(): WirelessAdbState = runOnWorker {
        val next = manager.setPairingDiscoveryActive(true)
        stopDiscovery(WirelessAdbManager.SERVICE_TYPE_PAIRING)
        startServiceDiscovery(WirelessAdbManager.SERVICE_TYPE_PAIRING)
        startServiceDiscovery(WirelessAdbManager.SERVICE_TYPE_CONNECT)
        next
    }

    fun stopPairingDiscovery(): WirelessAdbState = runOnWorker {
        val next = manager.setPairingDiscoveryActive(false)
        if (!monitoring) {
            stopDiscovery(WirelessAdbManager.SERVICE_TYPE_PAIRING)
        }
        next
    }

    fun pair(port: Int, code: String): WirelessAdbState = runOnWorker {
        manager.pair(port, code)
    }

    fun pairFromNotification(port: Int, code: String, onComplete: () -> Unit) {
        executor.execute {
            try {
                runCatching { manager.pair(port, code) }
            } finally {
                onComplete()
            }
        }
    }

    fun connect(port: Int?): WirelessAdbState = runOnWorker {
        manager.connect(port)
    }

    fun setKeepAlive(enabled: Boolean): WirelessAdbState = runOnWorker {
        manager.setKeepAliveTcpip5555(enabled)
    }

    private fun handleConnectivityChange() {
        executor.execute {
            if (!monitoring) return@execute
            val active = connectivityManager?.activeNetwork
            val caps = active?.let { connectivityManager?.getNetworkCapabilities(it) }
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                restartDiscoveryIfMonitoring(WirelessAdbManager.SERVICE_TYPE_CONNECT)
            }
            scheduleReconcileDebounced()
        }
    }

    private fun scheduleReconcileDebounced() {
        pendingReconcile?.cancel(false)
        pendingReconcile = executor.schedule(
            {
                if (monitoring) {
                    manager.onNetworkChanged()
                }
            },
            NETWORK_DEBOUNCE_MS,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun registerNetworkCallback() {
        if (networkCallbackRegistered) return
        val cm = connectivityManager ?: return
        runCatching {
            cm.registerDefaultNetworkCallback(networkCallback, mainHandler)
            networkCallbackRegistered = true
        }
    }

    private fun unregisterNetworkCallback() {
        if (!networkCallbackRegistered) return
        networkCallbackRegistered = false
        runCatching { connectivityManager?.unregisterNetworkCallback(networkCallback) }
    }

    private fun restartDiscoveryIfMonitoring(serviceType: String) {
        if (!monitoring) return
        stopDiscovery(serviceType)
        startServiceDiscovery(serviceType)
    }

    private fun startServiceDiscovery(serviceType: String) {
        val nsd = nsdManager ?: return
        val normalized = normalizeServiceType(serviceType)
        if (normalized == WirelessAdbManager.SERVICE_TYPE_CONNECT && connectDiscoveryListener != null) return
        if (normalized == WirelessAdbManager.SERVICE_TYPE_PAIRING && pairingDiscoveryListener != null) return

        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(type: String, errorCode: Int) {
                executor.execute {
                    clearListenerRef(normalized, this)
                    stopDiscovery(type)
                }
            }

            override fun onStopDiscoveryFailed(type: String, errorCode: Int) {
                executor.execute {
                    clearListenerRef(normalized, this)
                }
            }

            override fun onDiscoveryStarted(type: String) = Unit

            override fun onDiscoveryStopped(type: String) {
                executor.execute {
                    clearListenerRef(normalized, this)
                }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                registerInfoCallback(normalized, serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val key = serviceKey(normalized, serviceInfo.serviceName)
                val removed = activeInfoCallbacks.remove(key)
                if (removed != null) {
                    runCatching { nsd.unregisterServiceInfoCallback(removed) }
                }
                val lostPort = localServicePorts.remove(key) ?: return
                executor.execute {
                    if (normalized == WirelessAdbManager.SERVICE_TYPE_PAIRING) {
                        manager.onPairingServiceLost(lostPort)
                    } else if (normalized == WirelessAdbManager.SERVICE_TYPE_CONNECT) {
                        manager.onConnectServiceLost(lostPort)
                    }
                }
            }
        }

        if (normalized == WirelessAdbManager.SERVICE_TYPE_CONNECT) {
            connectDiscoveryListener = listener
        } else {
            pairingDiscoveryListener = listener
        }

        runCatching {
            nsd.discoverServices(normalized, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            clearListenerRef(normalized, listener)
        }
    }

    private fun registerInfoCallback(normalizedType: String, foundInfo: NsdServiceInfo) {
        val nsd = nsdManager ?: return
        val key = serviceKey(normalizedType, foundInfo.serviceName)
        activeInfoCallbacks.remove(key)?.let { previous ->
            runCatching { nsd.unregisterServiceInfoCallback(previous) }
        }

        val targetInfo = NsdServiceInfo().apply {
            serviceName = foundInfo.serviceName
            serviceType = foundInfo.serviceType ?: normalizedType
        }

        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                activeInfoCallbacks.remove(key, this)
                localServicePorts.remove(key)
            }

            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                val port = serviceInfo.port
                if (port !in 1..65535) return
                val hosts = serviceInfo.hostAddresses
                if (!WirelessAdbManager.isLocalServiceAddress(hosts, collectLocalAddresses())) return
                localServicePorts[key] = port
                if (normalizedType == WirelessAdbManager.SERVICE_TYPE_PAIRING) {
                    manager.onPairingServiceFound(port)
                } else if (normalizedType == WirelessAdbManager.SERVICE_TYPE_CONNECT) {
                    manager.onConnectServiceFound(port)
                }
            }

            override fun onServiceLost() {
                val lostPort = localServicePorts.remove(key) ?: return
                if (normalizedType == WirelessAdbManager.SERVICE_TYPE_PAIRING) {
                    manager.onPairingServiceLost(lostPort)
                } else if (normalizedType == WirelessAdbManager.SERVICE_TYPE_CONNECT) {
                    manager.onConnectServiceLost(lostPort)
                }
            }

            override fun onServiceInfoCallbackUnregistered() {
                activeInfoCallbacks.remove(key, this)
            }
        }

        activeInfoCallbacks[key] = callback
        runCatching {
            nsd.registerServiceInfoCallback(targetInfo, executor, callback)
        }.onFailure {
            activeInfoCallbacks.remove(key, callback)
        }
    }

    private fun stopAllDiscovery() {
        stopDiscovery(WirelessAdbManager.SERVICE_TYPE_CONNECT)
        stopDiscovery(WirelessAdbManager.SERVICE_TYPE_PAIRING)
        localServicePorts.clear()
        val callbacks = activeInfoCallbacks.values.toList()
        activeInfoCallbacks.clear()
        for (cb in callbacks) {
            runCatching { nsdManager?.unregisterServiceInfoCallback(cb) }
        }
    }

    private fun stopDiscovery(serviceType: String) {
        val normalized = normalizeServiceType(serviceType)
        val listener = if (normalized == WirelessAdbManager.SERVICE_TYPE_CONNECT) {
            connectDiscoveryListener.also { connectDiscoveryListener = null }
        } else {
            pairingDiscoveryListener.also { pairingDiscoveryListener = null }
        }
        if (listener != null) {
            runCatching { nsdManager?.stopServiceDiscovery(listener) }
        }
        val prefix = "$normalized:"
        val keys = activeInfoCallbacks.keys.filter { it.startsWith(prefix) }
        for (key in keys) {
            localServicePorts.remove(key)
            activeInfoCallbacks.remove(key)?.let { cb ->
                runCatching { nsdManager?.unregisterServiceInfoCallback(cb) }
            }
        }
        localServicePorts.keys.removeAll { it.startsWith(prefix) }
    }

    private fun clearListenerRef(normalizedType: String, listener: NsdManager.DiscoveryListener) {
        if (normalizedType == WirelessAdbManager.SERVICE_TYPE_CONNECT && connectDiscoveryListener === listener) {
            connectDiscoveryListener = null
        } else if (normalizedType == WirelessAdbManager.SERVICE_TYPE_PAIRING && pairingDiscoveryListener === listener) {
            pairingDiscoveryListener = null
        }
    }

    private fun collectLocalAddresses(): Set<InetAddress> {
        val addresses = LinkedHashSet<InetAddress>()
        val cm = connectivityManager
        if (cm != null) {
            val active = cm.activeNetwork
            if (active != null) {
                cm.getLinkProperties(active)?.linkAddresses?.forEach { linkAddr ->
                    linkAddr.address?.let { addresses.add(it) }
                }
            }
        }
        runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces != null && interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                val inetAddrs = iface.inetAddresses
                while (inetAddrs.hasMoreElements()) {
                    addresses.add(inetAddrs.nextElement())
                }
            }
        }
        return addresses
    }

    private fun postPairingNotification(
        title: String,
        text: String,
        port: Int?,
        ongoing: Boolean,
    ) {
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensurePairingChannel()

        val smallIcon = appContext.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_media_play
        val builder = NotificationCompat.Builder(appContext, PAIRING_CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)

        appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)?.let { launchIntent ->
            val contentPendingIntent = PendingIntent.getActivity(
                appContext,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.setContentIntent(contentPendingIntent)
        }

        if (port != null) {
            val pairIntent = Intent(appContext, WirelessAdbPairingReceiver::class.java).apply {
                action = WirelessAdbPairingReceiver.ACTION_PAIR
                putExtra(WirelessAdbPairingReceiver.EXTRA_PORT, port)
            }
            val pairPendingIntent = PendingIntent.getBroadcast(
                appContext,
                port,
                pairIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            val remoteInput = RemoteInput.Builder(WirelessAdbPairingReceiver.KEY_PAIRING_CODE)
                .setLabel("6-digit pairing code")
                .build()
            val action = NotificationCompat.Action.Builder(0, "Enter pairing code", pairPendingIntent)
                .addRemoteInput(remoteInput)
                .setAllowGeneratedReplies(false)
                .build()
            builder.addAction(action)
        }

        NotificationManagerCompat.from(appContext).notify(PAIRING_NOTIFICATION_ID, builder.build())
    }

    private fun ensurePairingChannel() {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(PAIRING_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    PAIRING_CHANNEL_ID,
                    "Wireless ADB pairing",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Prompts to enter the Android Wireless Debugging pairing code"
                },
            )
        }
    }

    private fun normalizeServiceType(raw: String): String = raw.trimEnd('.')

    private fun serviceKey(normalizedType: String, name: String): String = "$normalizedType:$name"

    companion object {
        private const val PAIRING_CHANNEL_ID = "deskfleet_wireless_adb"
        private const val PAIRING_NOTIFICATION_ID = 47703
        private const val NETWORK_DEBOUNCE_MS = 500L

        @Volatile
        private var instance: WirelessAdbController? = null

        fun get(context: Context): WirelessAdbController {
            val existing = instance
            if (existing != null) return existing
            return synchronized(this) {
                instance ?: WirelessAdbController(context.applicationContext).also { instance = it }
            }
        }
    }
}

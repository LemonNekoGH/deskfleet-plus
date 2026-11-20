package io.github.yet_another_ai.deskfleet.nativedesktop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * Receives inline RemoteInput pairing codes from the Wireless ADB pairing notification
 * and executes `adb pair` inside the embedded proot container.
 */
class WirelessAdbPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PAIR) return
        val port = intent.getIntExtra(EXTRA_PORT, -1)
        val rawCode = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(KEY_PAIRING_CODE)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (port !in 1..65535 || rawCode.isEmpty()) return

        val pendingResult = goAsync()
        WirelessAdbController.get(context.applicationContext).pairFromNotification(port, rawCode) {
            pendingResult.finish()
        }
    }

    companion object {
        const val ACTION_PAIR = "io.github.yet_another_ai.deskfleet.action.PAIR_WIRELESS_ADB"
        const val EXTRA_PORT = "port"
        const val KEY_PAIRING_CODE = "pairing_code"
    }
}

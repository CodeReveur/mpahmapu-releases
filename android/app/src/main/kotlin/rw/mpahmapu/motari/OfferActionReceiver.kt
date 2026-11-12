package rw.mpahmapu.motari

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles "ACCEPT" and "DECLINE" button taps directly from the Lock Screen
 * incoming-ride call notification or the system call overlay over other apps.
 */
class OfferActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_ACCEPT_OFFER = "rw.mpahmapu.motari.ACTION_ACCEPT_OFFER"
        const val ACTION_DECLINE_OFFER = "rw.mpahmapu.motari.ACTION_DECLINE_OFFER"
        const val EXTRA_RIDE_ID = "extra_ride_id"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val rideId = intent.getStringExtra(EXTRA_RIDE_ID) ?: return

        // Stop ringing, vibration, lock-screen call notification, and overlay immediately.
        MotariBackgroundService.dismissOfferCall(context)

        val isAccept = action == ACTION_ACCEPT_OFFER
        val apiAction = if (isAccept) "accept" else "decline"

        // Perform the API call in the background so it succeeds even if MainActivity
        // was not open or the phone is still on the lock screen.
        MotariBackgroundService.performOfferApiAction(context.applicationContext, rideId, apiAction)

        // Notify MainActivity if running, and if accepted, bring the app to the front.
        MainActivity.dispatchOfferActionToFlutter(apiAction, rideId)

        if (isAccept) {
            try {
                val openIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                    putExtra(MainActivity.EXTRA_OFFER_ACTION, "accept")
                    putExtra(EXTRA_RIDE_ID, rideId)
                }
                context.startActivity(openIntent)
            } catch (_: Throwable) {}
        }
    }
}

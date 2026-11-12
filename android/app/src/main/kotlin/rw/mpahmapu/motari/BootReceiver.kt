package rw.mpahmapu.motari

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Starts Ask Motari automatically when the phone boots up or when the app
 * finishes a self-update (`MY_PACKAGE_REPLACED`), launching the background
 * service and opening MainActivity so it initializes and runs in the background.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (
            action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            MotariBackgroundService.start(context)

            try {
                val activityIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                    putExtra(MainActivity.EXTRA_FROM_BOOT, true)
                }
                context.startActivity(activityIntent)
            } catch (_: Throwable) {
                // On newer Android versions where background activity start is restricted,
                // the foreground service continues running and keeps the app active.
            }
        }
    }
}

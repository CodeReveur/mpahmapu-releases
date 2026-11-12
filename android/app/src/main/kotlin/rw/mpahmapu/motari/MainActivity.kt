package rw.mpahmapu.motari

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "rw.mpahmapu.motari/app"
        const val EXTRA_FROM_BOOT = "extra_from_boot"
        const val EXTRA_INCOMING_CALL = "extra_incoming_call"
        const val EXTRA_OFFER_ACTION = "extra_offer_action"

        @Volatile
        var isForeground: Boolean = false

        @Volatile
        private var activeChannel: MethodChannel? = null

        @Volatile
        private var pendingOfferAction: Pair<String, String>? = null

        fun dispatchOfferActionToFlutter(action: String, rideId: String) {
            pendingOfferAction = Pair(action, rideId)
            val ch = activeChannel ?: return
            Handler(Looper.getMainLooper()).post {
                try {
                    ch.invokeMethod("onOfferAction", mapOf("action" to action, "rideId" to rideId))
                } catch (_: Throwable) {}
            }
        }
    }

    private var launchedFromBoot = false
    private var pendingInstallFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchedFromBoot = intent?.getBooleanExtra(EXTRA_FROM_BOOT, false) == true
        enableLockScreenCallWindow()
        handleOfferIntent(intent)
        MotariBackgroundService.start(applicationContext)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(EXTRA_FROM_BOOT, false)) {
            launchedFromBoot = true
        }
        enableLockScreenCallWindow()
        handleOfferIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        isForeground = true
        val pendingFile = pendingInstallFile
        if (pendingFile != null && pendingFile.exists()) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
                pendingInstallFile = null
                launchPackageInstaller(pendingFile)
            }
        }
    }

    override fun onPause() {
        isForeground = false
        super.onPause()
    }

    override fun onDestroy() {
        if (activeChannel != null) {
            activeChannel = null
        }
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun enableLockScreenCallWindow() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            window.addFlags(
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                intent?.getBooleanExtra(EXTRA_INCOMING_CALL, false) == true
            ) {
                val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                km.requestDismissKeyguard(this, null)
            }
        } catch (_: Throwable) {}
    }

    private fun handleOfferIntent(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_OFFER_ACTION)
        val rideId = intent?.getStringExtra(OfferActionReceiver.EXTRA_RIDE_ID)
        if (!action.isNullOrBlank() && !rideId.isNullOrBlank()) {
            dispatchOfferActionToFlutter(action, rideId)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        activeChannel = ch

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(info.versionName ?: "1.2.6")
                    } catch (e: Throwable) {
                        result.success("1.2.6")
                    }
                }
                "wasLaunchedFromBoot" -> {
                    val wasBoot = launchedFromBoot
                    launchedFromBoot = false
                    result.success(wasBoot)
                }
                "getUpdateDirectory" -> {
                    val dir = File(cacheDir, "updates")
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                "startBackgroundService" -> {
                    val title = call.argument<String>("title") ?: "Ask Motari"
                    val body = call.argument<String>("body") ?: "Running in background · Ready for rides"
                    MotariBackgroundService.start(applicationContext, title, body)
                    result.success(true)
                }
                "stopBackgroundService" -> {
                    MotariBackgroundService.stop(applicationContext)
                    result.success(true)
                }
                "showIncomingOfferCall" -> {
                    val rideId = call.argument<String>("rideId") ?: ""
                    val passengerName = call.argument<String>("passengerName") ?: "Passenger"
                    val kind = call.argument<String>("kind") ?: "RIDE"
                    val pickupName = call.argument<String>("pickupName")
                    val destName = call.argument<String>("destName")
                    val fareRwf = call.argument<Int>("fareRwf")
                    val distanceM = call.argument<Double>("distanceM") ?: 0.0
                    val expiresSeconds = call.argument<Int>("expiresSeconds") ?: 25
                    if (rideId.isNotEmpty()) {
                        MotariBackgroundService.showOfferCall(
                            context = applicationContext,
                            rideId = rideId,
                            passengerName = passengerName,
                            kind = kind,
                            pickupName = pickupName,
                            destName = destName,
                            fareRwf = fareRwf,
                            distanceM = distanceM,
                            expiresSeconds = expiresSeconds
                        )
                    }
                    result.success(true)
                }
                "dismissIncomingOfferCall" -> {
                    MotariBackgroundService.dismissOfferCall(applicationContext)
                    result.success(true)
                }
                "consumePendingOfferAction" -> {
                    val pending = pendingOfferAction
                    pendingOfferAction = null
                    if (pending != null) {
                        result.success(mapOf("action" to pending.first, "rideId" to pending.second))
                    } else {
                        result.success(null)
                    }
                }
                "canDrawOverlays" -> {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else {
                        true
                    }
                    result.success(ok)
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        try {
                            val overlayIntent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(overlayIntent)
                        } catch (_: Throwable) {}
                    }
                    result.success(true)
                }
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "bringToFront" -> {
                    try {
                        val frontIntent = Intent(this, MainActivity::class.java).apply {
                            addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                            )
                        }
                        startActivity(frontIntent)
                    } catch (_: Throwable) {}
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                    } else {
                        val ok = triggerApkInstall(File(path))
                        result.success(ok)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun triggerApkInstall(file: File): Boolean {
        if (!file.exists()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                pendingInstallFile = file
                val settingsIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(settingsIntent)
                return true
            }
            pendingInstallFile = null
            launchPackageInstaller(file)
        } catch (_: Throwable) {
            false
        }
    }

    private fun launchPackageInstaller(file: File): Boolean {
        return try {
            val apkUri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            true
        } catch (_: Throwable) {
            false
        }
    }
}

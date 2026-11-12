package rw.mpahmapu.motari

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.location.Location
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.NumberFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Persistent foreground service that:
 * 1. Keeps Ask Motari alive in the background as long as the phone is on.
 * 2. Polls `/api/rides/driver/state` and sends GPS heartbeats whenever the phone
 *    has internet, even if MainActivity was closed or the phone just booted.
 * 3. When a new ride offer arrives, wakes the screen, rings like a phone call,
 *    posts a Lock-Screen Call Notification with ACCEPT / DECLINE actions, and
 *    draws a Call Overlay on top of other apps.
 */
class MotariBackgroundService : Service() {
    companion object {
        const val CHANNEL_ID = "motari.background.service"
        const val CALL_CHANNEL_ID = "motari.incoming.call.v2"
        const val NOTIFICATION_ID = 4201
        const val CALL_NOTIFICATION_ID = 4202

        const val ACTION_START = "rw.mpahmapu.motari.ACTION_START"
        const val ACTION_SHOW_CALL = "rw.mpahmapu.motari.ACTION_SHOW_CALL"
        const val ACTION_DISMISS_CALL = "rw.mpahmapu.motari.ACTION_DISMISS_CALL"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_RIDE_ID = "rideId"
        const val EXTRA_PASSENGER_NAME = "passengerName"
        const val EXTRA_KIND = "kind"
        const val EXTRA_PICKUP_NAME = "pickupName"
        const val EXTRA_DEST_NAME = "destName"
        const val EXTRA_FARE_RWF = "fareRwf"
        const val EXTRA_DISTANCE_M = "distanceM"
        const val EXTRA_EXPIRES_SECONDS = "expiresSeconds"

        private const val API_BASE = "https://backend.mpahmapu.com"
        private const val PREFS_NAME = "FlutterSharedPreferences"

        @Volatile
        private var activeCallRideId: String? = null

        fun start(
            context: Context,
            title: String = "Ask Motari",
            body: String = "Running in background · Ready for rides"
        ) {
            val intent = Intent(context, MotariBackgroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                try {
                    context.startService(intent)
                } catch (_: Throwable) {}
            }
        }

        fun showOfferCall(
            context: Context,
            rideId: String,
            passengerName: String,
            kind: String,
            pickupName: String?,
            destName: String?,
            fareRwf: Int?,
            distanceM: Double,
            expiresSeconds: Int
        ) {
            val intent = Intent(context, MotariBackgroundService::class.java).apply {
                action = ACTION_SHOW_CALL
                putExtra(EXTRA_RIDE_ID, rideId)
                putExtra(EXTRA_PASSENGER_NAME, passengerName)
                putExtra(EXTRA_KIND, kind)
                putExtra(EXTRA_PICKUP_NAME, pickupName ?: "")
                putExtra(EXTRA_DEST_NAME, destName ?: "")
                putExtra(EXTRA_FARE_RWF, fareRwf ?: 0)
                putExtra(EXTRA_DISTANCE_M, distanceM)
                putExtra(EXTRA_EXPIRES_SECONDS, expiresSeconds)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                try {
                    context.startService(intent)
                } catch (_: Throwable) {}
            }
        }

        fun dismissOfferCall(context: Context) {
            activeCallRideId = null
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(CALL_NOTIFICATION_ID)
            } catch (_: Throwable) {}

            val intent = Intent(context, MotariBackgroundService::class.java).apply {
                action = ACTION_DISMISS_CALL
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {}
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, MotariBackgroundService::class.java))
            } catch (_: Throwable) {}
        }

        /**
         * Executes POST /api/rides/driver/{rideId}/{accept|decline} in a background thread
         * so lock-screen or overlay button taps work immediately even when MainActivity is closed.
         */
        fun performOfferApiAction(context: Context, rideId: String, action: String) {
            Executors.newSingleThreadExecutor().execute {
                try {
                    val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    var token = prefs.getString("flutter.access_token", null) ?: return@execute
                    val refresh = prefs.getString("flutter.refresh_token", null)

                    var code = postJson("$API_BASE/api/rides/driver/$rideId/$action", "{}", token).first
                    if (code == 401 && !refresh.isNullOrBlank()) {
                        val newToken = refreshAccessToken(prefs, refresh)
                        if (!newToken.isNullOrBlank()) {
                            token = newToken
                            postJson("$API_BASE/api/rides/driver/$rideId/$action", "{}", token)
                        }
                    }
                } catch (_: Throwable) {}
            }
        }

        private fun refreshAccessToken(
            prefs: android.content.SharedPreferences,
            refreshToken: String
        ): String? {
            return try {
                val payload = JSONObject().put("refreshToken", refreshToken).toString()
                val (code, body) = postJson("$API_BASE/api/auth/refresh", payload, null)
                if (code in 200..299 && body.isNotEmpty()) {
                    val data = JSONObject(body).optJSONObject("data")
                    val access = data?.optString("accessToken", "") ?: ""
                    val nextRefresh = data?.optString("refreshToken", "") ?: ""
                    if (access.isNotEmpty()) {
                        val editor = prefs.edit().putString("flutter.access_token", access)
                        if (nextRefresh.isNotEmpty()) {
                            editor.putString("flutter.refresh_token", nextRefresh)
                        }
                        editor.apply()
                        return access
                    }
                }
                null
            } catch (_: Throwable) {
                null
            }
        }

        private fun postJson(urlStr: String, jsonBody: String, bearer: String?): Pair<Int, String> {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 8000
                readTimeout = 8000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Accept", "application/json")
                if (!bearer.isNullOrBlank()) {
                    setRequestProperty("Authorization", "Bearer $bearer")
                }
            }
            return try {
                OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use {
                    it.write(jsonBody)
                    it.flush()
                }
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.let {
                    BufferedReader(InputStreamReader(it, Charsets.UTF_8)).use { r -> r.readText() }
                } ?: ""
                Pair(code, text)
            } finally {
                conn.disconnect()
            }
        }

        private fun getJson(urlStr: String, bearer: String): Pair<Int, String> {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Authorization", "Bearer $bearer")
            }
            return try {
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.let {
                    BufferedReader(InputStreamReader(it, Charsets.UTF_8)).use { r -> r.readText() }
                } ?: ""
                Pair(code, text)
            } finally {
                conn.disconnect()
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var screenWakeLock: PowerManager.WakeLock? = null
    private var scheduler: ScheduledExecutorService? = null
    private var mediaPlayer: MediaPlayer? = null
    private var overlayView: View? = null
    private var overlayTimerRunnable: Runnable? = null
    private var lastNotifiedRingAt: String? = null
    private var lastNotifiedCashDeclinedAt: String? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
        acquireWakeLock()
        startBackgroundLoop()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW_CALL -> {
                val rideId = intent.getStringExtra(EXTRA_RIDE_ID) ?: ""
                if (rideId.isNotEmpty()) {
                    val passenger = intent.getStringExtra(EXTRA_PASSENGER_NAME) ?: "Passenger"
                    val kind = intent.getStringExtra(EXTRA_KIND) ?: "RIDE"
                    val pickup = intent.getStringExtra(EXTRA_PICKUP_NAME)
                    val dest = intent.getStringExtra(EXTRA_DEST_NAME)
                    val fare = intent.getIntExtra(EXTRA_FARE_RWF, 0)
                    val distanceM = intent.getDoubleExtra(EXTRA_DISTANCE_M, 0.0)
                    val expires = intent.getIntExtra(EXTRA_EXPIRES_SECONDS, 25)
                    triggerIncomingCallAlert(
                        rideId = rideId,
                        passengerName = passenger,
                        kind = kind,
                        pickupName = pickup,
                        destName = dest,
                        fareRwf = if (fare > 0) fare else null,
                        distanceM = distanceM,
                        expiresSeconds = expires
                    )
                }
            }
            ACTION_DISMISS_CALL -> {
                stopCallAlertInternal()
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Ask Motari"
                val body = intent?.getStringExtra(EXTRA_BODY) ?: "Running in background · Ready for rides"
                val notification = buildServiceNotification(title, body)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                } catch (_: Throwable) {}
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        start(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopCallAlertInternal()
        scheduler?.shutdownNow()
        scheduler = null
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Polls driver state every 5 seconds in the background when the phone has internet,
     * so even if the app was started at boot or minimized/closed, incoming rides
     * immediately ring and pop up over other apps and on the lock screen.
     */
    private fun startBackgroundLoop() {
        if (scheduler != null) return
        scheduler = Executors.newSingleThreadScheduledExecutor().also { exec ->
            exec.scheduleWithFixedDelay({
                try {
                    pollDriverOfferInBackground()
                } catch (_: Throwable) {}
                try {
                    pollPassengerRideInBackground()
                } catch (_: Throwable) {}
            }, 1, 5, TimeUnit.SECONDS)
        }
    }

    private fun hasInternet(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(net) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Throwable) {
            true
        }
    }

    @SuppressLint("MissingPermission")
    private fun getLastKnownLocation(): Location? {
        return try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val gps = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
            val net = lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            val passive = lm.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER)
            listOfNotNull(gps, net, passive)
                .filter { it.accuracy <= 500f }
                .maxByOrNull { it.time }
        } catch (_: Throwable) {
            null
        }
    }

    private fun isMandatoryOnlineHours(): Boolean {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        val kigaliHour = (cal.get(Calendar.HOUR_OF_DAY) + 2) % 24
        return kigaliHour in 5..20
    }

    private fun pollDriverOfferInBackground() {
        if (!hasInternet()) return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        var token = prefs.getString("flutter.access_token", null)
        if (token.isNullOrBlank()) return
        val refresh = prefs.getString("flutter.refresh_token", null)
        val wantOnline = isMandatoryOnlineHours() || prefs.getBoolean("flutter.motari_want_online", true)

        val loc = getLastKnownLocation()
        var resp = if (loc != null && wantOnline) {
            val body = JSONObject()
                .put("lat", loc.latitude)
                .put("lng", loc.longitude)
                .toString()
            postJson("$API_BASE/api/rides/driver/heartbeat", body, token)
        } else if (wantOnline) {
            // Even without GPS lat/lng, recursively confirm active internet every 5s so motari stays online and can receive rides
            postJson("$API_BASE/api/rides/driver/online", """{"online":true}""", token)
        } else {
            getJson("$API_BASE/api/rides/driver/state", token)
        }

        if (resp.first == 401 && !refresh.isNullOrBlank()) {
            val newToken = refreshAccessToken(prefs, refresh)
            if (!newToken.isNullOrBlank()) {
                token = newToken
                resp = if (wantOnline) {
                    postJson("$API_BASE/api/rides/driver/online", """{"online":true}""", token)
                } else {
                    getJson("$API_BASE/api/rides/driver/state", token)
                }
            }
        }

        if (resp.first !in 200..299 || resp.second.isEmpty()) return

        val root = JSONObject(resp.second)
        val data = root.optJSONObject("data") ?: return
        val profile = data.optJSONObject("profile")
        if (profile != null && !profile.optBoolean("online", false) && wantOnline) {
            postJson("$API_BASE/api/rides/driver/online", """{"online":true}""", token)
        }

        val activeRide = data.optJSONObject("activeRide")
        if (activeRide != null) {
            val ringAt = activeRide.optString("lastRingAt", "").takeIf { it.isNotEmpty() && it != "null" }
            val ringBy = activeRide.optString("lastRingBy", "")
            if (ringAt != null && ringBy == "PASSENGER" && ringAt != lastNotifiedRingAt) {
                lastNotifiedRingAt = ringAt
                val pName = activeRide.optString("passengerName", "Passenger")
                postHighPriorityAlert(4210, "🔔 $pName is ringing you!", "Your passenger rang your bell.")
            }
        }
        val offer = data.optJSONObject("offer")
        val expires = offer?.optInt("expiresInSeconds", 0) ?: 0

        if (offer != null && activeRide == null && expires > 0) {
            val rideId = offer.optString("rideId", "")
            if (rideId.isNotEmpty()) {
                val passengerName = offer.optString("passengerName", "Passenger")
                val kind = offer.optString("kind", "RIDE")
                val pickupName = offer.optString("pickupName", "").takeIf { it != "null" }
                val destName = offer.optString("destName", "").takeIf { it != "null" }
                val offeredFare = offer.optInt("offeredFareRwf", 0)
                val quotedFare = offer.optInt("quotedFareRwf", 0)
                val fare = if (offeredFare > 0) offeredFare else if (quotedFare > 0) quotedFare else null
                val distanceM = offer.optDouble("distanceToPickupM", 0.0)

                mainHandler.post {
                    triggerIncomingCallAlert(
                        rideId = rideId,
                        passengerName = passengerName,
                        kind = kind,
                        pickupName = pickupName,
                        destName = destName,
                        fareRwf = fare,
                        distanceM = distanceM,
                        expiresSeconds = expires
                    )
                }
            }
        } else if (activeCallRideId != null) {
            mainHandler.post {
                stopCallAlertInternal()
            }
        }
    }

    private fun pollPassengerRideInBackground() {
        if (!hasInternet()) return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val rideToken = prefs.getString("flutter.passenger.ride.token", null)
        if (rideToken.isNullOrBlank()) return

        val loc = getLastKnownLocation()
        val resp = if (loc != null && loc.accuracy <= 35f) {
            val body = JSONObject()
                .put("lat", loc.latitude)
                .put("lng", loc.longitude)
                .toString()
            postJson("$API_BASE/api/rides/public/$rideToken/position", body, null)
        } else {
            getJson("$API_BASE/api/rides/public/$rideToken", "")
        }
        if (resp.first !in 200..299 || resp.second.isEmpty()) return

        val data = JSONObject(resp.second).optJSONObject("data") ?: return
        val ringAt = data.optString("lastRingAt", "").takeIf { it.isNotEmpty() && it != "null" }
        val ringBy = data.optString("lastRingBy", "")
        if (ringAt != null && ringBy == "DRIVER" && ringAt != lastNotifiedRingAt) {
            lastNotifiedRingAt = ringAt
            postHighPriorityAlert(4211, "🔔 Your Motari is ringing you!", "Your motari driver rang your bell.")
        }

        val cashDeclinedAt = data.optString("cashDeclinedAt", "").takeIf { it.isNotEmpty() && it != "null" }
        val paymentStatus = data.optString("paymentStatus", "")
        if (cashDeclinedAt != null && paymentStatus != "PAID" && cashDeclinedAt != lastNotifiedCashDeclinedAt) {
            lastNotifiedCashDeclinedAt = cashDeclinedAt
            postHighPriorityAlert(
                4212,
                "Please Complete Payment",
                "Motari declined cash confirmation. Please approve the MoMo payment prompt (+3.1% fee) on your phone."
            )
        }
    }

    private fun postHighPriorityAlert(notifId: Int, title: String, body: String) {
        try {
            wakeScreenUp()
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            val pi = PendingIntent.getActivity(this, notifId, launchIntent, flags)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CALL_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this).setPriority(Notification.PRIORITY_MAX)
            }
            builder.setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pi)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                builder.setVisibility(Notification.VISIBILITY_PUBLIC)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(notifId, builder.build())
        } catch (_: Throwable) {}
    }

    private fun triggerIncomingCallAlert(
        rideId: String,
        passengerName: String,
        kind: String,
        pickupName: String?,
        destName: String?,
        fareRwf: Int?,
        distanceM: Double,
        expiresSeconds: Int
    ) {
        val alreadyRingingThis = activeCallRideId == rideId
        activeCallRideId = rideId

        wakeScreenUp()

        val isCourier = kind.equals("COURIER", ignoreCase = true)
        val distKm = String.format(Locale.US, "%.1f km", distanceM / 1000.0)
        val fareText = if (fareRwf != null && fareRwf > 0) {
            "RWF " + NumberFormat.getNumberInstance(Locale.US).format(fareRwf)
        } else {
            "Meter ride"
        }

        val routeSummary = buildString {
            append(if (!pickupName.isNullOrBlank()) pickupName else "Pinned pickup")
            if (!destName.isNullOrBlank()) {
                append(" → ")
                append(destName)
            }
        }

        val callTitle = if (isCourier) {
            "PARCEL FOR YOU · $fareText"
        } else {
            "NEW RIDE FOR YOU · $fareText"
        }
        val callBody = "$passengerName ($distKm away) · $routeSummary"

        // 1. Show Lock-Screen + Full-Screen Call Notification with Accept & Decline buttons
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(
            CALL_NOTIFICATION_ID,
            buildIncomingCallNotification(
                rideId = rideId,
                title = callTitle,
                body = callBody,
                passengerName = passengerName,
                fareText = fareText,
                distKm = distKm,
                routeSummary = routeSummary
            )
        )

        if (!alreadyRingingThis) {
            // 2. Start ringing and vibrating like an incoming phone call
            startRingingAndVibration(isCourier)

            // 3. Draw System Call Overlay over other apps (if overlay permission is granted)
            showCallOverlay(
                rideId = rideId,
                isCourier = isCourier,
                passengerName = passengerName,
                distKm = distKm,
                fareText = fareText,
                routeSummary = routeSummary,
                expiresSeconds = expiresSeconds
            )

            // 4. Bring MainActivity to the front over lock screen / other apps if in background
            if (!MainActivity.isForeground) {
                try {
                    val fullIntent = Intent(this, MainActivity::class.java).apply {
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        )
                        putExtra(MainActivity.EXTRA_INCOMING_CALL, true)
                        putExtra(EXTRA_RIDE_ID, rideId)
                    }
                    startActivity(fullIntent)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun stopCallAlertInternal() {
        activeCallRideId = null
        stopRingingAndVibration()
        removeCallOverlay()
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(CALL_NOTIFICATION_ID)
        } catch (_: Throwable) {}
    }

    @Suppress("DEPRECATION")
    private fun wakeScreenUp() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (screenWakeLock?.isHeld == true) {
                screenWakeLock?.release()
            }
            screenWakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "AskMotari::IncomingRideScreenWake"
            ).apply {
                acquire(30_000L)
            }
        } catch (_: Throwable) {}
    }

    private fun startRingingAndVibration(isCourier: Boolean) {
        stopRingingAndVibration()
        try {
            val player = MediaPlayer()
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            player.setAudioAttributes(attrs)

            val assetPath = if (isCourier) {
                "flutter_assets/assets/audio/incoming-delivery.wav"
            } else {
                "flutter_assets/assets/audio/incoming-ride.wav"
            }

            try {
                val afd = assets.openFd(assetPath)
                player.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                afd.close()
            } catch (_: Throwable) {
                val ringUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                player.setDataSource(applicationContext, ringUri)
            }

            player.isLooping = true
            player.prepare()
            player.start()
            mediaPlayer = player
        } catch (_: Throwable) {}

        try {
            val pattern = longArrayOf(0, 900, 400, 900, 400, 900, 400)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v.vibrate(VibrationEffect.createWaveform(pattern, 0))
                } else {
                    @Suppress("DEPRECATION")
                    v.vibrate(pattern, 0)
                }
            }
        } catch (_: Throwable) {}
    }

    private fun stopRingingAndVibration() {
        try {
            mediaPlayer?.stop()
        } catch (_: Throwable) {}
        try {
            mediaPlayer?.release()
        } catch (_: Throwable) {}
        mediaPlayer = null

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator.cancel()
            } else {
                @Suppress("DEPRECATION")
                val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                v.cancel()
            }
        } catch (_: Throwable) {}
    }

    /**
     * Draws a full-width call banner over any other open app when "Display over other apps"
     * (`SYSTEM_ALERT_WINDOW`) is granted, with ACCEPT and DECLINE buttons.
     */
    private fun showCallOverlay(
        rideId: String,
        isCourier: Boolean,
        passengerName: String,
        distKm: String,
        fareText: String,
        routeSummary: String,
        expiresSeconds: Int
    ) {
        removeCallOverlay()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            return
        }

        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val dp = { v: Int ->
                TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_DIP,
                    v.toFloat(),
                    resources.displayMetrics
                ).toInt()
            }

            val root = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(14), dp(16), dp(14))
                background = GradientDrawable().apply {
                    setColor(Color.parseColor("#F50D0D0D"))
                    cornerRadius = dp(16).toFloat()
                    setStroke(dp(2), Color.parseColor("#F97316"))
                }
                elevation = dp(12).toFloat()
            }

            // Header row: Badge + Countdown
            val headerRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            val badgeText = TextView(this).apply {
                text = if (isCourier) "📦 PARCEL CALL FOR YOU" else "📞 NEW RIDE CALL FOR YOU"
                setTextColor(Color.parseColor("#F97316"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTypeface(typeface, Typeface.BOLD)
                letterSpacing = 0.08f
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            val timerText = TextView(this).apply {
                text = "${expiresSeconds}s"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setTypeface(typeface, Typeface.BOLD)
            }
            headerRow.addView(badgeText)
            headerRow.addView(timerText)
            root.addView(headerRow)

            // Passenger + Fare row
            val titleRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(6), 0, dp(2))
            }
            val nameView = TextView(this).apply {
                text = "$passengerName · $distKm"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTypeface(typeface, Typeface.BOLD)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            val fareView = TextView(this).apply {
                text = fareText
                setTextColor(Color.parseColor("#4ADE80"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setTypeface(typeface, Typeface.BOLD)
            }
            titleRow.addView(nameView)
            titleRow.addView(fareView)
            root.addView(titleRow)

            // Route summary
            val routeView = TextView(this).apply {
                text = routeSummary
                setTextColor(Color.parseColor("#BDBDBD"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
                setPadding(0, 0, 0, dp(12))
            }
            root.addView(routeView)

            // Buttons row: DECLINE and ACCEPT
            val buttonsRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }

            val declineBtn = TextView(this).apply {
                text = "✕  DECLINE"
                gravity = Gravity.CENTER
                setTextColor(Color.parseColor("#F87171"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(dp(12), dp(11), dp(12), dp(11))
                background = GradientDrawable().apply {
                    setColor(Color.parseColor("#261212"))
                    cornerRadius = dp(10).toFloat()
                    setStroke(dp(1), Color.parseColor("#7F1D1D"))
                }
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    rightMargin = dp(8)
                }
                setOnClickListener {
                    val broadcast = Intent(applicationContext, OfferActionReceiver::class.java).apply {
                        action = OfferActionReceiver.ACTION_DECLINE_OFFER
                        putExtra(OfferActionReceiver.EXTRA_RIDE_ID, rideId)
                    }
                    sendBroadcast(broadcast)
                }
            }

            val acceptBtn = TextView(this).apply {
                text = "✓  ACCEPT RIDE"
                gravity = Gravity.CENTER
                setTextColor(Color.BLACK)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(dp(12), dp(11), dp(12), dp(11))
                background = GradientDrawable().apply {
                    setColor(Color.parseColor("#F97316"))
                    cornerRadius = dp(10).toFloat()
                }
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.3f)
                setOnClickListener {
                    val broadcast = Intent(applicationContext, OfferActionReceiver::class.java).apply {
                        action = OfferActionReceiver.ACTION_ACCEPT_OFFER
                        putExtra(OfferActionReceiver.EXTRA_RIDE_ID, rideId)
                    }
                    sendBroadcast(broadcast)
                }
            }

            buttonsRow.addView(declineBtn)
            buttonsRow.addView(acceptBtn)
            root.addView(buttonsRow)

            root.setOnClickListener {
                try {
                    val openIntent = Intent(applicationContext, MainActivity::class.java).apply {
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        )
                    }
                    startActivity(openIntent)
                } catch (_: Throwable) {}
            }

            val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }

            @Suppress("DEPRECATION")
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                overlayType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = dp(28)
            }

            val container = LinearLayout(this).apply {
                setPadding(dp(12), 0, dp(12), 0)
                addView(
                    root,
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                )
            }

            wm.addView(container, params)
            overlayView = container

            var left = expiresSeconds
            val tick = object : Runnable {
                override fun run() {
                    left--
                    if (left <= 0 || activeCallRideId != rideId) {
                        removeCallOverlay()
                    } else {
                        timerText.text = "${left}s"
                        mainHandler.postDelayed(this, 1000L)
                    }
                }
            }
            overlayTimerRunnable = tick
            mainHandler.postDelayed(tick, 1000L)
        } catch (_: Throwable) {}
    }

    private fun removeCallOverlay() {
        overlayTimerRunnable?.let { mainHandler.removeCallbacks(it) }
        overlayTimerRunnable = null
        val v = overlayView ?: return
        overlayView = null
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(v)
        } catch (_: Throwable) {}
    }

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "AskMotari::BackgroundServiceWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Throwable) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Throwable) {}
        wakeLock = null
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val bgChannel = NotificationChannel(
                CHANNEL_ID,
                "Ask Motari Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Ask Motari connected for rides and automatic updates"
                setShowBadge(false)
            }
            manager.createNotificationChannel(bgChannel)

            val ringUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val callChannel = NotificationChannel(
                CALL_CHANNEL_ID,
                "Incoming Ride Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Full-screen incoming ride and parcel calls with Accept and Decline"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 900, 400, 900, 400)
                setBypassDnd(true)
                setSound(ringUri, audioAttrs)
            }
            manager.createNotificationChannel(callChannel)
        }
    }

    private fun buildServiceNotification(title: String, body: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    /**
     * Builds the Lock-Screen & Heads-Up Incoming Call Notification with:
     * - Full-Screen Intent (wakes screen & shows over lock screen)
     * - VISIBILITY_PUBLIC (shows passenger details & buttons on locked screen)
     * - ACCEPT and DECLINE action buttons
     */
    private fun buildIncomingCallNotification(
        rideId: String,
        title: String,
        body: String,
        passengerName: String,
        fareText: String,
        distKm: String,
        routeSummary: String
    ): Notification {
        val immutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val fullScreenIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra(MainActivity.EXTRA_INCOMING_CALL, true)
            putExtra(EXTRA_RIDE_ID, rideId)
        }
        val fullScreenPending = PendingIntent.getActivity(this, 100, fullScreenIntent, immutableFlag)

        val acceptIntent = Intent(this, OfferActionReceiver::class.java).apply {
            action = OfferActionReceiver.ACTION_ACCEPT_OFFER
            putExtra(OfferActionReceiver.EXTRA_RIDE_ID, rideId)
        }
        val acceptPending = PendingIntent.getBroadcast(this, 101, acceptIntent, immutableFlag)

        val declineIntent = Intent(this, OfferActionReceiver::class.java).apply {
            action = OfferActionReceiver.ACTION_DECLINE_OFFER
            putExtra(OfferActionReceiver.EXTRA_RIDE_ID, rideId)
        }
        val declinePending = PendingIntent.getBroadcast(this, 102, declineIntent, immutableFlag)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CALL_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MAX)
        }

        val declineAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "DECLINE",
            declinePending
        ).build()

        val acceptAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_call,
            "ACCEPT ($fareText)",
            acceptPending
        ).build()

        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setSubText("$passengerName · $distKm")
            .setStyle(Notification.BigTextStyle().bigText("$passengerName · $distKm away\n$routeSummary\nFare: $fareText"))
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setColor(Color.parseColor("#F97316"))
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(fullScreenPending)
            .setFullScreenIntent(fullScreenPending, true)
            .addAction(declineAction)
            .addAction(acceptAction)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build()
    }
}

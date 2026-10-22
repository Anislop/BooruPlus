package com.booruplus.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app's process in the foreground while downloads run, so leaving
 * the app (Home, another app, screen off) does not let Android stop them.
 * It runs nothing itself: the downloads stay on MainActivity's download
 * threads and in Dart's queue, which start, update, and stop it through the
 * `setDownloadsActive` channel method. Its notification shows the queue's
 * progress and opens the Download Manager.
 */
class DownloadKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification(
            this,
            intent?.getStringExtra(EXTRA_TEXT).orEmpty(),
            intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1,
        )
        startingAt = 0L
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (_: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Stopped while it was starting: a service started in the foreground
        // must call startForeground before it may stop.
        if (stopRequested) {
            stopRequested = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    // Android 15 limits data-sync services to six hours a day.
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    override fun onDestroy() {
        running = false
        startingAt = 0L
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 4201
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PERCENT = "percent"

        // Touched on the main thread only (channel calls and service callbacks).
        private var running = false
        private var stopRequested = false
        // When a start was requested and onStartCommand has not run yet; a
        // start Android dropped is tried again after a while.
        private var startingAt = 0L
        private const val START_TIMEOUT_MILLIS = 10_000L

        private val starting: Boolean
            get() = startingAt != 0L && android.os.SystemClock.elapsedRealtime() - startingAt < START_TIMEOUT_MILLIS

        /**
         * Shows [text] and [percent] (-1 when unknown), starting the service
         * when it is not running yet. Android refuses that start while the
         * app is in the background; Dart starts it when a download begins.
         */
        fun update(context: Context, text: String, percent: Int) {
            stopRequested = false
            if (running) {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(NOTIFICATION_ID, notification(context, text, percent))
                return
            }
            if (starting) return
            try {
                context.startForegroundService(
                    Intent(context, DownloadKeepAliveService::class.java)
                        .putExtra(EXTRA_TEXT, text)
                        .putExtra(EXTRA_PERCENT, percent)
                )
                startingAt = android.os.SystemClock.elapsedRealtime()
            } catch (_: Exception) {
                // Not allowed from the background; downloads still run while
                // the process lives.
            }
        }

        fun stop(context: Context) {
            if (starting) {
                stopRequested = true
                return
            }
            if (running) {
                // A new batch right after this starts the service again.
                running = false
                context.stopService(Intent(context, DownloadKeepAliveService::class.java))
            }
        }

        private fun notification(context: Context, text: String, percent: Int): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager?.getNotificationChannel(CHANNEL_ID) == null) {
                manager?.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Progress of downloads running in the background"
                        setShowBadge(false)
                    }
                )
            }
            // Opens the Download Manager, like a launcher shortcut.
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .putExtra(MainActivity.SHORTCUT_KIND, "downloads")
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Downloading")
                .setContentText(text.take(120))
                .setProgress(100, percent.coerceIn(0, 100), percent < 0)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .build()
        }
    }
}

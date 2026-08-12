// SC-cues@1.0.0 BR-005 backgrounded delivery (#31 / #13 port).
// iOS local-notification → Android NotificationChannel "rest_end" with
// WorkManager dispatch when the app is backgrounded. cue.rest.end is the ONLY
// cue that ever carries notification-class delivery (INV-C6).
package com.moore.app.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.moore.app.MainActivity
import com.moore.app.R
import java.time.Duration

object RestEndNotifications {

    const val CHANNEL_ID = "rest_end"

    /// Create the rest_end channel (idempotent; call at app start).
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.app_name) + " — rest over",
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "Fires when the rest timer expires while Moore is backgrounded (cue.rest.end)."
        manager.createNotificationChannel(channel)
    }

    /// Schedule the rest-end notification `remainingSec` from now via WorkManager
    /// (the backgrounded-dispatch seam). Returns the work request id string.
    fun scheduleRestEnd(context: Context, remainingSec: Int): String {
        val request = OneTimeWorkRequestBuilder<RestEndWorker>()
            .setInitialDelay(Duration.ofSeconds(remainingSec.toLong().coerceAtLeast(0)))
            .build()
        WorkManager.getInstance(context.applicationContext).enqueue(request)
        return request.id.toString()
    }

    /// Cancel a scheduled rest-end (skip / foreground re-entry inside the
    /// BR-005 grace window — the in-process cue wins).
    fun cancelRestEnd(context: Context, workId: String) {
        runCatching { WorkManager.getInstance(context.applicationContext).cancelWorkById(java.util.UUID.fromString(workId)) }
    }

    /// Post cue.rest.end (alert class + visual rest-over; audio is host policy).
    fun postRestEnd(context: Context) {
        val intent = Intent(context, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Rest over")
            .setContentText("Back to work — next set is ready.")
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(REST_END_NOTIFICATION_ID, notification)
    }

    private const val REST_END_NOTIFICATION_ID = 3101
}

/// WorkManager dispatch worker — posts the notification when the timer fires
/// while the process is backgrounded.
class RestEndWorker(
    private val context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        RestEndNotifications.postRestEnd(context)
        return Result.success()
    }
}

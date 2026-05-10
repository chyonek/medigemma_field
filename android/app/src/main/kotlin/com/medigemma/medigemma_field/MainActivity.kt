package com.medigemma.medigemma_field

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity
 *
 * 役割:
 *  1. POST_NOTIFICATIONS の runtime 許可取得 (Android 13+)
 *  2. Flutter ↔ ネイティブ通知用 MethodChannel ハンドラ
 *
 * 通知を MethodChannel で出す理由 (2026-05-11):
 *  flutter_local_notifications は plugin loader 問題で未導入。
 *  permission_handler も Windows-Gradle 環境問題で撤去。
 *  そのため LINE 風 heads-up / lock-screen notification は MainActivity で
 *  直接 NotificationCompat を使って実装する。
 *
 *  実装する notification の特徴:
 *   - IMPORTANCE_HIGH (画面 ON 時は heads-up でポップ表示)
 *   - VISIBILITY_PUBLIC (ロック画面でも全文表示)
 *   - default sound + vibration
 *   - AutoCancel (タップで消える)
 *   - tap → MainActivity 復帰 (PendingIntent)
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MediGemmaMain"
        private const val REQ_POST_NOTIFICATIONS = 1001

        // 通知チャンネル ID (Android 8+ で必須)
        private const val CHANNEL_ID = "medigemma_field_default"
        private const val CHANNEL_NAME = "MediGemma Field"
        private const val CHANNEL_DESC = "Setup and triage notifications"

        // Flutter ↔ Native の MethodChannel 名 (Dart 側と一致させる)
        private const val METHOD_CHANNEL = "medigemma.notifications"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureNotificationChannel()
        ensureNotificationPermission()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        val id = call.argument<Int>("id") ?: 1000
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        try {
                            showNotification(id, title, body)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "showNotification failed", e)
                            result.error("SHOW_FAILED", e.message, null)
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<Int>("id") ?: 0
                        NotificationManagerCompat.from(this).cancel(id)
                        result.success(true)
                    }
                    "cancelAll" -> {
                        NotificationManagerCompat.from(this).cancelAll()
                        result.success(true)
                    }
                    "isPermissionGranted" -> {
                        result.success(isNotificationPermissionGranted())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ─── 通知チャンネル作成 (Android 8+ 必須) ────────────────────
    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH  // heads-up + sound + vibration
        ).apply {
            description = CHANNEL_DESC
            enableVibration(true)
            enableLights(true)
            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
        Log.i(TAG, "Notification channel created: $CHANNEL_ID")
    }

    // ─── 通知表示 (LINE 風 heads-up + lock screen 対応) ──────────
    private fun showNotification(id: Int, title: String, body: String) {
        if (!isNotificationPermissionGranted()) {
            Log.w(TAG, "Notification permission not granted; skipping notification id=$id")
            return
        }
        // タップで MainActivity に戻る PendingIntent
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)  // heads-up (pre-Android 8)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)  // lock screen 全文
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
            .setDefaults(NotificationCompat.DEFAULT_VIBRATE or NotificationCompat.DEFAULT_LIGHTS)

        try {
            NotificationManagerCompat.from(this).notify(id, builder.build())
            Log.i(TAG, "Notification shown: id=$id title='$title'")
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS 未許可の場合 (Android 13+)
            Log.w(TAG, "Notification blocked by permission: ${e.message}")
        }
    }

    // ─── POST_NOTIFICATIONS 許可チェック ────────────────────────
    private fun isNotificationPermissionGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    // ─── 起動時の許可リクエスト ─────────────────────────────────
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Log.i(TAG, "API < 33: POST_NOTIFICATIONS not required")
            return
        }
        if (isNotificationPermissionGranted()) {
            Log.i(TAG, "POST_NOTIFICATIONS already granted")
            return
        }
        Log.i(TAG, "Requesting POST_NOTIFICATIONS permission")
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_POST_NOTIFICATIONS
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            Log.i(TAG, "POST_NOTIFICATIONS result: ${if (granted) "GRANTED" else "DENIED"}")
        }
    }
}

package com.twilio.twilio_voice.receivers

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * BroadcastReceiver that handles inline reply actions from chat notifications
 * shown natively (when the app is in background).
 *
 * Reads persisted API config, auth token, and phone lookup from SharedPreferences,
 * resolves the sender_id, and sends the reply via HTTP directly from Kotlin.
 */
class ChatReplyReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ChatReplyReceiver"
        const val EXTRA_NOTIFICATION_ID = "notificationId"
        const val EXTRA_PAYLOAD = "payload"
        const val KEY_REPLY_TEXT = "reply_input"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "onReceive: action=${intent.action}")

        // Extract the inline reply text
        val remoteInput = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(KEY_REPLY_TEXT)?.toString()
        Log.d(TAG, "replyText=$replyText")

        if (replyText.isNullOrBlank()) {
            Log.d(TAG, "Empty reply text, ignoring")
            return
        }

        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Show "Sending..." loader notification immediately
        if (notificationId != -1) {
            showSendingNotification(context, nm, notificationId)
        }

        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: ""
        Log.d(TAG, "payload=$payload")

        // Do the HTTP call on a background thread, then dismiss notification
        Thread {
            try {
                sendReply(context, replyText, payload)
            } catch (e: Exception) {
                Log.e(TAG, "sendReply failed: ${e.message}", e)
            } finally {
                // Always dismiss the notification after response (success or failure)
                if (notificationId != -1) {
                    nm.cancel(notificationId)
                    Log.d(TAG, "Dismissed notification $notificationId after reply")
                }
            }
        }.start()
    }

    /**
     * Updates the notification to show a "Sending..." state with progress indicator.
     */
    private fun showSendingNotification(context: Context, nm: NotificationManager, notificationId: Int) {
        val channelId = "high_importance_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "High Importance Notifications",
                NotificationManager.IMPORTANCE_HIGH
            )
            nm.createNotificationChannel(channel)
        }
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Sending message...")
            .setProgress(0, 0, true) // indeterminate progress bar
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
        nm.notify(notificationId, notification)
    }

    private fun sendReply(context: Context, replyText: String, payload: String) {
        // Read SharedPreferences (flutter's default shared_preferences prefix is "FlutterSharedPreferences")
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        
        val apiConfigJson = prefs.getString("flutter.notification_reply_api_config", null)
        if (apiConfigJson == null) {
            Log.e(TAG, "No API config in SharedPreferences")
            return
        }
        val apiConfig = JSONObject(apiConfigJson)
        val sendChatUrl = apiConfig.getString("sendChatUrl")
        val authSecret = apiConfig.getString("serverAuthCode")

        val tokenJson = prefs.getString("flutter.notification_reply_auth_token", null)
        if (tokenJson == null) {
            Log.e(TAG, "No auth token in SharedPreferences")
            return
        }
        val tokenMap = JSONObject(tokenJson)
        val tokenType = tokenMap.optString("token_type", "Bearer")
        val accessToken = tokenMap.optString("token", "")
        val authHeader = "$tokenType $accessToken"

        // Parse payload to extract receiver, sender info
        val payloadJson = JSONObject(payload)
        Log.d(TAG, "payloadJson keys: ${payloadJson.keys().asSequence().toList()}")
        
        val phoneNumber = payloadJson.optString("receiver", "")  // Easify phone number
        Log.d(TAG, "phoneNumber (from receiver field): $phoneNumber")
        
        val phoneStr = payloadJson.optString("phone", "")
        Log.d(TAG, "phoneStr raw: $phoneStr")
        val phoneObj = if (phoneStr.isNotEmpty()) {
            try { JSONObject(phoneStr) } catch (e: Exception) {
                Log.e(TAG, "Failed to parse phone as JSON: ${e.message}")
                null
            }
        } else null
        val assignId = phoneObj?.optString("assign_id", "") ?: ""
        Log.d(TAG, "assignId: $assignId")

        val contactStr = payloadJson.optString("contact", "")
        Log.d(TAG, "contactStr raw: $contactStr")
        val contactObj = if (contactStr.isNotEmpty()) {
            try { JSONObject(contactStr) } catch (e: Exception) {
                Log.e(TAG, "Failed to parse contact as JSON: ${e.message}")
                null
            }
        } else null
        val receiver = contactObj?.optString("phone_number", "") ?: ""
        // Handle JSON null: optString returns "null" for JSON null values
        val rawContactId = contactObj?.optString("id", "") ?: ""
        val contactId = if (rawContactId == "null") "" else rawContactId

        // Resolve sender_id from phone lookup
        val phoneLookupJson = prefs.getString("flutter.notification_reply_phone_lookup", null)
        var senderId = ""
        if (phoneLookupJson != null) {
            val lookup = JSONObject(phoneLookupJson)
            // Prefer number lookup (unique) over assign_id (can be shared)
            senderId = lookup.optString("number_$phoneNumber", "")
            if (senderId.isEmpty()) {
                senderId = lookup.optString("assign_$assignId", "")
            }
        }

        Log.d(TAG, "senderId=$senderId, receiver=$receiver, contactId=$contactId")
        if (senderId.isEmpty()) {
            Log.e(TAG, "Could not resolve sender_id, aborting")
            return
        }

        val body = JSONObject().apply {
            put("receiver", receiver)
            put("sender_id", senderId)
            put("message", replyText)
            put("sms_type", "sms")
            put("contact_id", contactId)
        }

        Log.d(TAG, "POST $sendChatUrl body=$body")

        var responseCode = doPost(sendChatUrl, body, authSecret, authHeader)
        Log.d(TAG, "Response code: $responseCode")

        // If 401, try refreshing the token and retry
        if (responseCode == 401) {
            Log.d(TAG, "Got 401 — attempting token refresh...")
            val refreshUrl = apiConfig.optString("refreshTokenUrl", "")
            val refreshToken = tokenMap.optString("refresh_token", "")
            if (refreshUrl.isNotEmpty() && refreshToken.isNotEmpty()) {
                val newAuthHeader = refreshAccessToken(context, refreshUrl, authSecret, refreshToken)
                if (newAuthHeader != null) {
                    Log.d(TAG, "Token refreshed, retrying POST...")
                    responseCode = doPost(sendChatUrl, body, authSecret, newAuthHeader)
                    Log.d(TAG, "Retry response code: $responseCode")
                } else {
                    Log.e(TAG, "Token refresh failed")
                }
            } else {
                Log.e(TAG, "No refresh URL or refresh token available")
            }
        }
    }

    /**
     * Performs an HTTP POST and returns the response code.
     */
    private fun doPost(url: String, body: JSONObject, authSecret: String, authHeader: String): Int {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Accept", "application/json")
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty("X-Server-Auth-Secret", authSecret)
        conn.setRequestProperty("X-Platform", "android")
        conn.setRequestProperty("X-Platform-Type", "App")
        conn.setRequestProperty("Authorization", authHeader)
        conn.doOutput = true
        conn.connectTimeout = 30000
        conn.readTimeout = 30000

        val writer = OutputStreamWriter(conn.outputStream)
        writer.write(body.toString())
        writer.flush()
        writer.close()

        val responseCode = conn.responseCode
        if (responseCode == 200) {
            val response = conn.inputStream.bufferedReader().readText()
            Log.d(TAG, "SUCCESS: $response")
        } else {
            val error = try { conn.errorStream?.bufferedReader()?.readText() } catch (e: Exception) { "no body" }
            Log.e(TAG, "FAILED: $responseCode $error")
        }
        conn.disconnect()
        return responseCode
    }

    /**
     * Refreshes the access token using the refresh token.
     * On success, saves the new token to SharedPreferences and returns the new auth header.
     */
    private fun refreshAccessToken(context: Context, refreshUrl: String, authSecret: String, refreshToken: String): String? {
        try {
            val conn = URL(refreshUrl).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.setRequestProperty("Accept", "application/json")
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("X-Server-Auth-Secret", authSecret)
            conn.setRequestProperty("X-Platform", "android")
            conn.setRequestProperty("X-Platform-Type", "App")
            conn.doOutput = true
            conn.connectTimeout = 30000
            conn.readTimeout = 30000

            val reqBody = JSONObject().apply { put("refresh_token", refreshToken) }
            val writer = OutputStreamWriter(conn.outputStream)
            writer.write(reqBody.toString())
            writer.flush()
            writer.close()

            val responseCode = conn.responseCode
            Log.d(TAG, "Refresh token response: $responseCode")

            if (responseCode == 200) {
                val responseStr = conn.inputStream.bufferedReader().readText()
                val responseJson = JSONObject(responseStr)
                val data = responseJson.optJSONObject("data")
                if (data != null && data.has("token")) {
                    // Save refreshed token to SharedPreferences
                    val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    prefs.edit().putString("flutter.notification_reply_auth_token", data.toString()).apply()
                    Log.d(TAG, "Refreshed token saved to SharedPreferences")

                    val tokenType = data.optString("token_type", "Bearer")
                    val accessToken = data.optString("token", "")
                    return "$tokenType $accessToken"
                }
            } else {
                val error = try { conn.errorStream?.bufferedReader()?.readText() } catch (e: Exception) { "no body" }
                Log.e(TAG, "Refresh FAILED: $responseCode $error")
            }
            conn.disconnect()
        } catch (e: Exception) {
            Log.e(TAG, "refreshAccessToken exception: ${e.message}", e)
        }
        return null
    }
}

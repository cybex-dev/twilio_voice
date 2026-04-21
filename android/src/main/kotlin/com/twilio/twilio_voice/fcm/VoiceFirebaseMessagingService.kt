package com.twilio.twilio_voice.fcm

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.twilio.twilio_voice.receivers.ChatReplyReceiver
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite
import com.twilio.voice.CancelledCallInvite
import com.twilio.voice.MessageListener
import com.twilio.voice.Voice

class VoiceFirebaseMessagingService : FirebaseMessagingService(), MessageListener {
    // Logging counters
    private var log_fcmReceivedCounter: Int = 0
    private var log_onCallInviteCounter: Int = 0

    companion object {
        private const val TAG = "VoiceFirebaseMessagingService"
        private const val WAKELOCK_TAG = "twilio_voice:incoming_call_wakelock"

        /**
         * Action used with [EXTRA_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val ACTION_NEW_TOKEN = "ACTION_NEW_TOKEN"

        /**
         * Extra used with [ACTION_NEW_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val EXTRA_FCM_TOKEN = "token"

        /**
         * Extra used with [ACTION_NEW_TOKEN] to send the FCM token to the TwilioVoicePlugin
         */
        const val EXTRA_TOKEN = "token"
    }


    override fun onNewToken(token: String) {
        val intent = Intent(ACTION_NEW_TOKEN).also {
            it.putExtra(EXTRA_FCM_TOKEN, token)
        }
        sendBroadcast(intent)
    }

    /**
     * Called when message is received.
     *
     * @param remoteMessage Object representing the message received from Firebase Cloud Messaging.
     */
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
    log_fcmReceivedCounter++
    Log.d(TAG, "[LOG] onMessageReceived CALLED. log_fcmReceivedCounter=$log_fcmReceivedCounter")
        val msgTimestamp = System.currentTimeMillis()
        Log.d(TAG, "╔════════════════════════════════════════════════════════════════════╗")
        Log.d(TAG, "║ onMessageReceived START - Timestamp: $msgTimestamp")
        Log.d(TAG, "║ Thread: ${Thread.currentThread().name} (${Thread.currentThread().id})")
        Log.d(TAG, "╚════════════════════════════════════════════════════════════════════╝")
        Log.d(TAG, "Bundle data: " + remoteMessage.data)
        Log.d(TAG, "From: " + remoteMessage.from)
        
        // ============================================================
        // EARLY CHECK: Before even handling the message, use ATOMIC 
        // tryClaimFcmCall() to both CHECK and SET the processing flag
        // in one synchronized operation. This prevents the race condition  
        // where two FCM messages arrive simultaneously and both pass the
        // check before either sets the flag.
        // ============================================================
        if (remoteMessage.data.containsKey("twi_message_type") && 
            remoteMessage.data["twi_message_type"] == "twilio.voice.call") {
            Log.d(TAG, "[FCM-EARLY] Detected Twilio Voice call message")
            
            // ATOMIC check-and-set: This will check if another call exists
            // AND immediately set the processing flag if no other call exists.
            // This prevents two simultaneous FCMs from both passing the check.
            val claimed = TVConnectionService.tryClaimFcmMessage(applicationContext)
            
            if (!claimed) {
                Log.w(TAG, "[FCM-EARLY] ❌ BLOCKING - Another call already exists or is being processed!")
                Log.w(TAG, "[FCM-EARLY] ❌ NOT calling Voice.handleMessage for this FCM")
                Log.d(TAG, "========== onMessageReceived END (early block) ==========")
                return // Don't even let Twilio SDK process this message
            }
            Log.d(TAG, "[FCM-EARLY] ✓ CLAIMED FCM processing slot, proceeding with Voice.handleMessage")
        }
        // ============================================================
        
        // Check if this is a Twilio Voice message
        if (remoteMessage.data.isNotEmpty()) {
            Log.d(TAG, "Data payload is not empty, checking if Twilio message...")
            val valid = Voice.handleMessage(this, remoteMessage.data, this)
            Log.d(TAG, "Voice.handleMessage returned: $valid")
            if (!valid) {
                Log.d(TAG, "onMessageReceived: The message was not a valid Twilio Voice SDK payload, forwarding to Flutter...")
                // Not a Twilio message - release the FCM claim since no onCallInvite will follow
                TVConnectionService.releaseFcmClaim()

                val isChatMessage = remoteMessage.data.containsKey("conversation_id")
                if (isChatMessage) {
                    val isAppInForeground = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
                    if (isAppInForeground) {
                        // App in foreground — forward to Flutter so Dart-side
                        // conversation filter can decide whether to show.
                        Log.d(TAG, "Chat message in foreground — forwarding to Flutter for filtering")
                        forwardToFlutterFirebaseMessaging(remoteMessage)
                    } else {
                        // App in background/terminated — show native notification
                        // with reply action (Dart won't reliably show here).
                        Log.d(TAG, "Chat message in background — showing native notification with reply")
                        showChatNotificationWithReply(remoteMessage)
                    }
                } else {
                    // Forward other non-Twilio messages to Flutter firebase_messaging plugin
                    forwardToFlutterFirebaseMessaging(remoteMessage)
                }
            } else {
                Log.d(TAG, "Twilio Voice message handled successfully - waiting for onCallInvite callback")
            }
        } else {
            Log.d(TAG, "Data payload is empty, forwarding to Flutter")
            // If there's no data payload, forward to Flutter
            forwardToFlutterFirebaseMessaging(remoteMessage)
        }
        Log.d(TAG, "========== onMessageReceived END ==========")
    }
    
    /**
     * Forward the message to the Flutter firebase_messaging plugin for handling
     */
    private fun forwardToFlutterFirebaseMessaging(remoteMessage: RemoteMessage) {
        try {
            // Use reflection to call the Flutter firebase_messaging service
            val flutterServiceClass = Class.forName("io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService")
            val method = flutterServiceClass.getMethod("onMessageReceived", android.content.Context::class.java, RemoteMessage::class.java)
            method.invoke(null, applicationContext, remoteMessage)
        } catch (e: Exception) {
            Log.d(TAG, "Could not forward message to Flutter firebase_messaging: ${e.message}")
        }
    }

    /**
     * Shows a chat notification with an inline reply action entirely from native.
     * The reply is handled by [ChatReplyReceiver] which sends the HTTP request
     * using persisted auth/config from SharedPreferences.
     */
    private fun showChatNotificationWithReply(remoteMessage: RemoteMessage) {
        try {
            val data = remoteMessage.data
            val channelId = "high_importance_channel"
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    channelId,
                    "High Importance Notifications",
                    NotificationManager.IMPORTANCE_HIGH
                )
                notificationManager.createNotificationChannel(channel)
            }

            val notificationId = System.currentTimeMillis().toInt()
            val payloadJson = org.json.JSONObject(data as Map<*, *>).toString()

            // RemoteInput for inline reply
            val remoteInput = RemoteInput.Builder(ChatReplyReceiver.KEY_REPLY_TEXT)
                .setLabel("Type a message...")
                .build()

            // Intent targeting ChatReplyReceiver which sends reply via HTTP
            val replyIntent = Intent(applicationContext, ChatReplyReceiver::class.java).apply {
                action = "reply_action"
                putExtra(ChatReplyReceiver.EXTRA_NOTIFICATION_ID, notificationId)
                putExtra(ChatReplyReceiver.EXTRA_PAYLOAD, payloadJson)
            }

            val replyPendingIntent = PendingIntent.getBroadcast(
                applicationContext,
                notificationId,
                replyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )

            val replyAction = NotificationCompat.Action.Builder(
                android.R.drawable.ic_menu_send,
                "Reply",
                replyPendingIntent
            ).addRemoteInput(remoteInput).build()

            val title = data["title"] ?: data["sender"] ?: remoteMessage.notification?.title ?: "New Message"
            val body = data["body"] ?: data["message"] ?: remoteMessage.notification?.body ?: ""

            val notification = NotificationCompat.Builder(applicationContext, channelId)
                .setSmallIcon(applicationContext.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .addAction(replyAction)
                .build()

            notificationManager.notify(notificationId, notification)
            Log.d(TAG, "showChatNotificationWithReply: shown id=$notificationId title=$title body=$body")
        } catch (e: Exception) {
            Log.e(TAG, "showChatNotificationWithReply failed: ${e.message}", e)
        }
    }

    //region MessageListener
    @SuppressLint("MissingPermission")
    override fun onCallInvite(callInvite: CallInvite) {
    log_onCallInviteCounter++
    Log.d(TAG, "[LOG] onCallInvite CALLED. log_onCallInviteCounter=$log_onCallInviteCounter callSid=${callInvite.callSid}")
        val currentThread = Thread.currentThread()
        val timestamp = System.currentTimeMillis()
        Log.d(TAG, "╔════════════════════════════════════════════════════════════════════╗")
        Log.d(TAG, "║ FCM onCallInvite START - Thread: ${currentThread.name} (${currentThread.id})")
        Log.d(TAG, "║ Timestamp: $timestamp")
        Log.d(TAG, "║ CallSid: ${callInvite.callSid}")
        Log.d(TAG, "║ From: ${callInvite.from}")
        Log.d(TAG, "╚════════════════════════════════════════════════════════════════════╝")

        // ============================================================
        // SIMULTANEOUS INCOMING CALLS HANDLING - ATOMIC CHECK-AND-SET
        // Use synchronized tryClaimIncomingCall() to atomically:
        // 1. Check if there's already an active/pending call
        // 2. If not, immediately mark THIS call as pending
        // This prevents race conditions where two FCM callbacks run in parallel.
        // ============================================================
        Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] Attempting to claim call...")
        val claimed = TVConnectionService.tryClaimIncomingCall(applicationContext, callInvite.callSid)
        
        if (!claimed) {
            // Another call already exists - reject this one immediately
            Log.w(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ❌ FAILED to claim - another call exists!")
            Log.w(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] Rejecting this call at FCM level immediately")
            
            try {
                callInvite.reject(applicationContext)
                Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ✓ Successfully rejected at FCM level")
            } catch (e: Exception) {
                Log.e(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] Failed to reject: ${e.message}", e)
            }
            
            Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ════ FCM END (rejected) ════")
            return // Exit immediately - don't start service, don't show UI
        }
        
        // Successfully claimed this call - proceed with showing UI
        Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ✓ CLAIMED successfully, proceeding with UI")
        // ============================================================

        // ============================================================
        // SYSTEM CALL CHECK: Reject incoming Twilio call if the device
        // is already on a system (cellular/SIM) phone call. This prevents
        // the user seeing two calls ringing simultaneously.
        // NOTE: If the active call is from OUR app (Twilio), the check
        // above (tryClaimIncomingCall) handles it for call waiting.
        // This check is specifically for non-Twilio system calls.
        // ============================================================
        val isDeviceOnSystemCall = isDeviceInSystemCall()
        Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] System call check: isDeviceOnSystemCall=$isDeviceOnSystemCall")
        if (isDeviceOnSystemCall) {
            Log.w(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ❌ Device is already on a system call - rejecting Twilio incoming call")
            try {
                callInvite.reject(applicationContext)
                Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ✓ Successfully rejected (system call active)")
            } catch (e: Exception) {
                Log.e(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] Failed to reject: ${e.message}", e)
            }
            // Clear the pending call claim so future calls can come through
            TVConnectionService.clearPendingIncomingCallFromPrefs(applicationContext)
            Log.d(TAG, "[FCM-${callInvite.callSid.takeLast(6)}] ════ FCM END (rejected - system call active) ════")
            return
        }
        // ============================================================

        // Acquire a partial wake lock to ensure the CPU stays awake long enough
        // to start the foreground service and show the incoming call UI
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            WAKELOCK_TAG
        )
        wakeLock.acquire(10 * 1000L) // 10 seconds max
        Log.d(TAG, "onCallInvite: Wake lock acquired")

        try {
            // Start the TVConnectionService to handle the incoming call
            // The service will show a notification with full-screen intent that works in terminated state
            Log.d(TAG, "onCallInvite: Starting TVConnectionService with ACTION_INCOMING_CALL")
            Intent(applicationContext, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_INCOMING_CALL
                putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, callInvite)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Log.d(TAG, "onCallInvite: Using startForegroundService for Android O+")
                    applicationContext.startForegroundService(this)
                } else {
                    Log.d(TAG, "onCallInvite: Using startService for pre-Android O")
                    applicationContext.startService(this)
                }
            }
            Log.d(TAG, "onCallInvite: TVConnectionService started successfully")

            // Send broadcast to TVBroadcastReceiver for Flutter (if app is in foreground)
            Log.d(TAG, "onCallInvite: Sending broadcast to TVBroadcastReceiver")
            Intent(applicationContext, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL
                putExtra(TVBroadcastReceiver.EXTRA_CALL_INVITE, callInvite)
                putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
                LocalBroadcastManager.getInstance(applicationContext).sendBroadcast(this)
            }
            Log.d(TAG, "onCallInvite: Broadcast sent")
        } catch (e: Exception) {
            Log.e(TAG, "onCallInvite: EXCEPTION while starting service: ${e.message}", e)
        } finally {
            // Release wake lock after starting service (service will manage its own wake state)
            if (wakeLock.isHeld) {
                wakeLock.release()
                Log.d(TAG, "onCallInvite: Wake lock released")
            }
        }
        Log.d(TAG, "========== onCallInvite END ==========")
        
        // Note: We don't directly start IncomingCallActivity here because:
        // 1. On Android 10+, background activity starts are restricted
        // 2. The foreground service's notification with full-screen intent handles this properly
        // 3. The full-screen intent will show IncomingCallActivity even in terminated state
    }

    override fun onCancelledCallInvite(cancelledCallInvite: CancelledCallInvite, callException: CallException?) {
        Log.d(TAG, "onCancelledCallInvite: ", callException)
        Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_CANCEL_CALL_INVITE
            putExtra(TVConnectionService.EXTRA_CANCEL_CALL_INVITE, cancelledCallInvite)
            // IMPORTANT: Must use startForegroundService on Android O+ to avoid crash
            // The service MUST call startForeground() immediately in onStartCommand
            // This fixes: "Context.startForegroundService() did not then call Service.startForeground()"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(this)
            } else {
                applicationContext.startService(this)
            }
        }
    }
    //endregion

    /**
     * Checks if the device is currently on a system (cellular/SIM) phone call.
     * Uses TelecomManager to detect active managed calls (non-self-managed).
     * This does NOT detect Twilio VoIP calls - only native telephony calls.
     * 
     * NOTE: We use TelecomManager.isInManagedCall() instead of TelephonyManager.callState because:
     * - TelephonyManager.callState requires READ_PHONE_STATE runtime permission on Android 12+
     *   (manifest declaration alone is insufficient → SecurityException on Samsung/Android 16)
     * - isInManagedCall() detects only managed (cellular) calls, excluding our self-managed VoIP calls
     * - Both APIs technically require READ_PHONE_STATE, but isInManagedCall() is more robust
     *   and the try-catch gracefully degrades to false if permission is not granted
     * 
     * @return true if the device has an active or ringing system call, false if no system call
     *         or if permission check fails (graceful degradation — we just allow the Twilio call)
     */
    @SuppressLint("MissingPermission")
    private fun isDeviceInSystemCall(): Boolean {
        return try {
            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as? android.telecom.TelecomManager
            telecomManager?.let {
                // isInManagedCall() returns true only for managed ConnectionService calls (cellular)
                // and false for self-managed calls (our Twilio VoIP), which is exactly what we want.
                val isInManagedCall = it.isInManagedCall
                Log.d(TAG, "isDeviceInSystemCall: TelecomManager.isInManagedCall=$isInManagedCall")
                isInManagedCall
            } ?: false
        } catch (e: SecurityException) {
            // READ_PHONE_STATE not granted at runtime — gracefully degrade.
            // We just allow the Twilio call to proceed (better than crashing).
            Log.w(TAG, "isDeviceInSystemCall: SecurityException (READ_PHONE_STATE not granted at runtime), allowing Twilio call")
            false
        } catch (e: Exception) {
            Log.e(TAG, "isDeviceInSystemCall: Error checking call state: ${e.message}", e)
            false
        }
    }
}
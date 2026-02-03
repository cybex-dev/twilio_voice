package com.twilio.twilio_voice.fcm

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite
import com.twilio.voice.CancelledCallInvite
import com.twilio.voice.MessageListener
import com.twilio.voice.Voice

class VoiceFirebaseMessagingService : FirebaseMessagingService(), MessageListener {

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
        Log.d(TAG, "========== onMessageReceived START ==========")
        Log.d(TAG, "Received onMessageReceived()")
        Log.d(TAG, "Bundle data: " + remoteMessage.data)
        Log.d(TAG, "From: " + remoteMessage.from)
        Log.d(TAG, "Priority: " + remoteMessage.priority)
        Log.d(TAG, "Original Priority: " + remoteMessage.originalPriority)
        Log.d(TAG, "TTL: " + remoteMessage.ttl)
        Log.d(TAG, "Sent Time: " + remoteMessage.sentTime)
        
        // Check if this is a Twilio Voice message
        if (remoteMessage.data.isNotEmpty()) {
            Log.d(TAG, "Data payload is not empty, checking if Twilio message...")
            val valid = Voice.handleMessage(this, remoteMessage.data, this)
            Log.d(TAG, "Voice.handleMessage returned: $valid")
            if (!valid) {
                Log.d(TAG, "onMessageReceived: The message was not a valid Twilio Voice SDK payload, forwarding to Flutter...")
                // Forward non-Twilio messages to Flutter firebase_messaging plugin
                forwardToFlutterFirebaseMessaging(remoteMessage)
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

    //region MessageListener
    @SuppressLint("MissingPermission")
    override fun onCallInvite(callInvite: CallInvite) {
        Log.d(TAG, "========== onCallInvite START ==========")
        Log.d(
            TAG,
            "onCallInvite: {\n\t" +
                    "CallSid: ${callInvite.callSid}, \n\t" +
                    "From: ${callInvite.from}, \n\t" +
                    "To: ${callInvite.to}, \n\t" +
                    "Parameters: ${callInvite.customParameters.entries.joinToString { "${it.key}:${it.value}" }},\n\t" +
                    "}"
        )

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
}
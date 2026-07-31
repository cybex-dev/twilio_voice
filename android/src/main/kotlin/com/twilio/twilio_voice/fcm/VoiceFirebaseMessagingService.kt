package com.twilio.twilio_voice.fcm

import android.content.Intent
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VoiceFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "VoiceFirebaseMessagingService"

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
        Log.d(TAG, "onNewToken: FCM token rotated")
        // Deliver via LocalBroadcastManager to TwilioVoicePlugin (when the app is running) so
        // it can re-register the rotated token with Twilio and notify the Dart side. The
        // previous global implicit broadcast reached no receiver on API 26+, silently losing
        // the rotation until the app's next `tokens` call.
        Intent(ACTION_NEW_TOKEN).apply {
            putExtra(EXTRA_FCM_TOKEN, token)
            LocalBroadcastManager.getInstance(applicationContext).sendBroadcast(this)
        }
    }

    /**
     * Called when message is received.
     *
     * @param remoteMessage Object representing the message received from Firebase Cloud Messaging.
     */
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        Log.d(TAG, "Received onMessageReceived()")
        Log.d(TAG, "Bundle data: " + remoteMessage.data)
        Log.d(TAG, "From: " + remoteMessage.from)
        TwilioVoiceFcm.handleMessage(applicationContext, remoteMessage.data)
    }
}

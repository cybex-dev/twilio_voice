package com.twilio.twilio_voice.fcm

import android.util.Log
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
        TwilioVoiceFcm.updateToken(applicationContext, token)
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

package com.twilio.twilio_voice.fcm

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.telecom.*
import android.util.Log
import androidx.core.content.ContextCompat
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
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneState

class VoiceFirebaseMessagingService : FirebaseMessagingService(), MessageListener {

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
        Log.d(TAG, "Received onMessageReceived()")
        Log.d(TAG, "Bundle data: " + remoteMessage.data)
        Log.d(TAG, "From: " + remoteMessage.from)
        // If application is running in the foreground use local broadcast to handle message.
        // Otherwise use the background isolate to handle message.
        if (remoteMessage.data.isNotEmpty()) {
            val valid = Voice.handleMessage(this, remoteMessage.data, this)
            if (!valid) {
                Log.d(TAG, "onMessageReceived: The message was not a valid Twilio Voice SDK payload, continuing...")
            }
        }
    }

    //region MessageListener
    @SuppressLint("MissingPermission")
    override fun onCallInvite(callInvite: CallInvite) {

        // Get TelecomManager instance
        val tm = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        // check read phone state permission here before sending broadcasts
        if (!tm.canReadPhoneState(applicationContext)) {
            Log.e(TAG, "onCallInvite: No READ_PHONE_STATE permission, cannot check if phone account is registered. Ignoring incoming call");

            // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
            Intent(applicationContext, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED
                putExtra(TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON, "No READ_PHONE_STATE permission, cannot check if phone account is registered. Ignoring incoming call")
                putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
                LocalBroadcastManager.getInstance(applicationContext).sendBroadcast(this)
            }

            // Reject incoming call
            Log.d(TAG, "onCallInvite: Rejecting incoming call")
            callInvite.reject(applicationContext);

            return
        }

        // send broadcast to TVConnectionService, we notify the TelecomManager about incoming call
        Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_INCOMING_CALL
            putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, callInvite)
            applicationContext.startService(this)
        }

        // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
        Intent(applicationContext, TVBroadcastReceiver::class.java).apply {
            action = TVBroadcastReceiver.ACTION_INCOMING_CALL
            putExtra(TVBroadcastReceiver.EXTRA_CALL_INVITE, callInvite)
            putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
            LocalBroadcastManager.getInstance(applicationContext).sendBroadcast(this)
        }
    }

    override fun onCancelledCallInvite(cancelledCallInvite: CancelledCallInvite, callException: CallException?) {
        Log.e(TAG, "onCancelledCallInvite: ", callException)
        Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_CANCEL_CALL_INVITE
            putExtra(TVConnectionService.EXTRA_CANCEL_CALL_INVITE, cancelledCallInvite)
            ContextCompat.startForegroundService(applicationContext, this)
        }
    }
    //endregion
}
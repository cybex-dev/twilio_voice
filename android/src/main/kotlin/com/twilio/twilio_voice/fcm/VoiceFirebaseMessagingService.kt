package com.twilio.twilio_voice.fcm

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.telecom.*
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.content.ContextCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.types.ContextExtension.hasMicrophoneAccess
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneNumbers
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite
import com.twilio.voice.CancelledCallInvite
import com.twilio.voice.MessageListener
import com.twilio.voice.Voice
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneState
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccount

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
    @RequiresPermission(allOf = [Manifest.permission.RECORD_AUDIO, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS])
    @SuppressLint("MissingPermission")
    override fun onCallInvite(callInvite: CallInvite) {
        // Get TelecomManager instance
        val tm = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        var shouldRejectCall = false
        var requiredPermissions: Array<String> = emptyArray()

        // Check permission READ_PHONE_STATE
        if (!tm.canReadPhoneState(applicationContext)) {
            shouldRejectCall = true
            requiredPermissions += "No `READ_PHONE_STATE` permission, cannot check if phone account is registered. Request this with `requestReadPhoneStatePermission()`"
        }

        // Check permission READ_PHONE_NUMBERS
        if (!tm.canReadPhoneNumbers(applicationContext)) {
            shouldRejectCall = true
            requiredPermissions += "No `READ_PHONE_NUMBERS` permission, cannot communicate with ConnectionService if not granted. Request this with `requestReadPhoneNumbersPermission()`"
        }

        // Check permission RECORD_AUDIO
        if (!applicationContext.hasMicrophoneAccess()) {
            shouldRejectCall = true
            requiredPermissions += "No `RECORD_AUDIO` permission, VoiceSDK requires this permission. Request this with `requestMicPermission()`"
        }

        if(!tm.hasCallCapableAccount(applicationContext, TVConnectionService::class.java.name)) {
            shouldRejectCall = true
            requiredPermissions += "No call capable phone account registered. Request this with `registerPhoneAccount()`"
        }

        if (shouldRejectCall) {
            requiredPermissions.forEach { Log.e(TAG, it) }
            Log.e(TAG, "onCallInvite: Rejecting incoming call\nSID: ${callInvite.callSid}")

            // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
            Intent(applicationContext, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED
                putExtra(TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON, requiredPermissions)
                putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
                LocalBroadcastManager.getInstance(applicationContext).sendBroadcast(this)
            }

            // Reject incoming call
            Log.d(TAG, "onCallInvite: Rejecting incoming call")
            callInvite.reject(applicationContext)

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
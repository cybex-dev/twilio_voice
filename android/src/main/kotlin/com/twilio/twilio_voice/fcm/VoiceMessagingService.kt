package com.twilio.twilio_voice.fcm

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.google.firebase.messaging.RemoteMessage
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.storage.StorageImpl
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneNumbers
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneState
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccount
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite
import com.twilio.voice.CancelledCallInvite
import com.twilio.voice.MessageListener
import com.twilio.voice.Voice

class VoiceMessagingService(private val applicationContext: Context) : MessageListener{
    companion object {
        private const val TAG = "VoiceMessagingService"


    }

    //region MessageListener
    @RequiresPermission(allOf = [Manifest.permission.RECORD_AUDIO, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS])
    @SuppressLint("MissingPermission")
    override fun onCallInvite(callInvite: CallInvite) {
        Log.d(
            TAG,
            "onCallInvite: {\n\t" +
                    "CallSid: ${callInvite.callSid}, \n\t" +
                    "From: ${callInvite.from}, \n\t" +
                    "To: ${callInvite.to}, \n\t" +
                    "Parameters: ${callInvite.customParameters.entries.joinToString { "${it.key}:${it.value}" }},\n\t" +
                    "}"
        )
        // Get TelecomManager instance
        val tm = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        val shouldRejectOnNoPermissions: Boolean = StorageImpl(applicationContext).rejectOnNoPermissions
        var missingPermissions: Array<String> = emptyArray()

        // Check permission READ_PHONE_STATE
        if (!tm.canReadPhoneState(applicationContext)) {
            missingPermissions += "No `READ_PHONE_STATE` permission, cannot check if phone account is registered. Request this with `requestReadPhoneStatePermission()`"
        }

        // Check permission READ_PHONE_NUMBERS
        if (!tm.canReadPhoneNumbers(applicationContext)) {
            missingPermissions += "No `READ_PHONE_NUMBERS` permission, cannot communicate with ConnectionService if not granted. Request this with `requestReadPhoneNumbersPermission()`"
        }

        // NOTE(cybex-dev): Foreground services requiring privacy permission e.g. microphone or
        // camera are required to be started in the foreground. Since we're using the Telecom's
        // PhoneAccount, we don't directly require microphone access. Further, microphone access
        // is always denied if the app requiring microphone access via a Foreground service
        // is in the background (by design).
//        // Check permission RECORD_AUDIO
//        if (!applicationContext.hasMicrophoneAccess()) {
//            shouldRejectCall = true
//            requiredPermissions += "No `RECORD_AUDIO` permission, VoiceSDK requires this permission. Request this with `requestMicPermission()`"
//        }

        if(!tm.hasCallCapableAccount(applicationContext, TVConnectionService::class.java.name)) {
            missingPermissions += "No call capable phone account registered. Request this with `registerPhoneAccount()`"
        }

        // If we have missingPermissions, then we cannot proceed with answering the call.
        if (missingPermissions.isNotEmpty()) {
            missingPermissions.forEach { Log.e(TAG, it) }

            // If we're not rejecting on no permissions, and can't answer because we don't have the required permissions / phone account, we let it ring.
            // This details a use-case where multiple instances of a user is logged in, and can accept the call on another device.
            if(!shouldRejectOnNoPermissions) {
                return
            }

            Log.e(TAG, "onCallInvite: Rejecting incoming call\nSID: ${callInvite.callSid}")

            // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
            Intent(applicationContext, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED
                putExtra(TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON, missingPermissions)
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
        Log.d(TAG, "onCancelledCallInvite: ", callException)
        Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_CANCEL_CALL_INVITE
            putExtra(TVConnectionService.EXTRA_CANCEL_CALL_INVITE, cancelledCallInvite)
            applicationContext.startService(this)
        }
    }
}
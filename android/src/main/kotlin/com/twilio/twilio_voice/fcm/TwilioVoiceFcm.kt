package com.twilio.twilio_voice.fcm

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.localbroadcastmanager.content.LocalBroadcastManager
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

/**
 * Entry point for FCM messages for Twilio Voice calls.
 */
object TwilioVoiceFcm {

    private const val TAG = "TwilioVoiceFcm"

    /**
     * Hands [data] to the Twilio Voice SDK, raising an incoming call (or cancelling one) if it is
     * a Twilio Voice payload. Safe for any payload. Non-twilio payloads are ignored.
     *
     * @param context any [Context]; the application context is used internally.
     * @param data the FCM message data payload, i.e. `RemoteMessage.getData()`.
     * @return `true` if [data] was a Twilio Voice payload and has been handled, `false` otherwise -
     *         in which case the caller should handle the message itself.
     */
    @JvmStatic
    fun handleMessage(context: Context, data: Map<String, String>): Boolean {
        if (data.isEmpty()) {
            Log.d(TAG, "handleMessage: empty data payload, ignoring.")
            return false
        }
        val appContext = context.applicationContext
        val handled = Voice.handleMessage(appContext, data, VoiceMessageListener(appContext))
        if (!handled) {
            Log.d(TAG, "handleMessage: not a valid Twilio Voice SDK payload, continuing...")
        }
        return handled
    }

    /**
     * Notifies the plugin that the FCM token has rotated, so it can re-register it with Twilio.
     * Note: this is the FCM device token, not the Twilio access token.
     *
     * @param context any [Context]; the application context is used internally.
     * @param token the new FCM registration token.
     */
    @JvmStatic
    fun updateToken(context: Context, token: String) {
        Log.d(TAG, "updateToken: FCM token rotated")
        val appContext = context.applicationContext
        // Deliver via LocalBroadcastManager to TwilioVoicePlugin (when the app is running) so it
        // can re-register the rotated token with Twilio and notify the Dart side.
        Intent(VoiceFirebaseMessagingService.ACTION_NEW_TOKEN).apply {
            putExtra(VoiceFirebaseMessagingService.EXTRA_FCM_TOKEN, token)
            LocalBroadcastManager.getInstance(appContext).sendBroadcast(this)
        }
    }
}

/**
 * A [MessageListener] that handles Twilio Voice SDK call invites and cancellations, raising
 * incoming calls via the system TelecomManager and notifying the Flutter side via local broadcasts.
 */
internal class VoiceMessageListener(private val context: Context) : MessageListener {

    companion object {
        private const val TAG = "VoiceMessageListener"
    }

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
        val storage = StorageImpl(context)

        // Reject the invite when already on a call and the app opted out of concurrent calls.
        // Deliberately uses TVConnectionService.hasActiveCalls() - the plugin's *own* connections -
        // rather than TelecomManager.isOnCall(), which reports true for any call on the device
        // (including unrelated SIM/carrier calls).
        if (!storage.allowIncomingWhileBusy && TVConnectionService.hasActiveCalls()) {
            Log.i(TAG, "onCallInvite: already on a call and allowIncomingWhileBusy is false, rejecting\nSID: ${callInvite.callSid}")

            // Notify Flutter the call was ignored, mirroring the no-permissions path.
            Intent(context, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED
                putExtra(
                    TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON,
                    arrayOf("Already on a call and `allowIncomingWhileBusy` is disabled.")
                )
                putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
                LocalBroadcastManager.getInstance(context).sendBroadcast(this)
            }

            callInvite.reject(context)
            return
        }

        // Get TelecomManager instance
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        val shouldRejectOnNoPermissions: Boolean = storage.rejectOnNoPermissions
        var missingPermissions: Array<String> = emptyArray()

        // Check permission READ_PHONE_STATE
        if (!tm.canReadPhoneState(context)) {
            missingPermissions += "No `READ_PHONE_STATE` permission, cannot check if phone account is registered. Request this with `requestReadPhoneStatePermission()`"
        }

        // Check permission READ_PHONE_NUMBERS
        if (!tm.canReadPhoneNumbers(context)) {
            missingPermissions += "No `READ_PHONE_NUMBERS` permission, cannot communicate with ConnectionService if not granted. Request this with `requestReadPhoneNumbersPermission()`"
        }

        // NOTE(cybex-dev): Foreground services requiring privacy permission e.g. microphone or
        // camera are required to be started in the foreground. Since we're using the Telecom's
        // PhoneAccount, we don't directly require microphone access. Further, microphone access
        // is always denied if the app requiring microphone access via a Foreground service
        // is in the background (by design).

        if (!tm.hasCallCapableAccount(context, TVConnectionService::class.java.name)) {
            missingPermissions += "No call capable phone account registered. Request this with `registerPhoneAccount()`"
        }

        // If we have missingPermissions, then we cannot proceed with answering the call.
        if (missingPermissions.isNotEmpty()) {
            missingPermissions.forEach { Log.e(TAG, it) }

            // If we're not rejecting on no permissions, and can't answer because we don't have the required permissions / phone account, we let it ring.
            // This details a use-case where multiple instances of a user is logged in, and can accept the call on another device.
            if (!shouldRejectOnNoPermissions) {
                return
            }

            Log.e(TAG, "onCallInvite: Rejecting incoming call\nSID: ${callInvite.callSid}")

            // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
            Intent(context, TVBroadcastReceiver::class.java).apply {
                action = TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED
                putExtra(TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON, missingPermissions)
                putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
                LocalBroadcastManager.getInstance(context).sendBroadcast(this)
            }

            // Reject incoming call
            Log.d(TAG, "onCallInvite: Rejecting incoming call")
            callInvite.reject(context)

            return
        }

        // send broadcast to TVConnectionService, we notify the TelecomManager about incoming call
        Intent(context, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_INCOMING_CALL
            putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, callInvite)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(this)
            } else {
                context.startService(this)
            }
        }

        // send broadcast to TVBroadcastReceiver, we notify Flutter about incoming call
        Intent(context, TVBroadcastReceiver::class.java).apply {
            action = TVBroadcastReceiver.ACTION_INCOMING_CALL
            putExtra(TVBroadcastReceiver.EXTRA_CALL_INVITE, callInvite)
            putExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callInvite.callSid)
            LocalBroadcastManager.getInstance(context).sendBroadcast(this)
        }
    }

    override fun onCancelledCallInvite(cancelledCallInvite: CancelledCallInvite, callException: CallException?) {
        Log.d(
            TAG,
            "onCancelledCallInvite: {\n\t" +
                    "Message: ${callException?.message ?: "no message"}, \n\t" +
                    "LocalizedMessage: ${callException?.localizedMessage ?: "no localized message"}, \n\t" +
                    "ErrorCode: ${callException?.errorCode ?: "no code"}, \n\t" +
                    "}",
            callException
        )

        Intent(context, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_CANCEL_CALL_INVITE
            putExtra(TVConnectionService.EXTRA_CANCEL_CALL_INVITE, cancelledCallInvite)
            callException?.errorCode?.let { t ->
                putExtra(TVConnectionService.EXTRA_CANCEL_CALL_INVITE_ERROR_CODE, t)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(this) // Ensure it's started as a foreground service
            } else {
                context.startService(this)
            }
        }
    }
}

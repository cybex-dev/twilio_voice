// TODO
// - add twilio parameter interpretation
// - create contact with twi:// from twilio parameters

package com.twilio.twilio_voice.service

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.call.TVParameters
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.types.CallAudioStateExtension.copyWith
import com.twilio.twilio_voice.types.CallDirection
import com.twilio.twilio_voice.types.CallExceptionExtension.toBundle
import com.twilio.twilio_voice.types.CompletionHandler
import com.twilio.twilio_voice.types.TVNativeCallActions
import com.twilio.twilio_voice.types.TVNativeCallEvents
import com.twilio.twilio_voice.types.ValueBundleChanged
import com.twilio.voice.Call
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite


class TVCallInviteConnection(
    ctx: Context,
    ci: CallInvite,
    callParams: TVParameters,
    onEvent: ValueBundleChanged<String>? = null,
    onAction: ValueBundleChanged<String>? = null,
    onDisconnected: CompletionHandler<DisconnectCause>? = null
) : TVCallConnection(ctx, onEvent, onAction, onDisconnected) {

    override val TAG = "VoipCallInviteConnection"
    private val callInvite: CallInvite
    override val callDirection = CallDirection.INCOMING

    init {
        callInvite = ci
        setCallParameters(callParams)
    }

    override fun onAnswer() {
        Log.d(TAG, "onAnswer: onAnswer")
        super.onAnswer()
        twilioCall = callInvite.accept(context, this)
        onAction?.onChange(TVNativeCallActions.ACTION_ANSWERED, Bundle().apply {
            putParcelable(TVBroadcastReceiver.EXTRA_CALL_INVITE, callInvite)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
        })
    }

    fun acceptInvite() {
        Log.d(TAG, "acceptInvite: acceptInvite")
        onAnswer()
    }

    fun rejectInvite() {
        Log.d(TAG, "rejectInvite: rejectInvite")
        onReject()
    }

    override fun onReject() {
        Log.d(TAG, "onReject: onReject")
        super.onReject()
        callInvite.reject(context)
        // if the call was answered, then immediately rejected/ended, we need to disconnect the call also
        twilioCall?.let {
            Log.d(TAG, "onReject: disconnecting call")
            it.disconnect()
        }
        onEvent?.onChange(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL, null)
        onDisconnected?.withValue(DisconnectCause(DisconnectCause.REJECTED))
        onAction?.onChange(TVNativeCallActions.ACTION_REJECTED, null)
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
    }
}

open class TVCallConnection(
    ctx: Context,
    onEvent: ValueBundleChanged<String>? = null,
    onAction: ValueBundleChanged<String>? = null,
    onDisconnected: CompletionHandler<DisconnectCause>? = null,
) : Connection(), Call.Listener {

    open val TAG = "VoipConnection"
    val context: Context
    var twilioCall: Call? = null
    var onDisconnected: CompletionHandler<DisconnectCause>? = null
    var onEvent: ValueBundleChanged<String>? = null
    var onAction: ValueBundleChanged<String>? = null
    private var onCallStateListener: CompletionHandler<Call.State>? = null
    open val callDirection = CallDirection.OUTGOING
    private var callParams: TVParameters? = null

    init {
        context = ctx
        this.onDisconnected = onDisconnected
        this.onEvent = onEvent
        this.onAction = onAction
        audioModeIsVoip = true
        connectionCapabilities = CAPABILITY_MUTE or CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD
    }

    fun setOnCallDisconnected(handler: CompletionHandler<DisconnectCause>) {
        onDisconnected = handler
    }

    fun setOnCallEventListener(listener: ValueBundleChanged<String>) {
        onEvent = listener
    }

    fun setOnCallActionListener(listener: ValueBundleChanged<String>) {
        onAction = listener
    }

    fun setOnCallStateListener(listener: CompletionHandler<Call.State>) {
        onCallStateListener = listener
    }

    fun setCallParameters(params: TVParameters) {
        callParams = params
    }

    fun getCallParameters(): TVParameters? {
        return callParams
    }

    //region Call.Listener
    /**
     * The call failed to connect.
     *
     *
     * Calls that fail to connect will result in [Call.Listener.onConnectFailure]
     * and always return a [CallException] providing more information about what failure occurred.
     *
     *
     * @param call          An object model representing a call that failed to connect.
     * @param callException CallException that describes why the connect failed.
     */
    override fun onConnectFailure(call: Call, callException: CallException) {
        Log.d(TAG, "onConnectFailure: onConnectFailure")
        twilioCall = null
        this@TVCallConnection.setDisconnected(DisconnectCause(DisconnectCause.ERROR, callException.message))
        onEvent?.onChange(TVNativeCallEvents.EVENT_CONNECT_FAILURE, callException.toBundle())
        onCallStateListener?.withValue(call.state)
    }

    /**
     * Emitted once before the [Call.Listener.onConnected] callback. If
     * `answerOnBridge` is true, this represents the callee being alerted of a call.
     *
     * The [Call.getSid] is now available.
     *
     * @param call  An object model representing a call.
     */
    override fun onRinging(call: Call) {
        twilioCall = call

        when (callDirection) {
            CallDirection.INCOMING -> {
                setRinging()
            }
            CallDirection.OUTGOING -> {
                setInitialized()
            }
        }
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_RINGING, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM, callParams?.fromRaw)
            putString(TVBroadcastReceiver.EXTRA_CALL_TO, callParams?.toRaw)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
        })
    }

    override fun onConnected(call: Call) {
        Log.d(TAG, "onConnected: onConnected")
        twilioCall = call
        setActive()
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_CONNECTED, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM, callParams?.fromRaw)
            putString(TVBroadcastReceiver.EXTRA_CALL_TO, callParams?.toRaw)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
        })
    }

    /**
     * The call starts reconnecting.
     *
     * Reconnect is triggered when a network change is detected and Call is already in [Call.State.CONNECTED] state.
     * If the call is in [Call.State.CONNECTING] or in [Call.State.RINGING] when network
     * change happened the SDK will continue attempting to connect, but a reconnect event will not be raised.
     *
     * @param call           An object model representing a call.
     * @param callException  CallException that describes the reconnect reason. This would have one of the two
     * possible values with error codes 53001 "Signaling connection disconnected" and 53405 "Media connection failed".
     */
    override fun onReconnecting(call: Call, callException: CallException) {
        twilioCall = call
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_RECONNECTING, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM, callParams?.fromRaw)
            putString(TVBroadcastReceiver.EXTRA_CALL_TO, callParams?.toRaw)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
            putExtras(callException.toBundle())
        })
    }

    /**
     * The call is reconnected.
     *
     * @param call An object model representing a call.
     */
    override fun onReconnected(call: Call) {
        twilioCall = call
        setActive()
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_RECONNECTED, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM, callParams?.fromRaw)
            putString(TVBroadcastReceiver.EXTRA_CALL_TO, callParams?.toRaw)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
        });
    }

    override fun onDisconnected(call: Call, reason: CallException?) {
        // TODO run below only if we did NOT ended call i.e. remove disconnect from other client
        Log.d(TAG, "onDisconnected: onDisconnected, reason: ${reason?.message}.\nException: ${reason.toString()}")
        twilioCall = null
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE, Bundle().apply {
            reason?.toBundle()?.let { putExtras(it) }
        })
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        onDisconnected?.withValue(DisconnectCause(DisconnectCause.REMOTE))
        destroy()
    }
    //endregion

    override fun onAbort() {
        super.onAbort()
        Log.i(TAG, "onAbort: onAbort")
        twilioCall?.disconnect()
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        onAction?.onChange(TVNativeCallActions.ACTION_ABORT, null)
        onDisconnected?.withValue(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
    }

    override fun onDisconnect() {
        super.onDisconnect()
        Log.i(TAG, "onDisconnect: onDisconnect")
        twilioCall?.disconnect()
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        this.onDisconnected?.withValue(DisconnectCause(DisconnectCause.LOCAL))
        onEvent?.onChange(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL, null)
        destroy()
        // TODO - ACTION_END_CALL
//        val myIntent: Intent = Intent(context, IncomingCallNotificationService::class.java)
//        myIntent.action = Constants.ACTION_END_CALL
//        myIntent.putExtra(Constants.INCOMING_CALL_INVITE, getCallInvite())
//        myIntent.putExtra(Constants.INCOMING_CALL_NOTIFICATION_ID, getNotificationId())
//        context.startService(myIntent)
    }

    override fun onHold() {
        super.onHold()
        Log.i(TAG, "onHold: onHold")
        twilioCall?.hold(true)
        setOnHold()
        onAction?.onChange(TVNativeCallActions.ACTION_HOLD, null)

        Intent(TVBroadcastReceiver.ACTION_CALL_STATE).apply {
            putExtra(TVBroadcastReceiver.EXTRA_HOLD_STATE, true)
        }.also {
            sendBroadcast(context, it)
        }
    }

    override fun onUnhold() {
        super.onUnhold()
        Log.i(TAG, "onUnhold: onUnhold")
        twilioCall?.hold(false)
        setActive()
        onAction?.onChange(TVNativeCallActions.ACTION_UNHOLD, null)

        Intent(TVBroadcastReceiver.ACTION_CALL_STATE).apply {
            putExtra(TVBroadcastReceiver.EXTRA_HOLD_STATE, false)
        }.also {
            sendBroadcast(context, it)
        }
    }

    override fun onPlayDtmfTone(c: Char) {
        super.onPlayDtmfTone(c)
        Log.i(TAG, "onPlayDtmfTone: dtmf tone: $c")
        twilioCall?.sendDigits(c.toString())
        onAction?.onChange(TVNativeCallActions.ACTION_DTMF, Bundle().apply {
            putString(TVNativeCallActions.EXTRA_DTMF_TONE, c.toString())
        })
    }

    override fun onExtrasChanged(extras: Bundle?) {
        super.onExtrasChanged(extras)
        Log.i(TAG, "onExtrasChanged: onExtrasChanged " + extras.toString())
        extras?.let {
            val set = it.keySet()
            set.forEach {
                Log.i(TAG, "extra: $it")
            }
//            setCallerDisplayName()
        }
    }

    override fun onAnswer(videoState: Int) {
        super.onAnswer(videoState)
        Log.d(TAG, "onAnswer: onAnswer")
    }

    override fun onReject(rejectReason: Int) {
        Log.d(TAG, "onReject: onReject $rejectReason")
        super.onReject(rejectReason)
        twilioCall?.disconnect()
        onAction?.onChange(TVNativeCallActions.ACTION_REJECTED, null)
    }

    override fun onReject(replyMessage: String?) {
        Log.d(TAG, "onReject: onReject $replyMessage")
        super.onReject(replyMessage)
        twilioCall?.disconnect()
        onAction?.onChange(TVNativeCallActions.ACTION_REJECTED, Bundle().apply {
            putString(TVNativeCallActions.EXTRA_REJECT_REASON, replyMessage)
        })
    }

    @Suppress("DEPRECATION")
    @Deprecated("Deprecated in Java")
    override fun onCallAudioStateChanged(state: CallAudioState?) {
        Log.d(TAG, "onCallAudioStateChanged: onCallAudioStateChanged ${state.toString()}")
        super.onCallAudioStateChanged(state)

        Intent(TVBroadcastReceiver.ACTION_AUDIO_STATE).apply {
            putExtra(TVBroadcastReceiver.EXTRA_AUDIO_STATE, state)
        }.also {
            sendBroadcast(context, it)
        }
    }

    override fun onStateChanged(state: Int) {
        super.onStateChanged(state)
        Log.d(TAG, "onStateChanged: $state")
//        when (state) {
//            STATE_ACTIVE -> {
//                Log.d(TAG, "onStateChanged: STATE_ACTIVE")
//                setActive()
//            }
//
//            STATE_DIALING -> {
//                Log.d(TAG, "onStateChanged: STATE_DIALING")
//                setDialing()
//            }
//
//            STATE_DISCONNECTED -> {
//                Log.d(TAG, "onStateChanged: STATE_DISCONNECTED")
//                destroy()
//            }
//
//            STATE_HOLDING -> {
//                Log.d(TAG, "onStateChanged: STATE_HOLDING")
//                setOnHold()
//            }
//
//            STATE_NEW -> {
//                Log.d(TAG, "onStateChanged: STATE_NEW")
//                setRinging()
//            }
//
//            STATE_RINGING -> {
//                Log.d(TAG, "onStateChanged: STATE_RINGING")
//                setRinging()
//            }
//
//            else -> {
//                Log.d(TAG, "onStateChanged: STATE_UNKNOWN")
//            }
//        }
    }

    fun toggleHold(newState: Boolean) {
        if (newState) {
            onHold()
        } else {
            onUnhold()
        }
    }

    /**
     * Toggle mute state of the call.
     * @param newState: true to mute, false to unmute
     * Note: [getCallAudioState] and [onCallAudioStateChanged] has been deprecated in API 34,
     * however this will be used until [getCurrentCallEndpoint], [onCallEndpointChanged] and [onMuteStateChanged] has been implemented.
     */
    @Suppress("DEPRECATION")
    fun toggleMute(newState: Boolean) {
        //TODO(cybex-dev) implement API 34 endpoint & mute state change listeners
        twilioCall?.let {
            it.mute(newState)
            callAudioState?.let { a ->
                val newAudioRoute = a.copyWith(newState)
                onCallAudioStateChanged(newAudioRoute)
            } ?: run {
                Log.e(TAG, "toggleMute: Unable to toggle mute, callAudioState is null")
            }
        } ?: run {
            Log.e(TAG, "toggleMute: Unable to toggle mute, active call is null")
        }
    }

    /**
     * Toggle audio route of the call.
     * @param newState: true if speaker is enabled, false if speaker is disabled
     */
    fun toggleSpeaker(newState: Boolean) {
        toggleAudioRoute(CallAudioState.ROUTE_SPEAKER, newState)
    }

    /**
     * Toggle audio route of the call.
     * @param newState: true if bluetooth is enabled, false if bluetooth is disabled
     */
    fun toggleBluetooth(newState: Boolean) {
        toggleAudioRoute(CallAudioState.ROUTE_BLUETOOTH, newState)
    }

    /**
     * Toggle audio route of the call.
     * @param newAudioRoute: the new audio route to set
     * @param condition: true to use [newAudioRoute], false to use [fallback]
     * @param fallback: the fallback audio route to use if [condition] is false
     *
     * Note: [getCallAudioState] and [onCallAudioStateChanged] has been deprecated in API 34,
     * however this will be used until [getCurrentCallEndpoint], [onCallEndpointChanged] and [onMuteStateChanged] has been implemented.
     */
    @Suppress("DEPRECATION")
    private fun toggleAudioRoute(newAudioRoute: Int, condition: Boolean? = null, fallback: Int = CallAudioState.ROUTE_WIRED_OR_EARPIECE) {
        //TODO(cybex-dev) implement API 34 endpoint & mute state change listeners
        callAudioState?.let {
            val newRoute = if (condition ?: (newAudioRoute == fallback)) newAudioRoute else fallback
            setAudioRoute(newRoute)

            // Since audio route onCallAudioStateChanged does not respond to changes when call is on hold, we invoke this change manually to notify the UI.
            if (state == STATE_HOLDING) {
                onCallAudioStateChanged(callAudioState.copyWith(newRoute))
            }
        }
    }

    /**
     * Send a broadcast to the [TVBroadcastReceiver] with the given [intent].
     * @param ctx: the context
     * @param intent: the intent to send
     */
    private fun sendBroadcast(ctx: Context, intent: Intent) {
        LocalBroadcastManager.getInstance(ctx).sendBroadcast(intent)
    }

    /**
     * Disconnect the call.
     * If the call is ringing and is an incoming call, reject the call using the [CallInvite.reject].
     * Otherwise, disconnect the call using [Call.disconnect] with [DisconnectCause.LOCAL]
     */
    fun disconnect() {
        Log.d(TAG, "disconnect: disconnect")
        if (this is TVCallInviteConnection && state == STATE_RINGING) {
            rejectInvite()
        } else {
            Log.d(TAG, "onDisconnected: onDisconnected")
            twilioCall.let {
                it?.disconnect()
            }
            onEvent?.onChange(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL, null)
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            onDisconnected?.withValue(DisconnectCause(DisconnectCause.LOCAL))
            onCallStateListener?.withValue(Call.State.DISCONNECTED)
            destroy()
        }
    }

    /**
     * Send digits to the active call.
     * @param digits: the digits to send
     */
    fun sendDigits(digits: String) {
        twilioCall?.sendDigits(digits) ?: run {
            Log.e(TAG, "sendDigits: Unable to send digits, active call is null")
        }
    }
}
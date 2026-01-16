
package com.twilio.twilio_voice.service

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
    val callInvite: CallInvite
    override val callDirection = CallDirection.INCOMING

    init {
        callInvite = ci
        setCallParameters(callParams)
    }

 override fun onAnswer() {
    Log.d(TAG, "onAnswer: onAnswer")
    super.onAnswer()
    
    // Request audio focus to pause any playing music and route audio properly
    requestAudioFocus()

    // Accept the call and assign it to twilioCall
    twilioCall = callInvite.accept(context, this)

    // Extract the user number from callInvite.from using your custom extractUserNumber method
    val extractedFrom = extractUserNumber(callInvite.from ?: "")

    // Broadcast the call answered action with the extracted number
    onAction?.onChange(TVNativeCallActions.ACTION_ANSWERED, Bundle().apply {
        putParcelable(TVBroadcastReceiver.EXTRA_CALL_INVITE, callInvite)
        putString(TVBroadcastReceiver.EXTRA_CALL_FROM, extractedFrom)  // Use extracted number here
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
        releaseAudioFocus()
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
    
    // Audio focus management
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    
    // Handler for audio device callbacks
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Track if audio device callback is registered
    private var isAudioDeviceCallbackRegistered = false
    
    // Flag to track if we're currently on Bluetooth (to detect disconnect)
    private var wasOnBluetooth = false
    
    // Audio device callback to detect Bluetooth connect/disconnect during calls
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            Log.d(TAG, "onAudioDevicesAdded: ${addedDevices?.map { "type=${it.type}, name=${it.productName}" }}")
            addedDevices?.forEach { device ->
                if (isBluetoothDevice(device)) {
                    Log.d(TAG, "onAudioDevicesAdded: Bluetooth device connected mid-call!")
                    // Auto-route to the newly connected Bluetooth device
                    mainHandler.postDelayed({
                        autoRouteToBluetoothOnConnect()
                    }, 500) // Small delay to let the device fully connect
                }
            }
        }
        
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            Log.d(TAG, "onAudioDevicesRemoved: ${removedDevices?.map { "type=${it.type}, name=${it.productName}" }}")
            removedDevices?.forEach { device ->
                if (isBluetoothDevice(device)) {
                    Log.d(TAG, "onAudioDevicesRemoved: Bluetooth device disconnected mid-call!")
                    // Auto-route to earpiece when Bluetooth disconnects
                    mainHandler.postDelayed({
                        autoRouteToEarpieceOnBluetoothDisconnect()
                    }, 200)
                }
            }
        }
    }
    
    private fun isBluetoothDevice(device: AudioDeviceInfo): Boolean {
        return device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
               device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
               device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
               device.type == AudioDeviceInfo.TYPE_HEARING_AID ||
               device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
    }

    init {
        context = ctx
        this.onDisconnected = onDisconnected
        this.onEvent = onEvent
        this.onAction = onAction
        audioModeIsVoip = true
        connectionCapabilities = CAPABILITY_MUTE or CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    
    /**
     * Request audio focus for voice call.
     * This will pause any playing music and route audio to the appropriate device (earpiece/speaker/bluetooth)
     */
    protected fun requestAudioFocus() {
        if (hasAudioFocus) {
            Log.d(TAG, "requestAudioFocus: Already have audio focus")
            return
        }
        
        val am = audioManager ?: return
        Log.d(TAG, "requestAudioFocus: Requesting audio focus for voice call")
        
        // Register audio device callback to detect Bluetooth connect/disconnect during calls
        registerAudioDeviceCallback()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            
            audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(audioAttributes)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener { focusChange ->
                    Log.d(TAG, "Audio focus changed: $focusChange")
                    when (focusChange) {
                        AudioManager.AUDIOFOCUS_LOSS -> {
                            Log.d(TAG, "Audio focus lost")
                            hasAudioFocus = false
                        }
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                            Log.d(TAG, "Audio focus lost transient")
                        }
                        AudioManager.AUDIOFOCUS_GAIN -> {
                            Log.d(TAG, "Audio focus gained")
                            hasAudioFocus = true
                        }
                    }
                }
                .build()
            
            val result = am.requestAudioFocus(audioFocusRequest!!)
            hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            Log.d(TAG, "requestAudioFocus: Result = $result, hasAudioFocus = $hasAudioFocus")
        } else {
            @Suppress("DEPRECATION")
            val result = am.requestAudioFocus(
                { focusChange -> Log.d(TAG, "Audio focus changed: $focusChange") },
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
            hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            Log.d(TAG, "requestAudioFocus (legacy): Result = $result, hasAudioFocus = $hasAudioFocus")
        }
        
        // Set audio mode for voice call
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        
        // Ensure speaker is off by default for new calls
        // This prevents inheriting speaker state from previous call
        if (am.isSpeakerphoneOn) {
            Log.d(TAG, "requestAudioFocus: Turning off speakerphone for new call")
            am.isSpeakerphoneOn = false
        }
        
        // For Android 12+, explicitly route to earpiece first, then check for Bluetooth
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                // Clear any previous communication device setting
                am.clearCommunicationDevice()
                Log.d(TAG, "requestAudioFocus: Cleared communication device")
            } catch (e: Exception) {
                Log.e(TAG, "requestAudioFocus: Failed to clear communication device", e)
            }
        }
        
        // Route to Bluetooth if connected, otherwise audio will go to earpiece by default
        routeAudioToBluetoothIfConnected()
    }
    
    /**
     * Register audio device callback to detect Bluetooth connect/disconnect during calls
     */
    private fun registerAudioDeviceCallback() {
        if (isAudioDeviceCallbackRegistered) {
            Log.d(TAG, "registerAudioDeviceCallback: Already registered")
            return
        }
        
        val am = audioManager ?: return
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Log.d(TAG, "registerAudioDeviceCallback: Registering audio device callback")
            am.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
            isAudioDeviceCallbackRegistered = true
            
            // Check current Bluetooth state
            wasOnBluetooth = isCurrentlyOnBluetooth()
            Log.d(TAG, "registerAudioDeviceCallback: Initial Bluetooth state=$wasOnBluetooth")
        }
    }
    
    /**
     * Unregister audio device callback
     */
    private fun unregisterAudioDeviceCallback() {
        if (!isAudioDeviceCallbackRegistered) return
        
        val am = audioManager ?: return
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Log.d(TAG, "unregisterAudioDeviceCallback: Unregistering audio device callback")
            try {
                am.unregisterAudioDeviceCallback(audioDeviceCallback)
            } catch (e: Exception) {
                Log.e(TAG, "unregisterAudioDeviceCallback: Error", e)
            }
            isAudioDeviceCallbackRegistered = false
        }
    }
    
    /**
     * Check if currently on Bluetooth
     */
    private fun isCurrentlyOnBluetooth(): Boolean {
        val am = audioManager ?: return false
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val commDevice = am.communicationDevice
            if (commDevice != null && isBluetoothDevice(commDevice)) {
                return true
            }
        }
        
        return am.isBluetoothScoOn
    }
    
    /**
     * Auto-route to Bluetooth when a Bluetooth device connects mid-call
     */
    private fun autoRouteToBluetoothOnConnect() {
        Log.d(TAG, "=== autoRouteToBluetoothOnConnect START ===")
        val am = audioManager ?: return
        
        // Check if we're in a call
        if (twilioCall == null) {
            Log.d(TAG, "autoRouteToBluetoothOnConnect: No active call, skipping")
            return
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val availableDevices = am.availableCommunicationDevices
                Log.d(TAG, "autoRouteToBluetoothOnConnect: Available devices: ${availableDevices.map { "type=${it.type}" }}")
                
                val bluetoothDevice = availableDevices.firstOrNull { isBluetoothDevice(it) }
                if (bluetoothDevice != null) {
                    Log.d(TAG, "autoRouteToBluetoothOnConnect: Found Bluetooth device, auto-routing")
                    val result = am.setCommunicationDevice(bluetoothDevice)
                    Log.d(TAG, "autoRouteToBluetoothOnConnect: setCommunicationDevice result=$result")
                    
                    if (result) {
                        wasOnBluetooth = true
                        // Notify Flutter about Bluetooth connection
                        Log.d(TAG, "autoRouteToBluetoothOnConnect: Broadcasting EVENT_BLUETOOTH with state=true")
                        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                        })
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "autoRouteToBluetoothOnConnect: Error", e)
            }
        } else {
            // Legacy: Try to start Bluetooth SCO
            if (am.isBluetoothScoAvailableOffCall) {
                Log.d(TAG, "autoRouteToBluetoothOnConnect: Using legacy startBluetoothSco()")
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
                wasOnBluetooth = true
                
                onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                })
            }
        }
        Log.d(TAG, "=== autoRouteToBluetoothOnConnect END ===")
    }
    
    /**
     * Auto-route to earpiece when Bluetooth disconnects mid-call
     */
    private fun autoRouteToEarpieceOnBluetoothDisconnect() {
        Log.d(TAG, "=== autoRouteToEarpieceOnBluetoothDisconnect START ===")
        Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: wasOnBluetooth=$wasOnBluetooth")
        val am = audioManager ?: return
        
        // Check if we're in a call
        if (twilioCall == null) {
            Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: No active call, skipping")
            return
        }
        
        // Always route to earpiece when a Bluetooth device is removed during a call
        // This ensures audio doesn't get stuck on a non-existent device
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Clearing communication device")
                am.clearCommunicationDevice()
                
                val availableDevices = am.availableCommunicationDevices
                val earpieceDevice = availableDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                if (earpieceDevice != null) {
                    val result = am.setCommunicationDevice(earpieceDevice)
                    Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: setCommunicationDevice to earpiece result=$result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Error", e)
            }
        } else {
            // Legacy
            am.stopBluetoothSco()
            am.isBluetoothScoOn = false
        }
        
        wasOnBluetooth = false
        
        // ALWAYS notify Flutter about Bluetooth disconnection when a BT device is removed
        // This ensures UI is immediately updated
        Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Broadcasting EVENT_BLUETOOTH with state=false")
        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, false)
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
        })
        Log.d(TAG, "=== autoRouteToEarpieceOnBluetoothDisconnect END ===")
    }
    
    /**
     * Release audio focus when call ends
     */
    protected fun releaseAudioFocus() {
        val am = audioManager ?: return
        Log.d(TAG, "releaseAudioFocus: Releasing audio focus")
        
        // Unregister audio device callback
        unregisterAudioDeviceCallback()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let {
                am.abandonAudioFocusRequest(it)
            }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
        
        hasAudioFocus = false
        wasOnBluetooth = false
        
        // Reset speaker state to ensure next call starts on earpiece (unless Bluetooth is connected)
        // This fixes the issue where ending a call on speaker causes the next call to start on speaker
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                Log.d(TAG, "releaseAudioFocus: Clearing communication device (Android 12+)")
                am.clearCommunicationDevice()
            } catch (e: Exception) {
                Log.e(TAG, "releaseAudioFocus: Failed to clear communication device", e)
            }
        }
        
        // Explicitly turn off speaker to reset audio route for next call
        if (am.isSpeakerphoneOn) {
            Log.d(TAG, "releaseAudioFocus: Turning off speakerphone")
            am.isSpeakerphoneOn = false
        }
        
        am.mode = AudioManager.MODE_NORMAL
        
        // Stop Bluetooth SCO if it was started
        if (am.isBluetoothScoOn) {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
        }
        
        Log.d(TAG, "releaseAudioFocus: Audio state reset complete - isSpeakerphoneOn=${am.isSpeakerphoneOn}, isBluetoothScoOn=${am.isBluetoothScoOn}")
    }
    
    /**
     * Route audio to Bluetooth if a Bluetooth device is connected
     * Only broadcasts EVENT_BLUETOOTH if routing actually succeeds
     */
    private fun routeAudioToBluetoothIfConnected() {
        Log.d(TAG, "=== routeAudioToBluetoothIfConnected START ===")
        val am = audioManager ?: run {
            Log.w(TAG, "routeAudioToBluetoothIfConnected: audioManager is NULL, returning")
            return
        }
        
        Log.d(TAG, "routeAudioToBluetoothIfConnected: Android SDK=${Build.VERSION.SDK_INT}, isBluetoothScoAvailableOffCall=${am.isBluetoothScoAvailableOffCall}, isBluetoothScoOn=${am.isBluetoothScoOn}")
        
        var routedSuccessfully = false
        
        // For Android 12+, check available communication devices
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val availableDevices = am.availableCommunicationDevices
                Log.d(TAG, "routeAudioToBluetoothIfConnected: Available communication devices: ${availableDevices.map { "type=${it.type}, name=${it.productName}" }}")
                
                // Look for Bluetooth SCO device specifically (for voice calls)
                // TYPE_BLUETOOTH_A2DP is for media streaming, not voice calls
                val bluetoothDevice = availableDevices.firstOrNull { 
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                    it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                }
                if (bluetoothDevice != null) {
                    Log.d(TAG, "routeAudioToBluetoothIfConnected: Found Bluetooth device type=${bluetoothDevice.type}, routing via setCommunicationDevice")
                    val result = am.setCommunicationDevice(bluetoothDevice)
                    Log.d(TAG, "routeAudioToBluetoothIfConnected: setCommunicationDevice result=$result")
                    
                    if (result) {
                        wasOnBluetooth = true
                        routedSuccessfully = true
                    }
                } else {
                    Log.d(TAG, "routeAudioToBluetoothIfConnected: No Bluetooth SCO/BLE device in availableCommunicationDevices")
                }
            } catch (e: Exception) {
                Log.e(TAG, "routeAudioToBluetoothIfConnected: Failed to use setCommunicationDevice", e)
            }
        } else {
            // Fallback for older Android: Check if Bluetooth SCO is available
            if (am.isBluetoothScoAvailableOffCall) {
                Log.d(TAG, "routeAudioToBluetoothIfConnected: Bluetooth available via legacy check, routing audio to Bluetooth")
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
                wasOnBluetooth = true
                routedSuccessfully = true
            } else {
                Log.d(TAG, "routeAudioToBluetoothIfConnected: No Bluetooth device connected (legacy check)")
            }
        }
        
        // Only broadcast EVENT_BLUETOOTH if routing actually succeeded
        if (routedSuccessfully) {
            Log.d(TAG, "routeAudioToBluetoothIfConnected: Routing succeeded, broadcasting EVENT_BLUETOOTH with state=true")
            onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            })
        } else {
            Log.d(TAG, "routeAudioToBluetoothIfConnected: No Bluetooth routing, audio stays on default (earpiece)")
        }
        
        Log.d(TAG, "=== routeAudioToBluetoothIfConnected END ===")
    }

    // Idempotency guard for disconnect/decline
    @Volatile private var isDisconnectingOrDisconnected = false

    /**
     * Force disconnect with extra logging for debugging decline issues.
     * Idempotent: only processes disconnect once.
     */
    fun forceDisconnectWithLogging() {
        if (isDisconnectingOrDisconnected) {
            Log.w(TAG, "[Decline] forceDisconnectWithLogging called but already disconnecting/disconnected. Ignoring repeat call. State: $state, Direction: $callDirection, CallParams: ${getCallParameters()?.callSid}")
            return
        }
        isDisconnectingOrDisconnected = true
        Log.i(TAG, "[Decline] forceDisconnectWithLogging called. State: $state, Direction: $callDirection, twilioCall: ${twilioCall != null}, CallParams: ${getCallParameters()?.callSid}")
        
        // Release audio focus when disconnecting
        releaseAudioFocus()
        
        try {
            // For incoming call invites that haven't been answered yet, reject the invite
            // The twilioCall is null until the invite is accepted via callInvite.accept()
            if (this is TVCallInviteConnection && twilioCall == null) {
                Log.i(TAG, "[Decline] TVCallInviteConnection with no active call (not answered yet), calling rejectInvite()")
                (this as TVCallInviteConnection).rejectInvite()
            } else if (this is TVCallInviteConnection && state == STATE_RINGING) {
                Log.i(TAG, "[Decline] TVCallInviteConnection in RINGING state, calling rejectInvite()")
                (this as TVCallInviteConnection).rejectInvite()
            } else {
                Log.i(TAG, "[Decline] Active call present, calling disconnect() on twilioCall")
                twilioCall?.disconnect() ?: Log.w(TAG, "[Decline] twilioCall is null")
                onEvent?.onChange(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL, null)
                setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                onDisconnected?.withValue(DisconnectCause(DisconnectCause.LOCAL))
                onCallStateListener?.withValue(Call.State.DISCONNECTED)
                destroy()
            }
        } catch (e: Exception) {
            Log.e(TAG, "[Decline] Exception in forceDisconnectWithLogging: ${e.message}", e)
        }
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
        val rejectedErrorCodeList = listOf(
            31600, // Call invite rejected
        )
        val disconnectCauseCode = if (rejectedErrorCodeList.contains(callException.errorCode)) {
            DisconnectCause.REJECTED
        } else {
            DisconnectCause.ERROR
        }
        val disconnectCause = DisconnectCause(disconnectCauseCode, callException.message);
        this@TVCallConnection.setDisconnected(disconnectCause)
        onDisconnected?.withValue(disconnectCause)
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
                // Request audio focus early for outgoing calls to pause any playing music
                requestAudioFocus()
            }
        }
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_RINGING, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM,extractUserNumber( callParams?.fromRaw ?: ""))
            putString(TVBroadcastReceiver.EXTRA_CALL_TO, callParams?.toRaw)
            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, callDirection.id)
        })
    }


    fun extractUserNumber(input: String): String {
        // Define the regular expression pattern to match the user_number part
        val pattern = Regex("""user_number:([^\s:]+)""")

        // Search for the first match in the input string
        val match = pattern.find(input)

        // Extract the matched part (user_number:+11230123)
        return match?.groups?.get(1)?.value ?: input
    }

    override fun onConnected(call: Call) {
        Log.d(TAG, "onConnected: onConnected")
        twilioCall = call
        
        // Request audio focus when call connects (for outgoing calls)
        // For incoming calls, audio focus is already requested in onAnswer()
        requestAudioFocus()
        
        setActive()
        onCallStateListener?.withValue(call.state)
        onEvent?.onChange(TVNativeCallEvents.EVENT_CONNECTED, Bundle().apply {
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            putString(TVBroadcastReceiver.EXTRA_CALL_FROM,extractUserNumber(callParams?.fromRaw ?: "" ))
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
        releaseAudioFocus()
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
        releaseAudioFocus()
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        onAction?.onChange(TVNativeCallActions.ACTION_ABORT, null)
        onDisconnected?.withValue(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
    }

    override fun onDisconnect() {
        super.onDisconnect()
        Log.i(TAG, "onDisconnect: onDisconnect")
        twilioCall?.disconnect()
        releaseAudioFocus()
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
                // Fallback: Broadcast mute state change directly when not using TelecomManager
                Log.d(TAG, "toggleMute: Using direct mute, newState=$newState")
                onEvent?.onChange(TVNativeCallEvents.EVENT_MUTE, Bundle().apply {
                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_MUTE_STATE, newState)
                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                })
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
        Log.d(TAG, "=== toggleSpeaker START === newState=$newState")
        // First try using TelecomManager's audio route
        if (callAudioState != null) {
            Log.d(TAG, "toggleSpeaker: Using TelecomManager route, newState=$newState")
            toggleAudioRoute(CallAudioState.ROUTE_SPEAKER, newState)
        } else {
            // Fallback: Use AudioManager directly when not using TelecomManager
            Log.d(TAG, "toggleSpeaker: callAudioState is NULL, using AudioManager directly")
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            
            // Log current state before change
            Log.d(TAG, "toggleSpeaker: BEFORE - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
            
            if (newState) {
                // Turning Speaker ON - ensure Bluetooth is off first
                Log.d(TAG, "toggleSpeaker: Turning Speaker ON")
                
                // For Android 12+, clear communication device first then set speaker
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        Log.d(TAG, "toggleSpeaker: Android 12+, clearing communication device first")
                        audioManager.clearCommunicationDevice()
                        
                        val availableDevices = audioManager.availableCommunicationDevices
                        Log.d(TAG, "toggleSpeaker: Available devices: ${availableDevices.map { "type=${it.type}" }}")
                        
                        val speakerDevice = availableDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                        if (speakerDevice != null) {
                            val result = audioManager.setCommunicationDevice(speakerDevice)
                            Log.d(TAG, "toggleSpeaker: setCommunicationDevice to SPEAKER result=$result")
                        } else {
                            Log.w(TAG, "toggleSpeaker: No speaker device found!")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "toggleSpeaker: Failed to set communication device", e)
                    }
                }
                
                // Also use legacy methods
                Log.d(TAG, "toggleSpeaker: Using legacy methods - stopBluetoothSco, isSpeakerphoneOn=true")
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                audioManager.isSpeakerphoneOn = true
            } else {
                // Turning Speaker OFF - route to earpiece
                Log.d(TAG, "toggleSpeaker: Turning Speaker OFF, routing to earpiece")
                audioManager.isSpeakerphoneOn = false
                
                // For Android 12+, clear and set earpiece
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        Log.d(TAG, "toggleSpeaker: Android 12+, clearing and setting earpiece")
                        audioManager.clearCommunicationDevice()
                        val earpieceDevice = audioManager.availableCommunicationDevices
                            .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                        if (earpieceDevice != null) {
                            val result = audioManager.setCommunicationDevice(earpieceDevice)
                            Log.d(TAG, "toggleSpeaker: setCommunicationDevice to EARPIECE result=$result")
                        } else {
                            Log.w(TAG, "toggleSpeaker: No earpiece device found!")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "toggleSpeaker: Failed to set communication device", e)
                    }
                }
            }
            
            // Log state after change
            Log.d(TAG, "toggleSpeaker: AFTER - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
            
            // Broadcast speaker state change
            Log.d(TAG, "toggleSpeaker: Broadcasting EVENT_SPEAKER with state=$newState")
            onEvent?.onChange(TVNativeCallEvents.EVENT_SPEAKER, Bundle().apply {
                putBoolean(TVBroadcastReceiver.EXTRA_CALL_SPEAKER_STATE, newState)
                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            })
        }
        Log.d(TAG, "=== toggleSpeaker END ===")
    }

    /**
     * Toggle audio route of the call.
     * @param newState: true if bluetooth is enabled, false if bluetooth is disabled
     */
    fun toggleBluetooth(newState: Boolean) {
        Log.d(TAG, "=== toggleBluetooth START === newState=$newState")
        // When callAudioState is available, toggleAudioRoute triggers onCallAudioStateChanged
        // which broadcasts ACTION_AUDIO_STATE, and the handler in TwilioVoicePlugin emits events.
        if (callAudioState != null) {
            Log.d(TAG, "toggleBluetooth: Using TelecomManager route, newState=$newState")
            toggleAudioRoute(CallAudioState.ROUTE_BLUETOOTH, newState)
        } else {
            // Fallback: Use AudioManager directly when not using TelecomManager
            Log.d(TAG, "toggleBluetooth: callAudioState is NULL, using AudioManager directly")
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            
            // Log current state before change
            Log.d(TAG, "toggleBluetooth: BEFORE - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
            
            if (newState) {
                // Turning Bluetooth ON - turn off speaker first
                Log.d(TAG, "toggleBluetooth: Turning Bluetooth ON")
                audioManager.isSpeakerphoneOn = false
                
                // For Android 12+, clear then set Bluetooth
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        Log.d(TAG, "toggleBluetooth: Android 12+, clearing communication device first")
                        audioManager.clearCommunicationDevice()
                        
                        val availableDevices = audioManager.availableCommunicationDevices
                        Log.d(TAG, "toggleBluetooth: Available devices: ${availableDevices.map { "type=${it.type}" }}")
                        
                        // Look for any Bluetooth device type (SCO, BLE headset, hearing aid, BLE speaker)
                        val bluetoothDevice = availableDevices.firstOrNull { 
                            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                            it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                        }
                        if (bluetoothDevice != null) {
                            Log.d(TAG, "toggleBluetooth: Found Bluetooth device type=${bluetoothDevice.type}")
                            val result = audioManager.setCommunicationDevice(bluetoothDevice)
                            Log.d(TAG, "toggleBluetooth: setCommunicationDevice to BLUETOOTH result=$result")
                            if (result) {
                                wasOnBluetooth = true
                            }
                        } else {
                            Log.w(TAG, "toggleBluetooth: No Bluetooth device found in availableCommunicationDevices!")
                            Log.d(TAG, "toggleBluetooth: Trying legacy startBluetoothSco()")
                            audioManager.startBluetoothSco()
                            audioManager.isBluetoothScoOn = true
                            wasOnBluetooth = true
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "toggleBluetooth: Failed to set communication device, using legacy", e)
                        audioManager.startBluetoothSco()
                        audioManager.isBluetoothScoOn = true
                        wasOnBluetooth = true
                    }
                } else {
                    Log.d(TAG, "toggleBluetooth: Pre-Android 12, using legacy startBluetoothSco()")
                    audioManager.startBluetoothSco()
                    audioManager.isBluetoothScoOn = true
                    wasOnBluetooth = true
                }
            } else {
                // Turning Bluetooth OFF - route to earpiece
                Log.d(TAG, "toggleBluetooth: Turning Bluetooth OFF, routing to earpiece")
                wasOnBluetooth = false
                
                // For Android 12+, clear then set earpiece
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        Log.d(TAG, "toggleBluetooth: Android 12+, clearing and setting earpiece")
                        audioManager.clearCommunicationDevice()
                        
                        val availableDevices = audioManager.availableCommunicationDevices
                        Log.d(TAG, "toggleBluetooth: Available devices: ${availableDevices.map { "type=${it.type}" }}")
                        
                        val earpieceDevice = availableDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                        if (earpieceDevice != null) {
                            val result = audioManager.setCommunicationDevice(earpieceDevice)
                            Log.d(TAG, "toggleBluetooth: setCommunicationDevice to EARPIECE result=$result")
                        } else {
                            Log.w(TAG, "toggleBluetooth: No earpiece device found!")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "toggleBluetooth: Failed to set communication device", e)
                    }
                }
                
                // Also use legacy methods for compatibility
                Log.d(TAG, "toggleBluetooth: Using legacy methods - stopBluetoothSco")
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                audioManager.isSpeakerphoneOn = false
            }
            
            // Log state after change
            Log.d(TAG, "toggleBluetooth: AFTER - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
            
            // Broadcast bluetooth state change only in fallback path
            Log.d(TAG, "toggleBluetooth: Broadcasting EVENT_BLUETOOTH with state=$newState")
            onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, newState)
                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            })
        }
        Log.d(TAG, "=== toggleBluetooth END ===")
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
        } ?: run {
            // Fallback for when not using TelecomManager
            Log.d(TAG, "toggleAudioRoute: callAudioState is null, using AudioManager directly")
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            when (newAudioRoute) {
                CallAudioState.ROUTE_SPEAKER -> {
                    audioManager.isSpeakerphoneOn = condition ?: true
                }
                CallAudioState.ROUTE_WIRED_OR_EARPIECE -> {
                    audioManager.isSpeakerphoneOn = false
                }
                CallAudioState.ROUTE_BLUETOOTH -> {
                    audioManager.isBluetoothScoOn = condition ?: true
                    if (condition == true) {
                        audioManager.startBluetoothSco()
                    } else {
                        audioManager.stopBluetoothSco()
                    }
                }
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
            twilioCall?.disconnect()
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



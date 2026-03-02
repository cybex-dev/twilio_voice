
package com.twilio.twilio_voice.service

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothProfile
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
import android.telecom.CallEndpoint
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.audio.RingbackManager
import com.twilio.twilio_voice.call.TVParameters
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.types.CallAudioStateExtension.copyWith
import com.twilio.twilio_voice.types.CallDirection
import com.twilio.twilio_voice.types.CallExceptionExtension.toBundle
import com.twilio.twilio_voice.types.CompletionHandler
import com.twilio.twilio_voice.types.TVNativeCallActions
import com.twilio.twilio_voice.types.TVNativeCallEvents
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
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
    Log.d(TAG, "onAnswer: CALLED — source could be UI button, BT headset button, or system. State=${state}, callSid=${callInvite.callSid}")
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

    // Notify the service to handle notification management (cancel incoming notification,
    // release wake lock, show ongoing call notification, launch MainActivity).
    // This is critical when onAnswer() is triggered by the system (BT headset button)
    // because the ACTION_ANSWER path in onStartCommand is NOT reached in that case.
    Log.d(TAG, "onAnswer: Invoking onAnswerCallback for notification management")
    onAnswerCallback?.invoke()
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
        val otherCallsActive = hasOtherActiveCalls?.invoke() ?: false
        Log.d(TAG, "onReject: onReject, otherCallsActive=$otherCallsActive")
        super.onReject()
        callInvite.reject(context)
        if (otherCallsActive) {
            Log.d(TAG, "onReject: Skipping releaseAudioFocus — other calls still active")
        } else {
            releaseAudioFocus()
        }
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

    /**
     * Called by the system for self-managed ConnectionService to show its own incoming call UI.
     * For self-managed apps, Android calls this on the Connection returned from
     * onCreateIncomingConnection() instead of showing the system's default incoming call screen.
     * Our IncomingCallActivity is already launched via the notification's fullScreenIntent
     * in startIncomingCallForegroundService(), so we just log here.
     */
    override fun onShowIncomingCallUi() {
        Log.d(TAG, "onShowIncomingCallUi: System requesting incoming call UI (self-managed)")
        // Our notification with fullScreenIntent already handles the UI:
        //   - Device locked/screen off → full-screen IncomingCallActivity
        //   - Device unlocked/in use → heads-up notification
        // No additional action needed.
    }

    /**
     * Called by the system when the user presses volume-down during an incoming call.
     * Available on API 29+ (Android 10+). Both test devices support this:
     *   - Redmi Note 7 Pro: SDK 29
     *   - Samsung Galaxy A15: SDK 36
     * 
     * Expected behavior: silence the ringtone but keep the call in ringing state.
     * The user can still answer or reject the call after silencing.
     */
    override fun onSilence() {
        Log.d(TAG, "onSilence: User pressed volume-down to silence ringtone")
        onSilenceCallback?.invoke()
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
    
    // Flag to ignore the initial callback firing when callback is first registered
    private var ignoreInitialAudioDeviceCallback = true
    
    // API 34+ (Gap 5/6): Track available call endpoints for requestCallEndpointChange().
    // Populated by onAvailableCallEndpointsChanged(). MUST use these endpoints — creating
    // custom CallEndpoint objects will fail.
    @Volatile
    private var availableCallEndpoints: List<Any> = emptyList()  // List<CallEndpoint> at runtime on API 34+
    
    companion object {
        /**
         * PERF: Single-thread executor shared across all TVConnection instances.
         * All AudioManager operations (toggleSpeaker, toggleBluetooth) are submitted
         * to this executor so they run SEQUENTIALLY. This eliminates the race condition
         * where two concurrent Thread {} calls both try to acquire AudioManager's
         * internal lock — the second thread would block for 500ms-1.5s causing UI freezes
         * when detectAudioState() is called on the main thread (it also needs the lock).
         */
        val audioExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "TVConnection-AudioExecutor").apply { isDaemon = true }
        }
    }
    
    // Audio device callback to detect Bluetooth connect/disconnect during calls
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            Log.d(TAG, "onAudioDevicesAdded: ${addedDevices?.map { "type=${it.type}, name=${it.productName}" }}")
            
            // Skip initial callback - we only want to auto-route for devices connected AFTER call starts
            if (ignoreInitialAudioDeviceCallback) {
                Log.d(TAG, "onAudioDevicesAdded: Ignoring initial callback (devices already present at registration)")
                return
            }
            
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
        // PROPERTY_SELF_MANAGED tells the system this Connection belongs to a self-managed
        // VoIP app. Required for proper HFP (Bluetooth headset) integration — without it,
        // the system may not route HFP indicators (ring, answer, reject) to BT headsets.
        // See: BLE Audio managed calls guide — setConnectionProperties(PROPERTY_SELF_MANAGED)
        connectionProperties = PROPERTY_SELF_MANAGED
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
     * Force re-acquire audio focus for this connection.
     * Used when another connection's disconnect released the shared OS audio focus,
     * leaving this connection's audio routing broken (MODE_NORMAL, no communication device).
     *
     * This resets [hasAudioFocus] so [requestAudioFocus] will perform a full re-acquire
     * including MODE_IN_COMMUNICATION, audio device callback, and Bluetooth routing.
     */
    internal fun restoreAudioFocus() {
        Log.d(TAG, "restoreAudioFocus: Forcing audio focus re-acquire (current hasAudioFocus=$hasAudioFocus)")
        hasAudioFocus = false
        requestAudioFocus()
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
            
            // Set flag to ignore initial callback - the callback may fire immediately with existing devices
            ignoreInitialAudioDeviceCallback = true
            
            am.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
            isAudioDeviceCallbackRegistered = true
            
            // Check current Bluetooth state
            wasOnBluetooth = isCurrentlyOnBluetooth()
            Log.d(TAG, "registerAudioDeviceCallback: Initial Bluetooth state=$wasOnBluetooth")
            
            // After a short delay, allow the callback to process new device connections
            mainHandler.postDelayed({
                ignoreInitialAudioDeviceCallback = false
                Log.d(TAG, "registerAudioDeviceCallback: Now accepting audio device callbacks")
            }, 1000) // 1 second delay to ensure initial callbacks are ignored
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
     * Auto-route to Bluetooth when a Bluetooth device connects mid-call.
     * This is called from onAudioDevicesAdded callback, so we know a BT device was just connected.
     * Only broadcasts EVENT_BLUETOOTH after verifying SCO is actually active.
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
                        // Verify SCO is actually active before notifying Flutter
                        mainHandler.postDelayed({
                            val scoActive = am.isBluetoothScoOn
                            Log.d(TAG, "autoRouteToBluetoothOnConnect: Delayed SCO check - scoActive=$scoActive")
                            if (scoActive) {
                                wasOnBluetooth = true
                                Log.d(TAG, "autoRouteToBluetoothOnConnect: Broadcasting EVENT_BLUETOOTH with state=true")
                                onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                                })
                            }
                        }, 500)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "autoRouteToBluetoothOnConnect: Error", e)
            }
        } else {
            // Legacy (Android < 12): This is called from onAudioDevicesAdded, so we know BT device was just connected
            // Just try to start SCO and verify it activates
            Log.d(TAG, "autoRouteToBluetoothOnConnect: Legacy - attempting to start SCO (device was just connected via callback)")
            
            try {
                am.startBluetoothSco()
                
                // Verify SCO actually started after a delay
                mainHandler.postDelayed({
                    val scoActive = am.isBluetoothScoOn
                    Log.d(TAG, "autoRouteToBluetoothOnConnect: Legacy delayed SCO check - scoActive=$scoActive")
                    if (scoActive) {
                        wasOnBluetooth = true
                        Log.d(TAG, "autoRouteToBluetoothOnConnect: SCO activated, broadcasting EVENT_BLUETOOTH with state=true")
                        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                        })
                    } else {
                        Log.d(TAG, "autoRouteToBluetoothOnConnect: SCO did not activate, staying on current audio route")
                    }
                }, 500)
            } catch (e: Exception) {
                Log.e(TAG, "autoRouteToBluetoothOnConnect: Failed to start SCO", e)
            }
        }
        Log.d(TAG, "=== autoRouteToBluetoothOnConnect END ===")
    }
    
    /**
     * Handle audio route when Bluetooth disconnects mid-call.
     *
     * If the user was actively on Bluetooth → switch to earpiece.
     * If the user was on speaker or earpiece (not using BT for audio) → keep current route.
     * Always notifies Flutter that Bluetooth is no longer available.
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
        
        // Determine if the user was currently on speaker BEFORE clearing communication device
        val wasOnSpeaker = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val commDevice = am.communicationDevice
            val onSpeakerViaCommunicationDevice = commDevice != null && commDevice.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            val onSpeakerViaLegacy = am.isSpeakerphoneOn
            Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: commDevice type=${commDevice?.type}, isSpeakerphoneOn=$onSpeakerViaLegacy, onSpeakerViaCommunicationDevice=$onSpeakerViaCommunicationDevice")
            onSpeakerViaCommunicationDevice || onSpeakerViaLegacy
        } else {
            am.isSpeakerphoneOn
        }

        Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: wasOnSpeaker=$wasOnSpeaker")

        if (wasOnBluetooth && !wasOnSpeaker) {
            // User was actively on Bluetooth → switch to earpiece
            Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Was on BT, routing to earpiece")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    am.clearCommunicationDevice()
                    val availableDevices = am.availableCommunicationDevices
                    val earpieceDevice = availableDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                    if (earpieceDevice != null) {
                        val result = am.setCommunicationDevice(earpieceDevice)
                        Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: setCommunicationDevice to earpiece result=$result")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Error routing to earpiece", e)
                }
            } else {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
            }
        } else if (wasOnSpeaker) {
            // User was on speaker → keep speaker, just clean up BT SCO
            Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Was on speaker, keeping speaker active")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                // Legacy: just stop BT SCO, speaker stays active via isSpeakerphoneOn
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
            }
            // For Android 12+: communication device is already set to speaker, no change needed
        } else {
            // User was on earpiece (not on BT, not on speaker) → stay on earpiece
            Log.d(TAG, "autoRouteToEarpieceOnBluetoothDisconnect: Was on earpiece, staying on earpiece")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
            }
            // For Android 12+: communication device is already earpiece or default, no change needed
        }
        
        wasOnBluetooth = false
        
        // ALWAYS notify Flutter about Bluetooth disconnection when a BT device is removed
        // This ensures UI is immediately updated (BT option removed from audio toggle)
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
     * Only broadcasts EVENT_BLUETOOTH if routing actually succeeds AND SCO becomes active
     * 
     * CRITICAL: We must verify Bluetooth HEADSET profile is connected (not just paired)
     * and SCO actually activates before reporting Bluetooth as active.
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
                        // Verify SCO is actually active after setting communication device
                        mainHandler.postDelayed({
                            val scoNowActive = am.isBluetoothScoOn
                            Log.d(TAG, "routeAudioToBluetoothIfConnected: Delayed SCO check - scoActive=$scoNowActive")
                            if (scoNowActive) {
                                wasOnBluetooth = true
                                onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                                })
                            }
                        }, 500)
                        // Don't set routedSuccessfully here - let the delayed check handle it
                    }
                } else {
                    Log.d(TAG, "routeAudioToBluetoothIfConnected: No Bluetooth SCO/BLE device in availableCommunicationDevices")
                }
            } catch (e: Exception) {
                Log.e(TAG, "routeAudioToBluetoothIfConnected: Failed to use setCommunicationDevice", e)
            }
        } else {
            // Legacy (Android < 12): Must verify Bluetooth HEADSET profile is actually connected
            // isBluetoothScoAvailableOffCall returns true even without BT connected - it just means device supports SCO
            // Wrap in try-catch because BluetoothAdapter requires BLUETOOTH permission
            var headsetConnected = false
            try {
                val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
                headsetConnected = bluetoothAdapter?.getProfileConnectionState(BluetoothProfile.HEADSET) == BluetoothProfile.STATE_CONNECTED
            } catch (e: SecurityException) {
                Log.w(TAG, "routeAudioToBluetoothIfConnected: No BLUETOOTH permission, cannot check headset state", e)
            }
            
            Log.d(TAG, "routeAudioToBluetoothIfConnected: Legacy - headsetProfileConnected=$headsetConnected, isBluetoothScoAvailableOffCall=${am.isBluetoothScoAvailableOffCall}")
            
            // ONLY try to route if HEADSET profile is actually connected
            if (headsetConnected && am.isBluetoothScoAvailableOffCall) {
                Log.d(TAG, "routeAudioToBluetoothIfConnected: Bluetooth HEADSET connected, attempting to start SCO")
                am.startBluetoothSco()
                
                // Verify SCO actually started after a short delay
                mainHandler.postDelayed({
                    val scoNowActive = am.isBluetoothScoOn
                    Log.d(TAG, "routeAudioToBluetoothIfConnected: Legacy delayed SCO check - scoActive=$scoNowActive")
                    if (scoNowActive) {
                        wasOnBluetooth = true
                        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                        })
                    } else {
                        Log.d(TAG, "routeAudioToBluetoothIfConnected: SCO did not activate, staying on earpiece")
                    }
                }, 500)
            } else {
                Log.d(TAG, "routeAudioToBluetoothIfConnected: No Bluetooth HEADSET connected, staying on earpiece")
            }
        }
        
        Log.d(TAG, "=== routeAudioToBluetoothIfConnected END ===")
    }

    // Idempotency guard for disconnect/decline
    @Volatile private var isDisconnectingOrDisconnected = false

    /**
     * Callback to check whether other active calls exist in the service.
     * Set by TVConnectionService.attachCallEventListeners().
     * Used by onDisconnected() to decide whether to release audio focus:
     * if other calls are still active, we must NOT release audio focus or the
     * OS (Android 12+/16) will kill the foreground notification for the remaining call.
     */
    var hasOtherActiveCalls: (() -> Boolean)? = null

    /**
     * Callback to silence the ringtone when onSilence() is called by the system.
     * Set by TVConnectionService.attachCallEventListeners().
     * Called when the user presses volume-down during incoming call ringing.
     */
    var onSilenceCallback: (() -> Unit)? = null

    /**
     * Callback invoked when onAnswer() is triggered by the system (e.g. BT headset button).
     * Set by TVConnectionService.attachCallEventListeners().
     * Handles notification cancellation, wake lock release, ongoing call notification,
     * and MainActivity launch — the same work that ACTION_ANSWER does in onStartCommand.
     * Without this, answering via BT headset leaves the incoming call notification visible.
     */
    var onAnswerCallback: (() -> Unit)? = null

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
        val otherCallsActive = hasOtherActiveCalls?.invoke() ?: false
        Log.i(TAG, "[Decline] forceDisconnectWithLogging called. State: $state, Direction: $callDirection, twilioCall: ${twilioCall != null}, CallParams: ${getCallParameters()?.callSid}, otherCallsActive=$otherCallsActive")
        
        // Stop ringback tone if playing
        stopRingback()

        // Release audio focus when disconnecting — but ONLY if no other calls are active.
        // When other calls exist, releasing audio focus would kill their foreground notification.
        if (otherCallsActive) {
            Log.d(TAG, "[Decline] Skipping releaseAudioFocus — other calls still active")
        } else {
            releaseAudioFocus()
        }
        
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

        // Stop ringback tone on connect failure
        stopRingback()

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
                // Start ringback tone for outgoing calls
                startRingback()
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

        // Stop ringback tone when call connects (callee answered)
        stopRingback()

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
        
        // IMPORTANT: Detect and route to initial audio device (Bluetooth/Earpiece)
        // This is critical for MIUI and other devices where Bluetooth should be auto-selected
        mainHandler.postDelayed({
            detectAndRouteToInitialAudioDevice()
        }, 500) // Small delay to let audio routing settle
    }
    
    /**
     * Detect the initial audio device and route accordingly.
     * If Bluetooth is connected, try to route to it and notify Flutter.
     * Otherwise, stay on earpiece and notify Flutter.
     * 
     * This handles the case where Bluetooth is already connected when the call starts.
     */
    private fun detectAndRouteToInitialAudioDevice() {
        Log.d(TAG, "=== detectAndRouteToInitialAudioDevice START ===")
        val am = audioManager ?: return
        
        // First check if SCO is already active
        val isBluetoothScoActive = am.isBluetoothScoOn
        Log.d(TAG, "detectAndRouteToInitialAudioDevice: isBluetoothScoOn=$isBluetoothScoActive")
        
        if (isBluetoothScoActive) {
            // SCO is already active, just emit Bluetooth ON
            Log.d(TAG, "detectAndRouteToInitialAudioDevice: SCO already active, emitting Bluetooth ON")
            wasOnBluetooth = true
            onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
            })
            Log.d(TAG, "=== detectAndRouteToInitialAudioDevice END ===")
            return
        }
        
        // SCO is not active - check if a Bluetooth device is connected and try to route to it
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val availableDevices = am.availableCommunicationDevices
                Log.d(TAG, "detectAndRouteToInitialAudioDevice: Available devices: ${availableDevices.map { "type=${it.type}, name=${it.productName}" }}")
                
                val bluetoothDevice = availableDevices.firstOrNull { isBluetoothDevice(it) }
                if (bluetoothDevice != null) {
                    Log.d(TAG, "detectAndRouteToInitialAudioDevice: Found Bluetooth device, routing to it")
                    val result = am.setCommunicationDevice(bluetoothDevice)
                    Log.d(TAG, "detectAndRouteToInitialAudioDevice: setCommunicationDevice result=$result")
                    
                    if (result) {
                        // Verify SCO activates after a delay
                        mainHandler.postDelayed({
                            val scoNowActive = am.isBluetoothScoOn
                            Log.d(TAG, "detectAndRouteToInitialAudioDevice: Delayed SCO check - scoActive=$scoNowActive")
                            if (scoNowActive) {
                                wasOnBluetooth = true
                                onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                                })
                            } else {
                                // SCO didn't activate, emit Bluetooth OFF
                                wasOnBluetooth = false
                                onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, false)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                                })
                            }
                        }, 500)
                        Log.d(TAG, "=== detectAndRouteToInitialAudioDevice END (waiting for SCO) ===")
                        return
                    }
                } else {
                    Log.d(TAG, "detectAndRouteToInitialAudioDevice: No Bluetooth device available")
                }
            } catch (e: Exception) {
                Log.e(TAG, "detectAndRouteToInitialAudioDevice: Error", e)
            }
        } else {
            // Legacy (Android < 12): Try to start SCO if Bluetooth might be available
            Log.d(TAG, "detectAndRouteToInitialAudioDevice: Legacy - attempting to start SCO")
            try {
                am.startBluetoothSco()
                
                // Check if SCO activated after a delay
                mainHandler.postDelayed({
                    val scoNowActive = am.isBluetoothScoOn
                    Log.d(TAG, "detectAndRouteToInitialAudioDevice: Legacy delayed SCO check - scoActive=$scoNowActive")
                    if (scoNowActive) {
                        wasOnBluetooth = true
                        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, true)
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                        })
                    } else {
                        // SCO didn't activate - no Bluetooth connected
                        wasOnBluetooth = false
                        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, false)
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                        })
                    }
                }, 500)
                Log.d(TAG, "=== detectAndRouteToInitialAudioDevice END (waiting for SCO) ===")
                return
            } catch (e: Exception) {
                Log.e(TAG, "detectAndRouteToInitialAudioDevice: Failed to start SCO", e)
            }
        }
        
        // No Bluetooth available or routing failed - emit Bluetooth OFF
        Log.d(TAG, "detectAndRouteToInitialAudioDevice: No Bluetooth, emitting Bluetooth OFF state")
        wasOnBluetooth = false
        onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
            putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, false)
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
        })
        
        Log.d(TAG, "=== detectAndRouteToInitialAudioDevice END ===")
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
        val otherCallsActive = hasOtherActiveCalls?.invoke() ?: false
        Log.d(TAG, "onDisconnected: onDisconnected, reason: ${reason?.message}, isDisconnectingOrDisconnected=$isDisconnectingOrDisconnected, otherCallsActive=$otherCallsActive.\nException: ${reason.toString()}")

        // Stop ringback tone if playing
        stopRingback()

        twilioCall = null

        // If forceDisconnectWithLogging() already handled this disconnect,
        // skip releaseAudioFocus/destroy to avoid killing the restored audio focus
        // of a remaining call in a call-waiting scenario.
        if (isDisconnectingOrDisconnected) {
            Log.d(TAG, "onDisconnected: Already handled by forceDisconnectWithLogging, skipping duplicate cleanup")
            return
        }
        isDisconnectingOrDisconnected = true

        // Only release audio focus if no other calls are still active.
        // When another call exists (e.g. held call that will resume), releasing audio
        // focus resets AudioManager to MODE_NORMAL, abandons focus, and clears the
        // communication device — on Android 12+/16 this causes the OS to revoke the
        // FOREGROUND_SERVICE_TYPE_PHONE_CALL foreground notification for the remaining call.
        if (otherCallsActive) {
            Log.d(TAG, "onDisconnected: Skipping releaseAudioFocus — other calls still active, preserving audio state for remaining call")
        } else {
            releaseAudioFocus()
        }
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
        val otherCallsActive = hasOtherActiveCalls?.invoke() ?: false
        Log.i(TAG, "onAbort: onAbort, isDisconnectingOrDisconnected=$isDisconnectingOrDisconnected, otherCallsActive=$otherCallsActive")
        if (isDisconnectingOrDisconnected) {
            Log.d(TAG, "onAbort: Already handled by forceDisconnectWithLogging, skipping duplicate cleanup")
            return
        }
        isDisconnectingOrDisconnected = true

        // Stop ringback tone if playing
        stopRingback()

        twilioCall?.disconnect()
        if (otherCallsActive) {
            Log.d(TAG, "onAbort: Skipping releaseAudioFocus — other calls still active")
        } else {
            releaseAudioFocus()
        }
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        onAction?.onChange(TVNativeCallActions.ACTION_ABORT, null)
        onDisconnected?.withValue(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
    }

    override fun onDisconnect() {
        super.onDisconnect()
        val otherCallsActive = hasOtherActiveCalls?.invoke() ?: false
        Log.i(TAG, "onDisconnect: onDisconnect, isDisconnectingOrDisconnected=$isDisconnectingOrDisconnected, otherCallsActive=$otherCallsActive")
        if (isDisconnectingOrDisconnected) {
            Log.d(TAG, "onDisconnect: Already handled by forceDisconnectWithLogging, skipping duplicate cleanup")
            return
        }
        isDisconnectingOrDisconnected = true

        // Stop ringback tone if playing
        stopRingback()

        twilioCall?.disconnect()
        if (otherCallsActive) {
            Log.d(TAG, "onDisconnect: Skipping releaseAudioFocus — other calls still active")
        } else {
            releaseAudioFocus()
        }
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

    // =========================================================================
    // API 34+ CallEndpoint-based audio callbacks (Gap 5)
    // These replace the deprecated onCallAudioStateChanged() on Android 14+.
    // We convert CallEndpoint data into CallAudioState for backward compatibility
    // with the existing broadcast mechanism that TwilioVoicePlugin.handleBroadcastIntent
    // depends on.
    // =========================================================================

    /**
     * Called when the current audio endpoint changes (API 34+).
     * Replaces the deprecated onCallAudioStateChanged() for audio route tracking.
     */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onCallEndpointChanged(callEndpoint: CallEndpoint) {
        Log.d(TAG, "onCallEndpointChanged: endpoint=${callEndpoint.endpointName}, type=${callEndpoint.endpointType}")
        super.onCallEndpointChanged(callEndpoint)

        // Map CallEndpoint type to CallAudioState route for backward compatibility
        val route = when (callEndpoint.endpointType) {
            CallEndpoint.TYPE_EARPIECE -> CallAudioState.ROUTE_EARPIECE
            CallEndpoint.TYPE_SPEAKER -> CallAudioState.ROUTE_SPEAKER
            CallEndpoint.TYPE_BLUETOOTH -> CallAudioState.ROUTE_BLUETOOTH
            CallEndpoint.TYPE_WIRED_HEADSET -> CallAudioState.ROUTE_WIRED_HEADSET
            CallEndpoint.TYPE_STREAMING -> CallAudioState.ROUTE_EARPIECE // fallback
            else -> CallAudioState.ROUTE_EARPIECE
        }

        // Track Bluetooth state for toggleBluetooth early-return optimization
        wasOnBluetooth = callEndpoint.endpointType == CallEndpoint.TYPE_BLUETOOTH

        // Build a CallAudioState to broadcast — this is what TwilioVoicePlugin.handleBroadcastIntent expects
        @Suppress("DEPRECATION")
        val syntheticAudioState = CallAudioState(
            false, // mute state is handled separately by onMuteStateChanged
            route,
            route // supportedRouteMask — simplified, actual available routes tracked by availableCallEndpoints
        )

        Intent(TVBroadcastReceiver.ACTION_AUDIO_STATE).apply {
            putExtra(TVBroadcastReceiver.EXTRA_AUDIO_STATE, syntheticAudioState)
        }.also {
            sendBroadcast(context, it)
        }
    }

    /**
     * Called when the list of available audio endpoints changes (API 34+).
     * Stores the endpoints for use by requestCallEndpointChange() in toggleSpeaker/toggleBluetooth.
     */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onAvailableCallEndpointsChanged(availableEndpoints: List<CallEndpoint>) {
        Log.d(TAG, "onAvailableCallEndpointsChanged: ${availableEndpoints.map { "${it.endpointName}(type=${it.endpointType})" }}")
        super.onAvailableCallEndpointsChanged(availableEndpoints)
        // Store as List<Any> to avoid class verification issues on pre-34 devices.
        // At runtime on API 34+ these are always CallEndpoint instances.
        availableCallEndpoints = availableEndpoints
    }

    /**
     * Called when the mute state changes (API 34+).
     * Replaces the mute tracking from onCallAudioStateChanged().
     */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onMuteStateChanged(isMuted: Boolean) {
        Log.d(TAG, "onMuteStateChanged: isMuted=$isMuted")
        super.onMuteStateChanged(isMuted)

        // Broadcast mute state change using the same mechanism
        onEvent?.onChange(TVNativeCallEvents.EVENT_MUTE, Bundle().apply {
            putBoolean(TVBroadcastReceiver.EXTRA_CALL_MUTE_STATE, isMuted)
            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
        })
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
     * API 34+: Uses onMuteStateChanged() callback.
     * Pre-34: Uses deprecated callAudioState.copyWith() path.
     */
    @Suppress("DEPRECATION")
    fun toggleMute(newState: Boolean) {
        twilioCall?.let {
            it.mute(newState)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // API 34+: onMuteStateChanged() will fire automatically from the system
                // when the mute state changes. We also emit directly for immediate UI update.
                Log.d(TAG, "toggleMute: API 34+ — muted via Twilio SDK, onMuteStateChanged will fire")
                onEvent?.onChange(TVNativeCallEvents.EVENT_MUTE, Bundle().apply {
                    putBoolean(TVBroadcastReceiver.EXTRA_CALL_MUTE_STATE, newState)
                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                })
            } else {
                // Pre-API 34: Use deprecated callAudioState path
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
        Log.d(TAG, "=== toggleSpeaker START === newState=$newState, state=$state, callAudioState=$callAudioState")

        // Update ringback audio route if playing
        try {
            val ringbackManager = RingbackManager.getInstance(context)
            if (ringbackManager.isRingbackPlaying()) {
                ringbackManager.updateAudioRoute(newState)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update ringback audio route: ${e.message}")
        }

        // When the connection is alive, use the official TelecomManager audio routing API.
        // API 34+: requestCallEndpointChange() (new, non-deprecated)
        // Pre-34:  setAudioRoute() (deprecated but works)
        // When callAudioState is null (e.g. after call-waiting), these silently fail
        // so we must manipulate AudioManager directly — same as the disconnected path.
        if (state != STATE_DISCONNECTED && (callAudioState != null || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && availableCallEndpoints.isNotEmpty()))) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // API 34+: Use requestCallEndpointChange with endpoints from onAvailableCallEndpointsChanged
                val targetType = if (newState) CallEndpoint.TYPE_SPEAKER else CallEndpoint.TYPE_EARPIECE
                @Suppress("UNCHECKED_CAST")
                val endpoints = availableCallEndpoints as List<CallEndpoint>
                val targetEndpoint = endpoints.firstOrNull { it.endpointType == targetType }
                if (targetEndpoint != null) {
                    Log.d(TAG, "toggleSpeaker: API 34+ requestCallEndpointChange to ${targetEndpoint.endpointName} (type=$targetType)")
                    requestCallEndpointChange(targetEndpoint, { it.run() }, object : android.os.OutcomeReceiver<Void?, android.telecom.CallEndpointException> {
                        override fun onResult(result: Void?) {
                            Log.d(TAG, "toggleSpeaker: requestCallEndpointChange succeeded")
                        }
                        override fun onError(error: android.telecom.CallEndpointException) {
                            Log.e(TAG, "toggleSpeaker: requestCallEndpointChange failed: ${error.message}")
                        }
                    })
                } else {
                    Log.w(TAG, "toggleSpeaker: No endpoint of type $targetType found in ${endpoints.map { it.endpointType }}, falling back to setAudioRoute")
                    @Suppress("DEPRECATION")
                    if (newState) setAudioRoute(CallAudioState.ROUTE_SPEAKER) else setAudioRoute(CallAudioState.ROUTE_WIRED_OR_EARPIECE)
                }
            } else {
                // Pre-API 34: Use deprecated setAudioRoute
                Log.d(TAG, "toggleSpeaker: Using TelecomManager setAudioRoute, newState=$newState")
                @Suppress("DEPRECATION")
                if (newState) setAudioRoute(CallAudioState.ROUTE_SPEAKER) else setAudioRoute(CallAudioState.ROUTE_WIRED_OR_EARPIECE)
            }
        } else {
            // Use AudioManager directly when callAudioState is null or disconnected.
            // PERF: Submit to the shared single-thread executor so that concurrent
            // toggleSpeaker + toggleBluetooth calls are serialized. This avoids two
            // threads racing on AudioManager's internal lock (which caused 1-2s freezes
            // when detectAudioState() was called on the main thread).
            Log.d(TAG, "toggleSpeaker: callAudioState is null or disconnected, submitting AudioManager work to audioExecutor")
            audioExecutor.submit {
                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                
                // Log current state before change
                Log.d(TAG, "toggleSpeaker: BEFORE - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
                
                if (newState) {
                    // Turning Speaker ON - ensure Bluetooth is off first
                    Log.d(TAG, "toggleSpeaker: Turning Speaker ON")
                    
                    // For Android 12+, use setCommunicationDevice (preferred, skips legacy)
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
                                Log.w(TAG, "toggleSpeaker: No speaker device found, using legacy fallback")
                                audioManager.stopBluetoothSco()
                                audioManager.isBluetoothScoOn = false
                                audioManager.isSpeakerphoneOn = true
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "toggleSpeaker: Failed to set communication device, using legacy fallback", e)
                            audioManager.stopBluetoothSco()
                            audioManager.isBluetoothScoOn = false
                            audioManager.isSpeakerphoneOn = true
                        }
                    } else {
                        // Pre-Android 12: use legacy methods
                        Log.d(TAG, "toggleSpeaker: Pre-Android 12, using legacy methods")
                        audioManager.stopBluetoothSco()
                        audioManager.isBluetoothScoOn = false
                        audioManager.isSpeakerphoneOn = true
                    }
                } else {
                    // Turning Speaker OFF - route to earpiece
                    Log.d(TAG, "toggleSpeaker: Turning Speaker OFF, routing to earpiece")
                    audioManager.isSpeakerphoneOn = false
                    
                    // For Android 12+, use setCommunicationDevice (preferred, skips legacy)
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
                
                // Broadcast speaker state change (must be on main thread for LocalBroadcastManager)
                Handler(Looper.getMainLooper()).post {
                    Log.d(TAG, "toggleSpeaker: Broadcasting EVENT_SPEAKER with state=$newState")
                    onEvent?.onChange(TVNativeCallEvents.EVENT_SPEAKER, Bundle().apply {
                        putBoolean(TVBroadcastReceiver.EXTRA_CALL_SPEAKER_STATE, newState)
                        putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                    })
                }
            }
        }
        Log.d(TAG, "=== toggleSpeaker END ===")
    }

    /**
     * Toggle audio route of the call.
     * @param newState: true if bluetooth is enabled, false if bluetooth is disabled
     */
    fun toggleBluetooth(newState: Boolean) {
        Log.d(TAG, "=== toggleBluetooth START === newState=$newState, state=$state, callAudioState=$callAudioState")

        // PERF: Early-return when turning BT off but it's already off.
        // This avoids unnecessary AudioManager work (and lock contention) when
        // the Dart side fires ToggleBluetooth(false) from earpiece→speaker transitions.
        if (!newState && !wasOnBluetooth) {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (!audioManager.isBluetoothScoOn) {
                Log.d(TAG, "toggleBluetooth: BT already off (wasOnBluetooth=false, scoOff), skipping")
                return
            }
        }

        // Update ringback Bluetooth audio route if playing
        try {
            val ringbackManager = RingbackManager.getInstance(context)
            if (ringbackManager.isRingbackPlaying()) {
                ringbackManager.updateBluetoothRoute(newState)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update ringback bluetooth route: ${e.message}")
        }

        // When the connection is alive, use the official TelecomManager audio routing API.
        // API 34+: requestCallEndpointChange() (new, non-deprecated)
        // Pre-34:  setAudioRoute() (deprecated but works)
        if (state != STATE_DISCONNECTED && (callAudioState != null || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && availableCallEndpoints.isNotEmpty()))) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // API 34+: Use requestCallEndpointChange with endpoints from onAvailableCallEndpointsChanged
                val targetType = if (newState) CallEndpoint.TYPE_BLUETOOTH else CallEndpoint.TYPE_EARPIECE
                @Suppress("UNCHECKED_CAST")
                val endpoints = availableCallEndpoints as List<CallEndpoint>
                val targetEndpoint = endpoints.firstOrNull { it.endpointType == targetType }
                if (targetEndpoint != null) {
                    Log.d(TAG, "toggleBluetooth: API 34+ requestCallEndpointChange to ${targetEndpoint.endpointName} (type=$targetType)")
                    requestCallEndpointChange(targetEndpoint, { it.run() }, object : android.os.OutcomeReceiver<Void?, android.telecom.CallEndpointException> {
                        override fun onResult(result: Void?) {
                            Log.d(TAG, "toggleBluetooth: requestCallEndpointChange succeeded")
                        }
                        override fun onError(error: android.telecom.CallEndpointException) {
                            Log.e(TAG, "toggleBluetooth: requestCallEndpointChange failed: ${error.message}")
                        }
                    })
                } else {
                    Log.w(TAG, "toggleBluetooth: No endpoint of type $targetType found in ${endpoints.map { it.endpointType }}, falling back to setAudioRoute")
                    @Suppress("DEPRECATION")
                    if (newState) setAudioRoute(CallAudioState.ROUTE_BLUETOOTH) else setAudioRoute(CallAudioState.ROUTE_WIRED_OR_EARPIECE)
                }
            } else {
                // Pre-API 34: Use deprecated setAudioRoute
                Log.d(TAG, "toggleBluetooth: Using TelecomManager setAudioRoute, newState=$newState")
                @Suppress("DEPRECATION")
                if (newState) setAudioRoute(CallAudioState.ROUTE_BLUETOOTH) else setAudioRoute(CallAudioState.ROUTE_WIRED_OR_EARPIECE)
            }

            if (newState) wasOnBluetooth = true else wasOnBluetooth = false
        } else {
            // Use AudioManager directly when callAudioState is null or disconnected.
            // PERF: Submit to the shared single-thread executor so that concurrent
            // toggleSpeaker + toggleBluetooth calls are serialized. This avoids two
            // threads racing on AudioManager's internal lock.
            Log.d(TAG, "toggleBluetooth: callAudioState is null or disconnected, submitting AudioManager work to audioExecutor")
            audioExecutor.submit {
                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                
                // Log current state before change
                Log.d(TAG, "toggleBluetooth: BEFORE - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
                
                if (newState) {
                    // Turning Bluetooth ON - turn off speaker first
                    Log.d(TAG, "toggleBluetooth: Turning Bluetooth ON")
                    audioManager.isSpeakerphoneOn = false
                    
                    // For Android 12+, use setCommunicationDevice (preferred, skips legacy)
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
                                Log.w(TAG, "toggleBluetooth: No Bluetooth device found in availableCommunicationDevices, using legacy")
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
                        // Pre-Android 12: use legacy methods
                        Log.d(TAG, "toggleBluetooth: Pre-Android 12, using legacy startBluetoothSco()")
                        audioManager.startBluetoothSco()
                        audioManager.isBluetoothScoOn = true
                        wasOnBluetooth = true
                    }
                } else {
                    // Turning Bluetooth OFF - route to earpiece
                    Log.d(TAG, "toggleBluetooth: Turning Bluetooth OFF, routing to earpiece")
                    wasOnBluetooth = false
                    
                    // For Android 12+, use setCommunicationDevice (preferred, skips legacy)
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
                    
                    // Legacy methods - needed for pre-12 and as fallback
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        Log.d(TAG, "toggleBluetooth: Pre-Android 12, using legacy methods - stopBluetoothSco")
                        audioManager.stopBluetoothSco()
                        audioManager.isBluetoothScoOn = false
                        audioManager.isSpeakerphoneOn = false
                    }
                }
                
                // Log state after change
                Log.d(TAG, "toggleBluetooth: AFTER - isSpeakerphoneOn=${audioManager.isSpeakerphoneOn}, isBluetoothScoOn=${audioManager.isBluetoothScoOn}")
                
                // Broadcast bluetooth state change (must be on main thread for LocalBroadcastManager)
                Handler(Looper.getMainLooper()).post {
                    Log.d(TAG, "toggleBluetooth: Broadcasting EVENT_BLUETOOTH with state=$newState")
                    onEvent?.onChange(TVNativeCallEvents.EVENT_BLUETOOTH, Bundle().apply {
                        putBoolean(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, newState)
                        putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callParams?.callSid)
                    })
                }
            }
        }
        Log.d(TAG, "=== toggleBluetooth END ===")
    }

    /**
     * Toggle audio route of the call.
     * @param newAudioRoute: the new audio route to set (CallAudioState.ROUTE_*)
     * @param condition: true to use [newAudioRoute], false to use [fallback]
     * @param fallback: the fallback audio route to use if [condition] is false
     *
     * Supports API 34+ via requestCallEndpointChange() and falls back to
     * deprecated setAudioRoute() on older devices.
     */
    @Suppress("DEPRECATION")
    private fun toggleAudioRoute(newAudioRoute: Int, condition: Boolean? = null, fallback: Int = CallAudioState.ROUTE_WIRED_OR_EARPIECE) {
        val targetRoute = if (condition ?: (newAudioRoute == fallback)) newAudioRoute else fallback

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && availableCallEndpoints.isNotEmpty()) {
            // API 34+: Map CallAudioState route to CallEndpoint type
            val targetEndpointType = when (targetRoute) {
                CallAudioState.ROUTE_SPEAKER -> CallEndpoint.TYPE_SPEAKER
                CallAudioState.ROUTE_BLUETOOTH -> CallEndpoint.TYPE_BLUETOOTH
                CallAudioState.ROUTE_WIRED_HEADSET -> CallEndpoint.TYPE_WIRED_HEADSET
                else -> CallEndpoint.TYPE_EARPIECE
            }
            @Suppress("UNCHECKED_CAST")
            val endpoints = availableCallEndpoints as List<CallEndpoint>
            val targetEndpoint = endpoints.firstOrNull { it.endpointType == targetEndpointType }
            if (targetEndpoint != null) {
                Log.d(TAG, "toggleAudioRoute: API 34+ requestCallEndpointChange to ${targetEndpoint.endpointName}")
                requestCallEndpointChange(targetEndpoint, { it.run() }, object : android.os.OutcomeReceiver<Void?, android.telecom.CallEndpointException> {
                    override fun onResult(result: Void?) {
                        Log.d(TAG, "toggleAudioRoute: requestCallEndpointChange succeeded")
                    }
                    override fun onError(error: android.telecom.CallEndpointException) {
                        Log.e(TAG, "toggleAudioRoute: requestCallEndpointChange failed: ${error.message}")
                    }
                })
                return
            }
            Log.w(TAG, "toggleAudioRoute: No endpoint of type $targetEndpointType, falling back to setAudioRoute")
        }

        callAudioState?.let {
            setAudioRoute(targetRoute)

            // Since audio route onCallAudioStateChanged does not respond to changes when call is on hold, we invoke this change manually to notify the UI.
            if (state == STATE_HOLDING) {
                onCallAudioStateChanged(callAudioState.copyWith(targetRoute))
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

        // Stop ringback tone if playing
        stopRingback()

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
     * Starts the ringback tone for outgoing calls.
     * Respects current audio route (speaker/bluetooth/earpiece).
     */
    private fun startRingback() {
        try {
            val ringbackManager = RingbackManager.getInstance(context)
            val useSpeaker = callAudioState?.route == CallAudioState.ROUTE_SPEAKER
                || (audioManager?.isSpeakerphoneOn == true)
            val useBluetooth = callAudioState?.route == CallAudioState.ROUTE_BLUETOOTH
                || (audioManager?.isBluetoothScoOn == true)
            ringbackManager.startRingback(useSpeaker, useBluetooth)
            Log.d(TAG, "Started ringback tone (speaker=$useSpeaker, bluetooth=$useBluetooth)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start ringback: ${e.message}")
        }
    }

    /**
     * Stops the ringback tone.
     */
    private fun stopRingback() {
        try {
            val ringbackManager = RingbackManager.getInstance(context)
            ringbackManager.stopRingback()
            Log.d(TAG, "Stopped ringback tone")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop ringback: ${e.message}")
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



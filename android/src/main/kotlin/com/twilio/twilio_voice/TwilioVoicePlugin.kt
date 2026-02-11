package com.twilio.twilio_voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.telecom.CallAudioState
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.appcompat.app.AlertDialog
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.constants.Constants
import com.twilio.twilio_voice.constants.FlutterErrorCodes
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.storage.Storage
import com.twilio.twilio_voice.storage.StorageImpl
import com.twilio.twilio_voice.types.CallDirection
import com.twilio.twilio_voice.types.CallExceptionExtension
import com.twilio.twilio_voice.types.ContextExtension.hasMicrophoneAccess
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneNumbersPermission
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneStatePermission
import com.twilio.twilio_voice.types.ContextExtension.checkPermission
import com.twilio.twilio_voice.types.ContextExtension.hasCallPhonePermission
import com.twilio.twilio_voice.types.ContextExtension.hasManageOwnCallsPermission
import com.twilio.twilio_voice.types.IntentExtension.getParcelableExtraSafe
import com.twilio.twilio_voice.types.TVMethodChannels
import com.twilio.twilio_voice.types.TVNativeCallActions
import com.twilio.twilio_voice.types.TVNativeCallEvents
import com.twilio.twilio_voice.types.TelecomManagerExtension.canReadPhoneNumbers
import com.twilio.twilio_voice.types.TelecomManagerExtension.getPhoneAccountHandle
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccount
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccountSafe
import com.twilio.twilio_voice.types.TelecomManagerExtension.openPhoneAccountSettings
import com.twilio.twilio_voice.types.TelecomManagerExtension.registerPhoneAccount
import com.twilio.voice.Call
import com.twilio.voice.CallException
import com.twilio.voice.CallInvite
import com.twilio.voice.RegistrationException
import com.twilio.voice.RegistrationListener
import com.twilio.voice.UnregistrationListener
import com.twilio.voice.Voice
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry.NewIntentListener
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener
import org.json.JSONObject
import java.util.Locale

class TwilioVoicePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, NewIntentListener, RequestPermissionsResultListener {

    private val TAG = "TwilioVoicePlugin"

    // Locals
    private var fcmToken: String? = null
    private var accessToken: String? = null
    private var context: Context? = null
    private var activity: Activity? = null

    // Flag indicating whether TVBroadcastReceiver has been registered/unregistered with LocalBroadcastManager
    private var isReceiverRegistered = false
    private var broadcastReceiver: TVBroadcastReceiver? = null

    // Instances
    private var telecomManager: TelecomManager? = null
    private var storage: Storage? = null

    // Flutter
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventSink? = null
    
    // Event queue for events that arrive before Flutter is ready
    private val pendingEvents = mutableListOf<String>()

    // member instance functions
    private var callListener = callListener()

    // Constants
    private val kCHANNEL_NAME = "twilio_voice"
    private val REQUEST_CODE_MICROPHONE = 1
    private val REQUEST_CODE_CALL_PHONE = 3
    private val REQUEST_CODE_READ_PHONE_NUMBERS = 4
    private val REQUEST_CODE_READ_PHONE_STATE = 5
    private val REQUEST_CODE_MICROPHONE_FOREGROUND = 6
    private val REQUEST_CODE_MANAGE_CALLS = 7
    private val REQUEST_CODE_SCHEDULE_EXACT_ALARM = 8

    private var isSpeakerOn: Boolean = false
    private var isBluetoothOn: Boolean = false
    private var isMuted: Boolean = false
    private var isHolding: Boolean = false
    private var callSid: String? = null


    private var hasStarted = false

    // Provides a mapping of permission to result handler for when the permission is granted or denied via the PluginRegistry, then responds via future to the Flutter side
    private val permissionResultHandler: MutableMap<Int, (Boolean) -> Unit> = mutableMapOf()

    /**
     * UNIFIED AUDIO STATE DETECTION
     * Works across all Android devices (Samsung, MIUI/Xiaomi, Stock Android, etc.)
     * by checking multiple sources in order of reliability.
     * 
     * Returns a data class with:
     * - audioRoute: "bluetooth", "speaker", "wired_headset", or "earpiece"
     * - isBluetoothConnected: whether a Bluetooth audio device is connected
     * - isBluetoothActive: whether audio is actively routing through Bluetooth
     */
    data class AudioState(
        val audioRoute: String,
        val isBluetoothConnected: Boolean,
        val isBluetoothActive: Boolean,
        val isSpeakerActive: Boolean
    )
    
    private fun detectAudioState(): AudioState {
        Log.d(TAG, "=== detectAudioState START ===")
        
        var audioRoute = "earpiece"
        var isBluetoothConnected = false
        var isBluetoothActive = false
        var isSpeakerActive = false
        
        val audioManager = context?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        
        // CRITICAL: First check SCO state - this is the definitive source for voice call Bluetooth
        val isBluetoothScoOn = audioManager?.isBluetoothScoOn == true
        Log.d(TAG, "detectAudioState: [MASTER CHECK] isBluetoothScoOn=$isBluetoothScoOn")
        
        // ===== CHECK 1: Android 12+ communicationDevice =====
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && audioManager != null) {
            try {
                val commDevice = audioManager.communicationDevice
                Log.d(TAG, "detectAudioState: [CHECK 1] communicationDevice type=${commDevice?.type}")
                
                if (commDevice != null) {
                    when (commDevice.type) {
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_BLE_HEADSET,
                        AudioDeviceInfo.TYPE_HEARING_AID,
                        AudioDeviceInfo.TYPE_BLE_SPEAKER -> {
                            // Only trust Bluetooth device if SCO is actually on
                            if (isBluetoothScoOn) {
                                audioRoute = "bluetooth"
                                isBluetoothActive = true
                                isBluetoothConnected = true
                                Log.d(TAG, "detectAudioState: [CHECK 1] -> bluetooth (type=${commDevice.type}, SCO verified)")
                            } else {
                                audioRoute = "earpiece"
                                Log.d(TAG, "detectAudioState: [CHECK 1] -> BT device but SCO OFF, using earpiece")
                            }
                        }
                        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> {
                            audioRoute = "speaker"
                            isSpeakerActive = true
                            Log.d(TAG, "detectAudioState: [CHECK 1] -> speaker")
                        }
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        AudioDeviceInfo.TYPE_USB_HEADSET -> {
                            audioRoute = "wired_headset"
                            Log.d(TAG, "detectAudioState: [CHECK 1] -> wired_headset")
                        }
                        else -> {
                            audioRoute = "earpiece"
                            Log.d(TAG, "detectAudioState: [CHECK 1] -> earpiece (type=${commDevice.type})")
                        }
                    }
                    
                    // Update stored state and return early
                    isBluetoothOn = isBluetoothActive
                    isSpeakerOn = isSpeakerActive
                    
                    // CRITICAL: Check if Bluetooth device is available even if not currently active
                    // This is needed for showing the Bluetooth option in the audio toggle popup
                    if (!isBluetoothConnected) {
                        isBluetoothConnected = checkBluetoothDeviceAvailable()
                    }
                    
                    Log.d(TAG, "=== detectAudioState END (via communicationDevice) === route=$audioRoute, btConnected=$isBluetoothConnected, btActive=$isBluetoothActive")
                    return AudioState(audioRoute, isBluetoothConnected, isBluetoothActive, isSpeakerActive)
                }
            } catch (e: Exception) {
                Log.e(TAG, "detectAudioState: [CHECK 1] Error checking communicationDevice", e)
            }
        }
        
        // ===== CHECK 2: Bluetooth SCO state (fallback for older Android) =====
        if (audioManager != null) {
            try {
                Log.d(TAG, "detectAudioState: [CHECK 2] isBluetoothScoOn=$isBluetoothScoOn")
                if (isBluetoothScoOn) {
                    audioRoute = "bluetooth"
                    isBluetoothActive = true
                    isBluetoothConnected = true
                }
                
                // Also check speaker
                if (!isBluetoothActive) {
                    isSpeakerActive = audioManager.isSpeakerphoneOn
                    if (isSpeakerActive) {
                        audioRoute = "speaker"
                    }
                    Log.d(TAG, "detectAudioState: [CHECK 2] isSpeakerphoneOn=$isSpeakerActive")
                }
            } catch (e: Exception) {
                Log.e(TAG, "detectAudioState: [CHECK 2] Error checking AudioManager", e)
            }
        }
        
        // ===== CHECK 3: Skip BluetoothAdapter check - unreliable for voice call Bluetooth =====
        // BluetoothAdapter.getProfileConnectionState can show connected even when SCO is not available
        // We only trust isBluetoothScoOn for voice call Bluetooth detection
        
        // ===== CHECK 4: TelecomManager CallAudioState (if available) =====
        val activeCall = TVConnectionService.activeConnections.values.firstOrNull()
        if (activeCall != null) {
            val callAudioState = activeCall.callAudioState
            if (callAudioState != null) {
                Log.d(TAG, "detectAudioState: [CHECK 4] callAudioState.route=${CallAudioState.audioRouteToString(callAudioState.route)}")
                
                // Use CallAudioState as the source of truth for audio route
                when (callAudioState.route) {
                    CallAudioState.ROUTE_BLUETOOTH -> {
                        // Only trust Bluetooth route if SCO is actually active
                        if (isBluetoothScoOn) {
                            audioRoute = "bluetooth"
                            isBluetoothActive = true
                            isBluetoothConnected = true
                            Log.d(TAG, "detectAudioState: [CHECK 4] ROUTE_BLUETOOTH with SCO active -> bluetooth")
                        } else {
                            // TelecomManager says Bluetooth but SCO is not active - stale state on MIUI
                            Log.d(TAG, "detectAudioState: [CHECK 4] ROUTE_BLUETOOTH but SCO NOT active, forcing earpiece")
                            audioRoute = "earpiece"
                            isBluetoothActive = false
                            isBluetoothConnected = false
                        }
                    }
                    CallAudioState.ROUTE_SPEAKER -> {
                        audioRoute = "speaker"
                        isSpeakerActive = true
                        isBluetoothActive = false
                    }
                    CallAudioState.ROUTE_WIRED_HEADSET -> {
                        audioRoute = "wired_headset"
                        isBluetoothActive = false
                    }
                    CallAudioState.ROUTE_EARPIECE -> {
                        audioRoute = "earpiece"
                        isBluetoothActive = false
                    }
                }
            }
        }
        
        // FINAL CONSISTENCY CHECK: Ensure isBluetoothActive matches audioRoute
        if (audioRoute != "bluetooth") {
            isBluetoothActive = false
            // NOTE: Do NOT reset isBluetoothConnected here!
            // isBluetoothConnected means "BT device is available", not "audio is on BT"
            // User might have switched to speaker but BT is still connected
        }
        if (audioRoute != "speaker") {
            isSpeakerActive = false
        }
        
        // Check if Bluetooth is available (device connected) even if not currently active
        // This is needed for showing the Bluetooth option in the audio popup
        if (!isBluetoothConnected) {
            isBluetoothConnected = checkBluetoothDeviceAvailable()
        }
        
        // Update stored state
        isBluetoothOn = isBluetoothActive
        isSpeakerOn = isSpeakerActive
        
        Log.d(TAG, "=== detectAudioState END === route=$audioRoute, btConnected=$isBluetoothConnected, btActive=$isBluetoothActive, spkActive=$isSpeakerActive")
        return AudioState(audioRoute, isBluetoothConnected, isBluetoothActive, isSpeakerActive)
    }
    
    /**
     * Check if a Bluetooth audio device is connected and available for voice calls.
     * This is separate from whether audio is currently routed to Bluetooth.
     * 
     * IMPORTANT: Must be strict to avoid showing Bluetooth option when no BT is connected.
     */
    private fun checkBluetoothDeviceAvailable(): Boolean {
        val audioManager = context?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        
        // First check: Use getDevices() which shows ALL connected audio devices (not just active ones)
        // This works on Android 6.0+ (API 23+) and doesn't require BLUETOOTH permission
        var hasBluetoothDevice = false
        try {
            val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            hasBluetoothDevice = outputDevices.any { device ->
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && (
                    device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                )) ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && 
                    device.type == AudioDeviceInfo.TYPE_HEARING_AID)
            }
            Log.d(TAG, "checkBluetoothDeviceAvailable: getDevices check - found ${outputDevices.size} devices, hasBluetoothDevice=$hasBluetoothDevice")
            
            if (hasBluetoothDevice) {
                return true
            }
        } catch (e: Exception) {
            Log.e(TAG, "checkBluetoothDeviceAvailable: Error checking output devices", e)
        }
        
        // Second check for Android 12+: availableCommunicationDevices (more reliable for call audio)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val availableDevices = audioManager.availableCommunicationDevices
                val hasCommDevice = availableDevices.any { device ->
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    device.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                    device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                }
                Log.d(TAG, "checkBluetoothDeviceAvailable: Android 12+ availableCommunicationDevices - hasCommDevice=$hasCommDevice")
                if (hasCommDevice) {
                    return true
                }
            } catch (e: Exception) {
                Log.e(TAG, "checkBluetoothDeviceAvailable: Error checking available communication devices", e)
            }
        }
        
        // Third check: BluetoothAdapter profile connection state
        // This is especially useful for Android 12+ devices (like Vivo) where getDevices() 
        // may not show Bluetooth when audio is routed to speaker/earpiece
        try {
            val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
            if (bluetoothAdapter != null && bluetoothAdapter.isEnabled) {
                val headsetState = bluetoothAdapter.getProfileConnectionState(BluetoothProfile.HEADSET)
                val a2dpState = bluetoothAdapter.getProfileConnectionState(BluetoothProfile.A2DP)
                val btConnected = (headsetState == BluetoothProfile.STATE_CONNECTED) || 
                                  (a2dpState == BluetoothProfile.STATE_CONNECTED)
                Log.d(TAG, "checkBluetoothDeviceAvailable: BluetoothAdapter check - headsetState=$headsetState, a2dpState=$a2dpState, btConnected=$btConnected")
                if (btConnected) {
                    return true
                }
            }
        } catch (e: Exception) {
            // May fail due to BLUETOOTH permission on some devices - that's OK, we have other checks
            Log.d(TAG, "checkBluetoothDeviceAvailable: BluetoothAdapter check failed (permission issue), continuing with other checks")
        }
        
        // Fourth check: isBluetoothScoOn (audio is currently routed to Bluetooth)
        val scoOn = audioManager.isBluetoothScoOn
        Log.d(TAG, "checkBluetoothDeviceAvailable: scoOn=$scoOn, hasBluetoothDevice=$hasBluetoothDevice")
        
        return scoOn || hasBluetoothDevice
    }

    private fun register(
        messenger: BinaryMessenger,
        plugin: TwilioVoicePlugin,
        context: Context
    ) {
        Log.d(TAG, "register(BinaryMessenger")
        plugin.methodChannel = MethodChannel(messenger, "$kCHANNEL_NAME/messages")
        plugin.methodChannel!!.setMethodCallHandler(plugin)
        plugin.eventChannel = EventChannel(messenger, "$kCHANNEL_NAME/events")
        plugin.eventChannel!!.setStreamHandler(plugin)
        plugin.context = context
        plugin.broadcastReceiver = TVBroadcastReceiver(plugin)
        plugin.telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        plugin.storage = StorageImpl(context)
    }

    //region Flutter FlutterPlugin
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPluginBinding) {
        register(
            flutterPluginBinding.binaryMessenger,
            this,
            flutterPluginBinding.applicationContext
        )
        hasStarted = true
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        Log.d(TAG, "Detached from Flutter engine")
        context = null
        methodChannel!!.setMethodCallHandler(null)
        methodChannel = null
        eventChannel!!.setStreamHandler(null)
        eventChannel = null
    }
    //endregion

//    //region TwilioVoice RegistrationListeners
//    override fun onRegistered(accessToken: String, fcmToken: String) {
//        Log.d(TAG, "Successfully registered FCM $fcmToken")
//    }
//
//    override fun onUnregistered(accessToken: String?, fcmToken: String?) {
//        Log.d(TAG, "Successfully un-registered FCM $fcmToken")
//    }
//
//    override fun onError(registrationException: RegistrationException, accessToken: String, fcmToken: String) {
//        val message = String.format("(un)Registration Error: %d, %s", registrationException.errorCode, registrationException.message)
//        Log.e(TAG, message)
//    }
//    //endregion

    //region TwilioVoice Call.Listeners
    private fun callListener(): Call.Listener {
        return object : Call.Listener {
            /*
             * This callback is emitted once before the Call.Listener.onConnected() callback when
             * the callee is being alerted of a Call. The behavior of this callback is determined by
             * the answerOnBridge flag provided in the Dial verb of your TwiML application
             * associated with this client. If the answerOnBridge flag is false, which is the
             * default, the Call.Listener.onConnected() callback will be emitted immediately after
             * Call.Listener.onRinging(). If the answerOnBridge flag is true, this will cause the
             * call to emit the onConnected callback only after the call is answered.
             * See answerOnBridge for more details on how to use it with the Dial TwiML verb. If the
             * twiML response contains a Say verb, then the call will emit the
             * Call.Listener.onConnected callback immediately after Call.Listener.onRinging() is
             * raised, irrespective of the value of answerOnBridge being set to true or false
             */
            override fun onRinging(call: Call) {
                Log.d(TAG, "onRinging")
                // TODO - outgoing call check
                val list = arrayOf("Ringing", call.from ?: "", call.to ?: "", "Incoming")
                logEvents("", list)
            }

            override fun onConnectFailure(call: Call, error: CallException) {
                Log.d(TAG, "Connect failure")
                val message = String.format(
                    Locale.getDefault(),
                    "Call Error: %d, %s",
                    error.errorCode,
                    error.message
                )
                logEvent(message)
                logEvent("", "Call Ended")
                TVConnectionService.clearActiveConnections()

            }

            override fun onConnected(call: Call) {
                Log.d(TAG, "onConnected")
                // TODO - outgoing call check
                val list = arrayOf("Connected", call.from ?: "", call.to ?: "", "Incoming")
                logEvents("", list)
            }

            override fun onReconnecting(call: Call, callException: CallException) {
                Log.d(TAG, "onReconnecting")
            }

            override fun onReconnected(call: Call) {
                Log.d(TAG, "onReconnected")
            }

            override fun onDisconnected(call: Call, error: CallException?) {
                Log.d(TAG, "Disconnected")
                if (error != null) {
                    val message = String.format(
                        Locale.getDefault(),
                        "Call Error: %d, %s",
                        error.errorCode,
                        error.message
                    )
                    logEvent(message)
                }
                logEvent("", "Call Ended")
            }
        }
    }
    //endregion

    //region Flutter RequestPermissionsResultListener
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ): Boolean {
        Log.d(TAG, "onRequestPermissionsResult: $requestCode")

        if (permissions.isNotEmpty()) {
            permissionResultHandler[requestCode]?.let { handler ->
                val granted = grantResults[0] == PackageManager.PERMISSION_GRANTED
                handler(granted)
                permissionResultHandler.remove(requestCode)
            }
        }

        if (requestCode == REQUEST_CODE_MICROPHONE) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Microphone permission granted")
                requestPermissionForMicrophoneForeground(onPermissionResult = { granted ->
                    Log.d(TAG, "onRequestPermissionsResult: Microphone foreground permission granted: $granted");
                });
                logEventPermission("Microphone", true)
            } else {
                Log.d(TAG, "Microphone permission not granted")
                logEventPermission("Microphone", false)
            }
        } /*else if (requestCode == REQUEST_CODE_TELECOM) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Telecom permission granted")
                logEventPermission("Telecom", true)
            } else {
                Log.d(TAG, "Telecom permission not granted")
                logEventPermission("Telecom", false)
            }
        } */ else if (requestCode == REQUEST_CODE_READ_PHONE_NUMBERS) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Read Phone Numbers permission granted")
                logEventPermission("Read Phone Numbers", true)
            } else {
                Log.d(TAG, "Read Phone Numbers permission not granted")
                logEventPermission("Read Phone Numbers", false)
            }
        } else if (requestCode == REQUEST_CODE_READ_PHONE_STATE) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Read Phone State permission granted")
                logEventPermission("Read Phone State", true)
            } else {
                Log.d(TAG, "Read Phone State permission not granted")
                logEventPermission("Read Phone State", false)
            }
        } else if (requestCode == REQUEST_CODE_CALL_PHONE) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Call Phone permission granted")
                logEventPermission("Call Phone", true)
                requestPermissionForManagingCalls {
                    if(it) {
                        Log.d(TAG, "onRequestPermissionsResult: Manage Calls permission granted");
                    } else {
                        Log.d(TAG, "onRequestPermissionsResult: Manage Calls permission not granted");
                    }
                }
            } else {
                Log.d(TAG, "Call Phone permission not granted")
                logEventPermission("Call Phone State", false)
            }
        } else if (requestCode == REQUEST_CODE_MICROPHONE_FOREGROUND) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Microphone foreground permission granted")
                logEventPermission("Microphone", true)
            } else {
                Log.d(TAG, "Microphone foreground permission not granted")
                logEventPermission("Microphone", false)
            }
        } else if (requestCode == REQUEST_CODE_MANAGE_CALLS) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Manage Calls permission granted")
                logEventPermission("Manage Calls", true)
            } else {
                Log.d(TAG, "Manage Calls permission not granted")
                logEventPermission("Manage Calls", false)
            }
        } else if (requestCode == REQUEST_CODE_SCHEDULE_EXACT_ALARM) {
            if (permissions.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Schedule Exact Alarm (Show on Lock Screen) permission granted")
                logEventPermission("Show on Lock Screen", true)
            } else {
                Log.d(TAG, "Schedule Exact Alarm (Show on Lock Screen) permission not granted")
                logEventPermission("Show on Lock Screen", false)
            }
        }
        return true
    }
    //endregion

    //region Flutter EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventSink?) {
        Log.i(TAG, "Setting event sink")
        this.eventSink = events
        
        // Flush any pending events that arrived before Flutter was ready
        if (events != null && pendingEvents.isNotEmpty()) {
            Log.d(TAG, "Flushing ${pendingEvents.size} pending events to Flutter")
            for (event in pendingEvents) {
                Log.d(TAG, "Sending queued event: $event")
                events.success(event)
            }
            pendingEvents.clear()
        }
    }

    override fun onCancel(arguments: Any?) {
        Log.i(TAG, "Removing event sink")
        eventSink = null
    }
    //endregion

    //region Flutter MethodCallHandler
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Allow null or Map arguments
        if (call.arguments != null && call.arguments !is Map<*, *>) {
            result.error(
                FlutterErrorCodes.MALFORMED_ARGUMENTS,
                "Arguments must be a Map<String, Object>",
                null
            )
            return
        }
        val method: TVMethodChannels?
        try {
            method = TVMethodChannels.fromValue(call.method)
        } catch (e: NullPointerException) {
            e.printStackTrace()
            result.notImplemented()
            return
        } catch (e: IllegalArgumentException) {
            e.printStackTrace()
            result.notImplemented()
            return
        }
        when (method) {
            TVMethodChannels.TOKENS -> {
                val deviceToken = call.argument<String>("deviceToken") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'deviceToken' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                val accessToken = call.argument<String>("accessToken") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'accessToken' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                Log.d(TAG, "Setting up token")
                this.accessToken = accessToken
                this.fcmToken = deviceToken;

                Log.d(TAG, "Registering for call events")
                registerForCallInvites(accessToken, deviceToken)
                result.success(true)

                // TODO - read phone account permissions, else show rationale? and request on accept via requestPermissions Plugin registry response
//                if (checkReadPhoneStatePermission()) {
//                    this.registerPhoneAccount();
//                } else {
//                    this.requestPermissionForPhoneState()
//                }
//                requestPermissionOrShowRationale(
//                    "Read Phone Numbers",
//                    "Read phone numbers ability.",
//                    Manifest.permission.READ_PHONE_NUMBERS,
//                    REQUEST_CODE_READ_PHONE_NUMBERS
//                )
////            requestPermissionOrShowRationale(
////                "Default Caller App",
////                "Use phone telecom app to manage calls.",
////                Manifest.permission.BIND_TELECOM_CONNECTION_SERVICE,
////                TELECOM_PERMISSION_REQUEST_CODE
////            )
            }

            TVMethodChannels.SEND_DIGITS -> {
                val digits = call.argument<String>("digits") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'digits' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                val value = sendDigits(digits);
                result.success(value)
            }

            TVMethodChannels.HANGUP -> {
                Log.d(TAG, "Hanging up")
                hangup()
                result.success(true)
            }

            TVMethodChannels.TOGGLE_SPEAKER -> {
                val speakerIsOn = call.argument<Boolean>("speakerIsOn") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'speakerIsOn' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                if (isOnCall()) {
                    context?.let { ctx ->
                        toggleSpeaker(ctx, speakerIsOn)
                        result.success(true)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot toggle speaker")
                        result.success(false)
                    }
                } else {
                    Log.d(TAG, "onMethodCall: Not on call, cannot toggle speaker")
                    result.success(false)
                }
            }

            TVMethodChannels.IS_ON_SPEAKER -> {
                Log.d(TAG, "isSpeakerOn invoked")
                var actualSpeakerOn = isSpeakerOn
                
                // Try to get the actual route from active connection
                val activeCall = TVConnectionService.activeConnections.values.firstOrNull()
                Log.d(TAG, "isSpeakerOn: activeConnections count=${TVConnectionService.activeConnections.size}")
                if (activeCall != null) {
                    val audioState = activeCall.callAudioState
                    if (audioState != null) {
                        actualSpeakerOn = audioState.route == CallAudioState.ROUTE_SPEAKER
                        Log.d(TAG, "isSpeakerOn: from CallAudioState route=${CallAudioState.audioRouteToString(audioState.route)}, isSpeaker=$actualSpeakerOn")
                    } else {
                        Log.d(TAG, "isSpeakerOn: callAudioState is null")
                    }
                } else {
                    Log.d(TAG, "isSpeakerOn: no active connection found")
                }
                
                Log.d(TAG, "isSpeakerOn: stored=$isSpeakerOn, returning=$actualSpeakerOn")
                result.success(actualSpeakerOn)
            }

            TVMethodChannels.TOGGLE_BLUETOOTH -> {
                val bluetoothOn = call.argument<Boolean>("bluetoothOn") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'bluetoothOn' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                if (isOnCall()) {
                    context?.let { ctx ->
                        toggleBluetooth(ctx, bluetoothOn)
                        result.success(true)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot toggle bluetooth")
                        result.success(false)
                    }
                } else {
                    Log.d(TAG, "onMethodCall: Not on call, cannot toggle bluetooth")
                    result.success(false)
                }
            }

            TVMethodChannels.GetActiveCallOnResumeFromTerminatedState -> {
                //is on call
                val hasActiveCalls = isOnCall()
                if(hasActiveCalls){
                    val activeCalls = TVConnectionService.Companion.activeConnections
                    val currentCall = activeCalls.values.firstOrNull()
                    val isAnsweredCall = currentCall?.twilioCall?.state == Call.State.CONNECTED
                    if(isAnsweredCall){
                        val from = extractUserNumber(currentCall?.twilioCall?.from ?: "")
                        val to = currentCall?.twilioCall?.to ?: ""
                        val callDirection = currentCall?.callDirection ?: CallDirection.INCOMING
                        logEvents("", arrayOf("Connected", from, to, callDirection.label ))
                    }
                }
                result.success(true)

            }

            TVMethodChannels.IS_BLUETOOTH_ON -> {
                Log.d(TAG, "isBluetoothOn invoked")
                // Use unified audio state detection
                val audioState = detectAudioState()
                Log.d(TAG, "isBluetoothOn: returning=${audioState.isBluetoothActive}")
                result.success(audioState.isBluetoothActive)
            }

            TVMethodChannels.GET_AUDIO_ROUTE -> {
                Log.d(TAG, "getAudioRoute invoked")
                val previousBluetoothState = isBluetoothOn
                val previousSpeakerState = isSpeakerOn
                
                // Use unified audio state detection
                val audioState = detectAudioState()
                
                // Only emit events if there's an active call (to avoid false events during initialization)
                val hasActiveCall = TVConnectionService.activeConnections.isNotEmpty()
                if (hasActiveCall) {
                    // Emit events if state changed (for UI sync on all devices)
                    if (previousBluetoothState != audioState.isBluetoothActive) {
                        Log.d(TAG, "getAudioRoute: Bluetooth state changed from $previousBluetoothState to ${audioState.isBluetoothActive}, emitting event")
                        if (audioState.isBluetoothActive) {
                            logEvent("", "Bluetooth On")
                        } else {
                            logEvent("", "Bluetooth Off")
                        }
                    }
                    if (previousSpeakerState != audioState.isSpeakerActive) {
                        Log.d(TAG, "getAudioRoute: Speaker state changed from $previousSpeakerState to ${audioState.isSpeakerActive}, emitting event")
                        if (audioState.isSpeakerActive) {
                            logEvent("", "Speaker On")
                        } else if (!audioState.isBluetoothActive) {
                            logEvent("", "Speaker Off")
                        }
                    }
                } else {
                    Log.d(TAG, "getAudioRoute: No active call, skipping event emission")
                }
                
                Log.d(TAG, "getAudioRoute: returning=${audioState.audioRoute}")
                result.success(audioState.audioRoute)
            }

            TVMethodChannels.IS_BLUETOOTH_AVAILABLE -> {
                Log.d(TAG, "isBluetoothAvailable invoked")
                // Use unified audio state detection
                val audioState = detectAudioState()
                Log.d(TAG, "isBluetoothAvailable: returning=${audioState.isBluetoothConnected}")
                result.success(audioState.isBluetoothConnected)
            }

            TVMethodChannels.TOGGLE_MUTE -> {
                val muted = call.argument<Boolean>("muted") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'bluetoothOn' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                if (isOnCall()) {
                    context?.let { ctx ->
                        toggleMute(ctx, muted)
                        result.success(true)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot toggle mute")
                        result.success(false)
                    }
                } else {
                    Log.d(TAG, "onMethodCall: Not on call, cannot toggle mute")
                    result.success(false)
                }
            }

            TVMethodChannels.IS_MUTED -> {
                Log.d(TAG, "isMuted invoked")
                result.success(isMuted)
            }

            TVMethodChannels.CALL_SID -> {
                result.success(callSid)
            }

            TVMethodChannels.IS_ON_CALL -> {
                result.success(isOnCall())
                return

                // Disabled for now until a better solution for TelecomManager.isInCall() is found - this returns true for any ConnectionService including Cellular calls.
//                context?.let { ctx ->
//                    telecomManager?.let { tm ->
//                        result.success(isOnCall(ctx, tm))
//                    } ?: run {
//                        Log.w(TAG, "TelecomManager is null, cannot check if on call")
//                        result.success(false)
//                    }
//                } ?: run {
//                    Log.e(TAG, "Context is null, cannot check if on call")
//                    result.success(false)
//                }
            }

            TVMethodChannels.HOLD_CALL -> {
                val shouldHold = call.argument<Boolean>("shouldHold") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'shouldHold' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                Log.d(TAG, "Hold call invoked")
                if (isOnCall()) {
                    context?.let { ctx ->
                        toggleHold(ctx, shouldHold)
                        result.success(true)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot toggle hold call")
                        result.success(false)
                    }
                } else {
                    Log.d(TAG, "onMethodCall: Not on call, cannot toggle hold call")
                    result.success(false)
                }
            }

            TVMethodChannels.IS_HOLDING -> {
                Log.d(TAG, "isHolding call invoked")
                result.success(isHolding)
            }

            TVMethodChannels.ANSWER -> {
                Log.d(TAG, "Answering call")
                answer()
                result.success(true)
            }

            TVMethodChannels.UNREGISTER -> {
                val accessToken = call.argument<String?>("accessToken") ?: this.accessToken ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'accessToken' provided or invalid type, nor any previously set",
                        null
                    )
                    return@onMethodCall
                }

                unregisterForCallInvites(accessToken)
                result.success(true)
            }

            TVMethodChannels.MAKE_CALL -> {
                val args = call.arguments as? Map<*, *> ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "Arguments should be a Map<*, *>",
                        null
                    )
                    return@onMethodCall
                }

                Log.d(TAG, "Making new call")
                logEvent("Making new call")
                val params = HashMap<String, String>()
                for ((key, value) in args) {
                    when (key) {
                        Constants.PARAM_TO, Constants.PARAM_FROM -> {}
                        else -> {
                            params[key.toString()] = value.toString()
                        }
                    }
                }
//                callOutgoing = true
                val from = call.argument<String>(Constants.PARAM_FROM) ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No '${Constants.PARAM_FROM}' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                val to = call.argument<String>(Constants.PARAM_TO) ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No '${Constants.PARAM_TO}' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                val callerName = call.argument<String>(Constants.CALLER_NAME) ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No '${Constants.CALLER_NAME}' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }


                Log.d(TAG, "calling $from -> $to")

                accessToken?.let { token ->
                    context?.let { ctx ->
                        val success = placeCall(ctx, token, from, to, params,callerName )
                        result.success(success)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot place call")
                        result.success(false)
                    }
                } ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No accessToken set, are you registered?",
                        null
                    )
                }
            }

            TVMethodChannels.CONNECT -> {
                val args = call.arguments as? Map<*, *> ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "Arguments should be a Map<*, *>",
                        null
                    )
                    return@onMethodCall
                }

                Log.d(TAG, "Making new call via connect")
                logEvent("Making new call via connect")
                val params = HashMap<String, String>()
                for ((key, value) in args) {
                    when (key) {
                        Constants.PARAM_TO, Constants.PARAM_FROM -> {}
                        else -> {
                            params[key.toString()] = value.toString()
                        }
                    }
                }
//                callOutgoing = true
                val from = call.argument<String>(Constants.PARAM_FROM) ?: run {
                    logEvent("No 'from' provided or invalid type, ignoring.")
                    ""
                }

                val to = call.argument<String>(Constants.PARAM_TO) ?: run {
                    logEvent("No 'to' provided or invalid type, ignoring.")
                    ""
                }
                val paramsStringify = JSONObject(args).toString()
                Log.d(TAG, "calling with parameters: from: '$from' -> to: '$to', params: $paramsStringify")

                accessToken?.let { token ->
                    context?.let { ctx ->
                        val success = placeCall(ctx, token, from, to, params,null, connect = true)
                        result.success(success)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot place call")
                        result.success(false)
                    }
                } ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No accessToken set, are you registered?",
                        null
                    )
                }
            }

            TVMethodChannels.REGISTER_CLIENT -> {

                val clientId = call.argument<String>("id") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'id' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }
                val clientName = call.argument<String>("name") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'name' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                storage?.let {
                    logEvent("Registering client $clientId:$clientName")
                    result.success(it.addRegisteredClient(clientId, clientName))
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot register client. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.UNREGISTER_CLIENT -> {
                val clientId = call.argument<String>("id") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'id' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                storage?.let {
                    logEvent("Unregistering $clientId")
                    result.success(it.removeRegisteredClient(clientId))
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot unregister client. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.DEFAULT_CALLER -> {
                val defaultCaller = call.argument<String>("defaultCaller") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'defaultCaller' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                storage?.let {
                    logEvent("defaultCaller is $defaultCaller")
                    it.defaultCaller = defaultCaller
                    result.success(true)
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot set default caller. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.HAS_REGISTERED_PHONE_ACCOUNT -> {
                logEvent("hasRegisteredPhoneAccount")
                context?.let { ctx ->
                    telecomManager?.let { tm ->
                        if (!tm.canReadPhoneNumbers(ctx)) {
                            Log.e(
                                TAG,
                                "No read phone state permission, call `requestReadPhoneStatePermission()` first"
                            )
                            result.success(false)
                            return;
                        }

                        // Get phone account handle
                        val phoneAccountHandle = tm.getPhoneAccountHandle(ctx)

                        // Get PhoneAccount, if null it's not registered
                        val phoneAccount = tm.getPhoneAccount(phoneAccountHandle)
                        result.success(phoneAccount != null)
                    } ?: run {
                        Log.e(TAG, "Context is null, cannot check if registered phone account")
                        result.success(false)
                    }
                } ?: run {
                    Log.e(TAG, "Context is null, cannot check if registered phone account")
                    result.success(false)
                }
            }

            TVMethodChannels.REGISTER_PHONE_ACCOUNT -> {
                logEvent("registerPhoneAccount")
                result.success(registerPhoneAccount())
            }

            TVMethodChannels.IS_PHONE_ACCOUNT_ENABLED -> {
                logEvent("isPhoneAccountEnabled")
                result.success(checkIsPhoneAccountEnabled())
            }

            TVMethodChannels.OPEN_PHONE_ACCOUNT_SETTINGS -> {
                logEvent("changePhoneAccount")
                activity?.let { a ->
                    telecomManager?.let { tm ->
                        tm.openPhoneAccountSettings(a)
                        result.success(true)
                    } ?: run {
                        Log.e(TAG, "TelecomManager is null, cannot change phone account")
                        result.success(false)
                    }
                } ?: run {
                    Log.e(TAG, "Activity is null, cannot change phone account")
                    result.success(false)
                }
            }

            TVMethodChannels.HAS_MIC_PERMISSION -> {
                result.success(checkMicrophonePermission())
            }

            TVMethodChannels.REQUEST_MIC_PERMISSION -> {
                logEvent("requesting mic permission")
                if (!checkMicrophonePermission()) {
                    requestPermissionForMicrophone() { granted ->
                        result.success(granted)
                    }
                } else {
                    result.success(true)
                }
            }

            TVMethodChannels.HAS_READ_PHONE_STATE_PERMISSION -> {
                // No longer required - always return true
                result.success(true)
            }

            TVMethodChannels.REQUEST_READ_PHONE_STATE_PERMISSION -> {
                // No longer required - skip and return success
                logEvent("requestingReadPhoneStatePermission - skipped, not required")
                result.success(true)
            }

            TVMethodChannels.HAS_CALL_PHONE_PERMISSION -> {
                result.success(checkCallPhonePermission())
            }

            TVMethodChannels.REQUEST_CALL_PHONE_PERMISSION -> {
                logEvent("requestingCallPhonePermission")
                if (!checkCallPhonePermission()) {
                    requestPermissionForCallPhone() { granted ->
                        result.success(granted)
                    }
                } else {
                    result.success(true)
                }
            }

            TVMethodChannels.HAS_READ_PHONE_NUMBERS_PERMISSION -> {
                result.success(checkReadPhoneNumbersPermission())
            }

            TVMethodChannels.REQUEST_READ_PHONE_NUMBERS_PERMISSION -> {
                logEvent("requestingReadPhoneNumbersPermission")
                if (!checkReadPhoneNumbersPermission()) {
                    requestPermissionForReadPhoneNumbers() { granted ->
                        result.success(granted)
                    }
                } else {
                    result.success(true)
                }
            }

            TVMethodChannels.HAS_MANAGE_OWN_CALLS_PERMISSION -> {
                result.success(checkManageOwnCallsPermission())
            }

            TVMethodChannels.REQUEST_MANAGE_OWN_CALLS_PERMISSION -> {
                logEvent("requestingManageOwnCallsPermission")
                if (!checkManageOwnCallsPermission()) {
                    requestPermissionForManagingCalls() { granted ->
                        result.success(granted)
                    }
                } else {
                    result.success(true)
                }
            }

            TVMethodChannels.HAS_BLUETOOTH_PERMISSION -> {
                // Deprecated in favour of native call screen handling these permissions
                result.success(false)
            }

            TVMethodChannels.REQUEST_BLUETOOTH_PERMISSION -> {
                // Deprecated in favour of native call screen handling these permissions
                result.success(false)
            }

            TVMethodChannels.BACKGROUND_CALL_UI -> {
                // Deprecated in favour of ConnectionService implementation
                result.success(true)
            }

            TVMethodChannels.SHOW_NOTIFICATIONS -> {
                val shouldShowNotifications = call.argument<Boolean>("show") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'showNotifications' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                storage?.let {
                    it.showNotifications = shouldShowNotifications
                    result.success(true)
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot set showNotifications. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.REQUIRES_BACKGROUND_PERMISSIONS -> {
                // deprecated
                result.success(true)
            }

            TVMethodChannels.REQUEST_BACKGROUND_PERMISSIONS -> {
                // deprecated
                result.success(true)
            }

            TVMethodChannels.UPDATE_CALLKIT_ICON -> {
                // we don't use CallKit on Android... yet
                result.success(true)
            }

            TVMethodChannels.REJECT_CALL_ON_NO_PERMISSIONS -> {
                val shouldRejectOnNoPermissions = call.argument<Boolean>("shouldReject") ?: run {
                    result.error(
                        FlutterErrorCodes.MALFORMED_ARGUMENTS,
                        "No 'shouldReject' provided or invalid type",
                        null
                    )
                    return@onMethodCall
                }

                storage?.let {
                    Log.d(TAG, "onMethodCall: shouldRejectOnNoPermissions is $shouldRejectOnNoPermissions")
                    it.rejectOnNoPermissions = shouldRejectOnNoPermissions
                    result.success(true)
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot set reject on no permissions. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.IS_REJECTING_CALL_ON_NO_PERMISSIONS -> {
                storage?.let {
                    result.success(it.rejectOnNoPermissions)
                } ?: run {
                    Log.e(
                        TAG,
                        "Storage is null, cannot set reject on no permissions. Has Storage been initialized?"
                    )
                    result.success(false)
                }
            }

            TVMethodChannels.IS_BATTERY_OPTIMIZED -> {
                context?.let { ctx ->
                    val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val isIgnoringBatteryOptimizations = powerManager.isIgnoringBatteryOptimizations(ctx.packageName)
                    Log.d(TAG, "isBatteryOptimized: ${!isIgnoringBatteryOptimizations}")
                    result.success(!isIgnoringBatteryOptimizations)
                } ?: run {
                    Log.e(TAG, "Context is null, cannot check battery optimization")
                    result.success(true)
                }
            }

            TVMethodChannels.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS -> {
                context?.let { ctx ->
                    val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                    if (!powerManager.isIgnoringBatteryOptimizations(ctx.packageName)) {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:${ctx.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        try {
                            ctx.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to request ignore battery optimizations", e)
                            result.success(false)
                        }
                    } else {
                        Log.d(TAG, "Already ignoring battery optimizations")
                        result.success(true)
                    }
                } ?: run {
                    Log.e(TAG, "Context is null, cannot request battery optimization")
                    result.success(false)
                }
            }

            TVMethodChannels.OPEN_BATTERY_SETTINGS -> {
                context?.let { ctx ->
                    try {
                        // Try Samsung-specific settings first
                        val samsungIntent = Intent().apply {
                            component = android.content.ComponentName(
                                "com.samsung.android.lool",
                                "com.samsung.android.sm.battery.ui.BatteryActivity"
                            )
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        
                        if (samsungIntent.resolveActivity(ctx.packageManager) != null) {
                            ctx.startActivity(samsungIntent)
                            result.success(true)
                            return@onMethodCall
                        }
                        
                        // Try general app info settings
                        val appInfoIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:${ctx.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        ctx.startActivity(appInfoIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to open battery settings", e)
                        result.success(false)
                    }
                } ?: run {
                    Log.e(TAG, "Context is null, cannot open battery settings")
                    result.success(false)
                }
            }

            TVMethodChannels.HAS_OVERLAY_PERMISSION -> {
                context?.let { ctx ->
                    val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(ctx)
                    } else {
                        true // Permission not needed on older versions
                    }
                    Log.d(TAG, "hasOverlayPermission: $hasPermission")
                    result.success(hasPermission)
                } ?: run {
                    result.success(false)
                }
            }

            TVMethodChannels.REQUEST_OVERLAY_PERMISSION -> {
                context?.let { ctx ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(ctx)) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                                data = Uri.parse("package:${ctx.packageName}")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            ctx.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to request overlay permission", e)
                            result.success(false)
                        }
                    } else {
                        Log.d(TAG, "Already has overlay permission or not needed")
                        result.success(true)
                    }
                } ?: run {
                    result.success(false)
                }
            }

            TVMethodChannels.REQUEST_SHOW_ON_LOCK_SCREEN_PERMISSION -> {
                // For Android 12+, this permission is not needed
                // For Android 11 and below, we need to enable "Display on Lock Screen"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Android 12+ doesn't need this permission
                    Log.d(TAG, "Show on lock screen not needed for Android 12+")
                    result.success(true)
                } else {
                    // Android 11 and below - open MIUI or standard app settings
                    context?.let { ctx ->
                        try {
                            val isMiui = isMiuiDevice()
                            Log.d(TAG, "requestShowOnLockScreenPermission: isMiui=$isMiui, SDK=${Build.VERSION.SDK_INT}")
                            
                            var settingsOpened = false
                            
                            if (isMiui) {
                                // Try to open MIUI permission manager for lock screen display
                                try {
                                    val miuiIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                                        setClassName("com.miui.securitycenter", 
                                            "com.miui.permcenter.permissions.PermissionsEditorActivity")
                                        putExtra("extra_pkgname", ctx.packageName)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    ctx.startActivity(miuiIntent)
                                    settingsOpened = true
                                } catch (e: Exception) {
                                    Log.d(TAG, "MIUI permission editor not found, trying alternative")
                                }
                                
                                // Alternative: Open MIUI app info
                                if (!settingsOpened) {
                                    try {
                                        val miuiAltIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                                            setClassName("com.miui.securitycenter",
                                                "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
                                            putExtra("extra_pkgname", ctx.packageName)
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                        ctx.startActivity(miuiAltIntent)
                                        settingsOpened = true
                                    } catch (e: Exception) {
                                        Log.d(TAG, "MIUI alternative permission editor not found")
                                    }
                                }
                            }
                            
                            // Fallback: Open app notification settings
                            if (!settingsOpened) {
                                try {
                                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                        putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    ctx.startActivity(intent)
                                    settingsOpened = true
                                } catch (e: Exception) {
                                    // Final fallback to app settings
                                    val settingsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                        data = Uri.parse("package:${ctx.packageName}")
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    ctx.startActivity(settingsIntent)
                                    settingsOpened = true
                                }
                            }
                            
                            // Mark that user has visited settings (assume they granted permission)
                            if (settingsOpened) {
                                markShowOnLockScreenSettingsVisited(ctx)
                                Log.d(TAG, "requestShowOnLockScreenPermission: Settings opened, marked as visited")
                            }
                            
                            result.success(settingsOpened)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to request show on lock screen permission", e)
                            result.success(false)
                        }
                    } ?: run {
                        result.success(false)
                    }
                }
            }

            TVMethodChannels.HAS_SHOW_ON_LOCK_SCREEN_PERMISSION -> {
                // For Android 12+, always return true (not needed)
                // For Android 11 and below, check SCHEDULE_EXACT_ALARM permission
                context?.let { ctx ->
                    val isGranted = checkShowOnLockScreenPermission(ctx)
                    Log.d(TAG, "HAS_SHOW_ON_LOCK_SCREEN_PERMISSION: isGranted=$isGranted, SDK=${Build.VERSION.SDK_INT}")
                    result.success(isGranted)
                } ?: run {
                    Log.e(TAG, "Context is null, cannot check show on lock screen permission")
                    result.success(false)
                }
            }

            TVMethodChannels.OPEN_MIUI_PERMISSION_SETTINGS -> {
                context?.let { ctx ->
                    try {
                        // Check if this is a MIUI device
                        val isMiui = isMiuiDevice()
                        Log.d(TAG, "openMiuiPermissionSettings: isMiui=$isMiui")
                        
                        if (isMiui) {
                            // Try to open MIUI permission manager
                            try {
                                val miuiIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                                    setClassName("com.miui.securitycenter", 
                                        "com.miui.permcenter.permissions.PermissionsEditorActivity")
                                    putExtra("extra_pkgname", ctx.packageName)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                ctx.startActivity(miuiIntent)
                                result.success(true)
                                return@onMethodCall
                            } catch (e: Exception) {
                                Log.d(TAG, "MIUI permission editor not found, trying alternative")
                            }
                            
                            // Alternative: Open MIUI app info
                            try {
                                val miuiAltIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                                    setClassName("com.miui.securitycenter",
                                        "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
                                    putExtra("extra_pkgname", ctx.packageName)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                ctx.startActivity(miuiAltIntent)
                                result.success(true)
                                return@onMethodCall
                            } catch (e: Exception) {
                                Log.d(TAG, "MIUI alternative permission editor not found")
                            }
                        }
                        
                        // Fallback: Open general app settings
                        val appInfoIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:${ctx.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        ctx.startActivity(appInfoIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to open MIUI permission settings", e)
                        result.success(false)
                    }
                } ?: run {
                    result.success(false)
                }
            }

            else -> {
                result.notImplemented()
            }

            // TODO check creating contacts?
        }
    }
    //endregion


    private fun sendDigits(digits: String): Boolean {
        // Send to active call via Intent
        context?.let { ctx ->
            // Use callSid if available, otherwise get from active connections
            val handle = callSid ?: TVConnectionService.getActiveCallHandle()
            Log.d(TAG, "sendDigits: digits=$digits, callSid=$callSid, handle=$handle")
            
            Intent(ctx, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_SEND_DIGITS
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
                // Corrected line: Use EXTRA_DIGITS as the key for the digits extra
                putExtra(TVConnectionService.EXTRA_DIGITS, digits)
                ctx.startService(this)
            }
            return true
        } ?: run {
            Log.e(TAG, "Context is null. Cannot sendDigits.")
            return false
        }
    }


    private fun answer() {
        // Send to active call via Intent
        context?.let { ctx ->
            Intent(ctx, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                ctx.startService(this)
            }
        } ?: run {
            Log.e(TAG, "Context is null. Cannot answer call.")
        }
    }

    private fun hangup() {
        context?.let { ctx ->
            // Use callSid if it's still valid (exists in active connections), otherwise get from active connections
            val handle = if (callSid != null && TVConnectionService.getConnection(callSid!!) != null) {
                callSid
            } else {
                TVConnectionService.getActiveCallHandle()
            }
            Log.d(TAG, "hangup: callSid=$callSid, resolvedHandle=$handle, activeConnections=${TVConnectionService.getActiveCallHandle()}")
            
            Intent(ctx, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
                ctx.startService(this)
            }
        } ?: run {
            Log.e(TAG, "Context is null. Cannot hangup.")
        }
    }

    private fun isOnCall(/*ctx: Context, tm: TelecomManager*/): Boolean {
//        if (!checkReadPhoneStatePermission()) {
//            Log.e(
//                TAG,
//                "No read phone state permission, call `requestReadPhoneStatePermission()` first"
//            )
//            return false
//        }
//        if (callSid == null) {
//            Log.d(TAG, "isOnCall: CallSid is null.")
//        }
//        return tm.isOnCall(ctx)
        return TVConnectionService.hasActiveCalls()
    }

    private fun toggleSpeaker(ctx: Context, speakerIsOn: Boolean) {
        // Use callSid if available, otherwise get from active connections
        val handle = callSid ?: TVConnectionService.getActiveCallHandle()
        Log.d(TAG, "toggleSpeaker: speakerIsOn=$speakerIsOn, callSid=$callSid, handle=$handle")
        
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_SPEAKER
            putExtra(TVConnectionService.EXTRA_SPEAKER_STATE, speakerIsOn)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
            ctx.startService(this)
        }
    }

    private fun toggleMute(ctx: Context, mute: Boolean) {
        // Use callSid if available, otherwise get from active connections
        val handle = callSid ?: TVConnectionService.getActiveCallHandle()
        Log.d(TAG, "toggleMute: mute=$mute, callSid=$callSid, handle=$handle")
        
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_MUTE
            putExtra(TVConnectionService.EXTRA_MUTE_STATE, mute)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
            ctx.startService(this)
        }
    }

    private fun toggleBluetooth(ctx: Context, bluetoothOn: Boolean) {
        // Use callSid if available, otherwise get from active connections
        val handle = callSid ?: TVConnectionService.getActiveCallHandle()
        Log.d(TAG, "toggleBluetooth: bluetoothOn=$bluetoothOn, callSid=$callSid, handle=$handle")
        
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_BLUETOOTH
            putExtra(TVConnectionService.EXTRA_BLUETOOTH_STATE, bluetoothOn)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
            ctx.startService(this)
        }
    }

    private fun toggleHold(ctx: Context, shouldHold: Boolean) {
        // Use callSid if available, otherwise get from active connections
        val handle = callSid ?: TVConnectionService.getActiveCallHandle()
        Log.d(TAG, "toggleHold: shouldHold=$shouldHold, callSid=$callSid, handle=$handle")
        
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_HOLD
            putExtra(TVConnectionService.EXTRA_HOLD_STATE, shouldHold)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, handle)
            ctx.startService(this)
        }
    }

    /**
     * Attempts to place a call using the [TVConnectionService].
     * Requires permissions:
     * - [Manifest.permission.RECORD_AUDIO]: for placing the call and capturing microphone audio.
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    private fun placeCall(
        ctx: Context,
        accessToken: String,
        from: String?,
        to: String?,
        params: Map<String, String>,
        callerName: String?,
        connect: Boolean = false
    ): Boolean {
        assert(accessToken.isNotEmpty()) { "Twilio Access Token cannot be empty" }
        assert(!connect && (to == null || to.isNotEmpty())) { "To cannot be empty" }
        assert(!connect && (from == null || from.isNotEmpty())) { "From cannot be empty" }

        // Only microphone permission is required for direct Twilio Voice calls
        if (!checkMicrophonePermission()) {
            Log.e(TAG, "No microphone permission, call `requestMicrophonePermission()` first")
            return false
        }

        // Reset audio states for new outgoing call
        isSpeakerOn = false
        isBluetoothOn = false
        isMuted = false
        Log.d(TAG, "placeCall: Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")

        val callParams = HashMap<String, String>(params)
        if (params[Constants.PARAM_TO] == null) {
            Log.w(TAG, "Call parameters must include '${Constants.PARAM_TO}', removing...")
            callParams.remove(Constants.PARAM_TO)
        }
        if (params[Constants.PARAM_FROM] == null) {
            Log.w(TAG, "Call parameters must include '${Constants.PARAM_FROM}', removing...")
            callParams.remove(Constants.PARAM_FROM)
        }

        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_PLACE_OUTGOING_CALL
            putExtra(TVConnectionService.EXTRA_TOKEN, accessToken)
            if(connect) {
                putExtra(TVConnectionService.EXTRA_CONNECT_RAW, true)
            }
            putExtra(TVConnectionService.EXTRA_TO, to)
            putExtra(TVConnectionService.EXTRA_FROM, from)
            putExtra(TVConnectionService.EXTRA_CALLER_NAME, callerName)
            putExtra(TVConnectionService.EXTRA_OUTGOING_PARAMS, Bundle().apply {
                for ((key, value) in params) {
                    putString(key, value)
                }
            })
            ctx.startService(this)
        }

        return true
    }

    private fun formatCustomParams(
        customParameters: Map<String?, String?>,
        prefix: String = "|"
    ): String {
        if (customParameters.isEmpty()) {
            return ""
        }
        val json = JSONObject(customParameters)
        return "$prefix$json"
    }

    private fun checkAccountConnection(context: Context): Boolean {
        // Simply check if we have active connections instead of querying TelecomManager
        return TVConnectionService.hasActiveCalls()
    }

    /**
     * Attempts to register a [PhoneAccount] with the Telecom app.
     * Requires permissions:
     *  - [Manifest.permission.READ_PHONE_STATE]: for checking call capable accounts
     *  - [Manifest.permission.READ_PHONE_NUMBERS]: for getting the phone account via the handle.
     */
    @SuppressLint("MissingPermission")
    @RequiresPermission(allOf = [Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS])
    private fun registerPhoneAccount(): Boolean {
        context?.let { ctx ->
            telecomManager?.let { tm ->
                // Get PhoneAccountHandle
                val phoneAccountHandle = tm.getPhoneAccountHandle(ctx)

                if (!tm.canReadPhoneNumbers(ctx)) {
                    Log.e(TAG, "hasRegisteredPhoneAccount: No read phone numbers permission, call `requestReadPhoneNumbersPermission()` first")
                    return false;
                }

                // Get PhoneAccount, if null it's not registered
                val phoneAccount = tm.getPhoneAccount(phoneAccountHandle)
                if (phoneAccount != null) {
                    if (!phoneAccount.isEnabled) {
                        Log.e(
                            TVConnectionService.TAG,
                            "onStartCommand: PhoneAccount is not enabled, prompt the user to enable the phone account by opening settings with `openPhoneAccountSettings()`"
                        )
                        return true
                    }

                    // account is ready to use
                    return true
                }

                // Get telecom manager
//                if (!tm.canReadPhoneState(ctx)) {
//                    Log.e(TAG,"onStartCommand: Permission for READ_PHONE_STATE not granted or requested, call `requestReadPhoneStatePermission()` first")
//                    return false
//                }

                if (tm.hasCallCapableAccountSafe(ctx, phoneAccountHandle.componentName.className)) {
                    Log.w(TAG, "registerPhoneAccount: Phone account already registered, re-registering anyway")
//                    return true
                }

                tm.registerPhoneAccount(ctx, phoneAccountHandle)
                return true;
            } ?: run {
                Log.e(TAG, "Telecom Manager is null, cannot check if registered phone account")
                return false
            }
        } ?: run {
            Log.e(TAG, "Context is null, cannot register phone account")
            return false
        }
    }

    /**
     * Register your FCM token with Twilio to receive incoming call invites
     *
     * If a valid `google-services.json` has not been provided or the []FirebaseInstanceId] has not been
     * initialized the fcmToken will be null.
     *
     * In the case where the FirebaseInstanceId has not yet been initialized the
     * VoiceFirebaseInstanceIDService.onTokenRefresh should result in a LocalBroadcast to this
     * activity which will attempt registerForCallInvites again.
     * @param accessToken - Access token used to register with Twilio
     * @param fcmToken - FCM token used to register with Twilio
     */
    private fun registerForCallInvites(accessToken: String, fcmToken: String): Boolean {
        if (fcmToken.isEmpty()) {
            Log.e(TAG, "FCM token is empty, unable to register")
            return false
        }
        if (accessToken.isEmpty()) {
            Log.e(TAG, "Access token is empty, unable to register")
            return false
        }
        val registrationListener: RegistrationListener = object : RegistrationListener {
            override fun onRegistered(accessToken: String, fcmToken: String) {
                Log.d(TAG, "Successfully registered FCM $fcmToken")
            }

            override fun onError(
                registrationException: RegistrationException,
                accessToken: String,
                fcmToken: String
            ) {
                val message = String.format(
                    "(un)Registration Error: %d, %s",
                    registrationException.errorCode,
                    registrationException.message
                )
                Log.e(TAG, message)
            }
        }
        Voice.register(accessToken, Voice.RegistrationChannel.FCM, fcmToken, registrationListener)
        return true
    }

    /**
     * Un-register your FCM token from Twilio to stop receiving incoming call invites
     * @param accessToken - Access token used to register with Twilio
     */
    private fun unregisterForCallInvites(accessToken: String) {
        Log.i(TAG, "Un-registering with FCM")
        assert(accessToken.isNotEmpty()) { "Twilio Access Token cannot be empty" }
        assert(fcmToken != null) { "FCM token cannot be null" }
        fcmToken?.let {
            val unregistrationListener: UnregistrationListener = object : UnregistrationListener {
                override fun onUnregistered(accessToken: String?, fcmToken: String?) {
                    Log.d(TAG, "Successfully un-registered FCM $fcmToken")
                }

                override fun onError(
                    registrationException: RegistrationException,
                    accessToken: String,
                    fcmToken: String
                ) {
                    val message = String.format(
                        "(un)Registration Error: %d, %s",
                        registrationException.errorCode,
                        registrationException.message
                    )
                    Log.e(TAG, message)
                }
            }
            Voice.unregister(accessToken, Voice.RegistrationChannel.FCM, it, unregistrationListener)
        } ?: {
            Log.e(TAG, "FCM token is null, unable to unregister")
        }
    }

    //region Flutter ActivityPluginBinding
    override fun onAttachedToActivity(activityPluginBinding: ActivityPluginBinding) {
        Log.d(TAG, "onAttachedToActivity")
        activity = activityPluginBinding.activity
        activityPluginBinding.addOnNewIntentListener(this)
        activityPluginBinding.addRequestPermissionsResultListener(this)
        registerReceiver()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "onDetachedFromActivityForConfigChanges")
        unregisterReceiver()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(activityPluginBinding: ActivityPluginBinding) {
        Log.d(TAG, "onReattachedToActivityForConfigChanges")
        activity = activityPluginBinding.activity
        activityPluginBinding.addRequestPermissionsResultListener(this)
        activityPluginBinding.addOnNewIntentListener(this)
        registerReceiver()
    }

    override fun onDetachedFromActivity() {
        Log.d(TAG, "onDetachedFromActivity")
        unregisterReceiver()
        activity = null
    }
    //endregion

    //region Flutter BroadcastReceiver
    private fun registerReceiver() {
        assert(activity != null) { "Activity must not be null, has the plugin been registered?" }
        assert(broadcastReceiver != null) { "BroadcastReceiver must not be null, has the plugin been registered?" }
        if (!isReceiverRegistered) {
            Log.d(TAG, "registerReceiver")
            val intentFilter = IntentFilter().apply {
                addAction(TVBroadcastReceiver.ACTION_AUDIO_STATE)
                addAction(TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED)
                addAction(TVBroadcastReceiver.ACTION_INCOMING_CALL)
                addAction(TVBroadcastReceiver.ACTION_CALL_ENDED)
                addAction(TVBroadcastReceiver.ACTION_CALL_STATE)
                addAction(TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED)

                addAction(TVNativeCallActions.ACTION_ANSWERED)
                addAction(TVNativeCallActions.ACTION_REJECTED)
                addAction(TVNativeCallActions.ACTION_DTMF)
                addAction(TVNativeCallActions.ACTION_ABORT)
                addAction(TVNativeCallActions.ACTION_HOLD)
                addAction(TVNativeCallActions.ACTION_UNHOLD)

                addAction(TVNativeCallEvents.EVENT_CONNECTING)
                addAction(TVNativeCallEvents.EVENT_INCOMING)
                addAction(TVNativeCallEvents.EVENT_RINGING)
                addAction(TVNativeCallEvents.EVENT_CONNECTED)
                addAction(TVNativeCallEvents.EVENT_CONNECT_FAILURE)
                addAction(TVNativeCallEvents.EVENT_RECONNECTING)
                addAction(TVNativeCallEvents.EVENT_RECONNECTED)
                addAction(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL)
                addAction(TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE)
                addAction(TVNativeCallEvents.EVENT_MISSED)
                addAction(TVNativeCallEvents.EVENT_MUTE)
                addAction(TVNativeCallEvents.EVENT_SPEAKER)
                addAction(TVNativeCallEvents.EVENT_BLUETOOTH)
            }
            LocalBroadcastManager.getInstance(context!!)
                .registerReceiver(broadcastReceiver!!, intentFilter)
            isReceiverRegistered = true
        }
    }

    private fun unregisterReceiver() {
        assert(activity != null) { "Activity must not be null, has the plugin been registered?" }
        assert(broadcastReceiver != null) { "BroadcastReceiver must not be null, has the plugin been registered?" }
        if (isReceiverRegistered) {
            LocalBroadcastManager.getInstance(activity!!).unregisterReceiver(broadcastReceiver!!)
            isReceiverRegistered = false
        }
    }
    //endregion

    //region Flutter NewIntentListener
    override fun onNewIntent(intent: Intent): Boolean {
        Log.d(TAG, "onNewIntent")
        return false
    }
    //endregion

    //region Logging
    private fun logEvents(descriptions: Array<String>) {
        if (eventSink == null) {
            return
        }
        logEvents("LOG", "|", "|", descriptions, false)
    }

    private fun logEvents(prefix: String, descriptions: Array<String>) {
        if (eventSink == null) {
            return
        }
        logEvents(prefix, "|", "|", descriptions, false)
    }

    private fun logEvents(
        prefix: String = "LOG",
        separator: String = "|",
        descriptionSeparator: String = "|",
        descriptions: Array<String>,
        isError: Boolean = false
    ) {
        if (eventSink == null) {
            return
        }
        val description = descriptions.joinToString(descriptionSeparator)
        logEvent(prefix, separator, description, isError)
    }

    private fun logEvent(
        description: String,
    ) {
        logEvent("LOG", "|", description, false)
    }

    private fun logEventPermission(
        permissionName: String,
        state: Boolean,
    ) {
        logEvents(arrayOf("PERMISSION", permissionName, state.toString()))
    }

    private fun logEvent(
        prefix: String,
        description: String,
    ) {
        logEvent(prefix, "|", description, false)
    }

    private fun logEvent(
        prefix: String = "LOG",
        separator: String = "|",
        description: String,
        isError: Boolean = false
    ) {
        val message = if (prefix.isEmpty()) description else "$prefix$separator$description"
        
        if (eventSink == null) {
            // Queue important call events for when Flutter is ready
            // Only queue call state events, not general logs
            if (message.contains("Connected|") || message.contains("Ringing|") || 
                message.contains("Answer|") || message.contains("Call Ended") ||
                message.contains("Incoming|") || message.contains("IncomingWhileActive|") ||
                message.contains("Reconnecting") ||
                message.contains("Reconnected")) {
                Log.d(TAG, "logEvent: eventSink is null, queuing event: $message")
                pendingEvents.add(message)
            } else {
                Log.d(TAG, "logEvent: eventSink is null, dropping non-critical event: $message")
            }
            return
        }
        if (isError) {
            eventSink!!.error(FlutterErrorCodes.UNAVAILABLE_ERROR, description, null)
        } else {
            Log.d(TAG, "logEvent: $message")
            eventSink!!.success(message)
        }
    }
    //endregion

    private fun checkReadPhoneNumbersPermission(): Boolean {
        Log.d(TAG, "checkReadPhoneNumbersPermission")
        return context?.hasReadPhoneNumbersPermission() ?: false
    }

    private fun checkMicrophonePermission(): Boolean {
        Log.d(TAG, "checkMicrophonePermission")
        return context?.hasMicrophoneAccess() ?: false
    }

    private fun checkReadPhoneStatePermission(): Boolean {
        Log.d(TAG, "checkReadPhoneStatePermission")
        return context?.hasReadPhoneStatePermission() ?: false
    }

    private fun checkCallPhonePermission(): Boolean {
        Log.d(TAG, "checkCallPhonePermission")
        return context?.hasCallPhonePermission() ?: false
    }

    private fun checkManageOwnCallsPermission(): Boolean {
        Log.d(TAG, "checkManageOwnCallsPermission")
        if(Build.VERSION.SDK_INT <= Build.VERSION_CODES.TIRAMISU) {
            return context?.hasManageOwnCallsPermission() ?: false
        } else {
            return true
        }
    }

    /**
     * Checks if a [PhoneAccount] is registered with the Telecom app, and is enabled.
     * Requires permissions:
     * - [Manifest.permission.READ_PHONE_NUMBERS]: for getting the phone account via the handle.
     */
    @RequiresPermission(allOf = [Manifest.permission.READ_PHONE_NUMBERS])
    private fun checkIsPhoneAccountEnabled(): Boolean {
        context?.let { ctx ->
            telecomManager?.let { tm ->
                // Get PhoneAccountHandle
                val phoneAccountHandle = tm.getPhoneAccountHandle(ctx)

                if (!tm.canReadPhoneNumbers(ctx)) {
                    Log.e(TAG, "hasRegisteredPhoneAccount: No read phone numbers permission, call `requestReadPhoneNumbersPermission()` first")
                    return false;
                }

                return tm.getPhoneAccount(phoneAccountHandle).let {
                    it != null && it.isEnabled;
                }
            } ?: run {
                Log.e(TAG, "Telecom Manager is null, cannot check if registered phone account")
                return false
            }
        } ?: run {
            Log.e(TAG, "Context is null, cannot check if registered phone account")
            return false
        }
    }

    private fun requestPermissionForReadPhoneNumbers(onPermissionResult: (Boolean) -> Unit) {
        return requestPermissionOrShowRationale(
            "Read Phone Numbers",
            "Grant access to read phone numbers.",
            Manifest.permission.READ_PHONE_NUMBERS,
            REQUEST_CODE_READ_PHONE_NUMBERS,
            onPermissionResult
        )
    }

    private fun requestPermissionForMicrophone(onPermissionResult: (Boolean) -> Unit) {
        return requestPermissionOrShowRationale(
            "Microphone",
            "Microphone permission is required to make or receive phone calls.",
            Manifest.permission.RECORD_AUDIO,
            REQUEST_CODE_MICROPHONE,
            onPermissionResult
        )
    }

    /// Request permission for microphone on Android 14 and higher.
    /// Source: https://developer.android.com/reference/android/Manifest.permission#FOREGROUND_SERVICE_MICROPHONE
    private fun requestPermissionForMicrophoneForeground(onPermissionResult: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            Log.d(TAG, "requestPermissionForMicrophoneForeground: Microphone foreground permission automatically requested.");
            return requestPermissionOrShowRationale(
                "Microphone Foreground",
                "Microphone Foreground permission is required to make or receive phone calls on Android 14 and higher.",
                Manifest.permission.FOREGROUND_SERVICE_MICROPHONE,
                REQUEST_CODE_MICROPHONE_FOREGROUND,
                onPermissionResult
            )
        } else {
            Log.d(TAG, "requestPermissionForMicrophoneForeground: Microphone foreground permission skipped.");
        }
    }

    /// Request permission for manage own calls for Android 13 and lower.
    /// Source: https://developer.android.com/reference/android/Manifest.permission#MANAGE_OWN_CALLS
    /// Note from source: "Allows a calling application which manages its own calls through the self-managed ConnectionService APIs..."
    /// Even though we use a system-managed ConnectionService, we still need this permission for Android 13 and lower.
    private fun requestPermissionForManagingCalls(onPermissionResult: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.TIRAMISU) {
            Log.d(TAG, "requestPermissionForManagingCalls: Manage own calls automatically requested.");
            return requestPermissionOrShowRationale(
                "Manage Calls",
                "Manage own calls permission.",
                Manifest.permission.MANAGE_OWN_CALLS,
                REQUEST_CODE_MANAGE_CALLS,
                onPermissionResult
            )
        } else {
            Log.d(TAG, "requestPermissionForManagingCalls: Manage own calls permission skipped.");
        }
    }


    fun extractUserNumber(input: String): String {
        // Define the regular expression pattern to match the user_number part
        val pattern = Regex("""user_number:([^\s:]+)""")

        // Search for the first match in the input string
        val match = pattern.find(input)

        // Extract the matched part (user_number:+11230123)
        return match?.groups?.get(1)?.value ?: input
    }

    /**
     * Check if the "Display on Lock Screen" permission is granted.
     * 
     * For Android 12+: Not needed, always returns true
     * For Android 11 and below: Checks SCHEDULE_EXACT_ALARM permission
     * 
     * Note: On MIUI devices, this may not be 100% reliable as MIUI has custom permission handling,
     * but it's the best we can do without direct access to MIUI's permission database.
     */
    private fun checkShowOnLockScreenPermission(context: Context): Boolean {
        // Android 12+ doesn't need this permission  
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Log.d(TAG, "checkShowOnLockScreenPermission: Android 12+, returning true")
            return true
        }
        
        // Android 11 and below on MIUI devices:
        // The "Display on Lock Screen" permission is a MIUI-specific permission
        // that CANNOT be detected programmatically via any Android API.
        //
        // Options:
        // 1. Check overlay permission (canDrawOverlays) as a proxy - but this is different permission
        // 2. Store in SharedPreferences when user visits settings and assume granted
        // 3. Always return true and let actual functionality fail if not granted
        //
        // We'll use option 2: Check SharedPreferences for a flag set when user opens settings
        
        return try {
            val isMiui = isMiuiDevice()
            Log.d(TAG, "checkShowOnLockScreenPermission: SDK=${Build.VERSION.SDK_INT}, isMiui=$isMiui")
            
            // Check SharedPreferences for the flag
            val prefs = context.getSharedPreferences("twilio_voice_prefs", Context.MODE_PRIVATE)
            val hasVisitedSettings = prefs.getBoolean("show_on_lock_screen_settings_visited", false)
            
            if (hasVisitedSettings) {
                Log.d(TAG, "checkShowOnLockScreenPermission: User has visited settings, assuming granted")
                return true
            }
            
            // If user hasn't visited settings yet, return false
            Log.d(TAG, "checkShowOnLockScreenPermission: User hasn't visited settings yet, returning false")
            false
        } catch (e: Exception) {
            Log.e(TAG, "Error checking show on lock screen permission: ${e.message}", e)
            false
        }
    }
    
    private fun markShowOnLockScreenSettingsVisited(context: Context) {
        try {
            val prefs = context.getSharedPreferences("twilio_voice_prefs", Context.MODE_PRIVATE)
            prefs.edit().putBoolean("show_on_lock_screen_settings_visited", true).apply()
            Log.d(TAG, "markShowOnLockScreenSettingsVisited: Flag set to true")
        } catch (e: Exception) {
            Log.e(TAG, "Error setting show on lock screen flag: ${e.message}", e)
        }
    }

    private fun requestPermissionForPhoneState(onPermissionResult: (Boolean) -> Unit) {
        return requestPermissionOrShowRationale(
            "Read Phone State",
            "Read phone state to make or receive phone calls.",
            Manifest.permission.READ_PHONE_STATE,
            REQUEST_CODE_READ_PHONE_STATE,
            onPermissionResult
        )
    }

    private fun requestPermissionForCallPhone(onPermissionResult: (Boolean) -> Unit) {
        return requestPermissionOrShowRationale(
            "Access Phone",
            "Required to place calls with Telecom App",
            Manifest.permission.CALL_PHONE,
            REQUEST_CODE_CALL_PHONE,
            onPermissionResult
        )
    }

    private fun requestPermissionOrShowRationale(
        permissionName: String,
        description: String,
        manifestPermission: String,
        requestCode: Int,
        onPermissionResult: (Boolean) -> Unit,
    ) {
        if (activity == null) {
            onPermissionResult.invoke(false);
            return;
        }

        if (activity!!.checkPermission(manifestPermission)) {
            onPermissionResult.invoke(true)
            return
        }

        logEvent("requestPermissionFor$permissionName")
        val shouldShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(activity!!, manifestPermission)
        if (shouldShowRationale) {
            val clickListener =
                DialogInterface.OnClickListener { _: DialogInterface?, _: Int ->
                    ActivityCompat.requestPermissions(
                        activity!!, arrayOf(manifestPermission), requestCode
                    )
                }
            val dismissListener = DialogInterface.OnDismissListener { _: DialogInterface? ->
                logEvent("Request" + permissionName + "Access")
            }
            showPermissionRationaleDialog(activity!!, "$permissionName Permissions", description, clickListener, dismissListener)
        } else {
            ActivityCompat.requestPermissions(activity!!, arrayOf(manifestPermission), requestCode)
            permissionResultHandler[requestCode] = onPermissionResult
        }
    }

    private fun showPermissionRationaleDialog(
        context: Context,
        title: String,
        message: String,
        onClickListener: DialogInterface.OnClickListener,
        onDismissListener: DialogInterface.OnDismissListener
    ) {
        val builder = AlertDialog.Builder(context)
        builder.setTitle(title)
        builder.setMessage(message)
        builder.setPositiveButton(R.string.proceed, onClickListener)
        builder.setNegativeButton(R.string.cancel, null)
        builder.setOnDismissListener(onDismissListener)
        builder.show()
    }

    //region LocalBroadcastReceiver
    fun handleBroadcastIntent(intent: Intent) {
        when (intent.action) {
            TVBroadcastReceiver.ACTION_AUDIO_STATE -> {
                println("Event called Basil : TVBroadcastReceiver.ACTION_AUDIO_STATE")
                val callAudioState: CallAudioState =
                    intent.getParcelableExtraSafe(TVBroadcastReceiver.EXTRA_AUDIO_STATE) ?: run {
                        Log.e(
                            TAG,
                            "handleBroadcastIntent: No 'EXTRA_AUDIO_STATE' provided or invalid type, make sure to provide a [CallAudioState]"
                        )
                        return
                    }

                // Handle mute state change
                isMuted =
                    if (isMuted == callAudioState.isMuted) isMuted else callAudioState.isMuted.also {
                        logEvent("", if (it) "Mute" else "Unmute")
                    }
                
                // Determine the new audio route state
                val newRoute = callAudioState.route
                val newSpeakerState = newRoute == CallAudioState.ROUTE_SPEAKER
                val newBluetoothState = newRoute == CallAudioState.ROUTE_BLUETOOTH
                
                Log.d(TAG, "handleBroadcastIntent: Audio route changed - current speaker=$isSpeakerOn, bluetooth=$isBluetoothOn, new route=${CallAudioState.audioRouteToString(newRoute)}")
                
                // Only emit ONE event based on what actually changed
                // Priority: emit event for the route we're transitioning TO (if turning on)
                // or the route we're transitioning FROM (if turning off)
                when {
                    // Turning speaker ON (wasn't speaker, now is speaker)
                    !isSpeakerOn && newSpeakerState -> {
                        isSpeakerOn = true
                        isBluetoothOn = false
                        logEvent("", "Speaker On")
                    }
                    // Turning bluetooth ON (wasn't bluetooth, now is bluetooth)
                    !isBluetoothOn && newBluetoothState -> {
                        isBluetoothOn = true
                        isSpeakerOn = false
                        logEvent("", "Bluetooth On")
                    }
                    // Turning speaker OFF (was speaker, now not speaker)
                    isSpeakerOn && !newSpeakerState -> {
                        isSpeakerOn = false
                        // Only emit "Speaker Off" if we're not switching to bluetooth
                        if (!newBluetoothState) {
                            logEvent("", "Speaker Off")
                        }
                        // If switching to bluetooth, the bluetooth event will be emitted by the next state change
                        if (newBluetoothState) {
                            isBluetoothOn = true
                            logEvent("", "Bluetooth On")
                        }
                    }
                    // Turning bluetooth OFF (was bluetooth, now not bluetooth)
                    isBluetoothOn && !newBluetoothState -> {
                        isBluetoothOn = false
                        // Only emit "Bluetooth Off" if we're not switching to speaker
                        if (!newSpeakerState) {
                            logEvent("", "Bluetooth Off")
                        }
                        // If switching to speaker, emit speaker event
                        if (newSpeakerState) {
                            isSpeakerOn = true
                            logEvent("", "Speaker On")
                        }
                    }
                    // No state change - route is same or transitioning to earpiece from earpiece
                    else -> {
                        // Update states without emitting events
                        isSpeakerOn = newSpeakerState
                        isBluetoothOn = newBluetoothState
                    }
                }
                
                Log.d(
                    TAG,
                    "handleBroadcastIntent: Audio state changed to ${
                        CallAudioState.audioRouteToString(callAudioState.route)
                    }, isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn"
                )
            }

            TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED -> {
                Log.d(TAG, "handleBroadcastIntent: Active call changed to $callSid")
            }

            TVBroadcastReceiver.ACTION_INCOMING_CALL -> {
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(
                            TAG,
                            "handleBroadcastIntent: No 'EXTRA_CALL_HANDLE' provided or invalid type, make sure to provide a [CallSid]"
                        )
                        return
                    }
                val callInvite =
                    intent.getParcelableExtraSafe<CallInvite>(TVBroadcastReceiver.EXTRA_CALL_INVITE)
                        ?: run {
                            Log.e(
                                TAG,
                                "handleBroadcastIntent: No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                            )
                            return
                        }
                val from = extractUserNumber(callInvite.from ?: "")
                val to = callInvite.to
                val params = JSONObject().apply {
                    callInvite.customParameters.forEach { (key, value) ->
                        put(key, value)
                    }
                }.toString()

                // Check if there's already an active call
                if (callSid != null) {
                    // Active call exists - don't overwrite callSid or send Ringing
                    // Send a separate event so Flutter can track the waiting call
                    // without corrupting the active call's data
                    Log.d(TAG, "handleBroadcastIntent: ACTION_INCOMING_CALL during active call (callSid=$callSid), sending IncomingWhileActive for $callHandle")
                    logEvents("", arrayOf("IncomingWhileActive", from, to, CallDirection.INCOMING.label, params))
                } else {
                    callSid = callHandle
                    // Reset audio states for new incoming call (only when no active call)
                    isSpeakerOn = false
                    isBluetoothOn = false
                    isMuted = false
                    Log.d(TAG, "handleBroadcastIntent: ACTION_INCOMING_CALL - Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                    logEvents("", arrayOf("Incoming", from, to, CallDirection.INCOMING.label, params))
                    logEvents("", arrayOf("Ringing", from, to, CallDirection.INCOMING.label, params))
                }
            }

            TVBroadcastReceiver.ACTION_CALL_ENDED -> {
                println("Event called Basil : TVBroadcastReceiver.ACTION_CALL_ENDED")
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(
                            TAG,
                            "handleBroadcastIntent: No 'EXTRA_CALL_HANDLE' provided or invalid type, make sure to provide a [String]"
                        )
                        return
                    }
                // If other calls are still active, update callSid to the remaining call instead of null
                val remainingHandle = TVConnectionService.getActiveCallHandle()
                if (remainingHandle != null && remainingHandle != callHandle) {
                    callSid = remainingHandle
                    Log.d(TAG, "handleBroadcastIntent: Call Ended $callHandle, but remaining call active - setting callSid=$callSid")
                } else {
                    callSid = null
                    Log.d(TAG, "handleBroadcastIntent: Call Ended $callHandle, no remaining calls")
                }
                logEvent("", "Call Ended")
            }

            TVBroadcastReceiver.ACTION_CALL_STATE -> {
//                isMuted = intent.getBooleanExtra(TVBroadcastReceiver.EXTRA_MUTE_STATE, isMuted).also {
//                    Log.d(TAG, "handleBroadcastIntent: Call muted $it")
//                }
                isHolding =
                    intent.getBooleanExtra(TVBroadcastReceiver.EXTRA_HOLD_STATE, isHolding).also {
                        Log.d(TAG, "handleBroadcastIntent: Call holding $it")
                    }
            }

            TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED -> {
                val reason = intent.getStringArrayExtra(TVBroadcastReceiver.EXTRA_INCOMING_CALL_IGNORED_REASON) ?: arrayOf<String>()
                val handle = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: "N/A"
                Log.w(
                    TAG,
                    "handleBroadcastIntent: Incoming call ignored, see reason.\n" +
                            "Call Handle: $handle\n" +
                            "Reason(s):\n" +
                            "\t${reason.joinToString("\n\t")}"
                )
            }

            TVNativeCallActions.ACTION_ANSWERED -> {
                // Reset audio states when call is answered to ensure clean state
                // Audio routing will happen after the call connects
                isSpeakerOn = false
                isBluetoothOn = false
                isMuted = false
                Log.d(TAG, "handleBroadcastIntent: ACTION_ANSWERED - Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(
                            TAG,
                            "No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                        )
                        return
                    }
                val ci =
                    intent.getParcelableExtraSafe<CallInvite>(TVBroadcastReceiver.EXTRA_CALL_INVITE)
                        ?: run {
                            Log.e(
                                TAG,
                                "No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                            )
                            return
                        }
                val from = extractUserNumber(ci.from ?: "")
                val to = ci.to
                val params = JSONObject().apply {
                    ci.customParameters.forEach { (key, value) ->
                        put(key, value)
                    }
                }.toString()
                callSid = callHandle
                logEvents("", arrayOf("Answer", from, to, CallDirection.INCOMING.label, params))
            }

            TVNativeCallActions.ACTION_DTMF -> {
                val dtmf = intent.getStringExtra(TVNativeCallActions.EXTRA_DTMF_TONE) ?: run {
                    Log.e(
                        TAG,
                        "handleBroadcastIntent: No 'EXTRA_DTMF_TONE' provided or invalid type."
                    )
                    return
                }

                // TODO(cybex-dev): send to Flutter
//                logEvents(arrayOf("DTMF", dtmf))
                Log.d(TAG, "handleBroadcastIntent: DTMF $dtmf")
            }

            TVNativeCallActions.ACTION_REJECTED -> {
                logEvent("Call Rejected")
                callSid = null
            }

            TVNativeCallActions.ACTION_ABORT -> {
                Log.d(TAG, "handleBroadcastIntent: Abort")
                logEvent("", "Call Ended")
                callSid = null
            }

            TVNativeCallActions.ACTION_HOLD -> {
                Log.d(TAG, "handleBroadcastIntent: Hold")
                logEvent("", "Hold")
            }

            TVNativeCallActions.ACTION_UNHOLD -> {
                Log.d(TAG, "handleBroadcastIntent: Unhold")
                // Restore callSid from the remaining active connection
                // This is needed when a second call ends and the held call is restored
                val activeHandle = TVConnectionService.getActiveCallHandle()
                if (activeHandle != null && callSid == null) {
                    callSid = activeHandle
                    Log.d(TAG, "handleBroadcastIntent: Unhold - restored callSid=$callSid from active connection")
                }
                logEvent("", "Unhold")
            }

            TVNativeCallEvents.EVENT_CONNECTING -> {
                Log.d(TAG, "handleBroadcastIntent: Connecting")
            }

            TVNativeCallEvents.EVENT_RINGING -> {
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(TAG, "No 'EXTRA_CALL_INVITE' provided or invalid type")
                        return
                    }
                val from = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_FROM) ?: run {
                    Log.e(TAG, "No 'EXTRA_CALL_FROM' provided or invalid type")
                    return
                }
                val to = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_TO) ?: run {
                    Log.e(TAG, "No 'EXTRA_CALL_TO' provided or invalid type")
                    return
                }
                val direction = intent.getIntExtra(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, -1)
                val callDirection = CallDirection.fromId(direction).toString()

                // Only update callSid and send Ringing if no active call exists
                // or if this is the same call (not a second incoming call)
                if (callSid == null || callSid == callHandle) {
                    callSid = callHandle
                    logEvents("", arrayOf("Ringing", from, to, callDirection))
                } else {
                    // Active call exists with different SID - skip to avoid corrupting Flutter state
                    Log.d(TAG, "handleBroadcastIntent: EVENT_RINGING skipped for $callHandle (active callSid=$callSid)")
                }
            }

            TVNativeCallEvents.EVENT_CONNECTED -> {
                // TODO
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(
                            TAG,
                            "No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                        )
                        return
                    }
                val from = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_FROM) ?: run {
                    Log.e(
                        TAG,
                        "No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                    )
                    return
                }
                val to = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_TO) ?: run {
                    Log.e(
                        TAG,
                        "No 'EXTRA_CALL_INVITE' provided or invalid type, make sure to provide a [CallInvite]"
                    )
                    return
                }
                val direction = intent.getIntExtra(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, -1)
                val callDirection = CallDirection.fromId(direction)!!.label
                callSid = callHandle
                
                // Initialize audio state when call connects
                val activeCall = TVConnectionService.activeConnections.values.firstOrNull()
                if (activeCall != null) {
                    val audioState = activeCall.callAudioState
                    if (audioState != null) {
                        // Get the current audio route from TelecomManager
                        val route = when (audioState.route) {
                            CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"
                            CallAudioState.ROUTE_SPEAKER -> "speaker"
                            else -> "earpiece"
                        }
                        isBluetoothOn = route == "bluetooth"
                        isSpeakerOn = route == "speaker"
                        Log.d(TAG, "EVENT_CONNECTED: Initialized audio state from TelecomManager - route=$route, isBluetoothOn=$isBluetoothOn, isSpeakerOn=$isSpeakerOn")
                    } else {
                        // callAudioState is null, check AudioManager for actual routing
                        Log.d(TAG, "EVENT_CONNECTED: callAudioState is null, checking AudioManager")
                        context?.let { ctx ->
                            val audioManager = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                            if (audioManager != null) {
                                // Check if Bluetooth SCO is on - this is the most reliable indicator for voice calls
                                val bluetoothScoOn = audioManager.isBluetoothScoOn
                                val speakerOn = audioManager.isSpeakerphoneOn
                                
                                // Also check via communication device on Android 12+
                                var bluetoothCommDevice = false
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                    val commDevice = audioManager.communicationDevice
                                    bluetoothCommDevice = commDevice?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                                    Log.d(TAG, "EVENT_CONNECTED: communicationDevice type=${commDevice?.type}")
                                }
                                
                                isBluetoothOn = bluetoothScoOn || bluetoothCommDevice
                                isSpeakerOn = speakerOn && !isBluetoothOn
                                Log.d(TAG, "EVENT_CONNECTED: Initialized from AudioManager - bluetoothScoOn=$bluetoothScoOn, bluetoothCommDevice=$bluetoothCommDevice, speakerOn=$speakerOn, final isBluetoothOn=$isBluetoothOn, isSpeakerOn=$isSpeakerOn")
                            }
                        }
                    }
                }
                
                logEvents("", arrayOf("Connected", from, to, callDirection))
            }

            TVNativeCallEvents.EVENT_CONNECT_FAILURE -> {
                var code = intent.getIntExtra(CallExceptionExtension.EXTRA_CODE, -1)
                if(code == -1) {
                    // Fallback to the old code
                    code = intent.getIntExtra("code", -1)
                }
                val message = intent.getStringExtra(CallExceptionExtension.EXTRA_MESSAGE) ?: run {
                    Log.e(TAG, "No 'EXTRA_MESSAGE' provided or invalid type")
                    return
                }
                logEvent("Call Error: ${code}, $message");
                logEvent("", "Call Ended")
                callSid = null
                TVConnectionService.clearActiveConnections()

            }

            TVNativeCallEvents.EVENT_RECONNECTING -> {
                logEvent("", "Reconnecting");
            }

            TVNativeCallEvents.EVENT_RECONNECTED -> {
                logEvent("", "Reconnected");
            }

            TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL -> {
                logEvent("", "Call Ended")
                // Only null callSid if no other calls remain
                val remainingHandleLocal = TVConnectionService.getActiveCallHandle()
                if (remainingHandleLocal != null) {
                    callSid = remainingHandleLocal
                    Log.d(TAG, "handleBroadcastIntent: EVENT_DISCONNECTED_LOCAL - remaining call active, callSid=$callSid")
                } else {
                    callSid = null
                    // Reset audio states for next call
                    isSpeakerOn = false
                    isBluetoothOn = false
                    isMuted = false
                    Log.d(TAG, "handleBroadcastIntent: EVENT_DISCONNECTED_LOCAL - Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                }
            }

            TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE -> {
                logEvent("", "Call Ended")
                // Only null callSid if no other calls remain
                val remainingHandleRemote = TVConnectionService.getActiveCallHandle()
                if (remainingHandleRemote != null) {
                    callSid = remainingHandleRemote
                    Log.d(TAG, "handleBroadcastIntent: EVENT_DISCONNECTED_REMOTE - remaining call active, callSid=$callSid")
                } else {
                    callSid = null
                    // Reset audio states for next call
                    isSpeakerOn = false
                    isBluetoothOn = false
                    isMuted = false
                    Log.d(TAG, "handleBroadcastIntent: EVENT_DISCONNECTED_REMOTE - Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                }
            }

            TVNativeCallEvents.EVENT_MISSED -> {
                logEvent("", "Missed Call")
                logEvent("", "Call Ended")
                callSid = null
                // Reset audio states for next call
                isSpeakerOn = false
                isBluetoothOn = false
                isMuted = false
                Log.d(TAG, "handleBroadcastIntent: EVENT_MISSED - Reset audio states: isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
            }

            TVNativeCallEvents.EVENT_MUTE -> {
                val muteState = intent.getBooleanExtra(TVBroadcastReceiver.EXTRA_CALL_MUTE_STATE, false)
                isMuted = muteState
                logEvent("", if (muteState) "Mute" else "Unmute")
                Log.d(TAG, "handleBroadcastIntent: Mute state changed to $muteState")
            }

            TVNativeCallEvents.EVENT_SPEAKER -> {
                Log.d(TAG, "=== EVENT_SPEAKER RECEIVED ===")
                val speakerState = intent.getBooleanExtra(TVBroadcastReceiver.EXTRA_CALL_SPEAKER_STATE, false)
                Log.d(TAG, "EVENT_SPEAKER: speakerState from intent = $speakerState")
                Log.d(TAG, "EVENT_SPEAKER: BEFORE - isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                
                isSpeakerOn = speakerState
                // Speaker ON means Bluetooth should be OFF (mutual exclusion)
                if (speakerState) {
                    Log.d(TAG, "EVENT_SPEAKER: Speaker is ON, setting isBluetoothOn=false (mutual exclusion)")
                    isBluetoothOn = false
                }
                
                Log.d(TAG, "EVENT_SPEAKER: AFTER - isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                logEvent("", if (speakerState) "Speaker On" else "Speaker Off")
            }

            TVNativeCallEvents.EVENT_BLUETOOTH -> {
                Log.d(TAG, "=== EVENT_BLUETOOTH RECEIVED ===")
                val bluetoothState = intent.getBooleanExtra(TVBroadcastReceiver.EXTRA_CALL_BLUETOOTH_STATE, false)
                Log.d(TAG, "EVENT_BLUETOOTH: bluetoothState from intent = $bluetoothState")
                Log.d(TAG, "EVENT_BLUETOOTH: BEFORE - isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                
                isBluetoothOn = bluetoothState
                // Bluetooth ON means Speaker should be OFF (mutual exclusion)
                if (bluetoothState) {
                    Log.d(TAG, "EVENT_BLUETOOTH: Bluetooth is ON, setting isSpeakerOn=false (mutual exclusion)")
                    isSpeakerOn = false
                }
                
                Log.d(TAG, "EVENT_BLUETOOTH: AFTER - isSpeakerOn=$isSpeakerOn, isBluetoothOn=$isBluetoothOn")
                logEvent("", if (bluetoothState) "Bluetooth On" else "Bluetooth Off")
            }

            else -> {
                Log.e(TAG, "[VoiceBroadcastReceiver] Received unknown action ${intent.action}")
            }
        }
    }

//    override fun onConnectFailure(call: Call, callException: CallException) {
//        Log.e(TAG, "onConnectFailure: ${callException.message}")
//        logEvent("onConnectFailure", callException.message ?: "")
//    }
//
//    override fun onRinging(call: Call) {
//        Log.d(TAG, "onRinging")
//        logEvent("onRinging")
//    }
//
//    override fun onConnected(call: Call) {
//        Log.d(TAG, "onConnected")
//        logEvent("onConnected")
//    }
//
//    override fun onReconnecting(call: Call, callException: CallException) {
//        Log.d(TAG, "onReconnecting")
//        logEvent("onReconnecting")
//    }
//
//    override fun onReconnected(call: Call) {
//        Log.d(TAG, "onReconnected")
//        logEvent("onReconnected")
//    }
//
//    override fun onDisconnected(call: Call, callException: CallException?) {
//        Log.d(TAG, "onDisconnected")
//        logEvent("onDisconnected")
//    }
    //endregion
    
    /**
     * Check if the device is a MIUI (Xiaomi/Redmi/Poco) device.
     * MIUI devices require special permissions for showing UI over lock screen.
     */
    private fun isMiuiDevice(): Boolean {
        return try {
            val prop = Class.forName("android.os.SystemProperties")
            val get = prop.getMethod("get", String::class.java)
            val miuiVersion = get.invoke(null, "ro.miui.ui.version.name") as? String
            val brand = Build.BRAND.lowercase()
            val manufacturer = Build.MANUFACTURER.lowercase()
            
            !miuiVersion.isNullOrEmpty() || 
                brand.contains("xiaomi") || 
                brand.contains("redmi") || 
                brand.contains("poco") ||
                manufacturer.contains("xiaomi") ||
                manufacturer.contains("redmi")
        } catch (e: Exception) {
            val brand = Build.BRAND.lowercase()
            val manufacturer = Build.MANUFACTURER.lowercase()
            brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") ||
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi")
        }
    }
}
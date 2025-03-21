package com.twilio.twilio_voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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

    private var isSpeakerOn: Boolean = false
    private var isBluetoothOn: Boolean = false
    private var isMuted: Boolean = false
    private var isHolding: Boolean = false
    private val callSid: String?
        get() = TVConnectionService.getActiveCallHandle()

    private var hasStarted = false

    // Provides a mapping of permission to result handler for when the permission is granted or denied via the PluginRegistry, then responds via future to the Flutter side
    private val permissionResultHandler: MutableMap<Int, (Boolean) -> Unit> = mutableMapOf()

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
        }
        return true
    }
    //endregion

    //region Flutter EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventSink?) {
        Log.i(TAG, "Setting event sink")
        this.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        Log.i(TAG, "Removing event sink")
        eventSink = null
    }
    //endregion

    //region Flutter MethodCallHandler
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.arguments !is Map<*, *>) {
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
                result.success(isSpeakerOn)
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

            TVMethodChannels.IS_BLUETOOTH_ON -> {
                Log.d(TAG, "isBluetoothOn invoked")
                result.success(isBluetoothOn)
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
                val activeCallHandle = TVConnectionService.getActiveCallHandle();
                result.success(activeCallHandle)
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
                Log.d(TAG, "calling $from -> $to")

                accessToken?.let { token ->
                    context?.let { ctx ->
                        val success = placeCall(ctx, token, from, to, params)
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
                result.success(checkReadPhoneStatePermission())
            }

            TVMethodChannels.REQUEST_READ_PHONE_STATE_PERMISSION -> {
                logEvent("requestingReadPhoneStatePermission")
                if (!checkReadPhoneStatePermission()) {
                    requestPermissionForPhoneState() { granted ->
                        result.success(granted)
                    }
                } else {
                    result.success(true)
                }
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
            Intent(ctx, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_SEND_DIGITS
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
                putExtra(TVConnectionService.ACTION_SEND_DIGITS, digits)
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
            Intent(ctx, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
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
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_SPEAKER
            putExtra(TVConnectionService.EXTRA_SPEAKER_STATE, speakerIsOn)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
            ctx.startService(this)
        }
    }

    private fun toggleMute(ctx: Context, mute: Boolean) {
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_MUTE
            putExtra(TVConnectionService.EXTRA_MUTE_STATE, mute)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
            ctx.startService(this)
        }
    }

    private fun toggleBluetooth(ctx: Context, bluetoothOn: Boolean) {
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_BLUETOOTH
            putExtra(TVConnectionService.EXTRA_BLUETOOTH_STATE, bluetoothOn)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
            ctx.startService(this)
        }
    }

    private fun toggleHold(ctx: Context, shouldHold: Boolean) {
        Intent(ctx, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_TOGGLE_HOLD
            putExtra(TVConnectionService.EXTRA_HOLD_STATE, shouldHold)
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
            ctx.startService(this)
        }
    }

    /**
     * Attempts to place a call using the [TVConnectionService].
     * Requires permissions:
     * - [Manifest.permission.READ_PHONE_STATE]: for checking call capable accounts
     * - [Manifest.permission.READ_PHONE_NUMBERS]: for getting the phone account via the handle.
     * - [Manifest.permission.RECORD_AUDIO]: for placing the call and capturing microphone audio.
     */
    @RequiresPermission(allOf = [Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS, Manifest.permission.RECORD_AUDIO])
    private fun placeCall(
        ctx: Context,
        accessToken: String,
        from: String,
        to: String,
        params: Map<String, String>
    ): Boolean {
        assert(accessToken.isNotEmpty()) { "Twilio Access Token cannot be empty" }
        assert(to.isNotEmpty()) { "To cannot be empty" }
        assert(from.isNotEmpty()) { "From cannot be empty" }

        telecomManager?.let { tm ->
            if (!tm.hasCallCapableAccount(ctx, TVConnectionService::class.java.name)) {
                Log.e(TAG, "No registered phone account, call `registerPhoneAccount()` first")
                return false
            }
            if (!checkMicrophonePermission()) {
                Log.e(TAG, "No microphone permission, call `requestMicrophonePermission()` first")
                return false
            }
            if (!checkReadPhoneNumbersPermission()) {
                Log.e(TAG, "No read phone state permission, call `requestReadPhoneStatePermission()` first")
                return false
            }
            if (!checkCallPhonePermission()) {
                Log.e(TAG, "No call phone permission, call `requestCallPhonePermission()` first")
                return false
            }
            if (!checkManageOwnCallsPermission()) {
                Log.e(TAG, "No manage own calls permission, call `requestManageOwnCallsPermission()` first")
                return false
            }

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
                putExtra(TVConnectionService.EXTRA_TO, to)
                putExtra(TVConnectionService.EXTRA_FROM, from)
                putExtra(TVConnectionService.EXTRA_OUTGOING_PARAMS, Bundle().apply {
                    for ((key, value) in params) {
                        putString(key, value)
                    }
                })
                ctx.startService(this)
            }

            return true
        } ?: run {
            Log.e(TAG, "TelecomManager is null, cannot place call")
            return false
        }
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
        var isConnected = false
        val permissionResult =
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE)
        if (permissionResult == PackageManager.PERMISSION_GRANTED) {
            telecomManager?.let {
                val enabledAccounts: List<PhoneAccountHandle> = it.callCapablePhoneAccounts
                for (account in enabledAccounts) {
                    if (account.componentName.className == TVConnectionService::class.java.name) {
                        isConnected = true
                        break
                    }
                }
            }
        }
        return isConnected
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

                if (tm.hasCallCapableAccount(ctx, phoneAccountHandle.componentName.className)) {
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
        if (eventSink == null) {
            return
        }
        if (isError) {
            eventSink!!.error(FlutterErrorCodes.UNAVAILABLE_ERROR, description, null)
        } else {
            val message = if (prefix.isEmpty()) description else "$prefix$separator$description"
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
                val callAudioState: CallAudioState =
                    intent.getParcelableExtraSafe(TVBroadcastReceiver.EXTRA_AUDIO_STATE) ?: run {
                        Log.e(
                            TAG,
                            "handleBroadcastIntent: No 'EXTRA_AUDIO_STATE' provided or invalid type, make sure to provide a [CallAudioState]"
                        )
                        return
                    }

                isMuted =
                    if (isMuted == callAudioState.isMuted) isMuted else callAudioState.isMuted.also {
                        logEvent("", if (it) "Mute" else "Unmute")
                    }
                val speakerRouteSelected = callAudioState.route == CallAudioState.ROUTE_SPEAKER
                isSpeakerOn =
                    if (isSpeakerOn == speakerRouteSelected) isSpeakerOn else speakerRouteSelected.also {
                        logEvent("", if (it) "Speaker On" else "Speaker Off")
                    }
                val bluetoothRouteSelected = callAudioState.route == CallAudioState.ROUTE_BLUETOOTH
                isBluetoothOn =
                    if (isBluetoothOn == bluetoothRouteSelected) isBluetoothOn else bluetoothRouteSelected.also {
                        logEvent("", if (it) "Bluetooth On" else "Bluetooth Off")
                    }
                Log.d(
                    TAG,
                    "handleBroadcastIntent: Audio state changed to ${
                        CallAudioState.audioRouteToString(callAudioState.route)
                    }"
                )
            }

            TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED -> {
                Log.d(TAG, "handleBroadcastIntent: Active call changed to $callSid")
            }

            TVBroadcastReceiver.ACTION_INCOMING_CALL -> {
                // TODO
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
                val from = callInvite.from ?: ""
                val to = callInvite.to
                val params = JSONObject().apply {
                    callInvite.customParameters.forEach { (key, value) ->
                        put(key, value)
                    }
                }.toString()
//                callSid = callHandle
                logEvents("", arrayOf("Incoming", from, to, CallDirection.INCOMING.label, params))
                logEvents("", arrayOf("Ringing", from, to, CallDirection.INCOMING.label, params))
            }

            TVBroadcastReceiver.ACTION_CALL_ENDED -> {
                val callHandle =
                    intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE) ?: run {
                        Log.e(
                            TAG,
                            "handleBroadcastIntent: No 'EXTRA_CALL_HANDLE' provided or invalid type, make sure to provide a [String]"
                        )
                        return
                    }
//                callSid = null
                Log.d(TAG, "handleBroadcastIntent: Call ended $callHandle")
                logEvent("", "Call ended")
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
                // TODO
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
                val from = ci.from ?: ""
                val to = ci.to
                val params = JSONObject().apply {
                    ci.customParameters.forEach { (key, value) ->
                        put(key, value)
                    }
                }.toString()
//                callSid = callHandle
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
            }

            TVNativeCallActions.ACTION_ABORT -> {
                Log.d(TAG, "handleBroadcastIntent: Abort")
                logEvent("", "Call Ended")
            }

            TVNativeCallActions.ACTION_HOLD -> {
                Log.d(TAG, "handleBroadcastIntent: Hold")
                logEvent("", "Hold")
            }

            TVNativeCallActions.ACTION_UNHOLD -> {
                Log.d(TAG, "handleBroadcastIntent: Unhold")
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

//                callSid = callHandle
                logEvents("", arrayOf("Ringing", from, to, callDirection))
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
//                callSid = callHandle
                logEvents("", arrayOf("Connected", from, to, callDirection))
            }

            TVNativeCallEvents.EVENT_CONNECT_FAILURE -> {
                val code = intent.getIntExtra(CallExceptionExtension.EXTRA_CODE, -1)
                val message = intent.getStringExtra(CallExceptionExtension.EXTRA_MESSAGE) ?: run {
                    Log.e(TAG, "No 'EXTRA_MESSAGE' provided or invalid type")
                    return
                }
                logEvent("Call Error: ${code}, $message");
            }

            TVNativeCallEvents.EVENT_RECONNECTING -> {
                logEvent("", "Reconnecting");
            }

            TVNativeCallEvents.EVENT_RECONNECTED -> {
                logEvent("", "Reconnected");
            }

            TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL -> {
                logEvent("", "Call Ended")
            }

            TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE -> {
                logEvent("", "Call Ended")
            }

            TVNativeCallEvents.EVENT_MISSED -> {
                logEvent("", "Missed Call")
                logEvent("", "Call Ended")
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
}
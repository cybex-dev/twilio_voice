package com.twilio.twilio_voice.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.telecom.*
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.R
import com.twilio.twilio_voice.call.TVCallInviteParametersImpl
import com.twilio.twilio_voice.call.TVCallParametersImpl
import com.twilio.twilio_voice.call.TVParameters
import com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.storage.Storage
import com.twilio.twilio_voice.storage.StorageImpl
import com.twilio.twilio_voice.types.BundleExtensions.getParcelableSafe
import com.twilio.twilio_voice.types.CallDirection
import com.twilio.twilio_voice.types.CompletionHandler
import com.twilio.twilio_voice.types.ContextExtension.appName
import com.twilio.twilio_voice.types.ContextExtension.hasCallPhonePermission
import com.twilio.twilio_voice.types.ContextExtension.hasManageOwnCallsPermission
import com.twilio.twilio_voice.types.TVNativeCallEvents
import com.twilio.twilio_voice.IncomingCallActivity
import com.twilio.voice.CallInvite
import com.twilio.twilio_voice.types.ContextExtension.hasMicrophoneAccess
import com.twilio.twilio_voice.types.IntentExtension.getParcelableExtraSafe
import com.twilio.twilio_voice.types.TelecomManagerExtension.getPhoneAccountHandle
import com.twilio.twilio_voice.types.TelecomManagerExtension.hasCallCapableAccountSafe
import com.twilio.twilio_voice.types.TelecomManagerExtension.registerPhoneAccount
import com.twilio.twilio_voice.types.ValueBundleChanged
import com.twilio.voice.*
import com.twilio.voice.Call

class TVConnectionService : ConnectionService() {

    companion object {
        val TAG = "TwilioVoiceConnectionService"

        val activeConnections = HashMap<String, TVCallConnection>()

        val TWI_SCHEME: String = "twi"

        val SERVICE_TYPE_MICROPHONE: Int = 100
        
        val INCOMING_CALL_NOTIFICATION_ID: Int = 101

        //region ACTIONS_* Constants
        /**
         * Action used with [VoiceFirebaseMessagingService] to notify of incoming calls
         */
        const val ACTION_CALL_INVITE: String = "ACTION_CALL_INVITE"

        //region ACTIONS_* Constants
        /**
         * Action used with [EXTRA_CALL_HANDLE] to cancel a call connection.
         */
        const val ACTION_CANCEL_CALL_INVITE: String = "ACTION_CANCEL_CALL_INVITE"

        /**
         * Action used with [EXTRA_DIGITS] to send digits to the [TVConnection] active call.
         */
        const val ACTION_SEND_DIGITS: String = "ACTION_SEND_DIGITS"

        /**
         * Action used to hangup an active call connection.
         */
        const val ACTION_HANGUP: String = "ACTION_HANGUP"

        /**
         * Action used to toggle the speakerphone state of an active call connection.
         */
        const val ACTION_TOGGLE_SPEAKER: String = "ACTION_TOGGLE_SPEAKER"

        /**
         * Action used to toggle bluetooth state of an active call connection.
         */
        const val ACTION_TOGGLE_BLUETOOTH: String = "ACTION_TOGGLE_BLUETOOTH"

        /**
         * Action used to toggle hold state of an active call connection.
         */
        const val ACTION_TOGGLE_HOLD: String = "ACTION_TOGGLE_HOLD"

        /**
         * Action used to toggle mute state of an active call connection.
         */
        const val ACTION_TOGGLE_MUTE: String = "ACTION_TOGGLE_MUTE"

        /**
         * Action used to answer an incoming call connection.
         */
        const val ACTION_ANSWER: String = "ACTION_ANSWER"

        /**
         * Action used to answer an incoming call connection.
         */
        const val ACTION_INCOMING_CALL: String = "ACTION_INCOMING_CALL"

        /**
         * Action used to place an outgoing call connection.
         * Additional parameters are required: [EXTRA_TOKEN], [EXTRA_TO] and [EXTRA_FROM]. Optionally, [EXTRA_OUTGOING_PARAMS] for bundled extra custom parameters.
         */
        const val ACTION_PLACE_OUTGOING_CALL: String = "ACTION_PLACE_OUTGOING_CALL"

        /**
         * Action used to poll the ConnectionService for the active call handle.
         */
        const val ACTION_ACTIVE_HANDLE: String = "ACTION_ACTIVE_HANDLE"
        //endregion

        //region EXTRA_* Constants
        /**
         * Extra used with [ACTION_SEND_DIGITS] to send digits to the [TVConnection] active call.
         */
        const val EXTRA_DIGITS: String = "EXTRA_DIGITS"

        /**
         * Extra used with [ACTION_CANCEL_CALL_INVITE] to cancel a call connection.
         */
        const val EXTRA_INCOMING_CALL_INVITE: String = "EXTRA_INCOMING_CALL_INVITE"

        /**
         * Extra used to identify a call connection.
         */
        const val EXTRA_CALL_HANDLE: String = "EXTRA_CALL_HANDLE"

        /**
         * Extra used with [ACTION_CANCEL_CALL_INVITE] to cancel a call connection
         */
        const val EXTRA_CANCEL_CALL_INVITE: String = "EXTRA_CANCEL_CALL_INVITE"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the Twilio Voice access token.
         */
        const val EXTRA_TOKEN: String = "EXTRA_TOKEN"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection, denotes the call parameters treated as a Bundle.
         */
        const val EXTRA_CONNECT_RAW: String = "EXTRA_CONNECT_RAW"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the recipient's identity.
         */
        const val EXTRA_TO: String = "EXTRA_TO"

        const val EXTRA_CALLER_NAME: String = "EXTRA_CALLER_NAME"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to place an outgoing call connection. Denotes the caller's identity.
         */
        const val EXTRA_FROM: String = "EXTRA_FROM"

        /**
         * Extra used with [ACTION_PLACE_OUTGOING_CALL] to send additional parameters to the [TVConnectionService] active call.
         */
        const val EXTRA_OUTGOING_PARAMS: String = "EXTRA_OUTGOING_PARAMS"

        /**
         * Extra used with [ACTION_TOGGLE_SPEAKER] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_SPEAKER_STATE: String = "EXTRA_SPEAKER_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_BLUETOOTH] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_BLUETOOTH_STATE: String = "EXTRA_BLUETOOTH_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_HOLD] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_HOLD_STATE: String = "EXTRA_HOLD_STATE"

        /**
         * Extra used with [ACTION_TOGGLE_MUTE] to send additional parameters to the [TVCallConnection] active call.
         */
        const val EXTRA_MUTE_STATE: String = "EXTRA_MUTE_STATE"
        //endregion

        fun hasActiveCalls(): Boolean {
            return activeConnections.isNotEmpty()
        }

        //clear active connections
        fun clearActiveConnections() {
            activeConnections.clear()
        }


        

        /**
         * Active call definition is extended to include calls in which one can actively communicate, or call is on hold, or call is ringing or dialing. This applies only to this and calling functions.
         * Gets the first ongoing call handle, if any. Else, gets the first call on hold. Lastly, gets the first call in either a ringing or dialing state, if any. Returns null if there are no active calls. If there are more than one active calls, the first call handle is returned.
         * Note: this might not necessarily correspond to the current active call.
         */
        fun getActiveCallHandle(): String? {
            if (!hasActiveCalls()) return null
            return activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_ACTIVE }?.key
                ?: activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_HOLDING }?.key
                ?: activeConnections.entries.firstOrNull { arrayListOf(Connection.STATE_RINGING, Connection.STATE_DIALING).contains(it.value.state) }?.key
        }

        fun getIncomingCallHandle(): String? {
            if (!hasActiveCalls()) return null
            return activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_RINGING }?.key
        }

        fun getConnection(callSid: String): TVCallConnection? {
            return activeConnections[callSid]
        }
    }

    // WakeLock to keep CPU awake during incoming call
    private var wakeLock: PowerManager.WakeLock? = null

    @SuppressLint("WakelockTimeout")
    private fun wakeScreen() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            
            // Acquire a partial wake lock to keep CPU running
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "TwilioVoice:IncomingCallWakeLock"
            )
            wakeLock?.acquire(60 * 1000L) // 60 seconds max
            
            Log.d(TAG, "[VoiceConnectionService] Wake lock acquired for incoming call")
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Failed to acquire wake lock: $e")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "[VoiceConnectionService] Wake lock released")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Failed to release wake lock: $e")
        }
    }


    private fun stopSelfSafe(): Boolean {
        if (!hasActiveCalls()) {
            stopSelf()
            return true
        } else {
            return false
        }
    }

    //region Service onStartCommand
    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Thread.currentThread().contextClassLoader = CallInvite::class.java.classLoader
        super.onStartCommand(intent, flags, startId)
        intent?.let {
            when (it.action) {
                ACTION_SEND_DIGITS -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_SEND_DIGITS is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val digits = it.getStringExtra(EXTRA_DIGITS) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_SEND_DIGITS is missing String EXTRA_DIGITS")
                        return@let
                    }

                    getConnection(callHandle)?.sendDigits(digits) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_SEND_DIGITS] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_CANCEL_CALL_INVITE -> {
                    // Load CancelledCallInvite class loader
                    // See: https://github.com/twilio/voice-quickstart-android/issues/561#issuecomment-1678613170
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    val cancelledCallInvite = it.getParcelableExtraSafe<CancelledCallInvite>(EXTRA_CANCEL_CALL_INVITE) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_CANCEL_CALL_INVITE is missing parcelable EXTRA_CANCEL_CALL_INVITE")
                        return@let
                    }

                    val callHandle = cancelledCallInvite.callSid
                    
                    // Cancel the incoming call notification
                    cancelIncomingCallNotification()
                    
                    getConnection(callHandle)?.onAbort() ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_CANCEL_CALL_INVITE] could not find connection for callHandle: $callHandle")
                    }
                    
                    // Stop foreground and self if no active calls
                    stopForegroundService()
                    stopSelfSafe()
                }

                ACTION_INCOMING_CALL -> {
                    // Load CallInvite class loader & get callInvite
                    val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE) ?: run {
                        Log.e(TAG, "onStartCommand: 'ACTION_INCOMING_CALL' is missing parcelable 'EXTRA_INCOMING_CALL_INVITE'")
                        return@let
                    }

                    // Wake the screen first - this is critical for terminated state
                    wakeScreen()

                    // Start foreground service first for Android O+
                    startIncomingCallForegroundService(callInvite)

                    // Bypass TelecomManager - handle incoming call directly without PhoneAccount
                    val mStorage: Storage = StorageImpl(applicationContext)
                    
                    // Get call parameters from invite
                    val callParams = TVCallInviteParametersImpl(mStorage, callInvite)
                    
                    // Create incoming call connection with required parameters
                    val connection = TVCallInviteConnection(applicationContext, callInvite, callParams)
                    
                    val callSid = callInvite.callSid
                    
                    // Apply parameters and attach listeners
                    applyParameters(connection, callParams, callInvite.from ?: "")
                    attachCallEventListeners(connection, callSid)
                    
                    // Set call disconnected listener
                    val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                        if (activeConnections.containsKey(callSid)) {
                            activeConnections.remove(callSid)
                        }
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, connection.extras)
                        cancelIncomingCallNotification()
                        releaseWakeLock()
                        stopForegroundService()
                        stopSelfSafe()
                    }
                    connection.setOnCallDisconnected(onCallDisconnectedListener)
                    
                    // Notify about incoming call
                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_INCOMING_CALL, callSid, connection.extras)
                    sendBroadcastCallHandle(applicationContext, callSid)
                    
                    // Directly launch IncomingCallActivity - use a short delay to ensure foreground service is ready
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        try {
                            val incomingCallIntent = IncomingCallActivity.createIntent(applicationContext, callInvite)
                            incomingCallIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            applicationContext.startActivity(incomingCallIntent)
                            Log.d(TAG, "onStartCommand: IncomingCallActivity launched successfully")
                        } catch (e: Exception) {
                            Log.w(TAG, "Could not start IncomingCallActivity directly, relying on notification: ${e.message}")
                        }
                    }, 100)
                    
                    Log.d(TAG, "onStartCommand: Direct incoming call handled - callSid: $callSid")
                }

                ACTION_ANSWER -> {
                    // Set classloader for CallInvite deserialization
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getIncomingCallHandle()
                    var connection = if (callHandle != null) getConnection(callHandle) else null
                    
                    // If connection not found, try to recover from CallInvite in intent (terminated state case)
                    if (connection == null) {
                        val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE)
                        if (callInvite != null) {
                            Log.i(TAG, "onStartCommand: [ACTION_ANSWER] Recovering connection from CallInvite for terminated state")
                            // Start foreground service first
                            startIncomingCallForegroundService(callInvite)
                            
                            // Create and register the connection
                            val mStorage: Storage = StorageImpl(applicationContext)
                            val callParams = TVCallInviteParametersImpl(mStorage, callInvite)
                            val newConnection = TVCallInviteConnection(applicationContext, callInvite, callParams)
                            val callSid = callInvite.callSid
                            
                            applyParameters(newConnection, callParams, callInvite.from ?: "")
                            attachCallEventListeners(newConnection, callSid)
                            
                            // Set disconnect listener
                            val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                                if (activeConnections.containsKey(callSid)) {
                                    activeConnections.remove(callSid)
                                }
                                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, newConnection.extras)
                                cancelIncomingCallNotification()
                                releaseWakeLock()
                                stopForegroundService()
                                stopSelfSafe()
                            }
                            newConnection.setOnCallDisconnected(onCallDisconnectedListener)
                            
                            connection = newConnection
                        } else {
                            Log.e(TAG, "onStartCommand: [ACTION_ANSWER] could not find connection and no CallInvite in intent")
                            return@let
                        }
                    }

                    // Cancel incoming call notification
                    cancelIncomingCallNotification()
                    releaseWakeLock()

                    if(connection is TVCallInviteConnection) {
                        // Check for RECORD_AUDIO permission before accepting
                        if (!applicationContext.hasMicrophoneAccess()) {
                            Log.e(TAG, "onStartCommand: [ACTION_ANSWER] Missing RECORD_AUDIO permission, launching activity for permission")
                            // Store the call invite for later and launch activity to request permission
                            val callInviteFromConnection = (connection as TVCallInviteConnection).callInvite
                            val callSid = connection.getCallParameters()?.callSid ?: callInviteFromConnection.callSid
                            
                            // Launch main activity with permission request flag
                            try {
                                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                                launchIntent?.let { intent ->
                                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                                                   Intent.FLAG_ACTIVITY_CLEAR_TOP or 
                                                   Intent.FLAG_ACTIVITY_SINGLE_TOP
                                    intent.putExtra("fromIncomingCall", true)
                                    intent.putExtra("callHandle", callSid)
                                    intent.putExtra("needsMicrophonePermission", true)
                                    intent.putExtra(EXTRA_INCOMING_CALL_INVITE, callInviteFromConnection)
                                    startActivity(intent)
                                    Log.d(TAG, "Launched main activity for microphone permission request")
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "Could not launch main activity for permission: ${e.message}")
                            }
                            
                            // Send event to Flutter to request permission and then answer
                            sendBroadcastEvent(applicationContext, TVNativeCallEvents.EVENT_PERMISSION_REQUIRED, callSid, Bundle().apply {
                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                                putString("permission", "RECORD_AUDIO")
                            })
                            return@let
                        }
                        
                        connection.acceptInvite()
                        
                        val callSid = connection.getCallParameters()?.callSid ?: callHandle ?: ""
                        
                        // Send connected event after answering
                        val params = connection.getCallParameters()
                        sendBroadcastEvent(applicationContext, TVNativeCallEvents.EVENT_CONNECTED, callSid, Bundle().apply {
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                            putString(TVBroadcastReceiver.EXTRA_CALL_FROM, params?.fromRaw ?: "")
                            putString(TVBroadcastReceiver.EXTRA_CALL_TO, params?.toRaw ?: "")
                            putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, CallDirection.INCOMING.id)
                        })
                        
                        // Launch main activity after answering from notification
                        // Use Handler to give foreground service time to establish before launching activity
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            try {
                                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                                launchIntent?.let { intent ->
                                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                                                   Intent.FLAG_ACTIVITY_CLEAR_TOP or 
                                                   Intent.FLAG_ACTIVITY_SINGLE_TOP
                                    intent.putExtra("fromIncomingCall", true)
                                    intent.putExtra("callHandle", callSid)
                                    startActivity(intent)
                                    Log.d(TAG, "Launched main activity after answering call")
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Could not launch main activity after answering: ${e.message}")
                            }
                        }, 200)
                    } else {
                        Log.e(TAG, "onStartCommand: [ACTION_ANSWER] connection is not TVCallInviteConnection")
                    }
                }

                ACTION_HANGUP -> {
                    // Set classloader for CallInvite deserialization
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_HANGUP is missing String EXTRA_CALL_HANDLE")
                        activeConnections.clear()
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, null, null)
                        stopForegroundService()
                        stopSelfSafe()
                        return@let
                    }

                    Log.i(TAG, "[Decline] Received ACTION_HANGUP for callHandle: $callHandle. Active connections: ${activeConnections.keys}")
                    cancelIncomingCallNotification()
                    releaseWakeLock()

                    var connection = getConnection(callHandle)
                    
                    // If connection not found, try to recover from CallInvite in intent (terminated state case)
                    if (connection == null) {
                        val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE)
                        if (callInvite != null) {
                            Log.i(TAG, "[Decline] Recovering CallInvite from intent for terminated state reject")
                            // Directly reject the invite without creating a connection
                            callInvite.reject(applicationContext)
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, null)
                            stopForegroundService()
                            stopSelfSafe()
                            return@let
                        } else {
                            Log.e(TAG, "[Decline] No connection found and no CallInvite in intent for $callHandle. Forcing cleanup.")
                            activeConnections.clear()
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, null)
                        }
                    } else {
                        Log.i(TAG, "[Decline] Found connection for $callHandle, state=${connection.state}")
                        connection.forceDisconnectWithLogging()
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, connection.extras)
                        activeConnections.remove(callHandle)
                    }
                    stopForegroundService()
                    stopSelfSafe()
                }

                ACTION_PLACE_OUTGOING_CALL -> {

                    val rawConnect = it.getBooleanExtra(EXTRA_CONNECT_RAW, false)

                    fun getRequiredString(key: String, allowNullIfRaw: Boolean = false): String? {
                        val value = it.getStringExtra(key)
                        if (value == null) {
                            Log.e(TAG, "onStartCommand: ACTION_PLACE_OUTGOING_CALL is missing String $key")
                            if (!rawConnect || !allowNullIfRaw) return null
                        }
                        return value
                    }

                    val token = getRequiredString(EXTRA_TOKEN) ?: return@let
                    val to = getRequiredString(EXTRA_TO, allowNullIfRaw = true)
                    val from = getRequiredString(EXTRA_FROM, allowNullIfRaw = true)
                    val outgoingName = getRequiredString(EXTRA_CALLER_NAME, allowNullIfRaw = true)
                    val params = buildMap {
                        it.getParcelableExtraSafe<Bundle>(EXTRA_OUTGOING_PARAMS)?.let { bundle ->
                            for (key in bundle.keySet()) {
                                bundle.getString(key)?.let { value -> put(key, value) }
                            }
                        }
                        put(EXTRA_TOKEN, token)
                        put(EXTRA_CALLER_NAME, outgoingName)
                        if (!rawConnect) {
                            to?.let { v -> put(EXTRA_TO, v) }
                            from?.let { v -> put(EXTRA_FROM, v) }
                        }
                    }

                    val myBundle = Bundle().apply {
                        putBundle(EXTRA_OUTGOING_PARAMS, Bundle().apply {
                            params.forEach { (key, value) -> putString(key, value) }
                        })
                    }

                    // Bypass TelecomManager - directly create Twilio Voice call
                    // This avoids the need for PhoneAccount registration/enablement
                    
                    if (!applicationContext.hasMicrophoneAccess()) {
                        Log.e(TAG, "onStartCommand: Missing RECORD_AUDIO permission")
                        return@let
                    }

                    // Create call parameters
                    val callParams = HashMap<String, String>()
                    if (from != null) callParams["From"] = from
                    if (to != null) callParams["To"] = to
                    
                    // Add extra params
                    it.getParcelableExtraSafe<Bundle>(EXTRA_OUTGOING_PARAMS)?.let { bundle ->
                        for (key in bundle.keySet()) {
                            bundle.getString(key)?.let { value -> 
                                if (key != EXTRA_TOKEN && key != EXTRA_TO && key != EXTRA_FROM) {
                                    callParams[key] = value 
                                }
                            }
                        }
                    }

                    // Create connect options
                    val connectOptions = ConnectOptions.Builder(token)
                        .params(callParams)
                        .build()

                    // Create outgoing connection without TelecomManager
                    val connection = TVCallConnection(applicationContext)
                    
                    // Create storage instance for call parameters
                    val mStorage: Storage = StorageImpl(applicationContext)

                    // Set call state listener BEFORE connecting
                    val onCallStateListener: CompletionHandler<Call.State> = CompletionHandler { state ->
                        if (state == Call.State.RINGING || state == Call.State.CONNECTED) {
                            val call = connection.twilioCall!!
                            val callSid = call.sid!!

                            // Resolve call parameters
                            val tvCallParams = TVCallParametersImpl(mStorage, call, to ?: "", from ?: "", callParams)
                            connection.setCallParameters(tvCallParams)

                            // If call is not attached, attach it
                            if (!activeConnections.containsKey(callSid)) {
                                applyParameters(connection, tvCallParams, outgoingName ?: "")
                                attachCallEventListeners(connection, callSid)
                                tvCallParams.callSid = callSid
                                
                                // Manually send the ringing/connected event since onEvent was null when it first fired
                                val event = if (state == Call.State.RINGING) TVNativeCallEvents.EVENT_RINGING else TVNativeCallEvents.EVENT_CONNECTED
                                sendBroadcastEvent(applicationContext, event, callSid, Bundle().apply {
                                    putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_FROM, tvCallParams.fromRaw)
                                    putString(TVBroadcastReceiver.EXTRA_CALL_TO, tvCallParams.toRaw)
                                    putInt(TVBroadcastReceiver.EXTRA_CALL_DIRECTION, CallDirection.OUTGOING.id)
                                })
                                // Also send call handle broadcast
                                sendBroadcastCallHandle(applicationContext, callSid)
                            }
                        }
                    }

                    // Set call disconnected listener BEFORE connecting
                    val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                        connection.twilioCall?.let { call ->
                            if (activeConnections.containsKey(call.sid)) {
                                activeConnections.remove(call.sid)
                            }
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, call.sid ?: "", connection.extras)
                            stopForegroundService()
                            stopSelfSafe()
                        }
                    }

                    // Set listeners BEFORE calling Voice.connect
                    connection.setOnCallStateListener(onCallStateListener)
                    connection.setOnCallDisconnected(onCallDisconnectedListener)
                    
                    // Now connect with Voice SDK
                    connection.twilioCall = Voice.connect(applicationContext, connectOptions, connection)

                    Log.d(TAG, "onStartCommand: Direct Twilio Voice call initiated")
                }

                ACTION_TOGGLE_BLUETOOTH -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_BLUETOOTH is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val bluetoothState = it.getBooleanExtra(EXTRA_BLUETOOTH_STATE, false)

                    getConnection(callHandle)?.toggleBluetooth(bluetoothState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_BLUETOOTH] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_HOLD -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_HOLD is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val holdState = it.getBooleanExtra(EXTRA_HOLD_STATE, false)

                    getConnection(callHandle)?.toggleHold(holdState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_HOLD] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_MUTE -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_MUTE is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val muteState = it.getBooleanExtra(EXTRA_MUTE_STATE, false)

                    getConnection(callHandle)?.toggleMute(muteState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_MUTE] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_TOGGLE_SPEAKER -> {
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_TOGGLE_SPEAKER is missing String EXTRA_CALL_HANDLE")
                        return@let
                    }
                    val speakerState = it.getBooleanExtra(EXTRA_SPEAKER_STATE, false)
                    getConnection(callHandle)?.toggleSpeaker(speakerState) ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_TOGGLE_SPEAKER] could not find connection for callHandle: $callHandle")
                    }
                }

                ACTION_ACTIVE_HANDLE -> {
                    val activeCallHandle = getActiveCallHandle()
                    sendBroadcastCallHandle(applicationContext, activeCallHandle)
                }

                else -> {
                    Log.e(TAG, "onStartCommand: unknown action: ${it.action}")
                }
            }
        } ?: run {
            Log.e(TAG, "onStartCommand: intent is null")
        }
        return START_STICKY
    }
    //endregion

    override fun onCreateIncomingConnection(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        assert(request != null) { "ConnectionRequest cannot be null" }
        assert(connectionManagerPhoneAccount != null) { "ConnectionManagerPhoneAccount cannot be null" }

        super.onCreateIncomingConnection(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateIncomingConnection")

        val extras = request?.extras
        val myBundle: Bundle = extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS) ?: run {
            Log.e(TAG, "onCreateIncomingConnection: request is missing Bundle EXTRA_INCOMING_CALL_EXTRAS")
            throw Exception("onCreateIncomingConnection: request is missing Bundle EXTRA_INCOMING_CALL_EXTRAS");
        }

        myBundle.classLoader = CallInvite::class.java.classLoader
        val ci: CallInvite = myBundle.getParcelableSafe(EXTRA_INCOMING_CALL_INVITE) ?: run {
            Log.e(TAG, "onCreateIncomingConnection: request is missing CallInvite EXTRA_INCOMING_CALL_INVITE")
            throw Exception("onCreateIncomingConnection: request is missing CallInvite EXTRA_INCOMING_CALL_INVITE");
        }

        // Create storage instance for call parameters
        val storage: Storage = StorageImpl(applicationContext)

        // Resolve call parameters
        val callParams: TVParameters = TVCallInviteParametersImpl(storage, ci);

        // Create connection
        val connection = TVCallInviteConnection(applicationContext, ci, callParams)

        // Remove call invite from extras, causes marshalling error i.e. Class not found.
        val requestBundle = request.extras.also { it ->
            it.remove(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
        }
        connection.extras = requestBundle

        // Setup connection event listeners and UI parameters
        attachCallEventListeners(connection, ci.callSid)
        applyParameters(connection, callParams,null)
        connection.setRinging()

        startForegroundService()
        return connection
    }

    override fun onCreateOutgoingConnection(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        assert(request != null) { "ConnectionRequest cannot be null" }
        assert(connectionManagerPhoneAccount != null) { "ConnectionManagerPhoneAccount cannot be null" }

        super.onCreateOutgoingConnection(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateOutgoingConnection")

        val extras = request?.extras
        val myBundle: Bundle = extras?.getBundle(EXTRA_OUTGOING_PARAMS) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: request is missing Bundle EXTRA_OUTGOING_PARAMS")
            throw Exception("onCreateOutgoingConnection: request is missing Bundle EXTRA_OUTGOING_PARAMS");
        }

        // check required EXTRA_TOKEN, EXTRA_TO, EXTRA_FROM
        val token: String = myBundle.getString(EXTRA_TOKEN) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TOKEN")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TOKEN");
        }
        val to = myBundle.getString(EXTRA_TO) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TO")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_TO");
        }
        val from = myBundle.getString(EXTRA_FROM) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM");
        }

        val outGoingCallerName = myBundle.getString(EXTRA_CALLER_NAME) ?: run {
            Log.e(TAG, "onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_FROM")
            throw Exception("onCreateOutgoingConnection: ACTION_PLACE_OUTGOING_CALL is missing String EXTRA_CALLER_NAME");
        }

        // Get all params from bundle
        val params = HashMap<String, String>()
        myBundle.keySet().forEach { key ->
            when (key) {
                EXTRA_TO, EXTRA_FROM, EXTRA_TOKEN -> {}
                else -> {
                    myBundle.getString(key)?.let { value ->
                        params[key] = value
                    }
                }
            }
        }
        params["From"] = from
        params["To"] = to

        // create connect options
        val connectOptions = ConnectOptions.Builder(token)
            .params(params)
            .build()

        // create outgoing connection
        val connection = TVCallConnection(applicationContext)

        // create Voice SDK call
        connection.twilioCall = Voice.connect(applicationContext, connectOptions, connection)

        // create storage instance for call parameters
        val mStorage: Storage = StorageImpl(applicationContext)

        // Set call state listener, applies non-temporary Call SID when call is ringing or connected (i.e. when assigned by Twilio)
        val onCallStateListener: CompletionHandler<Call.State> = CompletionHandler { state ->
            if (state == Call.State.RINGING || state == Call.State.CONNECTED) {
                val call = connection.twilioCall!!
                val callSid = call.sid!!

                // Resolve call parameters
                val callParams = TVCallParametersImpl(mStorage, call, to, from, params)
                connection.setCallParameters(callParams)

                // If call is not attached, attach it
                if (!activeConnections.containsKey(callSid)) {
                    applyParameters(connection, callParams,outGoingCallerName )
                    attachCallEventListeners(connection, callSid)
                    callParams.callSid = callSid
                }
            }
        }


        // Set call disconnected listener, removes connection from active connections when call is disconnected
        val onCallInitializingDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
            connection.twilioCall?.let {
                if (activeConnections.containsKey(it.sid)) {
                    activeConnections.remove(it.sid)
                }
                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, it.sid ?: "", connection.extras)
                stopForegroundService()
                stopSelfSafe()
            }
        }

        // NOTE(cybex-dev): This could be used as an alternative to the [onCallInitializingDisconnectedListener],
        // however in the case of a call being initialized followed by a local disconnect - the call only has a temporary SID.
        // The call SID is set in the [attachCallEventListeners] method when the call is in a RINGING or CONNECTED state.
        // Thus, using [onEvent] will pass through a null call handle which may not be a good design.
//        val onEvent: ValueBundleChanged<String> = ValueBundleChanged { event: String?, extra: Bundle? ->
//            if(event == TVBroadcastReceiver.ACTION_CALL_ENDED) {
//                val callSid = connection.twilioCall?.sid;
//                sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
//                // This is a temporary solution since `isOnCall` returns true when there is an active ConnectionService, regardless of the source app. This also applies to SIM/Telecom calls.
//                sendBroadcastCallHandle(applicationContext, extra?.getString(TVBroadcastReceiver.EXTRA_CALL_HANDLE))
//            }
//        }

        connection.setOnCallStateListener(onCallStateListener)
        connection.setOnCallDisconnected(onCallInitializingDisconnectedListener)
//        connection.setOnCallEventListener(onEvent)

        // Setup connection UI parameters
        connection.setInitializing()

        // Apply extras
        connection.extras = request.extras

        startForegroundService()

        return connection
    }

    /**
     * Attach call event listeners to the given connection. This includes responding to call events, call actions and when call has ended.
     * @param connection The connection to attach the listeners to.
     * @param callSid The call SID of the connection.
     */
    private fun <T: TVCallConnection> attachCallEventListeners(connection: T, callSid: String) {

        val onAction: ValueBundleChanged<String> = ValueBundleChanged { event: String?, extra: Bundle? ->
            sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
        }

        val onEvent: ValueBundleChanged<String> = ValueBundleChanged { event: String?, extra: Bundle? ->
            sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
            // This is a temporary solution since `isOnCall` returns true when there is an active ConnectionService, regardless of the source app. This also applies to SIM/Telecom calls.
            sendBroadcastCallHandle(applicationContext, extra?.getString(TVBroadcastReceiver.EXTRA_CALL_HANDLE))
        }
        val onDisconnect: CompletionHandler<DisconnectCause> = CompletionHandler {
            if (activeConnections.containsKey(callSid)) {
                activeConnections.remove(callSid)
            }
            stopForegroundService()
            stopSelfSafe()
        }
        val onCallState: CompletionHandler<Call.State> = CompletionHandler { state ->
            if (state == Call.State.DISCONNECTED) {
                if (activeConnections.containsKey(callSid)) {
                    activeConnections.remove(callSid)
                }
                stopForegroundService()
                stopSelfSafe()
            }
        }

        // Add to local connection cache
        activeConnections[callSid] = connection

        // attach listeners
        connection.setOnCallActionListener(onAction)
        connection.setOnCallEventListener(onEvent)
        connection.setOnCallDisconnected(onDisconnect)
        connection.setOnCallStateListener(onCallState);
    }

    /**
     * Apply the given parameters to the given connection. This sets the address, caller display name and subject, any and all if present.
     * @param connection The connection to apply the parameters to.
     * @param params The parameters to apply to the connection.
     */
    private fun <T: TVCallConnection> applyParameters(connection: T, params: TVParameters, outgoingCallerName: String?) {
        params.getExtra(TVParameters.PARAM_SUBJECT, null)?.let {
            connection.extras.putString(TelecomManager.EXTRA_CALL_SUBJECT, it)
        }
        val name = if(connection.callDirection == CallDirection.OUTGOING) params.to else params.from

        val userName =  params.customParameters["client_name"]
        val userNumber = extractUserNumber(name)

        if(connection.callDirection == CallDirection.OUTGOING){

            connection.setAddress(Uri.fromParts(PhoneAccount.SCHEME_TEL, name, null), TelecomManager.PRESENTATION_ALLOWED)
            connection.setCallerDisplayName(outgoingCallerName, TelecomManager.PRESENTATION_ALLOWED)
        } else {
            connection.setAddress(Uri.fromParts(PhoneAccount.SCHEME_TEL, userNumber, null), TelecomManager.PRESENTATION_ALLOWED)
            connection.setCallerDisplayName(userName, TelecomManager.PRESENTATION_ALLOWED)
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


    private fun sendBroadcastEvent(ctx: Context, event: String, callSid: String?, extras: Bundle? = null) {
        Intent(ctx, TVBroadcastReceiver::class.java).apply {
            action = event
            putExtra(EXTRA_CALL_HANDLE, callSid)
            extras?.let { putExtras(it) }
            LocalBroadcastManager.getInstance(ctx).sendBroadcast(this)
        }
    }

    private fun sendBroadcastCallHandle(ctx: Context, callSid: String?) {
        Log.d(TAG, "sendBroadcastCallHandle: ${if (callSid != null) "On call" else "Not on call"}}")
        Intent(ctx, TVBroadcastReceiver::class.java).apply {
            action = TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED
            putExtra(EXTRA_CALL_HANDLE, callSid)
            LocalBroadcastManager.getInstance(ctx).sendBroadcast(this)
        }
    }

    override fun onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?) {
        super.onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateOutgoingConnectionFailed")
        println("Call error happened  basil")
        //clear the active connections
        activeConnections.clear()
        stopForegroundService()
    }

    override fun onCreateIncomingConnectionFailed(connectionManagerPhoneAccount: PhoneAccountHandle?, request: ConnectionRequest?) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        Log.d(TAG, "onCreateIncomingConnectionFailed")
        stopForegroundService()
    }

    private fun getOrCreateChannel(): NotificationChannel {
        val id = "${applicationContext.packageName}_calls"
        val name = applicationContext.appName
        val descriptionText = "Active Voice Calls"
        val importance = NotificationManager.IMPORTANCE_NONE
        val channel = NotificationChannel(id, name, importance).apply {
            description = descriptionText
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
        return channel
    }

    private fun createNotification(): Notification {
        val channel = getOrCreateChannel()

        val intent = Intent(applicationContext, TVConnectionService::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        val pendingIntent: PendingIntent = PendingIntent.getActivity(applicationContext, 0, intent, flag);

        return Notification.Builder(this, channel.id).apply {
            setOngoing(true)
            setContentTitle("Voice Calls")
            setCategory(Notification.CATEGORY_SERVICE)
            setContentIntent(pendingIntent)
            setSmallIcon(R.drawable.ic_microphone)
        }.build()
    }

    private fun cancelNotification() {
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(SERVICE_TYPE_MICROPHONE)
    }

    /// Source: https://github.com/react-native-webrtc/react-native-callkeep/blob/master/android/src/main/java/io/wazo/callkeep/VoiceConnectionService.java#L295
    private fun startForegroundService() {
        val notification = createNotification()
        Log.d(TAG, "[VoiceConnectionService] Starting foreground service")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Optional for Android +11, required for Android +14
                startForeground(SERVICE_TYPE_MICROPHONE, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(SERVICE_TYPE_MICROPHONE, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Can't start foreground service : $e")
        }
    }

    /// Source: https://github.com/react-native-webrtc/react-native-callkeep/blob/master/android/src/main/java/io/wazo/callkeep/VoiceConnectionService.java#L352C5-L377C6
    private fun stopForegroundService() {
        Log.d(TAG, "[VoiceConnectionService] stopForegroundService")
        try {
            stopForeground(SERVICE_TYPE_MICROPHONE)
            cancelNotification()
        } catch (e: java.lang.Exception) {
            Log.w(TAG, "[VoiceConnectionService] can't stop foreground service :$e")
        }
    }

    private fun getOrCreateIncomingCallChannel(): NotificationChannel {
        val id = "${applicationContext.packageName}_incoming_calls_v2"
        val name = "Incoming Calls"
        val descriptionText = "Incoming Voice Calls"
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        // Delete old channel if exists (in case importance was wrong)
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls")
        
        // IMPORTANCE_HIGH is required for full-screen intent to work in terminated state
        val importance = NotificationManager.IMPORTANCE_HIGH
        val channel = NotificationChannel(id, name, importance).apply {
            description = descriptionText
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null) // No sound from notification, activity will handle it
            enableVibration(false)
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
        return channel
    }

    private fun createIncomingCallNotification(callInvite: CallInvite): Notification {
        val channel = getOrCreateIncomingCallChannel()
        
        // Create full-screen intent for incoming call activity
        val fullScreenIntent = IncomingCallActivity.createIntent(applicationContext, callInvite)
        val fullScreenPendingIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            fullScreenIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Create answer intent - include CallInvite for terminated state recovery
        val answerIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = ACTION_ANSWER
            putExtra(EXTRA_CALL_HANDLE, callInvite.callSid)
            putExtra(EXTRA_INCOMING_CALL_INVITE, callInvite)
        }
        val answerPendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                applicationContext,
                1,
                answerIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                applicationContext,
                1,
                answerIntent,
                PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Create decline intent - include CallInvite for terminated state recovery
        val declineIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = ACTION_HANGUP
            putExtra(EXTRA_CALL_HANDLE, callInvite.callSid)
            putExtra(EXTRA_INCOMING_CALL_INVITE, callInvite)
        }
        val declinePendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                applicationContext,
                2,
                declineIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                applicationContext,
                2,
                declineIntent,
                PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Extract caller info
        val callerName = callInvite.customParameters["client_name"] ?: "Unknown Caller"
        
        // Create an intent that launches IncomingCallActivity with answer action
        val answerActivityIntent = Intent(applicationContext, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(IncomingCallActivity.EXTRA_CALL_SID, callInvite.callSid)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra("action", "answer")
        }
        val answerActivityPendingIntent = PendingIntent.getActivity(
            applicationContext,
            3,
            answerActivityIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        // Use CallStyle for Android 12+ for native incoming call UI in notification
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ - Use CallStyle for proper call notification
            val person = android.app.Person.Builder()
                .setName(callerName)
                .setImportant(true)
                .build()
            
            Notification.Builder(this, channel.id).apply {
                setSmallIcon(R.drawable.ic_microphone)
                setContentTitle("Incoming Call")
                setContentText(callerName)
                setCategory(Notification.CATEGORY_CALL)
                setVisibility(Notification.VISIBILITY_PUBLIC)
                setOngoing(true)
                setAutoCancel(false)
                setFullScreenIntent(fullScreenPendingIntent, true)
                setContentIntent(fullScreenPendingIntent)
                setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                // Use CallStyle for proper incoming call notification
                // answerActivityPendingIntent launches activity that answers and opens app
                // declinePendingIntent sends hangup to service
                style = Notification.CallStyle.forIncomingCall(
                    person,
                    declinePendingIntent,
                    answerActivityPendingIntent
                )
            }
        } else {
            // Pre-Android 12 - Use regular notification with actions
            Notification.Builder(this, channel.id).apply {
                setOngoing(true)
                setContentTitle("Incoming Call")
                setContentText(callerName)
                setCategory(Notification.CATEGORY_CALL)
                setSmallIcon(R.drawable.ic_microphone)
                setFullScreenIntent(fullScreenPendingIntent, true)
                setContentIntent(fullScreenPendingIntent)
                setVisibility(Notification.VISIBILITY_PUBLIC)
                setAutoCancel(false)
                // Add answer and decline actions
                addAction(Notification.Action.Builder(
                    android.R.drawable.ic_menu_call,
                    "Answer",
                    answerPendingIntent
                ).build())
                addAction(Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Decline",
                    declinePendingIntent
                ).build())
                // Priority for pre-Oreo devices
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    @Suppress("DEPRECATION")
                    setPriority(Notification.PRIORITY_MAX)
                }
            }
        }
        return builder.build()
    }

    private fun startIncomingCallForegroundService(callInvite: CallInvite) {
        val notification = createIncomingCallNotification(callInvite)
        Log.d(TAG, "[VoiceConnectionService] Starting incoming call foreground service")
        try {
            // For incoming call notification (before answering), use PHONE_CALL type only
            // MICROPHONE type requires RECORD_AUDIO permission to be granted at runtime
            // which may not be available yet when showing the incoming call UI
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14+ - use PHONE_CALL type
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification, 
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10-13 - use SHORT_SERVICE or default
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
            } else {
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Can't start incoming call foreground service : $e")
            // Fallback: try without specific service type
            try {
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "[VoiceConnectionService] Fallback foreground service also failed: $e2")
            }
        }
    }

    private fun cancelIncomingCallNotification() {
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(INCOMING_CALL_NOTIFICATION_ID)
    }
}

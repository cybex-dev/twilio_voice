package com.twilio.twilio_voice.service

import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.telecom.*
import android.util.Log
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
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
        
        // Track the start time of each call for notification Chronometer.
        // When a held call resumes, we use the original start time instead of
        // System.currentTimeMillis() so the timer doesn't reset to 00:00.
        val callStartTimes = HashMap<String, Long>()

        val TWI_SCHEME: String = "twi"

        val SERVICE_TYPE_MICROPHONE: Int = 100
        
        // Call waiting state - tracks active call info when a second call arrives
        @Volatile
    var hasActiveCallDuringIncoming: Boolean = false
    @Volatile
    var activeCallCallerName: String = ""
    @Volatile
    var activeCallCallerNumber: String = ""
    @Volatile
    var activeCallHandleDuringIncoming: String? = null
    // Logging counters
    @Volatile
    var log_callClaimCounter: Int = 0
    @Volatile
    var log_incomingCallClaimCounter: Int = 0
    @Volatile
    var log_callWaitingCounter: Int = 0
        
        fun clearCallWaitingState() {
            hasActiveCallDuringIncoming = false
            activeCallCallerName = ""
            activeCallCallerNumber = ""
            activeCallHandleDuringIncoming = null
        }
        
        val INCOMING_CALL_NOTIFICATION_ID: Int = 101
        
        val ONGOING_CALL_NOTIFICATION_ID: Int = 102

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
         * Action used to swap active and held calls atomically.
         */
        const val ACTION_SWAP_CALLS: String = "ACTION_SWAP_CALLS"

        /**
         * Action used to toggle mute state of an active call connection.
         */
        const val ACTION_TOGGLE_MUTE: String = "ACTION_TOGGLE_MUTE"

        /**
         * Action used to answer an incoming call connection.
         */
        const val ACTION_ANSWER: String = "ACTION_ANSWER"

        /**
         * Action used to answer an incoming call while putting the active call on hold.
         */
        const val ACTION_ANSWER_WITH_HOLD: String = "ACTION_ANSWER_WITH_HOLD"

        /**
         * Action used to answer an incoming call after ending the active call.
         */
        const val ACTION_ANSWER_WITH_END_FIRST: String = "ACTION_ANSWER_WITH_END_FIRST"

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

        /**
         * SharedPreferences key for tracking pending incoming call.
         * Using SharedPreferences instead of static variable for reliability across threads/processes.
         */
        private const val PREFS_NAME = "twilio_voice_call_state"
        private const val PREF_PENDING_CALL_SID = "pending_incoming_call_sid"
        private const val PREF_PENDING_CALL_TIMESTAMP = "pending_incoming_call_timestamp"
        private const val PENDING_CALL_TIMEOUT_MS = 60000L // 60 seconds timeout for pending calls

        /**
         * Tracks pending incoming call invite that is being processed but not yet fully connected.
         * This is used to detect and reject simultaneous incoming calls before the connection
         * is added to activeConnections.
         * Also kept in memory for faster access within same process.
         */
        @Volatile
        private var pendingIncomingCallSid: String? = null

        /**
         * Check if there's an active call OR a pending incoming call being processed.
         * This prevents race conditions where a second call arrives before the first
         * call's connection is added to activeConnections.
         * Also checks the isProcessingIncomingCall flag for very fast checks.
         */
        fun hasActiveOrPendingCall(): Boolean {
            val hasActive = activeConnections.isNotEmpty()
            val hasPending = pendingIncomingCallSid != null
            val isProcessing = isProcessingIncomingCall && 
                (System.currentTimeMillis() - processingStartTime) < PROCESSING_TIMEOUT_MS
            
            Log.d(TAG, "hasActiveOrPendingCall: hasActive=$hasActive, hasPending=$hasPending, isProcessing=$isProcessing")
            return hasActive || hasPending || isProcessing
        }
        
        /**
         * ATOMIC check-and-set for FCM-level call processing.
         * Called from onMessageReceived BEFORE Voice.handleMessage().
         * This immediately sets the processing flag so that a second FCM 
         * arriving near-simultaneously will see it and be blocked.
         * 
         * @return true if this FCM should be processed (no other call in progress)
         *         false if this FCM should be blocked (another call exists)
         */
        @Synchronized
        fun tryClaimFcmMessage(context: Context): Boolean {
            log_callClaimCounter++
            Log.d(TAG, "[LOG] tryClaimFcmMessage CALLED. log_callClaimCounter=$log_callClaimCounter")
            synchronized(incomingCallLock) {
                val timestamp = System.currentTimeMillis()
                Log.d(TAG, "[tryClaimFcmMessage] Checking at $timestamp on thread ${Thread.currentThread().name}")
                
                // Check if there's a truly answered/connected call (not just ringing)
                val hasAnsweredCall = activeConnections.values.any { 
                    it.state == Connection.STATE_ACTIVE || it.state == Connection.STATE_HOLDING 
                }
                
                // Block only if there's an answered call AND a pending ringing call
                // (= already 2 calls in progress, can't handle a 3rd)
                if (hasAnsweredCall && pendingIncomingCallSid != null) {
                    Log.w(TAG, "[tryClaimFcmMessage] ❌ Answered call AND pending call both exist - blocking 3rd call")
                    return false
                }
                
                // For all other cases, let the FCM through to Voice.handleMessage → onCallInvite.
                // The tryClaimIncomingCall() in onCallInvite will properly handle:
                //   - Ringing call + new call → reject with callInvite.reject() (caller hears busy)
                //   - Answered call + new call → allow for call waiting (bottom sheet)
                //   - Same call re-claim → allow
                //   - No existing call → claim normally
                
                // Set processing flag if not already set (for the first call)
                if (!isProcessingIncomingCall) {
                    isProcessingIncomingCall = true
                    processingStartTime = timestamp
                    Log.d(TAG, "[tryClaimFcmMessage] ✓ CLAIMED FCM processing slot at $timestamp")
                } else {
                    Log.d(TAG, "[tryClaimFcmMessage] ℹ️ Processing flag already set, allowing through for proper handling in onCallInvite")
                }
                return true
            }
        }
        
        /**
         * Release the FCM processing claim if Voice.handleMessage returned false
         * (meaning it wasn't a valid Twilio message, so no onCallInvite will follow).
         */
        fun releaseFcmClaim() {
            synchronized(incomingCallLock) {
                // Only release if no pending call has been set yet
                // (if pendingIncomingCallSid is set, onCallInvite already ran)
                if (pendingIncomingCallSid == null) {
                    Log.d(TAG, "[releaseFcmClaim] Releasing FCM claim (no pending call)")
                    isProcessingIncomingCall = false
                    processingStartTime = 0
                } else {
                    Log.d(TAG, "[releaseFcmClaim] Not releasing - pending call exists: $pendingIncomingCallSid")
                }
            }
        }
        
        /**
         * Lock object for synchronizing simultaneous call handling.
         * This ensures only ONE call can pass through the check-and-set at a time.
         */
        private val incomingCallLock = Any()
        
        /**
         * Global flag to track if we're currently processing an incoming call.
         * Set to true immediately when first call arrives, prevents any second call.
         */
        @Volatile
        private var isProcessingIncomingCall = false
        
        /**
         * Timestamp when we started processing current incoming call.
         * Used to auto-reset if processing takes too long (e.g., crash recovery).
         */
        @Volatile
        private var processingStartTime: Long = 0
        
        /**
         * Maximum time to consider an incoming call as "being processed" before auto-reset.
         */
        private const val PROCESSING_TIMEOUT_MS = 30000L // 30 seconds
        
        /**
         * ATOMIC check-and-set operation for handling simultaneous incoming calls.
         * This combines checking for existing calls AND setting the pending call into
         * a single synchronized operation to prevent race conditions.
         * 
         * @return true if this call should be processed (no existing call), 
         *         false if this call should be rejected (another call exists)
         */
        @Synchronized
        fun tryClaimIncomingCall(context: Context, callSid: String): Boolean {
            log_incomingCallClaimCounter++
            Log.d(TAG, "[LOG] tryClaimIncomingCall CALLED. log_incomingCallClaimCounter=$log_incomingCallClaimCounter callSid=$callSid")
            Log.d(TAG, "[LOG] handleActionIncomingCall CALLED. log_callWaitingCounter=$log_callWaitingCounter hasActiveCallDuringIncoming=$hasActiveCallDuringIncoming")
            synchronized(incomingCallLock) {
                val currentThread = Thread.currentThread()
                val timestamp = System.currentTimeMillis()
                val shortSid = callSid.takeLast(6)
                
                Log.d(TAG, "┌─────────────────────────────────────────────────────────────────┐")
                Log.d(TAG, "│ tryClaimIncomingCall - Thread: ${currentThread.name} (${currentThread.id})")
                Log.d(TAG, "│ Timestamp: $timestamp")
                Log.d(TAG, "│ CallSid: $callSid (short: $shortSid)")
                Log.d(TAG, "├─────────────────────────────────────────────────────────────────┤")
                
                // FIRST CHECK: Is another call currently being processed?
                Log.d(TAG, "│ Check 0 - Processing Flag:")
                Log.d(TAG, "│   isProcessingIncomingCall = $isProcessingIncomingCall")
                Log.d(TAG, "│   processingStartTime = $processingStartTime")
                if (isProcessingIncomingCall) {
                    val elapsed = timestamp - processingStartTime
                    Log.d(TAG, "│   elapsed since processing start = ${elapsed}ms")
                    
                    // Check if current pending call is the SAME call (re-entry is OK)
                    if (pendingIncomingCallSid == callSid) {
                        Log.d(TAG, "│   ✓ Same call re-claiming - allowing")
                    } else if (pendingIncomingCallSid == null) {
                        // Processing flag is set (likely by tryClaimFcmMessage), but no pending SID yet.
                        // This is the transition from FCM claim to Call Invite processing for the SAME call.
                        // Since tryClaimFcmMessage guards against multiple FCMs, this is safe.
                        Log.d(TAG, "│   ✓ FCM claim -> Call claim transition - allowing")
                    } else if (elapsed < PROCESSING_TIMEOUT_MS) {
                        Log.w(TAG, "│ ❌ REJECTED - Another call is being processed!")
                        Log.w(TAG, "│   Current pending: $pendingIncomingCallSid")
                        Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                        return false
                    } else {
                        Log.w(TAG, "│ ⚠ Processing flag timeout - resetting and allowing new call")
                        isProcessingIncomingCall = false
                    }
                }
                
                // Check 1: Active connections (already answered calls)
                // Allow through for call waiting feature - the second call will be
                // handled by IncomingCallActivity with a bottom sheet
                Log.d(TAG, "│ Check 1 - Active Connections:")
                Log.d(TAG, "│   activeConnections.isEmpty = ${activeConnections.isEmpty()}")
                Log.d(TAG, "│   activeConnections.size = ${activeConnections.size}")
                if (activeConnections.isNotEmpty()) {
                    Log.d(TAG, "│   activeConnections.keys = ${activeConnections.keys}")
                    // If 2+ calls already exist (e.g. one active + one on hold),
                    // reject the 3rd call immediately — we don't support 3-way calling
                    if (activeConnections.size >= 2) {
                        Log.w(TAG, "│ ❌ REJECTED - Already have ${activeConnections.size} active calls (hold/unhold), cannot accept a 3rd!")
                        Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                        return false
                    }
                    // Check if there's ALSO a pending call - if so, reject (can't have 3 calls)
                    if (pendingIncomingCallSid != null && pendingIncomingCallSid != callSid) {
                        Log.w(TAG, "│ ❌ REJECTED - Active connection AND different pending call both exist!")
                        Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                        return false
                    }
                    Log.d(TAG, "│   ℹ️ Active connection exists but allowing for call waiting")
                } else {
                    Log.d(TAG, "│   ✓ No active connections")
                }
                
                // Check 2: Memory-based pending call
                Log.d(TAG, "│ Check 2 - Memory Pending Call:")
                Log.d(TAG, "│   pendingIncomingCallSid = $pendingIncomingCallSid")
                if (pendingIncomingCallSid != null && pendingIncomingCallSid != callSid) {
                    Log.w(TAG, "│ ❌ REJECTED - Different pending call in memory: $pendingIncomingCallSid")
                    Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                    return false
                }
                if (pendingIncomingCallSid == callSid) {
                    Log.d(TAG, "│   ✓ Same call already pending - allow (re-claim)")
                }
                Log.d(TAG, "│   ✓ Memory check passed")
                
                // Check 3: SharedPreferences-based pending call (cross-process)
                Log.d(TAG, "│ Check 3 - SharedPreferences Pending Call:")
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val savedCallSid = prefs.getString(PREF_PENDING_CALL_SID, null)
                val savedTimestamp = prefs.getLong(PREF_PENDING_CALL_TIMESTAMP, 0)
                Log.d(TAG, "│   prefs.savedCallSid = $savedCallSid")
                Log.d(TAG, "│   prefs.savedTimestamp = $savedTimestamp")
                
                if (!savedCallSid.isNullOrEmpty() && savedCallSid != callSid) {
                    val elapsed = System.currentTimeMillis() - savedTimestamp
                    Log.d(TAG, "│   elapsed since prefs save = ${elapsed}ms")
                    if (elapsed < PENDING_CALL_TIMEOUT_MS) {
                        Log.w(TAG, "│ ❌ REJECTED - Different pending call in prefs: $savedCallSid (${elapsed}ms ago)")
                        Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                        return false
                    }
                    // Expired - can proceed
                    Log.d(TAG, "│   ⚠ Expired pending call in prefs - proceeding")
                }
                Log.d(TAG, "│   ✓ SharedPreferences check passed")
                
                // ========== CLAIM THE CALL ==========
                // Set processing flag FIRST (fastest check for next call)
                isProcessingIncomingCall = true
                processingStartTime = timestamp
                
                // No existing call - CLAIM this call atomically
                Log.d(TAG, "├─────────────────────────────────────────────────────────────────┤")
                Log.d(TAG, "│ CLAIMING CALL NOW...")
                pendingIncomingCallSid = callSid
                val committed = prefs.edit()
                    .putString(PREF_PENDING_CALL_SID, callSid)
                    .putLong(PREF_PENDING_CALL_TIMESTAMP, System.currentTimeMillis())
                    .commit()
                
                Log.d(TAG, "│   pendingIncomingCallSid = $pendingIncomingCallSid")
                Log.d(TAG, "│   SharedPreferences commit = $committed")
                Log.d(TAG, "│ ✓ CLAIMED call $shortSid successfully!")
                Log.d(TAG, "└─────────────────────────────────────────────────────────────────┘")
                return true
            }
        }
        
        /**
         * Check using SharedPreferences - more reliable across processes/threads.
         * Use this in FCM service which might run in a different process.
         */
        fun hasActiveOrPendingCallFromPrefs(context: Context): Boolean {
            if (activeConnections.isNotEmpty()) return true
            if (pendingIncomingCallSid != null) return true
            
            // Also check SharedPreferences for cross-process reliability
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val savedCallSid = prefs.getString(PREF_PENDING_CALL_SID, null)
            val savedTimestamp = prefs.getLong(PREF_PENDING_CALL_TIMESTAMP, 0)
            
            // Check if there's a valid pending call (not expired)
            if (!savedCallSid.isNullOrEmpty()) {
                val elapsed = System.currentTimeMillis() - savedTimestamp
                if (elapsed < PENDING_CALL_TIMEOUT_MS) {
                    Log.d(TAG, "hasActiveOrPendingCallFromPrefs: Found pending call in prefs: $savedCallSid (${elapsed}ms ago)")
                    return true
                } else {
                    // Expired, clear it
                    Log.d(TAG, "hasActiveOrPendingCallFromPrefs: Expired pending call in prefs: $savedCallSid (${elapsed}ms ago)")
                    clearPendingIncomingCallFromPrefs(context)
                }
            }
            return false
        }

        fun setPendingIncomingCall(callSid: String?) {
            pendingIncomingCallSid = callSid
            Log.d(TAG, "setPendingIncomingCall: callSid=$callSid")
        }
        
        /**
         * Set pending call in both memory and SharedPreferences for cross-process reliability.
         * Uses commit() instead of apply() for synchronous write - critical for race condition prevention.
         */
        fun setPendingIncomingCallWithPrefs(context: Context, callSid: String?) {
            pendingIncomingCallSid = callSid
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (callSid != null) {
                val committed = prefs.edit()
                    .putString(PREF_PENDING_CALL_SID, callSid)
                    .putLong(PREF_PENDING_CALL_TIMESTAMP, System.currentTimeMillis())
                    .commit() // Use commit() for synchronous write - critical!
                Log.d(TAG, "setPendingIncomingCallWithPrefs: callSid=$callSid, committed=$committed")
            } else {
                prefs.edit()
                    .remove(PREF_PENDING_CALL_SID)
                    .remove(PREF_PENDING_CALL_TIMESTAMP)
                    .commit()
                Log.d(TAG, "setPendingIncomingCallWithPrefs: cleared")
            }
        }

        fun getPendingIncomingCallSid(): String? {
            return pendingIncomingCallSid
        }
        
        fun getPendingIncomingCallSidFromPrefs(context: Context): String? {
            if (pendingIncomingCallSid != null) return pendingIncomingCallSid
            
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val savedCallSid = prefs.getString(PREF_PENDING_CALL_SID, null)
            val savedTimestamp = prefs.getLong(PREF_PENDING_CALL_TIMESTAMP, 0)
            
            if (!savedCallSid.isNullOrEmpty()) {
                val elapsed = System.currentTimeMillis() - savedTimestamp
                if (elapsed < PENDING_CALL_TIMEOUT_MS) {
                    return savedCallSid
                }
            }
            return null
        }

        /**
         * Application context for SharedPreferences access.
         * Set when the service is created.
         */
        @Volatile
        private var appContext: Context? = null
        
        fun setAppContext(context: Context) {
            appContext = context.applicationContext
        }

        fun clearPendingIncomingCall() {
            Log.d(TAG, "clearPendingIncomingCall: was=$pendingIncomingCallSid, isProcessing=$isProcessingIncomingCall")
            pendingIncomingCallSid = null
            isProcessingIncomingCall = false
            processingStartTime = 0
            // Also clear from SharedPreferences if context is available
            appContext?.let { ctx ->
                val prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                prefs.edit()
                    .remove(PREF_PENDING_CALL_SID)
                    .remove(PREF_PENDING_CALL_TIMESTAMP)
                    .commit() // Use commit() for synchronous write
            }
        }
        
        fun clearPendingIncomingCallFromPrefs(context: Context) {
            Log.d(TAG, "clearPendingIncomingCallFromPrefs: was=$pendingIncomingCallSid, isProcessing=$isProcessingIncomingCall")
            pendingIncomingCallSid = null
            isProcessingIncomingCall = false
            processingStartTime = 0
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit()
                .remove(PREF_PENDING_CALL_SID)
                .remove(PREF_PENDING_CALL_TIMESTAMP)
                .commit() // Use commit() for synchronous write
        }

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

        /**
         * Returns the best display name for a connection.
         * Priority: callerDisplayName (human name) > address (phone number) > extras caller_number > empty
         */
        fun getConnectionDisplayName(connection: TVCallConnection?): String {
            return connection?.callerDisplayName?.takeIf { it.isNotBlank() }
                ?: connection?.address?.schemeSpecificPart
                ?: connection?.extras?.getString("caller_number")
                ?: ""
        }
    }

    /**
     * Find the display name of the currently held call (if any).
     * Excludes the given [excludeCallSid] from the search (typically the active call).
     * Returns null if there is no held call.
     */
    private fun getHeldCallerName(excludeCallSid: String? = null): String? {
        val heldEntry = activeConnections.entries.firstOrNull {
            it.value.state == Connection.STATE_HOLDING && it.key != excludeCallSid
        }
        return if (heldEntry != null) getConnectionDisplayName(heldEntry.value) else null
    }

    // WakeLock to keep CPU awake during incoming call
    private var wakeLock: PowerManager.WakeLock? = null
    private var incomingCallWakeLock: PowerManager.WakeLock? = null
    
    // Ringtone and vibration for incoming calls
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false

    /**
     * Detect the current audio route from AudioManager.
     * Returns "speaker", "bluetooth", or "earpiece".
     * Called BEFORE a connection disconnects so we can restore the route later.
     */
    private fun detectCurrentAudioRoute(am: AudioManager): String {
        // Android 12+: use communicationDevice for accurate detection
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val commDevice = am.communicationDevice
                if (commDevice != null) {
                    return when (commDevice.type) {
                        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_BLE_HEADSET,
                        AudioDeviceInfo.TYPE_HEARING_AID,
                        AudioDeviceInfo.TYPE_BLE_SPEAKER -> {
                            if (am.isBluetoothScoOn) "bluetooth" else "earpiece"
                        }
                        else -> "earpiece"
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "detectCurrentAudioRoute: Error", e)
            }
        }
        // Fallback for older Android
        if (am.isBluetoothScoOn) return "bluetooth"
        if (am.isSpeakerphoneOn) return "speaker"
        return "earpiece"
    }

    /**
     * Check if a Bluetooth audio device is available for voice communication.
     * Uses communicationDevices on Android 12+, falls back to BluetoothAdapter check.
     */
    private fun isBluetoothDeviceAvailable(am: AudioManager?): Boolean {
        if (am == null) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                return am.availableCommunicationDevices.any {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                    it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                }
            } catch (e: Exception) {
                Log.e(TAG, "isBluetoothDeviceAvailable: Error", e)
            }
        }
        // Fallback: check if BT SCO is on
        return am.isBluetoothScoOn
    }

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
            
            // Also release incoming call wake lock
            incomingCallWakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "[VoiceConnectionService] Incoming call wake lock released")
                }
            }
            incomingCallWakeLock = null
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
        Log.d(TAG, "========== onStartCommand START ==========")
        Log.d(TAG, "onStartCommand: action=${intent?.action}, flags=$flags, startId=$startId")
        // Set app context for SharedPreferences access
        setAppContext(applicationContext)
        Thread.currentThread().contextClassLoader = CallInvite::class.java.classLoader
        super.onStartCommand(intent, flags, startId)
        intent?.let {
            Log.d(TAG, "onStartCommand: Processing action: ${it.action}")
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
                    // CRITICAL: Start foreground IMMEDIATELY to avoid crash on Android O+
                    // "Context.startForegroundService() did not then call Service.startForeground()"
                    // This must happen within 5 seconds of startForegroundService() being called
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val channel = getOrCreateIncomingCallChannel()
                            val notification = Notification.Builder(this, channel.id).apply {
                                setSmallIcon(R.drawable.ic_transparent)
                                setContentTitle("Call Cancelled")
                                setContentText("The call was cancelled")
                                setCategory(Notification.CATEGORY_CALL)
                                setAutoCancel(true)
                            }.build()
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
                            } else {
                                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
                            }
                            Log.d(TAG, "ACTION_CANCEL_CALL_INVITE: Started foreground to avoid ANR")
                        } catch (e: Exception) {
                            Log.e(TAG, "ACTION_CANCEL_CALL_INVITE: Failed to start foreground: ${e.message}", e)
                        }
                    }
                    
                    // Load CancelledCallInvite class loader
                    // See: https://github.com/twilio/voice-quickstart-android/issues/561#issuecomment-1678613170
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    val cancelledCallInvite = it.getParcelableExtraSafe<CancelledCallInvite>(EXTRA_CANCEL_CALL_INVITE) ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_CANCEL_CALL_INVITE is missing parcelable EXTRA_CANCEL_CALL_INVITE")
                        // Still stop foreground and self even if we can't get the invite
                        stopForegroundService()
                        stopSelfSafe()
                        return@let
                    }

                    val callHandle = cancelledCallInvite.callSid
                    
                    // Cancel the incoming call notification
                    cancelIncomingCallNotification()
                    
                    // Clear pending call if this was the pending one
                    if (getPendingIncomingCallSid() == callHandle) {
                        clearPendingIncomingCall()
                    }
                    
                    val cancelledConnection = getConnection(callHandle)
                    
                    // Check if other calls exist BEFORE removing this one
                    val otherCallsExistBeforeRemoval = activeConnections.keys.any { it != callHandle }
                    
                    if (cancelledConnection != null && otherCallsExistBeforeRemoval) {
                        // Other calls are active - clear listeners BEFORE calling onAbort()
                        // to prevent the abort's releaseAudioFocus/events from killing the
                        // remaining call's audio and sending "Call Ended" to Flutter
                        Log.d(TAG, "[ACTION_CANCEL_CALL_INVITE] Other calls active, clearing listeners before abort")
                        cancelledConnection.onEvent = null
                        cancelledConnection.onDisconnected = null
                        cancelledConnection.onAction = null
                    }
                    
                    cancelledConnection?.onAbort() ?: run {
                        Log.e(TAG, "onStartCommand: [ACTION_CANCEL_CALL_INVITE] could not find connection for callHandle: $callHandle")
                    }
                    activeConnections.remove(callHandle)
                    
                    // Always clear call waiting state
                    clearCallWaitingState()
                    
                    // Only stop service if no other calls remain
                    if (hasActiveCalls()) {
                        Log.d(TAG, "[ACTION_CANCEL_CALL_INVITE] Other calls still active, not stopping service")
                        // Re-show ongoing notification for remaining call
                        val remainingHandle = getActiveCallHandle()
                        if (remainingHandle != null) {
                            val remainingConn = getConnection(remainingHandle)
                            val remainingNumber = getConnectionDisplayName(remainingConn)
                            showOngoingCallNotification(remainingHandle, remainingNumber)
                            
                            // Restore audio focus for the remaining call.
                            // The cancelled call's onAbort() called releaseAudioFocus() which
                            // reset MODE to NORMAL and cleared communication devices, breaking
                            // audio for the still-active call.
                            remainingConn?.restoreAudioFocus()
                            Log.d(TAG, "[ACTION_CANCEL_CALL_INVITE] Restored audio focus for remaining call $remainingHandle")
                        }
                        
                        // Notify Flutter that the waiting/ringing call was cancelled
                        // so it can clear any pending call UI without closing the active call screen
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, callHandle, null)
                    } else {
                        stopForegroundService()
                        stopSelfSafe()
                    }
                }

                ACTION_INCOMING_CALL -> {
                    val serviceTimestamp = System.currentTimeMillis()
                    val currentThread = Thread.currentThread()
                    Log.d(TAG, "╔════════════════════════════════════════════════════════════════════╗")
                    Log.d(TAG, "║ ACTION_INCOMING_CALL START - Thread: ${currentThread.name} (${currentThread.id})")
                    Log.d(TAG, "║ Service Timestamp: $serviceTimestamp")
                    Log.d(TAG, "╚════════════════════════════════════════════════════════════════════╝")
                    
                    // Load CallInvite class loader & get callInvite
                    try {
                        it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                        Log.d(TAG, "[SVC] ClassLoader set successfully")
                    } catch (e: Exception) {
                        Log.e(TAG, "[SVC] Failed to set ClassLoader: ${e.message}", e)
                    }
                    
                    val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE) ?: run {
                        Log.e(TAG, "[SVC] 'ACTION_INCOMING_CALL' is missing parcelable 'EXTRA_INCOMING_CALL_INVITE'")
                        // Even if we can't get the CallInvite, try to start foreground to avoid ANR
                        try {
                            val channel = getOrCreateIncomingCallChannel()
                            val notification = Notification.Builder(this, channel.id).apply {
                                setSmallIcon(R.drawable.ic_transparent)
                                setContentTitle("Incoming Call")
                                setContentText("Connecting...")
                                setCategory(Notification.CATEGORY_CALL)
                            }.build()
                            startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
                            Log.d(TAG, "[SVC] Started fallback foreground notification")
                        } catch (e2: Exception) {
                            Log.e(TAG, "[SVC] Failed to start fallback foreground: ${e2.message}", e2)
                        }
                        return@let
                    }
                    
                    val currentCallSid = callInvite.callSid
                    val shortSid = currentCallSid.takeLast(6)
                    Log.d(TAG, "[SVC-$shortSid] Got CallInvite - fullSid=${currentCallSid}")

                    // ============================================================
                    // SIMULTANEOUS INCOMING CALLS HANDLING:
                    // If there's already an active call OR a DIFFERENT pending incoming call,
                    // reject this call immediately without showing any UI.
                    // 
                    // IMPORTANT: We need to check if this call is the SAME as the pending call
                    // (which is valid - it was set by FCM service) vs a DIFFERENT call
                    // (which should be rejected as a duplicate).
                    // ============================================================
                    val pendingCallSid = getPendingIncomingCallSidFromPrefs(applicationContext)
                    val activeCallHandle = getActiveCallHandle()
                    
                    Log.d(TAG, "[SVC-$shortSid] ┌─ State Check ─────────────────────────────────────┐")
                    Log.d(TAG, "[SVC-$shortSid] │ currentCallSid = $currentCallSid")
                    Log.d(TAG, "[SVC-$shortSid] │ pendingCallSid (prefs) = $pendingCallSid")
                    Log.d(TAG, "[SVC-$shortSid] │ pendingIncomingCallSid (mem) = $pendingIncomingCallSid")
                    Log.d(TAG, "[SVC-$shortSid] │ activeCallHandle = $activeCallHandle")
                    Log.d(TAG, "[SVC-$shortSid] │ activeConnections.size = ${activeConnections.size}")
                    Log.d(TAG, "[SVC-$shortSid] └────────────────────────────────────────────────────┘")
                    
                    // Check 1: If there's an active call (already answered/connected),
                    // allow the new call through so IncomingCallActivity can show
                    // a bottom sheet with hold/merge/end options
                    if (activeCallHandle != null) {
                        log_callWaitingCounter++
                        Log.d(TAG, "[LOG] Call waiting region HIT. log_callWaitingCounter=$log_callWaitingCounter activeCallCallerName=$activeCallCallerName activeCallCallerNumber=$activeCallCallerNumber activeCallHandleDuringIncoming=$activeCallHandleDuringIncoming")
                        Log.d(TAG, "[SVC-$shortSid] ℹ️ Active call exists (handle=$activeCallHandle)")
                        Log.d(TAG, "[SVC-$shortSid] ℹ️ Allowing second call - will show call waiting options")
                        // Store active caller info to pass to IncomingCallActivity
                        val activeConnection = activeConnections[activeCallHandle]
                        val activeCallerName = activeConnection?.extras?.getString("caller_name") ?: ""
                        val activeCallerNumber = getConnectionDisplayName(activeConnection)
                        
                        // Store active call info in static vars for IncomingCallActivity to access
                        hasActiveCallDuringIncoming = true
                        activeCallCallerName = activeCallerName
                        activeCallCallerNumber = activeCallerNumber
                        activeCallHandleDuringIncoming = activeCallHandle
                    }
                    
                    // Check 2: If there's a DIFFERENT pending call, reject this new call
                    // But if THIS call is the pending call, that's fine - it's the expected flow
                    if (pendingCallSid != null && pendingCallSid != currentCallSid) {
                        Log.w(TAG, "[SVC-$shortSid] ❌ Already have a DIFFERENT pending call!")
                        Log.w(TAG, "[SVC-$shortSid] ❌ pending=$pendingCallSid != current=$currentCallSid")
                        Log.w(TAG, "[SVC-$shortSid] ❌ Rejecting second incoming call NOW")
                        try {
                            callInvite.reject(applicationContext)
                            Log.d(TAG, "[SVC-$shortSid] ✓ Successfully rejected second incoming call")
                        } catch (e: Exception) {
                            Log.e(TAG, "[SVC-$shortSid] Failed to reject second incoming call: ${e.message}", e)
                        }
                        
                        // Send broadcast to notify Flutter about the rejected call
                        sendBroadcastEvent(
                            applicationContext, 
                            TVBroadcastReceiver.ACTION_CALL_ENDED, 
                            currentCallSid, 
                            Bundle().apply {
                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, currentCallSid)
                                putString("rejection_reason", "simultaneous_call_rejected")
                            }
                        )
                        Log.d(TAG, "[SVC-$shortSid] ════ ACTION_INCOMING_CALL END (rejected - different pending) ════")
                        return@let
                    }
                    
                    Log.d(TAG, "[SVC-$shortSid] ✓ This is the first/valid incoming call")
                    Log.d(TAG, "[SVC-$shortSid] ✓ pendingCallSid=$pendingCallSid matches or is null, currentCallSid=$currentCallSid")
                    
                    // ============================================================
                    // Safety net: Ensure pending call is set (normally already set in FCM service)
                    // This handles edge cases where service might be started from other sources
                    // ============================================================
                    if (getPendingIncomingCallSidFromPrefs(applicationContext) != callInvite.callSid) {
                        Log.d(TAG, "[SVC-$shortSid] Setting pending call (safety net)")
                        setPendingIncomingCallWithPrefs(applicationContext, callInvite.callSid)
                    }
                    // ============================================================

                    // Start foreground service (includes screen wake + notification).
                    // The notification's fullScreenIntent handles display automatically:
                    //   - Device locked/screen off → launches IncomingCallActivity full-screen
                    //   - Device unlocked/in use → shows heads-up notification (persistent with USE_FULL_SCREEN_INTENT)
                    // Note: wakeScreen() is NOT called separately — the FULL_WAKE_LOCK inside
                    // startIncomingCallForegroundService() handles turning on the screen.
                    Log.d(TAG, "[SVC-$shortSid] Starting foreground service (will launch IncomingCallActivity)...")
                    startIncomingCallForegroundService(callInvite)
                    Log.d(TAG, "[SVC-$shortSid] Foreground service started")

                    // Bypass TelecomManager - handle incoming call directly without PhoneAccount
                    val mStorage: Storage = StorageImpl(applicationContext)
                    
                    // Get call parameters from invite
                    val callParams = TVCallInviteParametersImpl(mStorage, callInvite)
                    Log.d(TAG, "ACTION_INCOMING_CALL: Call params created")
                    
                    // Create incoming call connection with required parameters
                    val connection = TVCallInviteConnection(applicationContext, callInvite, callParams)
                    Log.d(TAG, "ACTION_INCOMING_CALL: Connection created")
                    
                    val callSid = callInvite.callSid
                    
                    // Apply parameters and attach listeners
                    applyParameters(connection, callParams, callInvite.from ?: "")
                    attachCallEventListeners(connection, callSid)
                    // Mark connection as ringing (matches onCreateIncomingConnection behavior).
                    // Without this, connection.state stays STATE_NEW and multi-call
                    // disconnect handlers can't identify it as an unanswered incoming call.
                    connection.setRinging()
                    Log.d(TAG, "ACTION_INCOMING_CALL: Event listeners attached, state=RINGING")
                    
                    // Set call disconnected listener
                    val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                        // onCallStateListener fires BEFORE this handler (see TVConnection.onDisconnected order).
                        // If it already removed callSid and handled remaining-call logic, just do cleanup.
                        val alreadyHandled = !activeConnections.containsKey(callSid)
                        if (!alreadyHandled) {
                            activeConnections.remove(callSid)
                        }
                        // Clear pending call if this was the pending one
                        if (getPendingIncomingCallSidFromPrefs(applicationContext) == callSid) {
                            clearPendingIncomingCallFromPrefs(applicationContext)
                        }
                        // Only cancel incoming call notification/ringtone if no other calls
                        // are still ringing. Otherwise we'd kill Call B's notification when
                        // Call A (which was also created via ACTION_INCOMING_CALL) disconnects.
                        val hasOtherRingingCall = activeConnections.values.any { conn ->
                            conn.state == Connection.STATE_RINGING || conn.state == Connection.STATE_NEW
                        }
                        if (!hasOtherRingingCall) {
                            cancelIncomingCallNotification()
                            releaseWakeLock()
                        } else {
                            Log.d(TAG, "[ACTION_INCOMING_CALL onDisconnected] Skipping cancelIncomingCallNotification - another call is still ringing")
                        }

                        if (alreadyHandled) {
                            Log.d(TAG, "[ACTION_INCOMING_CALL onDisconnected] Call $callSid already handled by onCallState, skipping remaining-call logic")
                            if (!hasActiveCalls()) {
                                stopForegroundService()
                                stopSelfSafe()
                            }
                            return@CompletionHandler
                        }

                        // Only send ACTION_CALL_ENDED and stop service if no other calls remain
                        if (!hasActiveCalls()) {
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, connection.extras)
                            stopForegroundService()
                            stopSelfSafe()
                        } else {
                            Log.d(TAG, "[ACTION_INCOMING_CALL onDisconnected] Call $callSid ended but other calls still active (${activeConnections.size} remaining), suppressing ACTION_CALL_ENDED")
                            // Unhold remaining call if it was on hold
                            val remainingHandle = getActiveCallHandle()
                            if (remainingHandle != null) {
                                val remainingConn = getConnection(remainingHandle)
                                val remainingNumber = getConnectionDisplayName(remainingConn)
                                
                                if (remainingConn?.state == Connection.STATE_RINGING || remainingConn?.state == Connection.STATE_NEW) {
                                    // Remaining call is an unanswered incoming call.
                                    // IncomingCallActivity is already showing — do NOT bring
                                    // MainActivity to front (that would cover it).
                                    // Cancel the ongoing-call notification — it belongs to the
                                    // call that just ended; the ringing call has its own notification.
                                    cancelOngoingCallNotification()
                                    // Send ACTION_CALL_ENDED so Flutter resets its call UI.
                                    Log.d(TAG, "[ACTION_INCOMING_CALL onDisconnected] Remaining call $remainingHandle is RINGING/NEW (state=${remainingConn?.state}) - sending Call Ended, cancelled ongoing notification")
                                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, Bundle().apply {
                                        putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                                    })
                                } else {
                                    showOngoingCallNotification(remainingHandle, remainingNumber)
                                    if (remainingConn?.state == Connection.STATE_HOLDING) {
                                        // The remaining call is ON HOLD → the ACTIVE call ended.
                                        // Do NOT send ACTION_HELD_CALL_ENDED — the held call is still alive.
                                        remainingConn.toggleHold(false)
                                        Log.d(TAG, "[ACTION_INCOMING_CALL onDisconnected] Unholding remaining call $remainingHandle")
                                    } else {
                                        // The remaining call is NOT on hold → the HELD call ended.
                                        // Notify Flutter to clear the held call banner.
                                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, callSid, connection.extras)
                                    }
                                    bringMainActivityToFront()
                                }
                            }
                        }
                    }
                    connection.setOnCallDisconnected(onCallDisconnectedListener)
                    
                    // Notify about incoming call
                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_INCOMING_CALL, callSid, connection.extras)
                    sendBroadcastCallHandle(applicationContext, callSid)
                    
                    // Note: IncomingCallActivity is launched automatically by Android via the
                    // notification's fullScreenIntent (locked → full-screen, unlocked → heads-up)
                    
                    Log.d(TAG, "========== ACTION_INCOMING_CALL END - callSid: $callSid ==========")
                }

                ACTION_ANSWER -> {
                    // Set classloader for CallInvite deserialization
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    
                    // Check if IncomingCallActivity is handling the MainActivity launch
                    // If true, we should NOT launch MainActivity from the service (avoids dual onNewIntent)
                    val launchedFromActivity = it.getBooleanExtra("LAUNCHED_FROM_ACTIVITY", false)
                    
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
                                cancelIncomingCallNotification()
                                releaseWakeLock()
                                if (!hasActiveCalls()) {
                                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, newConnection.extras)
                                    stopForegroundService()
                                    stopSelfSafe()
                                } else {
                                    Log.d(TAG, "[ACTION_ANSWER onDisconnected] Call $callSid ended but other calls still active, suppressing ACTION_CALL_ENDED")
                                    val remainingHandle = getActiveCallHandle()
                                    if (remainingHandle != null) {
                                        val remainingConn = getConnection(remainingHandle)
                                        val remainingNumber = getConnectionDisplayName(remainingConn)
                                        if (remainingConn?.state == Connection.STATE_RINGING || remainingConn?.state == Connection.STATE_NEW) {
                                            // Remaining call is an unanswered incoming call.
                                            // Cancel the ongoing-call notification — it belongs to the
                                            // call that just ended; the ringing call has its own notification.
                                            cancelOngoingCallNotification()
                                            Log.d(TAG, "[ACTION_ANSWER onDisconnected] Remaining call $remainingHandle is RINGING/NEW - sending Call Ended, cancelled ongoing notification")
                                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, Bundle().apply {
                                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                                            })
                                        } else if (remainingConn?.state == Connection.STATE_HOLDING) {
                                            showOngoingCallNotification(remainingHandle, remainingNumber)
                                            // The remaining call is ON HOLD → the ACTIVE call ended.
                                            // Do NOT send ACTION_HELD_CALL_ENDED — the held call is still alive.
                                            remainingConn.toggleHold(false)
                                            Log.d(TAG, "[ACTION_ANSWER onDisconnected] Unholding remaining call $remainingHandle")
                                            bringMainActivityToFront()
                                        } else {
                                            showOngoingCallNotification(remainingHandle, remainingNumber)
                                            // The remaining call is NOT on hold → the HELD call ended.
                                            // Notify Flutter to clear the held call banner.
                                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, callSid, newConnection.extras)
                                            bringMainActivityToFront()
                                        }
                                    }
                                }
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
                        
                        // Clear pending call state now that the call has been answered.
                        // This is critical: if we don't clear it, tryClaimFcmMessage will
                        // see both an active connection AND a pending call, and block any
                        // subsequent incoming calls (e.g. call waiting).
                        clearPendingIncomingCall()
                        
                        // Get call info from the CallInvite (this is immediately available)
                        val callInvite = (connection as TVCallInviteConnection).callInvite
                        val callSid = callInvite.callSid
                        val callerFromInvite = callInvite.from ?: "Unknown"
                        val callerNumber = extractUserNumber(callerFromInvite)
                        val myNumber = callInvite.to ?: ""
                        
                        Log.d(TAG, "ACTION_ANSWER: Call answered from callInvite - from=$callerFromInvite, callerNumber=$callerNumber, to=$myNumber, callSid=$callSid")
                        
                        // NOTE: Do NOT send EVENT_CONNECTED here! The call is NOT connected yet.
                        // acceptInvite() starts ICE negotiation which takes 2-4 seconds.
                        // The real EVENT_CONNECTED will be sent from TVConnection.onConnected() 
                        // callback when ICE completes and media connection is established.
                        
                        // Show ongoing call notification (use display name if available, fallback to number)
                        val callerDisplayName = connection.callerDisplayName?.takeIf { it.isNotBlank() }
                            ?: callerNumber
                        showOngoingCallNotification(callSid, callerDisplayName, getHeldCallerName(excludeCallSid = callSid))
                        
                        // Only launch MainActivity from the service if IncomingCallActivity is NOT
                        // already handling it. When answering from the swipe UI or notification button
                        // in IncomingCallActivity, it sets LAUNCHED_FROM_ACTIVITY=true and handles
                        // the MainActivity launch itself. Launching here too causes dual onNewIntent
                        // calls which confuse Flutter and destroy/recreate the activity unnecessarily.
                        if (!launchedFromActivity) {
                            // This path is used when answering from notification action button
                            // that goes directly to the service (without IncomingCallActivity).
                            // 
                            // ARCHITECTURE: MainActivity NEVER shows over lock screen.
                            // Only IncomingCallActivity has showWhenLocked privileges.
                            // When device is locked, we store pendingAnsweredCallData and let
                            // the user unlock normally — MainActivity.onResume() picks it up.
                            // This matches WhatsApp/Telegram behavior.
                            try {
                                val keyguardMgr = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
                                val isLocked = keyguardMgr?.isKeyguardLocked == true
                                
                                if (isLocked) {
                                    // LOCKED PATH: Do NOT launch MainActivity over lock screen.
                                    // Store call data in pendingAnsweredCallData. User unlocks
                                    // normally → MainActivity.onResume() picks it up and
                                    // navigates to the active call screen.
                                    Log.d(TAG, "ACTION_ANSWER: Device is locked - storing pendingAnsweredCallData instead of launching MainActivity")
                                    IncomingCallActivity.pendingAnsweredCallData = mapOf(
                                        "callerName" to callerNumber,
                                        "callerNumber" to callerNumber,
                                        "myNumber" to myNumber,
                                        "callSid" to callSid,
                                        "callDirection" to "incoming",
                                        "isCallAnswered" to true
                                    )
                                } else {
                                    // UNLOCKED PATH: Launch MainActivity normally (no lock screen flags).
                                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                                    launchIntent?.let { intent ->
                                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                                                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                                        intent.putExtra("fromIncomingCall", true)
                                        intent.putExtra("callHandle", callSid)
                                        intent.putExtra("callAnswered", true)
                                        intent.putExtra("CALL_ANSWERED", true)
                                        intent.putExtra("CALL_SID", callSid)
                                        intent.putExtra("CALLER_NAME", callerNumber)
                                        intent.putExtra("CALLER_NUMBER", callerNumber)
                                        intent.putExtra("MY_NUMBER", myNumber)
                                        intent.putExtra("CALL_DIRECTION", "incoming")
                                        startActivity(intent)
                                        Log.d(TAG, "ACTION_ANSWER: Launched main activity (UNLOCKED path) - caller: $callerNumber")
                                    }
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Could not handle post-answer flow: ${e.message}")
                            }
                        } else {
                            Log.d(TAG, "ACTION_ANSWER: Skipping MainActivity launch - IncomingCallActivity is handling it")
                        }
                    } else {
                        Log.e(TAG, "onStartCommand: [ACTION_ANSWER] connection is not TVCallInviteConnection")
                    }
                }

                ACTION_ANSWER_WITH_HOLD -> {
                    // Answer the incoming call while putting the active call on hold
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    Log.d(TAG, "onStartCommand: ACTION_ANSWER_WITH_HOLD")
                    
                    val activeHandle = it.getStringExtra("EXTRA_ACTIVE_CALL_HANDLE") ?: activeCallHandleDuringIncoming
                    val newCallHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getIncomingCallHandle()
                    
                    // Step 1: Put active call on hold
                    if (activeHandle != null) {
                        getConnection(activeHandle)?.toggleHold(true)
                        Log.d(TAG, "[ACTION_ANSWER_WITH_HOLD] Active call $activeHandle put on hold")
                    }
                    
                    // Step 2: Answer the new call (same logic as ACTION_ANSWER)
                    var connection = if (newCallHandle != null) getConnection(newCallHandle) else null
                    if (connection == null) {
                        val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE)
                        if (callInvite != null) {
                            Log.i(TAG, "[ACTION_ANSWER_WITH_HOLD] Recovering connection from CallInvite")
                            startIncomingCallForegroundService(callInvite)
                            val mStorage: Storage = StorageImpl(applicationContext)
                            val callParams = TVCallInviteParametersImpl(mStorage, callInvite)
                            val newConnection = TVCallInviteConnection(applicationContext, callInvite, callParams)
                            val callSid = callInvite.callSid
                            applyParameters(newConnection, callParams, callInvite.from ?: "")
                            attachCallEventListeners(newConnection, callSid)
                            val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                                if (activeConnections.containsKey(callSid)) {
                                    activeConnections.remove(callSid)
                                }
                                // When second call ends, unhold the first call and restore its UI
                                if (activeHandle != null && hasActiveCalls()) {
                                    val heldConnection = getConnection(activeHandle)
                                    heldConnection?.toggleHold(false)
                                    Log.d(TAG, "[ACTION_ANSWER_WITH_HOLD] Second call ended, unholding first call $activeHandle")
                                    // Re-show ongoing notification and bring back call UI for the held call
                                    val heldNumber = getConnectionDisplayName(heldConnection)
                                    showOngoingCallNotification(activeHandle, heldNumber)
                                    // Bring back the main activity to show the held call's UI
                                    // Use bringMainActivityToFront() to avoid resetting Flutter call state
                                    bringMainActivityToFront()
                                    // Don't send ACTION_CALL_ENDED to Flutter - the held call is still active
                                    // Flutter would close the call screen if it received "Call Ended"
                                    Log.d(TAG, "[ACTION_ANSWER_WITH_HOLD] Skipping ACTION_CALL_ENDED broadcast - held call still active")
                                } else {
                                    // No remaining calls, send the call ended event normally
                                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, newConnection.extras)
                                }
                                cancelIncomingCallNotification()
                            }
                            newConnection.setOnCallDisconnected(onCallDisconnectedListener)
                            connection = newConnection
                        }
                    }
                    
                    cancelIncomingCallNotification()
                    releaseWakeLock()
                    
                    if (connection is TVCallInviteConnection) {
                        if (applicationContext.hasMicrophoneAccess()) {
                            connection.acceptInvite()
                            clearPendingIncomingCall() // Clear pending state so future calls can come through
                            val callInvite = connection.callInvite
                            val callSid = callInvite.callSid
                            val callerNumber = extractUserNumber(callInvite.from ?: "Unknown")
                            val callerName = connection.callerDisplayName?.takeIf { it.isNotBlank() }
                                ?: callerNumber
                            // The old active call (activeHandle) is now on hold — show its name in notification
                            val heldName = if (activeHandle != null) getConnectionDisplayName(getConnection(activeHandle)) else null
                            showOngoingCallNotification(callSid, callerName, heldName)
                            launchMainActivityWithCallData(callSid, callerNumber, callInvite.to ?: "")
                        }
                    }
                    clearCallWaitingState()
                }

                ACTION_ANSWER_WITH_END_FIRST -> {
                    // End the active call first, then answer the incoming call
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    Log.d(TAG, "onStartCommand: ACTION_ANSWER_WITH_END_FIRST")
                    
                    val activeHandle = it.getStringExtra("EXTRA_ACTIVE_CALL_HANDLE") ?: activeCallHandleDuringIncoming
                    val newCallHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getIncomingCallHandle()
                    
                    // Step 1: Hang up the active call
                    if (activeHandle != null) {
                        val activeConnection = getConnection(activeHandle)
                        activeConnection?.forceDisconnectWithLogging()
                        activeConnections.remove(activeHandle)
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, activeHandle, activeConnection?.extras)
                        Log.d(TAG, "[ACTION_ANSWER_WITH_END_FIRST] Active call $activeHandle ended")
                    }
                    
                    // Step 2: Answer the new call (same logic as ACTION_ANSWER)
                    var connection = if (newCallHandle != null) getConnection(newCallHandle) else null
                    if (connection == null) {
                        val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE)
                        if (callInvite != null) {
                            Log.i(TAG, "[ACTION_ANSWER_WITH_END_FIRST] Recovering connection from CallInvite")
                            startIncomingCallForegroundService(callInvite)
                            val mStorage: Storage = StorageImpl(applicationContext)
                            val callParams = TVCallInviteParametersImpl(mStorage, callInvite)
                            val newConnection = TVCallInviteConnection(applicationContext, callInvite, callParams)
                            val callSid = callInvite.callSid
                            applyParameters(newConnection, callParams, callInvite.from ?: "")
                            attachCallEventListeners(newConnection, callSid)
                            val onCallDisconnectedListener: CompletionHandler<DisconnectCause> = CompletionHandler {
                                if (activeConnections.containsKey(callSid)) {
                                    activeConnections.remove(callSid)
                                }
                                cancelIncomingCallNotification()
                                releaseWakeLock()
                                if (!hasActiveCalls()) {
                                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, newConnection.extras)
                                    stopForegroundService()
                                    stopSelfSafe()
                                } else {
                                    Log.d(TAG, "[ACTION_ANSWER_WITH_END_FIRST onDisconnected] Call $callSid ended but other calls still active, suppressing ACTION_CALL_ENDED")
                                }
                            }
                            newConnection.setOnCallDisconnected(onCallDisconnectedListener)
                            connection = newConnection
                        }
                    }
                    
                    cancelIncomingCallNotification()
                    releaseWakeLock()
                    
                    if (connection is TVCallInviteConnection) {
                        if (applicationContext.hasMicrophoneAccess()) {
                            connection.acceptInvite()
                            clearPendingIncomingCall() // Clear pending state so future calls can come through
                            val callInvite = connection.callInvite
                            val callSid = callInvite.callSid
                            val callerNumber = extractUserNumber(callInvite.from ?: "Unknown")
                            val callerName = connection.callerDisplayName?.takeIf { it.isNotBlank() }
                                ?: callerNumber
                            showOngoingCallNotification(callSid, callerName)
                            launchMainActivityWithCallData(callSid, callerNumber, callInvite.to ?: "")
                        }
                    }
                    clearCallWaitingState()
                }

                ACTION_HANGUP -> {
                    // Set classloader for CallInvite deserialization
                    it.setExtrasClassLoader(CallInvite::class.java.classLoader)
                    
                    val callHandle = it.getStringExtra(EXTRA_CALL_HANDLE) ?: getActiveCallHandle() ?: run {
                        Log.e(TAG, "onStartCommand: ACTION_HANGUP is missing String EXTRA_CALL_HANDLE")
                        // Don't clear all connections - there may be valid calls still active
                        clearPendingIncomingCall()
                        clearCallWaitingState()
                        cancelOngoingCallNotification()
                        if (!hasActiveCalls()) {
                            activeConnections.clear()
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, null, null)
                            stopForegroundService()
                            stopSelfSafe()
                        } else {
                            Log.d(TAG, "[ACTION_HANGUP] No handle but active calls exist (${activeConnections.keys}), not clearing")
                        }
                        return@let
                    }

                    Log.i(TAG, "[Decline] Received ACTION_HANGUP for callHandle: $callHandle. Active connections: ${activeConnections.keys}")
                    
                    // Only cancel the incoming call notification/ringtone/wakelock if:
                    // - The call being hung up is itself a ringing call, OR
                    // - There are no OTHER ringing/new calls that still need the notification
                    // If an active call is being hung up while another call is ringing,
                    // we must NOT cancel the notification or the ringing call loses its UI.
                    val hangupConnection = getConnection(callHandle)
                    val hangupCallIsRinging = hangupConnection != null && 
                        (hangupConnection.state == Connection.STATE_RINGING || hangupConnection.state == Connection.STATE_NEW)
                    val hasOtherRingingCall = activeConnections.any { (sid, conn) ->
                        sid != callHandle && (conn.state == Connection.STATE_RINGING || conn.state == Connection.STATE_NEW)
                    }
                    if (hangupCallIsRinging || !hasOtherRingingCall) {
                        cancelIncomingCallNotification()
                        releaseWakeLock()
                    } else {
                        Log.d(TAG, "[Decline] Skipping cancelIncomingCallNotification/releaseWakeLock - other call is still ringing")
                    }
                    
                    // Clear pending call if this matches
                    if (getPendingIncomingCallSid() == callHandle) {
                        clearPendingIncomingCall()
                    }

                    var connection = getConnection(callHandle)
                    
                    // ── Save current audio route BEFORE any disconnect resets it ──
                    // Declared here so it's in scope for the restoration code below,
                    // regardless of whether the connection was found or recovered.
                    var savedAudioRoute = "earpiece"
                    
                    // If connection not found, try to recover from CallInvite in intent (terminated state case)
                    if (connection == null) {
                        val callInvite = it.getParcelableExtraSafe<CallInvite>(EXTRA_INCOMING_CALL_INVITE)
                        if (callInvite != null) {
                            Log.i(TAG, "[Decline] Recovering CallInvite from intent for terminated state reject")
                            // Directly reject the invite without creating a connection
                            callInvite.reject(applicationContext)
                            // Clear pending call for the callInvite's SID as well
                            if (getPendingIncomingCallSid() == callInvite.callSid) {
                                clearPendingIncomingCall()
                            }
                            // Only broadcast call ended to Flutter if no other active calls remain
                            // Otherwise Flutter will close the active call's UI
                            if (!hasActiveCalls()) {
                                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, null)
                            } else {
                                Log.d(TAG, "[Decline] Skipping ACTION_CALL_ENDED broadcast - other calls still active")
                            }
                        } else {
                            Log.e(TAG, "[Decline] No connection found and no CallInvite in intent for $callHandle. Active connections: ${activeConnections.keys}")
                            // Only remove the specific handle, NOT all connections
                            activeConnections.remove(callHandle)
                            clearPendingIncomingCall()
                            if (!hasActiveCalls()) {
                                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, null)
                            } else {
                                Log.d(TAG, "[Decline] Skipping ACTION_CALL_ENDED - other calls still active after removing stale handle")
                            }
                        }
                    } else {
                        Log.i(TAG, "[Decline] Found connection for $callHandle, state=${connection.state}")
                        // Remove from activeConnections BEFORE disconnecting so hasActiveCalls() 
                        // reflects the correct state during disconnect callbacks
                        activeConnections.remove(callHandle)
                        
                        // Check if other calls remain BEFORE disconnecting
                        // If other calls are active, clear event/disconnect listeners to prevent
                        // the disconnect flow from sending "Call Ended" events to Flutter
                        // which would close the active call's UI
                        val otherCallsRemain = hasActiveCalls()
                        if (otherCallsRemain) {
                            Log.d(TAG, "[Decline] Other calls still active, clearing listeners before disconnect to prevent Flutter state reset")
                            connection.onEvent = null
                            connection.onDisconnected = null
                            connection.onAction = null
                        }
                        
                        // ── Snapshot the audio route before disconnect resets it ──
                        // forceDisconnectWithLogging → releaseAudioFocus clears speaker,
                        // stops BT SCO, and resets MODE to NORMAL.  We snapshot the route
                        // here so we can restore it on the remaining connection.
                        if (otherCallsRemain) {
                            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                            if (am != null) {
                                savedAudioRoute = detectCurrentAudioRoute(am)
                                Log.d(TAG, "[Decline] Saved audio route before disconnect: $savedAudioRoute")
                            }
                        }
                        
                        connection.forceDisconnectWithLogging()
                        
                        // Only broadcast call ended to Flutter if no other active calls remain
                        if (!otherCallsRemain) {
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, connection.extras)
                        } else {
                            Log.d(TAG, "[Decline] Skipping ACTION_CALL_ENDED broadcast - other calls still active")
                        }
                    }
                    
                    // Always clear call waiting state after any hangup
                    clearCallWaitingState()
                    
                    // Check if there are remaining active calls
                    if (hasActiveCalls()) {
                        // Other calls still active - DON'T stop the service
                        val remainingHandle = getActiveCallHandle()
                        if (remainingHandle != null) {
                            val remainingConnection = getConnection(remainingHandle)
                            val remainingIsRinging = remainingConnection != null &&
                                (remainingConnection.state == Connection.STATE_RINGING || remainingConnection.state == Connection.STATE_NEW)
                            
                            if (remainingIsRinging) {
                                // Remaining call is still ringing on IncomingCallActivity.
                                // Cancel the ongoing-call notification — it belongs to the call
                                // that just ended; the ringing call has its own incoming-call
                                // notification.
                                cancelOngoingCallNotification()
                                // Send ACTION_CALL_ENDED so Flutter resets its active call UI.
                                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callHandle, connection?.extras)
                                // Do NOT restore audio focus (not connected yet),
                                // and do NOT bring MainActivity to front (IncomingCallActivity
                                // is already handling the ringing call).
                                Log.d(TAG, "[Decline] Remaining call $remainingHandle is ringing (state=${remainingConnection?.state}), cancelled ongoing notification, keeping IncomingCallActivity visible")
                            } else {
                                // Remaining call is active/connected - restore its state
                                val remainingNumber = getConnectionDisplayName(remainingConnection)
                                Log.d(TAG, "[Decline] Other call still active: $remainingHandle, showing ongoing notification")
                                showOngoingCallNotification(remainingHandle, remainingNumber)
                                
                                // Unhold the remaining call if it was on hold
                                if (remainingConnection?.state == Connection.STATE_HOLDING) {
                                    remainingConnection.toggleHold(false)
                                    Log.d(TAG, "[Decline] Unholding remaining call $remainingHandle")
                                }

                                // Re-request audio focus for the remaining call.
                                // The disconnected call's forceDisconnectWithLogging() released audio focus
                                // which reset MODE to NORMAL, cleared communication device, and stopped BT SCO.
                                // Without re-requesting, audio toggles (speaker/earpiece/bluetooth) won't work.
                                remainingConnection?.let { conn ->
                                    Log.d(TAG, "[Decline] Restoring audio focus for remaining call $remainingHandle")
                                    conn.restoreAudioFocus()
                                    
                                    // ── Restore the audio route the user had selected ──
                                    Log.d(TAG, "[Decline] Restoring saved audio route: $savedAudioRoute")
                                    when (savedAudioRoute) {
                                        "speaker" -> {
                                            Log.d(TAG, "[Decline] Re-applying speaker route")
                                            conn.toggleSpeaker(true)
                                        }
                                        "bluetooth" -> {
                                            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                                            val btAvailable = am?.isBluetoothScoOn == true || isBluetoothDeviceAvailable(am)
                                            if (btAvailable) {
                                                Log.d(TAG, "[Decline] Re-applying bluetooth route (device still available)")
                                                conn.toggleBluetooth(true)
                                            } else {
                                                Log.d(TAG, "[Decline] Bluetooth device no longer available, staying on earpiece")
                                            }
                                        }
                                        else -> {
                                            Log.d(TAG, "[Decline] Earpiece is already the default, no action needed")
                                        }
                                    }
                                }
                                
                                // Bring back the main activity to show the remaining call's UI
                                bringMainActivityToFront()
                            }
                        }
                    } else {
                        // No more active calls - clean up everything
                        cancelOngoingCallNotification()
                        stopForegroundService()
                        stopSelfSafe()
                    }
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
                            if (!hasActiveCalls()) {
                                sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, call.sid ?: "", connection.extras)
                                stopForegroundService()
                                stopSelfSafe()
                            } else {
                                Log.d(TAG, "[Outgoing onDisconnected] Call ${call.sid} ended but other calls still active, suppressing ACTION_CALL_ENDED")
                                val remainingHandle = getActiveCallHandle()
                                if (remainingHandle != null) {
                                    val remainingConn = getConnection(remainingHandle)
                                    val remainingNumber = getConnectionDisplayName(remainingConn)
                                    showOngoingCallNotification(remainingHandle, remainingNumber)
                                    if (remainingConn?.state == Connection.STATE_HOLDING) {
                                        // The remaining call is ON HOLD → the ACTIVE call ended.
                                        // Do NOT send ACTION_HELD_CALL_ENDED — the held call is still alive.
                                        remainingConn.toggleHold(false)
                                        Log.d(TAG, "[Outgoing onDisconnected] Unholding remaining call $remainingHandle")
                                    } else {
                                        // The remaining call is NOT on hold → the HELD call ended.
                                        // Notify Flutter to clear the held call banner.
                                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, call.sid ?: "", connection.extras)
                                    }
                                    bringMainActivityToFront()
                                }
                            }
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

                ACTION_SWAP_CALLS -> {
                    // Swap active and held calls atomically.
                    // Find the active connection (STATE_ACTIVE) and the held connection (STATE_HOLDING).
                    val activeEntry = activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_ACTIVE }
                    val heldEntry = activeConnections.entries.firstOrNull { it.value.state == Connection.STATE_HOLDING }

                    if (activeEntry == null || heldEntry == null) {
                        Log.e(TAG, "onStartCommand: [ACTION_SWAP_CALLS] need both active and held connections. active=${activeEntry?.key}, held=${heldEntry?.key}")
                        return@let
                    }

                    Log.d(TAG, "onStartCommand: [ACTION_SWAP_CALLS] swapping active=${activeEntry.key} with held=${heldEntry.key}")

                    // Hold the currently active connection
                    activeEntry.value.toggleHold(true)
                    // Unhold the currently held connection
                    heldEntry.value.toggleHold(false)

                    // Update ongoing notification to show the newly active caller
                    // with the newly held caller's info
                    val newActiveHandle = heldEntry.key
                    val newActiveName = getConnectionDisplayName(heldEntry.value)
                    val newHeldName = getConnectionDisplayName(activeEntry.value)
                    showOngoingCallNotification(newActiveHandle, newActiveName, newHeldName)
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
                if (!hasActiveCalls()) {
                    sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, it.sid ?: "", connection.extras)
                    stopForegroundService()
                    stopSelfSafe()
                } else {
                    Log.d(TAG, "[onCallInitializingDisconnected] Call ${it.sid} ended but other calls still active")
                    val remainingHandle = getActiveCallHandle()
                    if (remainingHandle != null) {
                        val remainingConn = getConnection(remainingHandle)
                        val remainingNumber = getConnectionDisplayName(remainingConn)
                        
                        if (remainingConn?.state == Connection.STATE_RINGING || remainingConn?.state == Connection.STATE_NEW) {
                            Log.d(TAG, "[onCallInitializingDisconnected] Remaining call $remainingHandle is RINGING/NEW (state=${remainingConn?.state}) - sending Call Ended to Flutter")
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, it.sid ?: "", Bundle().apply {
                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, it.sid ?: "")
                            })
                        } else {
                            showOngoingCallNotification(remainingHandle, remainingNumber)
                            if (remainingConn?.state == Connection.STATE_HOLDING) {
                                remainingConn.toggleHold(false)
                                Log.d(TAG, "[onCallInitializingDisconnected] Unholding remaining call $remainingHandle")
                            }
                            bringMainActivityToFront()
                        }
                    }
                }
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
            // Don't forward disconnect events to Flutter if other calls are still active
            // Otherwise Flutter will close the active call's UI when a secondary call ends
            // NOTE: When onEvent fires, the current connection is still in activeConnections,
            // so we check if there are OTHER connections besides this one
            val isDisconnectEvent = event == TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL || 
                                   event == TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE
            val otherCallsExist = activeConnections.keys.any { it != callSid }
            if (isDisconnectEvent && otherCallsExist) {
                Log.d(TAG, "[onEvent] Suppressing disconnect event '$event' for $callSid - other calls still active (${activeConnections.keys.filter { it != callSid }})")
                return@ValueBundleChanged
            }
            sendBroadcastEvent(applicationContext, event ?: "", callSid, extra)
            // This is a temporary solution since `isOnCall` returns true when there is an active ConnectionService, regardless of the source app. This also applies to SIM/Telecom calls.
            sendBroadcastCallHandle(applicationContext, extra?.getString(TVBroadcastReceiver.EXTRA_CALL_HANDLE))
        }
        val onDisconnect: CompletionHandler<DisconnectCause> = CompletionHandler {
            // onCallState fires BEFORE onDisconnect (see TVConnection.onDisconnected order).
            // If onCallState already removed callSid from activeConnections and handled
            // the remaining-call logic, skip here to avoid duplicate broadcasts.
            if (!activeConnections.containsKey(callSid)) {
                Log.d(TAG, "[onDisconnect] Call $callSid already handled by onCallState, skipping")
                return@CompletionHandler
            }
            activeConnections.remove(callSid)
            // Clear pending call if this was the pending one
            if (getPendingIncomingCallSid() == callSid) {
                clearPendingIncomingCall()
            }
            // Only stop service if no other calls remain
            if (!hasActiveCalls()) {
                clearCallWaitingState()
                stopForegroundService()
                stopSelfSafe()
            } else {
                Log.d(TAG, "[onDisconnect] Call $callSid ended but other calls still active (${activeConnections.size} remaining)")
                
                val remainingHandle = getActiveCallHandle()
                if (remainingHandle != null) {
                    val remainingConn = getConnection(remainingHandle)
                    val remainingNumber = getConnectionDisplayName(remainingConn)
                    
                    if (remainingConn?.state == Connection.STATE_RINGING) {
                        // Cancel the ongoing-call notification — it belongs to the call that
                        // just ended; the ringing call has its own incoming-call notification.
                        cancelOngoingCallNotification()
                        Log.d(TAG, "[onDisconnect] Remaining call $remainingHandle is RINGING - sending Call Ended to Flutter, cancelled ongoing notification")
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, Bundle().apply {
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                        })
                    } else if (remainingConn?.state == Connection.STATE_HOLDING) {
                        // Remaining call is HOLDING — the ACTIVE call disconnected.
                        // Match iOS behavior: suppress Call Ended and just unhold
                        // the remaining call. The Unhold event will trigger Flutter's
                        // unhold handler which restores the held call as active.
                        Log.d(TAG, "[onDisconnect] Remaining call $remainingHandle is HOLDING (state=${remainingConn?.state}) - ACTIVE call $callSid ended, suppressing Call Ended + unholding remaining")
                        showOngoingCallNotification(remainingHandle, remainingNumber)
                        remainingConn.toggleHold(false)
                        Log.d(TAG, "[onDisconnect] Unholding remaining call $remainingHandle")
                        bringMainActivityToFront()
                    } else {
                        // Remaining call is ACTIVE — the HELD call disconnected.
                        // Send ACTION_HELD_CALL_ENDED so Flutter clears the
                        // held-call banner without touching the active call.
                        Log.d(TAG, "[onDisconnect] Remaining call $remainingHandle is ACTIVE (state=${remainingConn?.state}) - HELD call $callSid ended, sending Held Call Ended")
                        sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, callSid, Bundle().apply {
                            putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                        })
                        showOngoingCallNotification(remainingHandle, remainingNumber)
                        bringMainActivityToFront()
                    }
                }
            }
        }
        val onCallState: CompletionHandler<Call.State> = CompletionHandler { state ->
            // Show ongoing call notification when an outgoing call connects.
            // Incoming calls get their notification in ACTION_ANSWER, but outgoing
            // calls don't have an equivalent trigger. The temporary onCallStateListener
            // set in ACTION_PLACE_OUTGOING_CALL / onCreateOutgoingConnection is replaced
            // by this permanent handler when attachCallEventListeners is called (at RINGING),
            // so the CONNECTED state must be handled here.
            if (state == Call.State.CONNECTED && connection.callDirection == CallDirection.OUTGOING) {
                // Prefer the display name (e.g. "Qa 2") over the raw number for outgoing calls.
                // callerDisplayName is set by applyParameters() from the outgoingCallerName param.
                val displayName = connection.callerDisplayName?.takeIf { it.isNotBlank() }
                    ?: connection.address?.schemeSpecificPart ?: ""
                // Check if there's a held call (e.g. user placed outgoing while another was on hold)
                val heldName = getHeldCallerName(excludeCallSid = callSid)
                showOngoingCallNotification(callSid, displayName, heldName)
                Log.d(TAG, "[onCallState] Outgoing call $callSid connected - showing ongoing notification")
            }
            if (state == Call.State.DISCONNECTED) {
                // If callSid is already removed from activeConnections, it means another
                // handler (e.g. ACTION_HANGUP / Decline) already handled cleanup for this
                // call. Skip to avoid duplicate broadcasts and notification cancels.
                val alreadyHandled = !activeConnections.containsKey(callSid)
                if (alreadyHandled) {
                    Log.d(TAG, "[onCallState] Call $callSid already handled (not in activeConnections), skipping")
                    if (!hasActiveCalls()) {
                        clearCallWaitingState()
                        stopForegroundService()
                        stopSelfSafe()
                    }
                    return@CompletionHandler
                }
                activeConnections.remove(callSid)
                // Clear pending call if this was the pending one
                if (getPendingIncomingCallSid() == callSid) {
                    clearPendingIncomingCall()
                }
                // Only stop service if no other calls remain
                if (!hasActiveCalls()) {
                    clearCallWaitingState()
                    stopForegroundService()
                    stopSelfSafe()
                } else {
                    Log.d(TAG, "[onCallState] Call $callSid disconnected but other calls still active (${activeConnections.size} remaining)")
                    
                    val remainingHandle = getActiveCallHandle()
                    if (remainingHandle != null) {
                        val remainingConn = getConnection(remainingHandle)
                        val remainingNumber = getConnectionDisplayName(remainingConn)
                        
                        if (remainingConn?.state == Connection.STATE_RINGING || remainingConn?.state == Connection.STATE_NEW) {
                            // Remaining call is RINGING or NEW (unanswered incoming).
                            // The native IncomingCallActivity is already showing for this call.
                            // Cancel the ongoing-call notification — it belongs to the call that
                            // just ended, and the ringing call has its own incoming-call notification.
                            cancelOngoingCallNotification()
                            // Send ACTION_CALL_ENDED so Flutter knows the active call is over
                            // and resets its UI. Do NOT call bringMainActivityToFront() — that
                            // would cover the IncomingCallActivity with Flutter's stale call UI.
                            Log.d(TAG, "[onCallState] Remaining call $remainingHandle is RINGING/NEW (state=${remainingConn?.state}) - sending Call Ended to Flutter, cancelled ongoing notification")
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_CALL_ENDED, callSid, Bundle().apply {
                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                            })
                        } else if (remainingConn?.state == Connection.STATE_HOLDING) {
                            // Remaining call is HOLDING — the ACTIVE call disconnected.
                            // Match iOS behavior: suppress Call Ended and just unhold
                            // the remaining call. The Unhold event will trigger Flutter's
                            // unhold handler which restores the held call as active.
                            Log.d(TAG, "[onCallState] Remaining call $remainingHandle is HOLDING (state=${remainingConn?.state}) - ACTIVE call $callSid ended, suppressing Call Ended + unholding remaining")
                            showOngoingCallNotification(remainingHandle, remainingNumber)
                            remainingConn.toggleHold(false)
                            Log.d(TAG, "[onCallState] Unholding remaining call $remainingHandle")
                            bringMainActivityToFront()
                        } else {
                            // Remaining call is ACTIVE — the HELD call disconnected.
                            // Send ACTION_HELD_CALL_ENDED so Flutter clears the
                            // held-call banner without touching the active call.
                            Log.d(TAG, "[onCallState] Remaining call $remainingHandle is ACTIVE (state=${remainingConn?.state}) - HELD call $callSid ended, sending Held Call Ended")
                            sendBroadcastEvent(applicationContext, TVBroadcastReceiver.ACTION_HELD_CALL_ENDED, callSid, Bundle().apply {
                                putString(TVBroadcastReceiver.EXTRA_CALL_HANDLE, callSid)
                            })
                            showOngoingCallNotification(remainingHandle, remainingNumber)
                            bringMainActivityToFront()
                        }
                    }
                }
            }
        }

        // Add to local connection cache
        activeConnections[callSid] = connection
        
        // NOTE: Do NOT clear pendingIncomingCallSid here!
        // The IncomingCallActivity.onCreate() checks pendingCallSid to validate the call.
        // If we clear it here, the activity (launched 200ms later) will see null and
        // reject the call as orphaned. The pending state will be cleared when the call
        // is actually answered (ACTION_ANSWER) or ended (onDisconnect).

        // attach listeners
        connection.setOnCallActionListener(onAction)
        connection.setOnCallEventListener(onEvent)
        connection.setOnCallDisconnected(onDisconnect)
        connection.setOnCallStateListener(onCallState)
        
        // Provide callback so the connection can check for other active calls
        // before releasing audio focus on disconnect. This prevents killing the
        // foreground notification of a remaining call on Android 12+/16.
        connection.hasOtherActiveCalls = {
            // The disconnecting connection's callSid may or may not still be in
            // activeConnections at this point (depends on which handler ran first).
            // We check if there are connections OTHER than this one.
            activeConnections.keys.any { it != callSid }
        }
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

    /**
     * Formats a phone number to a readable format
     * Examples:
     * +12034098827 -> +1 (203) 409-8827
     * +1 203 409 8827 -> +1 (203) 409-8827
     */
    private fun formatPhoneNumber(phoneNumber: String?): String {
        if (phoneNumber.isNullOrEmpty()) return ""
        
        // Remove all non-digit characters except leading +
        val cleaned = phoneNumber.replace(Regex("[^\\d+]"), "")
        
        // Handle empty result
        if (cleaned.isEmpty()) return phoneNumber
        
        // Check if it starts with +
        val hasPlus = cleaned.startsWith("+")
        
        // Extract all content after + if exists
        val allDigits = if (hasPlus) {
            cleaned.substring(1)  // Remove the + sign
        } else {
            cleaned
        }
        
        // Format based on pattern
        return when {
            // International format: starts with + and has 11+ digits (country code + 10 digits)
            hasPlus && allDigits.length >= 11 -> {
                // Extract country code (usually 1-3 digits) and remaining digits
                // For +1 (US/Canada), it's 1 digit country code + 10 digit number
                val countryCode = allDigits.substring(0, 1)  // First digit is country code
                val areaCode = allDigits.substring(1, 4)
                val exchange = allDigits.substring(4, 7)
                val subscriber = allDigits.substring(7, 11)
                "+$countryCode ($areaCode) $exchange-$subscriber"
            }
            // North American without +: 10 digits
            !hasPlus && allDigits.length == 10 -> {
                val areaCode = allDigits.substring(0, 3)
                val exchange = allDigits.substring(3, 6)
                val subscriber = allDigits.substring(6, 10)
                "($areaCode) $exchange-$subscriber"
            }
            // Default: return original if format doesn't match
            else -> phoneNumber
        }
    }


    private fun sendBroadcastEvent(ctx: Context, event: String, callSid: String?, extras: Bundle? = null) {
        // Cancel ongoing call notification when call ends, but ONLY if no other calls remain
        if (event == TVBroadcastReceiver.ACTION_CALL_ENDED && !hasActiveCalls()) {
            cancelOngoingCallNotification()
        }
        
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
            setSmallIcon(R.drawable.ic_transparent)
        }.build()
    }

    private fun cancelAllNotifications() {
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(INCOMING_CALL_NOTIFICATION_ID)
        notificationManager.cancel(ONGOING_CALL_NOTIFICATION_ID)
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
        // Stop the ongoing call duration updater if running
        stopOngoingCallDurationUpdater()
        // Clear all stored call start times since all calls are ending
        callStartTimes.clear()
        try {
            // Use STOP_FOREGROUND_REMOVE to properly remove the foreground notification.
            // Previously used SERVICE_TYPE_MICROPHONE (100) as flags, but 100 doesn't include
            // STOP_FOREGROUND_REMOVE (1), so the notification was never actually removed.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            cancelAllNotifications()
        } catch (e: java.lang.Exception) {
            Log.w(TAG, "[VoiceConnectionService] can't stop foreground service :$e")
        }
    }
    
    private fun getOrCreateOngoingCallChannel(): NotificationChannel {
        val id = "${applicationContext.packageName}_ongoing_calls"
        val name = "Ongoing Calls"
        val descriptionText = "Active Voice Calls"
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        // Delete v2 channel if it exists (was a temporary experiment)
        try {
            notificationManager.deleteNotificationChannel("${applicationContext.packageName}_ongoing_calls_v2")
        } catch (_: Exception) {}
        
        // Use IMPORTANCE_DEFAULT for ongoing calls - shows in notification shade but no sound
        val importance = NotificationManager.IMPORTANCE_DEFAULT
        val channel = NotificationChannel(id, name, importance).apply {
            description = descriptionText
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null) // No sound for ongoing call notification
            enableVibration(false)
            setShowBadge(true)
        }
        notificationManager.createNotificationChannel(channel)
        return channel
    }
    
    private fun showOngoingCallNotification(callSid: String, callerName: String?, heldCallerName: String? = null) {
        Log.d(TAG, "[VoiceConnectionService] showOngoingCallNotification for callSid: $callSid, heldCallerName: $heldCallerName")
        
        val channel = getOrCreateOngoingCallChannel()
        
        // Create intent to launch main app when notification is tapped
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            // Use SINGLE_TOP + REORDER_TO_FRONT to preserve existing Flutter activity state
            // CLEAR_TOP was destroying and recreating MainActivity on notification tap during calls
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra("fromOngoingCall", true)
            putExtra("callHandle", callSid)
        }
        val contentIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        // Create hang up action
        val hangupIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = ACTION_HANGUP
            putExtra(EXTRA_CALL_HANDLE, callSid)
        }
        val hangupPendingIntent = PendingIntent.getService(
            applicationContext,
            2,
            hangupIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        val displayName = callerName ?: "Unknown"
        
        // Use the stored start time for this call if available (e.g. held call resuming),
        // otherwise record a new start time. This prevents the Chronometer from resetting
        // to 00:00 when a held call's notification is re-shown after the other call ends.
        val callStartTime = callStartTimes.getOrPut(callSid) { System.currentTimeMillis() }
        
        // On Android 12+ (API 31), CallStyle uses Android's built-in Chronometer
        // so we build the notification ONCE and let the OS handle the timer.
        // On older Android, we use a handler to manually update the custom RemoteViews every second.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val notification = buildOngoingCallNotification(
                displayName, "00:00", channel, contentIntent, hangupPendingIntent, callStartTime, heldCallerName
            )
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(ONGOING_CALL_NOTIFICATION_ID, notification, 
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                } else {
                    startForeground(ONGOING_CALL_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
                }
                Log.d(TAG, "[VoiceConnectionService] Started foreground service with CallStyle notification (Chronometer)")
            } catch (e: Exception) {
                Log.w(TAG, "[VoiceConnectionService] Could not start foreground with ongoing call notification: ${e.message}")
                try {
                    val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    notificationManager.notify(ONGOING_CALL_NOTIFICATION_ID, notification)
                } catch (e2: Exception) {
                    Log.e(TAG, "[VoiceConnectionService] Fallback notify also failed: ${e2.message}")
                }
            }
        } else {
            // Older Android: use handler-based duration updater with custom RemoteViews
            startOngoingCallDurationUpdater(callSid, displayName, callStartTime, channel, contentIntent, hangupPendingIntent, heldCallerName)
        }
    }
    
    // Handler for updating ongoing call notification duration
    private var ongoingCallHandler: android.os.Handler? = null
    private var ongoingCallRunnable: Runnable? = null
    
    private fun startOngoingCallDurationUpdater(
        callSid: String,
        displayName: String,
        callStartTime: Long,
        channel: NotificationChannel,
        contentIntent: PendingIntent,
        hangupPendingIntent: PendingIntent,
        heldCallerName: String? = null
    ) {
        // Cancel any existing handler
        stopOngoingCallDurationUpdater()
        
        ongoingCallHandler = android.os.Handler(android.os.Looper.getMainLooper())
        ongoingCallRunnable = object : Runnable {
            override fun run() {
                // Calculate duration
                val durationMs = System.currentTimeMillis() - callStartTime
                val durationText = formatCallDuration(durationMs)
                
                // Build and update notification
                val notification = buildOngoingCallNotification(
                    displayName, durationText, channel, contentIntent, hangupPendingIntent, 0L, heldCallerName
                )
                
                try {
                    val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    notificationManager.notify(ONGOING_CALL_NOTIFICATION_ID, notification)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to update ongoing call notification: ${e.message}")
                }
                
                // Update every second
                ongoingCallHandler?.postDelayed(this, 1000)
            }
        }
        
        // Build initial notification and start foreground
        val initialNotification = buildOngoingCallNotification(
            displayName, "00:00", channel, contentIntent, hangupPendingIntent, 0L, heldCallerName
        )
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(ONGOING_CALL_NOTIFICATION_ID, initialNotification, 
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ONGOING_CALL_NOTIFICATION_ID, initialNotification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else {
                startForeground(ONGOING_CALL_NOTIFICATION_ID, initialNotification)
            }
            Log.d(TAG, "[VoiceConnectionService] Started foreground service with ongoing call notification")
        } catch (e: Exception) {
            Log.w(TAG, "[VoiceConnectionService] Could not start foreground with ongoing call notification: ${e.message}")
            try {
                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notificationManager.notify(ONGOING_CALL_NOTIFICATION_ID, initialNotification)
            } catch (e2: Exception) {
                Log.e(TAG, "[VoiceConnectionService] Fallback notify also failed: ${e2.message}")
            }
        }
        
        // Start updating after 1 second
        ongoingCallHandler?.postDelayed(ongoingCallRunnable!!, 1000)
    }
    
    private fun stopOngoingCallDurationUpdater() {
        ongoingCallRunnable?.let { ongoingCallHandler?.removeCallbacks(it) }
        ongoingCallHandler = null
        ongoingCallRunnable = null
    }
    
    private fun formatCallDuration(durationMs: Long): String {
        val totalSeconds = durationMs / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        
        return if (hours > 0) {
            String.format("%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format("%02d:%02d", minutes, seconds)
        }
    }
    
    private fun buildOngoingCallNotification(
        displayName: String,
        durationText: String,
        channel: NotificationChannel,
        contentIntent: PendingIntent,
        hangupPendingIntent: PendingIntent,
        callStartTime: Long = 0L,
        heldCallerName: String? = null
    ): Notification {
        // On Android 12+ (API 31), use Notification.CallStyle which gives the
        // WhatsApp-style compact chip on the lock screen showing caller name + duration.
        // We use setUsesChronometer(true) + setWhen(callStartTime) so the OS handles
        // the timer natively — no need to rebuild the notification every second.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Build the Person name. When there's a held call, append it so
            // the compact lock-screen chip shows both callers, e.g.
            // "Active Name · On hold: Held Name"
            val personName = if (heldCallerName != null) {
                "$displayName · On hold: $heldCallerName"
            } else {
                displayName
            }
            val caller = Person.Builder()
                .setName(personName)
                .setImportant(true)
                .build()
            
            return Notification.Builder(this, channel.id).apply {
                setOngoing(true)
                setSmallIcon(R.drawable.ic_transparent)
                setContentIntent(contentIntent)
                setCategory(Notification.CATEGORY_CALL)
                setVisibility(Notification.VISIBILITY_PUBLIC)
                setColorized(true)
                setColor(Color.parseColor("#1C1C1E"))
                // CallStyle.forOngoingCall renders the lock screen chip (like WhatsApp)
                style = Notification.CallStyle.forOngoingCall(caller, hangupPendingIntent)
                // Also set contentText for the expanded notification view
                if (heldCallerName != null) {
                    setContentText("On hold: $heldCallerName")
                }
                // Let Android's built-in Chronometer handle the call duration display
                setUsesChronometer(true)
                setWhen(callStartTime)
            }.build()
        }
        
        // Fallback for Android < 12: use custom RemoteViews layout
        val remoteViews = android.widget.RemoteViews(packageName, R.layout.notification_ongoing_call)
        
        // Set caller name (title)
        remoteViews.setTextViewText(R.id.caller_name, displayName)
        
        // Set call duration (subtitle)
        remoteViews.setTextViewText(R.id.call_duration, durationText)
        
        // Set held caller info if available
        if (heldCallerName != null) {
            remoteViews.setTextViewText(R.id.held_caller_info, "On hold: $heldCallerName")
            remoteViews.setViewVisibility(R.id.held_caller_info, android.view.View.VISIBLE)
        } else {
            remoteViews.setViewVisibility(R.id.held_caller_info, android.view.View.GONE)
        }
        
        // Set hangup button click action
        remoteViews.setOnClickPendingIntent(R.id.hangup_button, hangupPendingIntent)
        
        return Notification.Builder(this, channel.id).apply {
            setOngoing(true)
            setSmallIcon(R.drawable.ic_transparent)
            setContentIntent(contentIntent)
            setCategory(Notification.CATEGORY_CALL)
            setVisibility(Notification.VISIBILITY_PUBLIC)
            setShowWhen(false)
            setColorized(true)
            setColor(Color.parseColor("#1C1C1E"))
            setContentTitle("")
            setContentText("")
            style = Notification.DecoratedMediaCustomViewStyle()
            
            // Use custom view for the notification content
            setCustomContentView(remoteViews)
            setCustomBigContentView(remoteViews)
        }.build()
    }
    
    private fun cancelOngoingCallNotification() {
        // Stop the duration updater
        stopOngoingCallDurationUpdater()
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        if (hasActiveCalls()) {
            // Other calls still exist (e.g. a ringing incoming call).
            // Do NOT call stopForeground() — that removes the CURRENT foreground
            // notification which may be the incoming-call notification (ID 101),
            // not the ongoing-call notification (ID 102).
            // Instead, just cancel the ongoing notification by its specific ID.
            Log.d(TAG, "[VoiceConnectionService] cancelOngoingCallNotification - other calls active, cancelling by ID only")
            notificationManager.cancel(ONGOING_CALL_NOTIFICATION_ID)
        } else {
            // No other calls remain — safe to fully stop the foreground service.
            Log.d(TAG, "[VoiceConnectionService] cancelOngoingCallNotification - no other calls, stopping foreground")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            } catch (e: Exception) {
                Log.w(TAG, "[VoiceConnectionService] Error stopping foreground for ongoing call: ${e.message}")
            }
            // Also cancel via NotificationManager as fallback
            notificationManager.cancel(ONGOING_CALL_NOTIFICATION_ID)
        }
    }

    private fun getOrCreateIncomingCallChannel(): NotificationChannel {
        val id = "${applicationContext.packageName}_incoming_calls_v7"
        val name = "Incoming Calls"
        val descriptionText = "Incoming Voice Calls"
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        // Delete old channels if exists (in case importance or settings were cached)
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls")
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls_v2")
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls_v3")
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls_v4")
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls_v5")
        notificationManager.deleteNotificationChannel("${applicationContext.packageName}_incoming_calls_v6")
        
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

    /**
     * Creates a circular gradient bitmap for the caller avatar.
     * If callerName is a real name (not "Unknown Caller"), shows the initials.
     * Otherwise, draws a person icon silhouette.
     * The gradient goes from a lighter dark gray to a deeper dark,
     * with a subtle ring border — matching the metallic look from the design.
     */
    private fun createCallerAvatarBitmap(callerName: String, sizeDp: Int = 64): Bitmap {
        val density = resources.displayMetrics.density
        val sizePx = (sizeDp * density).toInt()
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val cx = sizePx / 2f
        val cy = sizePx / 2f
        val radius = sizePx / 2f

        // Outer ring: subtle gray gradient border
        val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, sizePx.toFloat(), sizePx.toFloat(),
                Color.parseColor("#5A5A5A"),
                Color.parseColor("#3A3A3A"),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(cx, cy, radius, ringPaint)

        // Inner fill: dark radial gradient for metallic/3D look
        val innerRadius = radius - (2 * density) // 2dp border
        val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                cx * 0.8f, cy * 0.7f, innerRadius * 1.2f,
                Color.parseColor("#4A4A4A"),
                Color.parseColor("#1A1A1A"),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(cx, cy, innerRadius, innerPaint)

        val hasName = callerName != "Unknown Caller" && callerName.isNotBlank() &&
            // Detect phone numbers: if after removing common phone chars (+, -, (, ), spaces, dots)
            // the remaining string is all digits, it's a phone number, not a real name
            !callerName.replace(Regex("[+\\-()\\s.]"), "").all { it.isDigit() }

        if (hasName) {
            // Draw initials
            val initials = callerName.split(" ")
                .filter { it.isNotBlank() }
                .take(2)
                .joinToString("") { it.first().uppercase() }

            val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = sizePx * 0.35f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
            val textBounds = Rect()
            textPaint.getTextBounds(initials, 0, initials.length, textBounds)
            val textY = cy + textBounds.height() / 2f
            canvas.drawText(initials, cx, textY, textPaint)
        } else {
            // Draw person icon silhouette
            val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.parseColor("#CCCCCC")
                style = Paint.Style.FILL
            }
            // Head circle
            val headRadius = sizePx * 0.15f
            val headCy = cy - sizePx * 0.08f
            canvas.drawCircle(cx, headCy, headRadius, iconPaint)

            // Body arc (shoulders)
            val bodyTop = headCy + headRadius + sizePx * 0.06f
            val bodyRect = android.graphics.RectF(
                cx - sizePx * 0.28f,
                bodyTop,
                cx + sizePx * 0.28f,
                bodyTop + sizePx * 0.36f
            )
            canvas.drawOval(bodyRect, iconPaint)
        }

        return bitmap
    }

    /**
     * Extracts caller initials from a name string.
     * E.g., "John Doe" → "JD", "Alice" → "A", "Unknown Caller" → "", phone numbers → ""
     */
    private fun getCallerInitials(callerName: String): String {
        if (callerName == "Unknown Caller" || callerName.isBlank()) return ""
        // Don't generate initials from phone numbers
        if (callerName.replace(Regex("[+\\-()\\s.]"), "").all { it.isDigit() }) return ""
        return callerName.split(" ")
            .filter { it.isNotBlank() }
            .take(2)
            .joinToString("") { it.first().uppercase() }
    }

    private fun createIncomingCallNotification(callInvite: CallInvite): Notification {
        val shortSid = callInvite.callSid.takeLast(6)
        Log.d(TAG, "[SVC-$shortSid] ┌─ createIncomingCallNotification ────────────────────┐")
        
        val channel = getOrCreateIncomingCallChannel()
        
        // Create full-screen intent for incoming call activity
        // Use unique request code to avoid PendingIntent caching
        val fullScreenRequestCode = (callInvite.callSid.hashCode() and 0x7FFFFFFF) % 10000 + 1000
        val fullScreenIntent = IncomingCallActivity.createIntent(applicationContext, callInvite)
        
        // IMPORTANT: Include active call extras in fullScreenIntent so that if the system
        // fires the fullScreenIntent (e.g. lock screen), the IncomingCallActivity knows
        // about the active call and shows the call-waiting bottom sheet instead of
        // answering directly.
        if (hasActiveCallDuringIncoming) {
            fullScreenIntent.putExtra(IncomingCallActivity.EXTRA_HAS_ACTIVE_CALL, true)
            fullScreenIntent.putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALLER_NAME, activeCallCallerName)
            fullScreenIntent.putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALLER_NUMBER, activeCallCallerNumber)
            fullScreenIntent.putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALL_HANDLE, activeCallHandleDuringIncoming)
            Log.d(TAG, "[SVC-$shortSid] │ Added active call extras to fullScreenIntent")
        }
        
        val fullScreenPendingIntent = PendingIntent.getActivity(
            applicationContext,
            fullScreenRequestCode,
            fullScreenIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        Log.d(TAG, "[SVC-$shortSid] │ Created fullScreenPendingIntent (requestCode=$fullScreenRequestCode)")
        Log.d(TAG, "[SVC-$shortSid] │ CallSid in fullScreenIntent: ${callInvite.callSid}")

        // Use unique request codes based on callSid hash to avoid PendingIntent caching issues
        val answerServiceRequestCode = (callInvite.callSid.hashCode() and 0x7FFFFFFF) % 10000 + 2000
        val declineRequestCode = (callInvite.callSid.hashCode() and 0x7FFFFFFF) % 10000 + 3000
        Log.d(TAG, "createIncomingCallNotification: answerServiceRequestCode=$answerServiceRequestCode, declineRequestCode=$declineRequestCode")
        
        // Create answer intent - include CallInvite for terminated state recovery
        val answerIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = ACTION_ANSWER
            putExtra(EXTRA_CALL_HANDLE, callInvite.callSid)
            putExtra(EXTRA_INCOMING_CALL_INVITE, callInvite)
            // Add unique data URI to ensure PendingIntent is unique
            data = android.net.Uri.parse("twilio://answer-service/${callInvite.callSid}")
        }
        val answerPendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                applicationContext,
                answerServiceRequestCode,
                answerIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                applicationContext,
                answerServiceRequestCode,
                answerIntent,
                PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Create decline intent - include CallInvite for terminated state recovery
        val declineIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = ACTION_HANGUP
            putExtra(EXTRA_CALL_HANDLE, callInvite.callSid)
            putExtra(EXTRA_INCOMING_CALL_INVITE, callInvite)
            // Add unique data URI to ensure PendingIntent is unique
            data = android.net.Uri.parse("twilio://decline/${callInvite.callSid}")
        }
        val declinePendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                applicationContext,
                declineRequestCode,
                declineIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                applicationContext,
                declineRequestCode,
                declineIntent,
                PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Extract caller info
        val callerName = callInvite.customParameters["client_name"] ?: "Unknown Caller"
        val callerNumber = extractUserNumber(callInvite.from ?: "")
        val formattedCallerNumber = formatPhoneNumber(callerNumber)
        val myNumber = callInvite.to ?: ""
        
        // Use unique request code based on callSid hash to avoid PendingIntent caching issues
        val answerRequestCode = (callInvite.callSid.hashCode() and 0x7FFFFFFF) % 10000 + 1000
        Log.d(TAG, "createIncomingCallNotification: Creating answer intent with requestCode=$answerRequestCode for callSid=${callInvite.callSid}")
        
        // Create an intent that launches IncomingCallActivity with answer action
        val answerActivityIntent = Intent(applicationContext, IncomingCallActivity::class.java).apply {
            // Use flags that ensure the activity is started even when app is in foreground
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or 
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(IncomingCallActivity.EXTRA_CALL_SID, callInvite.callSid)
            putExtra(IncomingCallActivity.EXTRA_CALL_INVITE, callInvite)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NUMBER, callerNumber)
            putExtra("extra_my_number", myNumber)
            putExtra("action", "answer")
            // Pass active call info so handleAnswerFromNotification can show
            // the call-waiting bottom sheet instead of answering directly
            if (hasActiveCallDuringIncoming) {
                putExtra(IncomingCallActivity.EXTRA_HAS_ACTIVE_CALL, true)
                putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALLER_NAME, activeCallCallerName)
                putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALLER_NUMBER, activeCallCallerNumber)
                putExtra(IncomingCallActivity.EXTRA_ACTIVE_CALL_HANDLE, activeCallHandleDuringIncoming)
                Log.d(TAG, "createIncomingCallNotification: Added active call extras to answerActivityIntent")
            }
            // Add a unique data URI to ensure PendingIntent is unique and not cached
            data = android.net.Uri.parse("twilio://answer/${callInvite.callSid}")
        }
        val answerActivityPendingIntent = PendingIntent.getActivity(
            applicationContext,
            answerRequestCode,
            answerActivityIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE 
            else 
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        // Use CallStyle for Android 12+ for native incoming call UI in notification
        // Determine what to show: if caller has name, show name on top and number below
        // If no name, show number on top only
        val isPhoneNumber = callerName.replace(Regex("[+\\-()\\s.]"), "").all { it.isDigit() }
        val hasCallerName = callerName != "Unknown Caller" && callerName.isNotEmpty() && !isPhoneNumber
        val displayName = if (hasCallerName) callerName else formattedCallerNumber.ifEmpty { "Unknown Number" }
        val displaySubtext = if (hasCallerName && formattedCallerNumber.isNotEmpty()) formattedCallerNumber else null
        
        // Generate the circular gradient avatar bitmap
        val avatarBitmap = createCallerAvatarBitmap(callerName)
        
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ — use CallStyle for native incoming call UI
            // Note: CallStyle renders system-controlled text, so custom fonts are not possible here
            val callerPerson = Person.Builder()
                .setName(displayName)
                .setIcon(Icon.createWithBitmap(avatarBitmap))
                .setImportant(true)
                .build()
            
            val callStyle = Notification.CallStyle.forIncomingCall(
                callerPerson,
                declinePendingIntent,
                answerActivityPendingIntent
            )
            
            Notification.Builder(this, channel.id).apply {
                setSmallIcon(R.drawable.ic_easify_logo_mono)
                setVisibility(Notification.VISIBILITY_PUBLIC)
                setOngoing(true)
                setAutoCancel(false)
                setShowWhen(false)
                setFullScreenIntent(fullScreenPendingIntent, true)
                setContentIntent(fullScreenPendingIntent)
                setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                setCategory(Notification.CATEGORY_CALL)
                setContentTitle(displayName)
                setContentText(displaySubtext ?: "Incoming Call")
                style = callStyle
            }
        } else {
            // Pre-Android 12 — use custom RemoteViews for full control over fonts/colors
            val customView = RemoteViews(packageName, R.layout.notification_incoming_call)
            customView.setTextViewText(R.id.notification_caller_name, displayName)
            customView.setTextViewText(R.id.notification_caller_number, displaySubtext ?: "Incoming Call")
            customView.setImageViewBitmap(R.id.notification_avatar, avatarBitmap)
            customView.setOnClickPendingIntent(R.id.notification_decline_button, declinePendingIntent)
            customView.setOnClickPendingIntent(R.id.notification_answer_button, answerActivityPendingIntent)
            
            Notification.Builder(this, channel.id).apply {
                setOngoing(true)
                setSmallIcon(R.drawable.ic_easify_logo_mono)
                setFullScreenIntent(fullScreenPendingIntent, true)
                setContentIntent(fullScreenPendingIntent)
                setVisibility(Notification.VISIBILITY_PUBLIC)
                setAutoCancel(false)
                setShowWhen(false)
                setCategory(Notification.CATEGORY_CALL)
                setColorized(true)
                setColor(Color.parseColor("#1C1C1E"))
                setContentTitle("")
                setContentText("")
                style = Notification.DecoratedMediaCustomViewStyle()
                setCustomContentView(customView)
                setCustomBigContentView(customView)
                setCustomHeadsUpContentView(customView)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    @Suppress("DEPRECATION")
                    setPriority(Notification.PRIORITY_MAX)
                }
            }
        }
        
        return builder.build()
    }

    private fun startIncomingCallForegroundService(callInvite: CallInvite) {
        val shortSid = callInvite.callSid.takeLast(6)
        Log.d(TAG, "[SVC-$shortSid] ┌─ startIncomingCallForegroundService ─────────────┐")
        Log.d(TAG, "[SVC-$shortSid] │ Creating notification...")
        
        val notification = createIncomingCallNotification(callInvite)
        Log.d(TAG, "[SVC-$shortSid] │ Notification created")
        
        // Step 1: Acquire wake lock to ensure the screen turns on.
        // This is critical so that Android's fullScreenIntent fires when the device
        // is locked/screen-off. Without waking the screen, the system may not launch
        // the full-screen Activity on some devices.
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            @Suppress("DEPRECATION")
            val wakeLockFlags = PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE
            incomingCallWakeLock = powerManager?.newWakeLock(wakeLockFlags, "TwilioVoice:IncomingCallWakeLock")
            incomingCallWakeLock?.acquire(60000) // 60 seconds for incoming call
            Log.d(TAG, "[SVC-$shortSid] │ Acquired wake lock to turn screen on")
        } catch (e: Exception) {
            Log.w(TAG, "[SVC-$shortSid] │ Failed to acquire wake lock: $e")
        }
        
        // Step 2: Start foreground service with the notification.
        // The notification has setFullScreenIntent which Android handles automatically:
        //   - Device locked/screen off → Android launches the full-screen IncomingCallActivity
        //   - Device unlocked/in use → Android shows a heads-up notification
        // We do NOT manually launch IncomingCallActivity — that caused both the
        // full-screen UI and heads-up notification to appear simultaneously.
        Log.d(TAG, "[SVC-$shortSid] │ Starting foreground service...")
        
        try {
            // For incoming call notification (before answering), use PHONE_CALL type only
            // MICROPHONE type requires RECORD_AUDIO permission to be granted at runtime
            // which may not be available yet when showing the incoming call UI
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14+ - use PHONE_CALL type
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification, 
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
                Log.d(TAG, "[SVC-$shortSid] │ Started foreground with PHONE_CALL type (Android 14+)")
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10-13 - use SHORT_SERVICE or default
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
                Log.d(TAG, "[SVC-$shortSid] │ Started foreground (Android 10-13)")
            } else {
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
                Log.d(TAG, "[SVC-$shortSid] │ Started foreground (pre-Android 10)")
            }
            
            // Step 3: Start ringtone and vibration for incoming call
            Log.d(TAG, "[SVC-$shortSid] │ Starting ringtone...")
            startRinging()
            
            Log.d(TAG, "[SVC-$shortSid] │ Relying on fullScreenIntent for display:")
            Log.d(TAG, "[SVC-$shortSid] │   Locked → full-screen IncomingCallActivity")
            Log.d(TAG, "[SVC-$shortSid] │   Unlocked → heads-up notification")
            Log.d(TAG, "[SVC-$shortSid] └────────────────────────────────────────────────────┘")
            
        } catch (e: Exception) {
            Log.w(TAG, "[SVC-$shortSid] Can't start incoming call foreground service : $e")
            // Fallback: try without specific service type
            try {
                startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
                // Start ringtone even if fallback
                startRinging()
            } catch (e2: Exception) {
                Log.e(TAG, "[SVC-$shortSid] Fallback foreground service also failed: $e2")
            }
        }
    }
    
    // NOTE: showIncomingCallOverLockScreen() and launchIncomingCallActivity() were REMOVED.
    // They were the root cause of the dual full-screen + heads-up notification bug.
    // Android's setFullScreenIntent now handles display mode automatically:
    //   - Device locked/screen off → launches IncomingCallActivity full-screen
    //   - Device unlocked/in use → shows persistent heads-up notification
    // See INCOMING_CALL_NOTIFICATION_RESEARCH.md for full analysis.
    
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
    
    /**
     * Bring the main activity to the front WITHOUT passing call data extras.
     * Used when returning to an active call (e.g. after declining a second incoming call).
     * This avoids resetting Flutter's call state/timer by not sending CALL_ANSWERED/fromIncomingCall.
     */
    private fun bringMainActivityToFront() {
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            launchIntent?.let { intent ->
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                               Intent.FLAG_ACTIVITY_SINGLE_TOP or
                               Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                startActivity(intent)
                Log.d(TAG, "bringMainActivityToFront: Brought main activity to front (no call data)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "bringMainActivityToFront: Failed: ${e.message}")
        }
    }
    
    private fun launchMainActivityWithCallData(callSid: String, callerNumber: String, myNumber: String) {
        try {
            // ARCHITECTURE: MainActivity NEVER shows over lock screen.
            // If locked, skip launch — pendingAnsweredCallData was already stored
            // by the caller (IncomingCallActivity or ACTION_ANSWER handler).
            // MainActivity.onResume() will pick it up when the user unlocks normally.
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            if (keyguardManager?.isKeyguardLocked == true) {
                Log.d(TAG, "launchMainActivityWithCallData: Device is locked - skipping MainActivity launch (pendingAnsweredCallData will handle it on unlock)")
                return
            }
            
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            launchIntent?.let { intent ->
                // Use SINGLE_TOP + REORDER_TO_FRONT to preserve existing Flutter activity
                // CLEAR_TOP destroys and recreates MainActivity, killing Flutter engine state
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                               Intent.FLAG_ACTIVITY_SINGLE_TOP or
                               Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                intent.putExtra("fromIncomingCall", true)
                intent.putExtra("callHandle", callSid)
                intent.putExtra("callAnswered", true)
                // NOTE: No SHOW_OVER_LOCK_SCREEN extra — MainActivity never shows over
                // lock screen. The locked path returned early above (keyguard check).
                intent.putExtra("CALL_ANSWERED", true)
                intent.putExtra("CALL_SID", callSid)
                intent.putExtra("CALLER_NAME", callerNumber)
                intent.putExtra("CALLER_NUMBER", callerNumber)
                intent.putExtra("MY_NUMBER", myNumber)
                intent.putExtra("CALL_DIRECTION", "incoming")
                startActivity(intent)
                Log.d(TAG, "launchMainActivityWithCallData: Launched (UNLOCKED path) with caller=$callerNumber")
            }
        } catch (e: Exception) {
            Log.w(TAG, "launchMainActivityWithCallData: Failed: ${e.message}")
        }
    }
    
    private fun isCallHandled(callSid: String): Boolean {
        // Check if call is still pending (not answered or declined)
        val connection = activeConnections[callSid]
        return connection == null || connection.state != Connection.STATE_RINGING
    }

    private fun cancelIncomingCallNotification() {
        Log.d(TAG, "[VoiceConnectionService] cancelIncomingCallNotification")
        // Stop ringtone when cancelling notification
        stopRinging()
        
        val notificationManager: NotificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        if (hasActiveCalls()) {
            // Other calls still exist — an ongoing call notification (ID 102) is likely the
            // current foreground notification.  stopForeground(STOP_FOREGROUND_REMOVE) would
            // strip the service's foreground status and remove THAT notification, killing the
            // ongoing-call indicator.  Instead, just cancel the incoming notification by its
            // specific ID and leave the foreground state untouched.
            Log.d(TAG, "[VoiceConnectionService] cancelIncomingCallNotification - other calls active, cancelling incoming notification by ID only (preserving foreground)")
            notificationManager.cancel(INCOMING_CALL_NOTIFICATION_ID)
        } else {
            // No other calls remain — safe to fully stop the foreground service.
            Log.d(TAG, "[VoiceConnectionService] cancelIncomingCallNotification - no other calls, stopping foreground")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            } catch (e: Exception) {
                Log.w(TAG, "[VoiceConnectionService] Error stopping foreground for incoming call: $e")
            }
            // Also cancel via NotificationManager as a fallback
            notificationManager.cancel(INCOMING_CALL_NOTIFICATION_ID)
        }
    }
    
    private fun startRinging() {
        if (isRinging) return
        isRinging = true
        
        Log.d(TAG, "[VoiceConnectionService] Starting ringtone and vibration")
        
        try {
            // Get the default ringtone URI
            val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(applicationContext, ringtoneUri)
            
            ringtone?.let { ring ->
                // Set audio attributes for ringtone (call category)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    val audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    ring.audioAttributes = audioAttributes
                }
                
                // Set looping for continuous ringing
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    ring.isLooping = true
                }
                
                ring.play()
                Log.d(TAG, "[VoiceConnectionService] Ringtone started playing")
            }
        } catch (e: Exception) {
            Log.e(TAG, "[VoiceConnectionService] Error starting ringtone: ${e.message}", e)
        }
        
        // Start vibration
        try {
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vibratorManager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            
            vibrator?.let { vib ->
                if (vib.hasVibrator()) {
                    // Vibrate pattern: wait 0ms, vibrate 1000ms, pause 1000ms, repeat
                    val pattern = longArrayOf(0, 1000, 1000)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        vib.vibrate(VibrationEffect.createWaveform(pattern, 0)) // 0 = repeat from index 0
                    } else {
                        @Suppress("DEPRECATION")
                        vib.vibrate(pattern, 0)
                    }
                    Log.d(TAG, "[VoiceConnectionService] Vibration started")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "[VoiceConnectionService] Error starting vibration: ${e.message}", e)
        }
    }
    
    private fun stopRinging() {
        if (!isRinging) return
        isRinging = false
        
        Log.d(TAG, "[VoiceConnectionService] Stopping ringtone and vibration")
        
        try {
            ringtone?.let { ring ->
                if (ring.isPlaying) {
                    ring.stop()
                }
            }
            ringtone = null
        } catch (e: Exception) {
            Log.e(TAG, "[VoiceConnectionService] Error stopping ringtone: ${e.message}", e)
        }
        
        try {
            vibrator?.cancel()
            vibrator = null
        } catch (e: Exception) {
            Log.e(TAG, "[VoiceConnectionService] Error stopping vibration: ${e.message}", e)
        }
    }
}

package com.twilio.twilio_voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RenderEffect
import android.graphics.Shader
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import android.view.View
import android.view.MotionEvent
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.voice.CallInvite

/**
 * Full-screen incoming call activity that shows native UI for answering/declining calls.
 * This is shown when the app receives an incoming call and allows the user to answer or decline.
 * After answering, the Flutter UI will be shown.
 */
class IncomingCallActivity : AppCompatActivity() {
    // Logging counters
    private var log_showCallWaitingBottomSheetCounter: Int = 0
    private var log_acceptButtonCounter: Int = 0

    companion object {
        private const val TAG = "IncomingCallActivity"
        
        /**
         * Static flag to track whether IncomingCallActivity is currently alive/showing.
         * Used by TVConnectionService to avoid launching a second instance when the
         * notification's fullScreenIntent has already opened the activity.
         */
        @Volatile
        @JvmStatic
        var isActivityAlive: Boolean = false
            private set
        
        const val EXTRA_CALL_INVITE = "EXTRA_CALL_INVITE"
        const val EXTRA_CALLER_NAME = "EXTRA_CALLER_NAME"
        const val EXTRA_CALLER_NUMBER = "EXTRA_CALLER_NUMBER"
        const val EXTRA_CALL_SID = "EXTRA_CALL_SID"
        const val EXTRA_HAS_ACTIVE_CALL = "EXTRA_HAS_ACTIVE_CALL"
        const val EXTRA_ACTIVE_CALLER_NAME = "EXTRA_ACTIVE_CALLER_NAME"
        const val EXTRA_ACTIVE_CALLER_NUMBER = "EXTRA_ACTIVE_CALLER_NUMBER"
        const val EXTRA_ACTIVE_CALL_HANDLE = "EXTRA_ACTIVE_CALL_HANDLE"
        private const val REQUEST_RECORD_AUDIO_PERMISSION = 200

        fun createIntent(context: Context, callInvite: CallInvite): Intent {
            return Intent(context, IncomingCallActivity::class.java).apply {
                // Flags for lock screen incoming call display
                // FLAG_ACTIVITY_NO_USER_ACTION is critical for fullScreenIntent on lock screen
                // NOTE: FLAG_ACTIVITY_CLEAR_TOP is intentionally NOT used here because
                // combined with singleInstance launchMode it destroys the existing activity
                // and recreates it, causing a "double bottom sheet" flash when the
                // notification's fullScreenIntent and the explicit launchIncomingCallActivity
                // both fire. With singleInstance, the system will deliver onNewIntent instead.
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION
                
                // Add action to ensure proper handling
                action = "com.twilio.twilio_voice.INCOMING_CALL"
                
                putExtra(EXTRA_CALL_INVITE, callInvite)
                putExtra(EXTRA_CALL_SID, callInvite.callSid)
                
                // Extract caller info from custom parameters or from field
                val callerName = callInvite.customParameters["client_name"] ?: "Unknown"
                val callerNumber = extractUserNumber(callInvite.from ?: "Unknown")
                putExtra(EXTRA_CALLER_NAME, callerName)
                putExtra(EXTRA_CALLER_NUMBER, callerNumber)
            }
        }

        private fun extractUserNumber(input: String): String {
            val pattern = Regex("""user_number:([^\s:]+)""")
            val match = pattern.find(input)
            return match?.groups?.get(1)?.value ?: input
        }
    }

    private var callInvite: CallInvite? = null
    private var callSid: String? = null
    private var callerName: String? = null
    private var callerNumber: String? = null
    private var myNumber: String? = null  // The number receiving the call (to)
    private var wakeLock: PowerManager.WakeLock? = null
    
    // Call waiting state - active call info when this is a second incoming call
    private var hasActiveCall = false
    private var activeCallerName: String? = null
    private var activeCallerNumber: String? = null
    private var activeCallHandle: String? = null
    
    // Ringtone and vibration for incoming call
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false
    
    // Idempotency flag to prevent double-handling of answer/decline
    @Volatile
    private var callHandled = false
    
    // Guard to prevent showing the bottom sheet multiple times
    private var isBottomSheetShowing = false
    
    // Helper function to extract user number from Twilio format
    private fun extractUserNumber(input: String): String {
        val pattern = Regex("""user_number:([^\s:]+)""")
        val match = pattern.find(input)
        return match?.groups?.get(1)?.value ?: input
    }
    
    // Broadcast receiver to listen for call ended events (e.g., from notification decline)
    private val callEndedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action
            android.util.Log.d(TAG, "Received broadcast: $action")
            if (action == TVBroadcastReceiver.ACTION_CALL_ENDED) {
                // Call was ended (possibly from notification), close this activity
                android.util.Log.d(TAG, "Call ended broadcast received, finishing activity")
                stopRinging()
                callHandled = true
                releaseWakeLock()
                finishAndRemoveTask()
            }
        }
    }

    @SuppressLint("WakelockTimeout")
    override fun onCreate(savedInstanceState: Bundle?) {
    android.util.Log.d(TAG, "[LOG] onCreate: intent extras: " + intent.extras?.keySet()?.joinToString() + ", hasActiveCall=" + intent.getBooleanExtra(EXTRA_HAS_ACTIVE_CALL, false) + ", activeCallerName=" + intent.getStringExtra(EXTRA_ACTIVE_CALLER_NAME) + ", activeCallerNumber=" + intent.getStringExtra(EXTRA_ACTIVE_CALLER_NUMBER) + ", activeCallHandle=" + intent.getStringExtra(EXTRA_ACTIVE_CALL_HANDLE))
    // Enhanced: Dump all intent extras and relevant state
    val extras = intent?.extras
    if (extras != null) {
        for (key in extras.keySet()) {
            android.util.Log.d(TAG, "[LOG] onCreate: intent extra $key = ${extras.get(key)}")
        }
    } else {
        android.util.Log.d(TAG, "[LOG] onCreate: intent has no extras")
    }
        val activityTimestamp = System.currentTimeMillis()
        val currentThread = Thread.currentThread()
        val incomingCallSid = intent.getStringExtra(EXTRA_CALL_SID)
        val shortSid = incomingCallSid?.takeLast(6) ?: "null"
        
        android.util.Log.d(TAG, "╔════════════════════════════════════════════════════════════════════╗")
        android.util.Log.d(TAG, "║ IncomingCallActivity.onCreate START - Thread: ${currentThread.name}")
        android.util.Log.d(TAG, "║ Activity Timestamp: $activityTimestamp")
        android.util.Log.d(TAG, "║ CallSid from intent: $incomingCallSid (short: $shortSid)")
        android.util.Log.d(TAG, "╚════════════════════════════════════════════════════════════════════╝")

        // CRITICAL: Must call super.onCreate() BEFORE any finish()/return calls.
        // Android requires super.onCreate() to be called, otherwise a
        // SuperNotCalledException crash will occur.
        super.onCreate(savedInstanceState)
        
        // Mark activity as alive so TVConnectionService knows not to launch again
        isActivityAlive = true
        
        // ============================================================
        // SIMULTANEOUS INCOMING CALLS CHECK - IMMEDIATE EXIT
        // Check if this call's SID matches the pending/claimed call.
        // If not, this is a duplicate call that should have been rejected.
        // Immediately finish without showing any UI.
        // ============================================================
        val pendingCallSid = TVConnectionService.getPendingIncomingCallSidFromPrefs(applicationContext)
        val pendingCallSidMem = TVConnectionService.getPendingIncomingCallSid()
        val serviceActiveCallHandle = TVConnectionService.getActiveCallHandle()
        val activeConnectionsCount = TVConnectionService.activeConnections.size
        val isCallInActiveConnections = incomingCallSid != null && TVConnectionService.activeConnections.containsKey(incomingCallSid)
        
        android.util.Log.d(TAG, "[ACT-$shortSid] ┌─ State Check ─────────────────────────────────────┐")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ incomingCallSid = $incomingCallSid")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ pendingCallSid (prefs) = $pendingCallSid")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ pendingCallSid (mem) = $pendingCallSidMem")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ activeCallHandle = $serviceActiveCallHandle")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ activeConnections.size = $activeConnectionsCount")
        android.util.Log.d(TAG, "[ACT-$shortSid] │ isCallInActiveConnections = $isCallInActiveConnections")
        android.util.Log.d(TAG, "[ACT-$shortSid] └────────────────────────────────────────────────────┘")
        
        // ============================================================
        // CHECK 1: If NO pending call exists AND the call is not tracked in activeConnections,
        // this activity was triggered AFTER the call was already rejected/cleared.
        // This handles the race condition where:
        // - fullScreenIntent triggers activity launch
        // - call gets rejected (clears pendingCallSid)
        // - activity's onCreate runs with stale data
        //
        // NOTE: We also check activeConnections because the pending call SID may have been
        // cleared after the connection was added to activeConnections but before this
        // activity launched (200ms delay in showIncomingCallOverLockScreen).
        // ============================================================
        if (pendingCallSid == null && pendingCallSidMem == null && serviceActiveCallHandle == null && !isCallInActiveConnections) {
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ REJECTED - No pending call exists!")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ Call was likely rejected before activity launched")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ Finishing orphaned activity immediately")
            finish()
            return
        }
        
        // CHECK 2: If there's an active call already, allow it through for call waiting
        // The IncomingCallActivity will show a bottom sheet with hold/merge/end options
        if (serviceActiveCallHandle != null && serviceActiveCallHandle != incomingCallSid) {
            android.util.Log.d(TAG, "[ACT-$shortSid] ℹ️ Active call exists ($serviceActiveCallHandle) - will show call waiting options")
            // Don't finish() - we'll show a different UI for call waiting
        }
        
        // CHECK 3: If there's a different pending call in SharedPreferences, close immediately
        if (pendingCallSid != null && incomingCallSid != null && pendingCallSid != incomingCallSid) {
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ REJECTED - Different pending call exists!")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ pending=$pendingCallSid != current=$incomingCallSid")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ Finishing duplicate activity immediately")
            finish()
            return
        }
        
        // CHECK 4: If there's a different pending call in memory, close immediately
        if (pendingCallSidMem != null && incomingCallSid != null && pendingCallSidMem != incomingCallSid) {
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ REJECTED - Different pending call in memory!")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ pendingMem=$pendingCallSidMem != current=$incomingCallSid")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ Finishing duplicate activity immediately")
            finish()
            return
        }
        
        // CHECK 5: If this call's SID doesn't match the pending SID (when pending exists), reject
        if (pendingCallSid != null && pendingCallSid != incomingCallSid) {
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ REJECTED - CallSid mismatch with pending!")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ pending=$pendingCallSid != current=$incomingCallSid")
            android.util.Log.w(TAG, "[ACT-$shortSid] ❌ Finishing mismatched activity immediately")
            finish()
            return
        }
        
        android.util.Log.d(TAG, "[ACT-$shortSid] ✓ Call is valid, proceeding with UI")
        // ============================================================
        
        // For MIUI devices, try to set overlay window type BEFORE super.onCreate()
        if (isMiuiDevice() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                if (android.provider.Settings.canDrawOverlays(this)) {
                    android.util.Log.d(TAG, "onCreate: MIUI - Setting TYPE_APPLICATION_OVERLAY before super.onCreate()")
                    window.setType(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
                }
            } catch (e: Exception) {
                android.util.Log.w(TAG, "onCreate: Failed to set overlay type: ${e.message}")
            }
        }
        
        // CRITICAL: Set window flags for lock screen display
        showOverLockScreen()
        
        // Wake up the screen immediately after onCreate
        wakeUpScreen()
        
        // Check if this is an answer action from notification
        val action = intent.getStringExtra("action")
        android.util.Log.d(TAG, "onCreate: action=$action, callSid=${intent.getStringExtra(EXTRA_CALL_SID)}, hasCallInvite=${intent.hasExtra(EXTRA_CALL_INVITE)}")
        if (action == "answer") {
            android.util.Log.d(TAG, "onCreate: Detected 'answer' action - proceeding to handleAnswerFromNotification")
            // Direct answer from notification - answer and launch main app
            handleAnswerFromNotification()
            return
        }
        
        setContentView(R.layout.activity_incoming_call_custom)
        
        // Bring activity to foreground after setting content view
        bringActivityToFront()
        
        // For MIUI - try an additional aggressive approach after content is set
        if (isMiuiDevice()) {
            window.decorView.postDelayed({
                android.util.Log.d(TAG, "onCreate: MIUI delayed bringActivityToFront")
                showOverLockScreen()
                bringActivityToFront()
                moveTaskToFront()
            }, 300)
        }

        // Get call info from intent
        callInvite = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        callSid = intent.getStringExtra(EXTRA_CALL_SID)
        callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown"
        callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
        
        // Extract the "to" number (the number receiving the call)
        myNumber = callInvite?.to ?: ""
        
        // Get active call info (call waiting scenario)
        hasActiveCall = intent.getBooleanExtra(EXTRA_HAS_ACTIVE_CALL, false)
        activeCallerName = intent.getStringExtra(EXTRA_ACTIVE_CALLER_NAME)
        activeCallerNumber = intent.getStringExtra(EXTRA_ACTIVE_CALLER_NUMBER)
        activeCallHandle = intent.getStringExtra(EXTRA_ACTIVE_CALL_HANDLE)
        android.util.Log.d(TAG, "onCreate: hasActiveCall=$hasActiveCall, activeCallerName=$activeCallerName, activeCallerNumber=$activeCallerNumber")

        // Set caller info
        findViewById<TextView>(R.id.callerName).text = callerName
        val formattedNumber = formatPhoneNumber(callerNumber)
        findViewById<TextView>(R.id.callerNumber).text = if (formattedNumber.isNotEmpty()) "Mobile  $formattedNumber" else "Mobile"

        // Load Easify logo from Flutter assets using SvgPicture-like approach
        // For now, keep the vector drawable but make it more visible
        val easifyLogo = findViewById<ImageView>(R.id.easifyLogo)
        easifyLogo.elevation = 8f

    // Animated ring removed from UI per design change - keep avatar container in layout for initials/icon only.

            // Caller initials and person icon views removed from layout per design change.
            // No runtime handling required here.

        // Set up answer button with swipe animation
        val acceptButtonContainer = findViewById<FrameLayout>(R.id.acceptButton)
        val acceptButtonBg = findViewById<View>(R.id.acceptButtonBg)
        val acceptButtonCircle = findViewById<ImageView>(R.id.acceptButtonCircle)
        
        // Add elevation to buttons for more visibility
        acceptButtonContainer.elevation = 12f
        acceptButtonBg.elevation = 10f
        
        if (hasActiveCall) {
            android.util.Log.d(TAG, "[LOG] acceptButton: hasActiveCall=true, should show bottom sheet | callSid=$callSid, activeCallHandle=$activeCallHandle, callerName=$callerName, callerNumber=$callerNumber, activeCallerName=$activeCallerName, activeCallerNumber=$activeCallerNumber")
            // Call waiting mode: accept shows bottom sheet with options
            setupButtonSwipeAnimation(acceptButtonContainer, acceptButtonBg, acceptButtonCircle) {
                android.util.Log.d(TAG, "[LOG] acceptButton: onSwipe - about to showCallWaitingBottomSheet | hasActiveCall=$hasActiveCall, callSid=$callSid, activeCallHandle=$activeCallHandle")
                showCallWaitingBottomSheet()
            }
        } else {
            android.util.Log.d(TAG, "[LOG] acceptButton: hasActiveCall=false, should answer directly | callSid=$callSid, callerName=$callerName, callerNumber=$callerNumber")
            // Normal mode: accept answers directly
            setupButtonSwipeAnimation(acceptButtonContainer, acceptButtonBg, acceptButtonCircle) {
                android.util.Log.d(TAG, "[LOG] acceptButton: onSwipe - about to answerCall | hasActiveCall=$hasActiveCall, callSid=$callSid")
                answerCall()
            }
        }

        // Set up decline button with swipe animation
        val declineButtonContainer = findViewById<FrameLayout>(R.id.declineButton)
        val declineButtonBg = findViewById<View>(R.id.declineButtonBg)
        val declineButtonCircle = findViewById<ImageView>(R.id.declineButtonCircle)
        
        // Add elevation to buttons for more visibility
        declineButtonContainer.elevation = 12f
        declineButtonBg.elevation = 10f
        declineButtonCircle.elevation = 14f
        acceptButtonCircle.elevation = 14f
        
        setupButtonSwipeAnimation(declineButtonContainer, declineButtonBg, declineButtonCircle) {
            declineCall()
        }
        
        // If there's an active call, update the "Call from" label to indicate call waiting
        if (hasActiveCall) {
            val callFromLabel = findViewById<TextView>(R.id.callFromLabel)
            callFromLabel.text = "Another call from"
        }
        
        // Register broadcast receiver to listen for call ended events
        registerCallEndedReceiver()
        
        // Note: Ringtone is handled by TVConnectionService to ensure it plays even in terminated state
        // The activity doesn't need to start ringing since the service already does it
    }
    
    private fun startRinging() {
        if (isRinging) return
        isRinging = true
        
        android.util.Log.d(TAG, "Starting ringtone and vibration")
        
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
                android.util.Log.d(TAG, "Ringtone started playing")
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error starting ringtone: ${e.message}", e)
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
                    android.util.Log.d(TAG, "Vibration started")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error starting vibration: ${e.message}", e)
        }
    }
    
    private fun stopRinging() {
        if (!isRinging) return
        isRinging = false
        
        android.util.Log.d(TAG, "Stopping ringtone and vibration")
        
        try {
            ringtone?.let { ring ->
                if (ring.isPlaying) {
                    ring.stop()
                }
            }
            ringtone = null
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error stopping ringtone: ${e.message}", e)
        }
        
        try {
            vibrator?.cancel()
            vibrator = null
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error stopping vibration: ${e.message}", e)
        }
    }
    
    private fun registerCallEndedReceiver() {
        try {
            val filter = IntentFilter(TVBroadcastReceiver.ACTION_CALL_ENDED)
            LocalBroadcastManager.getInstance(this).registerReceiver(callEndedReceiver, filter)
            android.util.Log.d(TAG, "Registered call ended broadcast receiver")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Failed to register call ended receiver: $e")
        }
    }
    
    private fun unregisterCallEndedReceiver() {
        try {
            LocalBroadcastManager.getInstance(this).unregisterReceiver(callEndedReceiver)
            android.util.Log.d(TAG, "Unregistered call ended broadcast receiver")
        } catch (e: Exception) {
            // Receiver might not be registered
            android.util.Log.w(TAG, "Failed to unregister call ended receiver: $e")
        }
    }
    
    private fun handleAnswerFromNotification() {
        android.util.Log.d(TAG, "handleAnswerFromNotification: STARTED - Activity launched from notification answer action")
        // Mark as handled immediately to prevent any race conditions
        callHandled = true
        val sid = intent.getStringExtra(EXTRA_CALL_SID)
        // Try to get CallInvite from intent
        val invite: CallInvite? = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        
        android.util.Log.d(TAG, "handleAnswerFromNotification: sid=$sid, hasCallInvite=${invite != null}")
        
        // Store invite for permission callback
        if (invite != null) {
            callInvite = invite
        }
        if (sid != null) {
            callSid = sid
        }
        
        // Extract caller info from intent extras or callInvite (for launchMainActivity)
        callerName = intent.getStringExtra(EXTRA_CALLER_NAME) 
            ?: invite?.customParameters?.get("client_name")
            ?: extractUserNumber(invite?.from ?: "Unknown")
        callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER)
            ?: extractUserNumber(invite?.from ?: "")
        myNumber = intent.getStringExtra("extra_my_number")
            ?: invite?.to ?: ""
        
        android.util.Log.d(TAG, "handleAnswerFromNotification: Extracted caller info - name: $callerName, number: $callerNumber, myNumber: $myNumber")
        
        // Check for RECORD_AUDIO permission before answering
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.d(TAG, "handleAnswerFromNotification: Requesting RECORD_AUDIO permission")
            // Reset callHandled so proceedWithAnswer can set it again
            callHandled = false
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return
        }
        
        android.util.Log.d(TAG, "handleAnswerFromNotification: RECORD_AUDIO permission GRANTED - proceeding to answer call")
        
        if (sid != null) {
            android.util.Log.d(TAG, "handleAnswerFromNotification: Answering call with callSid: $sid, hasCallInvite: ${invite != null}")
            // Send answer intent to TVConnectionService - include CallInvite for terminated state recovery
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                // Tell the service that IncomingCallActivity is handling the MainActivity launch
                // so the service should NOT launch MainActivity again (avoids dual onNewIntent)
                putExtra("LAUNCHED_FROM_ACTIVITY", true)
                invite?.let { 
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, it) 
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.util.Log.d(TAG, "handleAnswerFromNotification: Calling startForegroundService with ACTION_ANSWER (from Activity context)")
                startForegroundService(answerIntent)
            } else {
                android.util.Log.d(TAG, "handleAnswerFromNotification: Calling startService with ACTION_ANSWER")
                startService(answerIntent)
            }
            
            android.util.Log.d(TAG, "handleAnswerFromNotification: Launching main Flutter activity")
            // Launch the main Flutter activity
            launchMainActivity()
        } else {
            android.util.Log.e(TAG, "handleAnswerFromNotification: sid is NULL - cannot answer call!")
        }
        android.util.Log.d(TAG, "handleAnswerFromNotification: COMPLETED - finishing activity")
        finishAndRemoveTask()
    }

    @SuppressLint("WakelockTimeout")
    private fun wakeUpScreen() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            
            // Use FULL_WAKE_LOCK to turn on the screen
            @Suppress("DEPRECATION")
            wakeLock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or 
                PowerManager.ACQUIRE_CAUSES_WAKEUP or 
                PowerManager.ON_AFTER_RELEASE,
                "TwilioVoice:IncomingCallScreenWake"
            )
            wakeLock?.acquire(60 * 1000L) // 60 seconds max
            
            android.util.Log.d(TAG, "Screen wake lock acquired")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Failed to acquire screen wake lock: $e")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    android.util.Log.d(TAG, "Screen wake lock released")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Failed to release screen wake lock: $e")
        }
    }

    private fun showOverLockScreen() {
        android.util.Log.d(TAG, "showOverLockScreen: Setting up window flags for lock screen display")
        
        // Check if this is a MIUI/Xiaomi device
        val isMiui = isMiuiDevice()
        android.util.Log.d(TAG, "showOverLockScreen: isMiuiDevice=$isMiui")
        
        // STEP 1: Add all window flags FIRST before anything else
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_FULLSCREEN
        )
        
        // STEP 2: For Android O_MR1+ (API 27+) use the newer API methods
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            android.util.Log.d(TAG, "showOverLockScreen: setShowWhenLocked and setTurnScreenOn called")
        }
        
        // STEP 3: Handle display cutout for notched devices (Android P+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode = 
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        
        // STEP 4: Disable the keyguard to show over lock screen
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguardManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                // Request to dismiss the keyguard (important for MIUI/Xiaomi devices)
                keyguardManager.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        android.util.Log.d(TAG, "showOverLockScreen: Keyguard dismissed successfully")
                    }
                    override fun onDismissCancelled() {
                        android.util.Log.d(TAG, "showOverLockScreen: Keyguard dismiss cancelled")
                    }
                    override fun onDismissError() {
                        android.util.Log.d(TAG, "showOverLockScreen: Keyguard dismiss error")
                    }
                })
            } else {
                // For older devices, use deprecated method
                @Suppress("DEPRECATION")
                keyguardManager.newKeyguardLock("IncomingCallActivity").disableKeyguard()
            }
        }
        
        // STEP 5: MIUI-specific handling - use system overlay window type
        if (isMiuiDevice() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                // Check if we have overlay permission
                if (android.provider.Settings.canDrawOverlays(this)) {
                    android.util.Log.d(TAG, "showOverLockScreen: MIUI device - has overlay permission, setting window type")
                    window.setType(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
                } else {
                    android.util.Log.w(TAG, "showOverLockScreen: MIUI device - NO overlay permission! User needs to grant this permission")
                }
            } catch (e: Exception) {
                android.util.Log.w(TAG, "showOverLockScreen: Failed to set overlay window type: ${e.message}")
            }
        }
        
        // STEP 6: Additional MIUI fix - set layout params
        try {
            window.attributes = window.attributes.apply {
                screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "showOverLockScreen: Failed to set brightness: ${e.message}")
        }
    }
    
    private fun isMiuiDevice(): Boolean {
        return try {
            val prop = Class.forName("android.os.SystemProperties")
            val get = prop.getMethod("get", String::class.java)
            val miuiVersion = get.invoke(null, "ro.miui.ui.version.name") as? String
            val brand = Build.BRAND.lowercase()
            val manufacturer = Build.MANUFACTURER.lowercase()
            
            val isMiui = !miuiVersion.isNullOrEmpty() || 
                         brand.contains("xiaomi") || 
                         brand.contains("redmi") || 
                         brand.contains("poco") ||
                         manufacturer.contains("xiaomi") ||
                         manufacturer.contains("redmi")
            
            android.util.Log.d(TAG, "isMiuiDevice: miuiVersion=$miuiVersion, brand=$brand, manufacturer=$manufacturer, result=$isMiui")
            isMiui
        } catch (e: Exception) {
            android.util.Log.w(TAG, "isMiuiDevice: Failed to detect MIUI: ${e.message}")
            // Fallback to brand check
            val brand = Build.BRAND.lowercase()
            val manufacturer = Build.MANUFACTURER.lowercase()
            brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") ||
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi")
        }
    }
    
    private fun moveTaskToFront() {
        try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            activityManager.moveTaskToFront(taskId, android.app.ActivityManager.MOVE_TASK_WITH_HOME)
            android.util.Log.d(TAG, "moveTaskToFront: Task moved to front")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "moveTaskToFront: Failed to move task to front: ${e.message}")
        }
    }
    
    private fun bringActivityToFront() {
        try {
            // Use multiple approaches to bring activity to front on MIUI
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            
            // Approach 1: Move task to front with HOME flag
            activityManager.moveTaskToFront(taskId, android.app.ActivityManager.MOVE_TASK_WITH_HOME)
            
            // Approach 2: Request window focus
            window.decorView.requestFocus()
            
            // Approach 3: For MIUI - try to dismiss keyguard again
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                keyguardManager.requestDismissKeyguard(this, object : android.app.KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        android.util.Log.d(TAG, "bringActivityToFront: Keyguard dismissed")
                        runOnUiThread {
                            moveTaskToFront()
                        }
                    }
                    override fun onDismissCancelled() {
                        android.util.Log.d(TAG, "bringActivityToFront: Keyguard dismiss cancelled")
                    }
                    override fun onDismissError() {
                        android.util.Log.d(TAG, "bringActivityToFront: Keyguard dismiss error")
                    }
                })
            }
            
            android.util.Log.d(TAG, "bringActivityToFront: Activity brought to front")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "bringActivityToFront: Failed: ${e.message}")
        }
    }
    
    override fun onResume() {
        super.onResume()
        android.util.Log.d(TAG, "onResume: Activity resumed")
        
        // Aggressively try to show over lock screen on resume
        showOverLockScreen()
        
        // Ensure we have focus on MIUI devices only
        if (isMiuiDevice()) {
            window.decorView.postDelayed({
                bringActivityToFront()
            }, 200)
        }
    }
    
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        android.util.Log.d(TAG, "onAttachedToWindow: Window attached")
        
        // This is critical for MIUI - set flags again when window is attached
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
        
        // For MIUI, try to use a higher window priority
        if (isMiuiDevice()) {
            try {
                // Use reflection to set higher priority for MIUI
                val layoutParams = window.attributes
                val priorityField = layoutParams.javaClass.getField("preferredDisplayModeId")
                priorityField.isAccessible = true
            } catch (e: Exception) {
                // Ignore, this is just an extra attempt
            }
            
            // Also try to bring to front again
            window.decorView.postDelayed({
                moveTaskToFront()
                bringActivityToFront()
            }, 100)
        }
    }
    
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        android.util.Log.d(TAG, "onWindowFocusChanged: hasFocus=$hasFocus")
        
        // If we lose focus on MIUI, try to regain it (only for MIUI devices)
        if (!hasFocus && isMiuiDevice()) {
            window.decorView.postDelayed({
                bringActivityToFront()
            }, 300)
        }
    }

    override fun onDestroy() {
        // Mark activity as no longer alive
        isActivityAlive = false
        super.onDestroy()
        stopRinging()
        unregisterCallEndedReceiver()
        releaseWakeLock()
    }

    // ============================================================
    // CALL WAITING BOTTOM SHEET
    // Shows 3 options when accepting a call while another is active
    // ============================================================
    
    private fun showCallWaitingBottomSheet() {
    log_showCallWaitingBottomSheetCounter++
    android.util.Log.d(TAG, "[LOG] showCallWaitingBottomSheet CALLED. log_showCallWaitingBottomSheetCounter=$log_showCallWaitingBottomSheetCounter | hasActiveCall=$hasActiveCall, callSid=$callSid, activeCallHandle=$activeCallHandle, callerName=$callerName, callerNumber=$callerNumber, activeCallerName=$activeCallerName, activeCallerNumber=$activeCallerNumber")
    
    // Guard: prevent showing the bottom sheet if it's already visible
    if (isBottomSheetShowing) {
        android.util.Log.d(TAG, "showCallWaitingBottomSheet: Already showing, ignoring duplicate call")
        return
    }
    isBottomSheetShowing = true
    
    android.util.Log.d(TAG, "showCallWaitingBottomSheet: Showing call waiting options")
        
        val bottomSheetOverlay = findViewById<ImageView>(R.id.callWaitingBottomSheetOverlay)
        val bottomSheetContainer = findViewById<View>(R.id.callWaitingBottomSheet)
        
        if (bottomSheetOverlay == null || bottomSheetContainer == null) {
            android.util.Log.w(TAG, "showCallWaitingBottomSheet: Bottom sheet views not found, falling back to hold+answer")
            answerCallWithHold()
            return
        }
        
        // Capture the current screen and apply blur for frosted glass effect
        applyBlurToOverlay(bottomSheetOverlay)
        
        // Push bottom sheet off-screen BEFORE making it visible to prevent 1-frame flash
        // (Previously, setting VISIBLE before post{} caused the sheet to appear at y=0
        // for one frame before being translated down and animated up)
        bottomSheetContainer.translationY = 2000f  // large value to ensure off-screen
        bottomSheetContainer.visibility = View.VISIBLE
        bottomSheetOverlay.visibility = View.VISIBLE
        
        // Animate bottom sheet sliding up (post to allow layout measurement)
        bottomSheetContainer.post {
            bottomSheetContainer.translationY = bottomSheetContainer.height.toFloat()
            bottomSheetContainer.animate()
                .translationY(0f)
                .setDuration(300)
                .setInterpolator(android.view.animation.DecelerateInterpolator())
                .start()
        }
        
        // Fade in overlay
        bottomSheetOverlay.alpha = 0f
        bottomSheetOverlay.animate()
            .alpha(1f)
            .setDuration(300)
            .start()
        
        // Dismiss on overlay tap
        bottomSheetOverlay.setOnClickListener {
            hideCallWaitingBottomSheet()
        }
        
        // Set dynamic text with active caller name
        val displayName = if (!activeCallerName.isNullOrEmpty() && activeCallerName != "Unknown") {
            activeCallerName!!
        } else if (!activeCallerNumber.isNullOrEmpty()) {
            formatPhoneNumber(activeCallerNumber)
        } else {
            "active call"
        }
        
    // Update bottom sheet option labels to use new resource ids
    findViewById<TextView>(R.id.put_1_222_3)?.text = "Put $displayName on hold"
    findViewById<TextView>(R.id.end_call_wi)?.text = "End call with $displayName"
        
        // Set up option buttons
        findViewById<View>(R.id.optionHoldAndAnswer)?.setOnClickListener {
            android.util.Log.d(TAG, "showCallWaitingBottomSheet: Option 1 - Hold & Answer")
            hideCallWaitingBottomSheet()
            answerCallWithHold()
        }
        
        findViewById<View>(R.id.optionEndAndAnswer)?.setOnClickListener {
            android.util.Log.d(TAG, "showCallWaitingBottomSheet: Option 2 - End & Answer")
            hideCallWaitingBottomSheet()
            answerCallWithEndFirst()
        }
        
        findViewById<View>(R.id.optionDecline)?.setOnClickListener {
            android.util.Log.d(TAG, "showCallWaitingBottomSheet: Option 3 - Decline incoming")
            hideCallWaitingBottomSheet()
            declineCall()
        }
    }
    
    private fun hideCallWaitingBottomSheet() {
        isBottomSheetShowing = false
        val bottomSheetOverlay = findViewById<View>(R.id.callWaitingBottomSheetOverlay)
        val bottomSheetContainer = findViewById<View>(R.id.callWaitingBottomSheet)
        
        bottomSheetContainer?.animate()
            ?.translationY(bottomSheetContainer.height.toFloat())
            ?.setDuration(200)
            ?.withEndAction {
                bottomSheetContainer.visibility = View.GONE
            }
            ?.start()
        
        bottomSheetOverlay?.animate()
            ?.alpha(0f)
            ?.setDuration(200)
            ?.withEndAction {
                bottomSheetOverlay.visibility = View.GONE
                // Clear the bitmap to free memory
                (bottomSheetOverlay as? ImageView)?.setImageDrawable(null)
            }
            ?.start()
    }

    /**
     * Captures the current screen content and applies a blur effect to the overlay ImageView.
     * Uses RenderEffect on Android 12+ for hardware-accelerated blur,
     * falls back to a fast stack blur algorithm on older versions.
     */
    private fun applyBlurToOverlay(overlayImageView: ImageView) {
        try {
            val rootView = window.decorView.rootView
            // Capture the root view into a bitmap
            val bitmap = Bitmap.createBitmap(rootView.width, rootView.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            rootView.draw(canvas)
            
            // Add a dark tint on top (semi-transparent black) for the frosted glass look
            val tintPaint = Paint().apply {
                color = Color.parseColor("#80000000") // 50% black tint
            }
            canvas.drawRect(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat(), tintPaint)
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+ - Use RenderEffect for GPU-accelerated blur
                overlayImageView.setImageBitmap(bitmap)
                overlayImageView.setRenderEffect(
                    RenderEffect.createBlurEffect(25f, 25f, Shader.TileMode.CLAMP)
                )
            } else {
                // Pre-Android 12 - Use fast stack blur on a downscaled bitmap
                val scaleFactor = 0.25f
                val scaledWidth = (bitmap.width * scaleFactor).toInt().coerceAtLeast(1)
                val scaledHeight = (bitmap.height * scaleFactor).toInt().coerceAtLeast(1)
                val scaledBitmap = Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)
                val blurredBitmap = fastStackBlur(scaledBitmap, 20)
                overlayImageView.setImageBitmap(blurredBitmap)
                overlayImageView.scaleType = ImageView.ScaleType.CENTER_CROP
                bitmap.recycle()
                if (scaledBitmap != blurredBitmap) scaledBitmap.recycle()
            }
            
            android.util.Log.d(TAG, "applyBlurToOverlay: Blur effect applied successfully")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "applyBlurToOverlay: Failed to apply blur, using dark fallback: ${e.message}")
            // Fallback: just use a semi-transparent dark background
            overlayImageView.setBackgroundColor(Color.parseColor("#99000000"))
        }
    }

    /**
     * Fast stack blur algorithm for pre-Android 12 devices.
     * This is a CPU-based blur that works on a downscaled bitmap for performance.
     */
    private fun fastStackBlur(sentBitmap: Bitmap, radius: Int): Bitmap {
        val bitmap = sentBitmap.copy(sentBitmap.config ?: Bitmap.Config.ARGB_8888, true)
        val w = bitmap.width
        val h = bitmap.height
        val pix = IntArray(w * h)
        bitmap.getPixels(pix, 0, w, 0, 0, w, h)

        val wm = w - 1
        val hm = h - 1
        val wh = w * h
        val div = radius + radius + 1
        val r = IntArray(wh)
        val g = IntArray(wh)
        val b = IntArray(wh)
        var rsum: Int; var gsum: Int; var bsum: Int
        var x: Int; var y: Int; var i: Int; var p: Int; var yp: Int; var yi: Int; var yw: Int
        val vmin = IntArray(maxOf(w, h))
        var divsum = (div + 1) shr 1
        divsum *= divsum
        val dv = IntArray(256 * divsum)
        i = 0
        while (i < 256 * divsum) { dv[i] = i / divsum; i++ }

        yi = 0; yw = 0
        val stack = Array(div) { IntArray(3) }
        var stackpointer: Int; var stackstart: Int; var sir: IntArray
        var rbs: Int; var r1 = radius + 1
        var routsum: Int; var goutsum: Int; var boutsum: Int
        var rinsum: Int; var ginsum: Int; var binsum: Int

        y = 0
        while (y < h) {
            rinsum = 0; ginsum = 0; binsum = 0
            routsum = 0; goutsum = 0; boutsum = 0
            rsum = 0; gsum = 0; bsum = 0
            i = -radius
            while (i <= radius) {
                p = pix[yi + minOf(wm, maxOf(i, 0))]
                sir = stack[i + radius]
                sir[0] = (p and 0xff0000) shr 16
                sir[1] = (p and 0x00ff00) shr 8
                sir[2] = (p and 0x0000ff)
                rbs = r1 - kotlin.math.abs(i)
                rsum += sir[0] * rbs; gsum += sir[1] * rbs; bsum += sir[2] * rbs
                if (i > 0) { rinsum += sir[0]; ginsum += sir[1]; binsum += sir[2] }
                else { routsum += sir[0]; goutsum += sir[1]; boutsum += sir[2] }
                i++
            }
            stackpointer = radius
            x = 0
            while (x < w) {
                r[yi] = dv[rsum]; g[yi] = dv[gsum]; b[yi] = dv[bsum]
                rsum -= routsum; gsum -= goutsum; bsum -= boutsum
                stackstart = stackpointer - radius + div
                sir = stack[stackstart % div]
                routsum -= sir[0]; goutsum -= sir[1]; boutsum -= sir[2]
                if (y == 0) vmin[x] = minOf(x + radius + 1, wm)
                p = pix[yw + vmin[x]]
                sir[0] = (p and 0xff0000) shr 16; sir[1] = (p and 0x00ff00) shr 8; sir[2] = (p and 0x0000ff)
                rinsum += sir[0]; ginsum += sir[1]; binsum += sir[2]
                rsum += rinsum; gsum += ginsum; bsum += binsum
                stackpointer = (stackpointer + 1) % div
                sir = stack[stackpointer % div]
                routsum += sir[0]; goutsum += sir[1]; boutsum += sir[2]
                rinsum -= sir[0]; ginsum -= sir[1]; binsum -= sir[2]
                yi++; x++
            }
            yw += w; y++
        }
        x = 0
        while (x < w) {
            rinsum = 0; ginsum = 0; binsum = 0
            routsum = 0; goutsum = 0; boutsum = 0
            rsum = 0; gsum = 0; bsum = 0
            yp = -radius * w
            i = -radius
            while (i <= radius) {
                yi = maxOf(0, yp) + x
                sir = stack[i + radius]
                sir[0] = r[yi]; sir[1] = g[yi]; sir[2] = b[yi]
                rbs = r1 - kotlin.math.abs(i)
                rsum += r[yi] * rbs; gsum += g[yi] * rbs; bsum += b[yi] * rbs
                if (i > 0) { rinsum += sir[0]; ginsum += sir[1]; binsum += sir[2] }
                else { routsum += sir[0]; goutsum += sir[1]; boutsum += sir[2] }
                if (i < hm) yp += w
                i++
            }
            yi = x; stackpointer = radius
            y = 0
            while (y < h) {
                pix[yi] = (0xff000000.toInt() and pix[yi]) or (dv[rsum] shl 16) or (dv[gsum] shl 8) or dv[bsum]
                rsum -= routsum; gsum -= goutsum; bsum -= boutsum
                stackstart = stackpointer - radius + div
                sir = stack[stackstart % div]
                routsum -= sir[0]; goutsum -= sir[1]; boutsum -= sir[2]
                if (x == 0) vmin[y] = minOf(y + r1, hm) * w
                p = x + vmin[y]
                sir[0] = r[p]; sir[1] = g[p]; sir[2] = b[p]
                rinsum += sir[0]; ginsum += sir[1]; binsum += sir[2]
                rsum += rinsum; gsum += ginsum; bsum += binsum
                stackpointer = (stackpointer + 1) % div
                sir = stack[stackpointer]
                routsum += sir[0]; goutsum += sir[1]; boutsum += sir[2]
                rinsum -= sir[0]; ginsum -= sir[1]; binsum -= sir[2]
                yi += w; y++
            }
            x++
        }
        bitmap.setPixels(pix, 0, w, 0, 0, w, h)
        return bitmap
    }
    
    private fun answerCallWithHold() {
        stopRinging()
        if (callHandled) {
            android.util.Log.w(TAG, "answerCallWithHold: Call already handled, ignoring")
            finishAndRemoveTask()
            return
        }
        
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.d(TAG, "answerCallWithHold: Requesting RECORD_AUDIO permission")
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return
        }
        
        callHandled = true
        android.util.Log.d(TAG, "answerCallWithHold: Holding active call and answering new call")
        releaseWakeLock()
        callSid?.let { sid ->
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER_WITH_HOLD
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                putExtra("EXTRA_ACTIVE_CALL_HANDLE", activeCallHandle)
                callInvite?.let { invite ->
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, invite)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            // Use call-waiting variant that doesn't destroy Flutter activity
            launchMainActivityForCallWaiting()
        }
        finishAndRemoveTask()
    }
    
    private fun answerCallWithEndFirst() {
        stopRinging()
        if (callHandled) {
            android.util.Log.w(TAG, "answerCallWithEndFirst: Call already handled, ignoring")
            finishAndRemoveTask()
            return
        }
        
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.d(TAG, "answerCallWithEndFirst: Requesting RECORD_AUDIO permission")
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return
        }
        
        callHandled = true
        android.util.Log.d(TAG, "answerCallWithEndFirst: Ending active call and answering new call")
        releaseWakeLock()
        callSid?.let { sid ->
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER_WITH_END_FIRST
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                putExtra("EXTRA_ACTIVE_CALL_HANDLE", activeCallHandle)
                callInvite?.let { invite ->
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, invite)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            // Use call-waiting variant that doesn't destroy Flutter activity
            launchMainActivityForCallWaiting()
        }
        finishAndRemoveTask()
    }

    private fun answerCall() {
        // Stop ringing immediately when answering
        stopRinging()
        
        // Idempotency check - prevent double handling
        if (callHandled) {
            android.util.Log.w(TAG, "answerCall: Call already handled, ignoring")
            finishAndRemoveTask()
            return
        }
        
        // Check for RECORD_AUDIO permission before answering
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.d(TAG, "answerCall: Requesting RECORD_AUDIO permission")
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return
        }
        
        proceedWithAnswer()
    }
    
    private fun proceedWithAnswer() {
        callHandled = true
        android.util.Log.d(TAG, "[LOG] proceedWithAnswer: STARTED - Answering call with callSid: $callSid, hasCallInvite: ${callInvite != null}, hasActiveCall=$hasActiveCall, activeCallHandle=$activeCallHandle, callerName=$callerName, callerNumber=$callerNumber, activeCallerName=$activeCallerName, activeCallerNumber=$activeCallerNumber")
        val extras = intent?.extras
        if (extras != null) {
            for (key in extras.keySet()) {
                android.util.Log.d(TAG, "[LOG] proceedWithAnswer: intent extra $key = ${extras.get(key)}")
            }
        } else {
            android.util.Log.d(TAG, "[LOG] proceedWithAnswer: intent has no extras")
        }
        releaseWakeLock()
        callSid?.let { sid ->
            android.util.Log.d(TAG, "proceedWithAnswer: Creating ACTION_ANSWER intent for TVConnectionService")
            // Send answer intent to TVConnectionService - include CallInvite for terminated state recovery
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                // Tell the service that IncomingCallActivity is handling the MainActivity launch
                // so the service should NOT launch MainActivity again (avoids dual onNewIntent)
                putExtra("LAUNCHED_FROM_ACTIVITY", true)
                callInvite?.let { invite ->
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, invite)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.util.Log.d(TAG, "proceedWithAnswer: Calling startForegroundService with ACTION_ANSWER (from Activity context - should have microphone access)")
                startForegroundService(answerIntent)
            } else {
                android.util.Log.d(TAG, "proceedWithAnswer: Calling startService with ACTION_ANSWER")
                startService(answerIntent)
            }
            
            android.util.Log.d(TAG, "proceedWithAnswer: Launching main Flutter activity")
            // Launch the main Flutter activity
            launchMainActivity()
        } ?: run {
            android.util.Log.e(TAG, "proceedWithAnswer: callSid is null - cannot answer call!")
        }
        android.util.Log.d(TAG, "proceedWithAnswer: Finishing IncomingCallActivity")
        finishAndRemoveTask()
    }
    
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_RECORD_AUDIO_PERMISSION -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    android.util.Log.d(TAG, "onRequestPermissionsResult: RECORD_AUDIO permission granted, proceeding with answer")
                    proceedWithAnswer()
                } else {
                    android.util.Log.w(TAG, "onRequestPermissionsResult: RECORD_AUDIO permission denied, cannot answer call")
                    // Show toast or message that permission is required
                    android.widget.Toast.makeText(this, "Microphone permission is required to answer calls", android.widget.Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun declineCall() {
        // Stop ringing immediately when declining
        stopRinging()
        
        // Idempotency check - prevent double handling
        if (callHandled) {
            android.util.Log.w(TAG, "declineCall: Call already handled, ignoring")
            finishAndRemoveTask()
            return
        }
        callHandled = true
        
        releaseWakeLock()
        callSid?.let { sid ->
            android.util.Log.d(TAG, "declineCall: Sending hangup for callSid: $sid")
            // Send hangup intent to TVConnectionService - include CallInvite for terminated state recovery
            val hangupIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                callInvite?.let { invite ->
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, invite)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(hangupIntent)
            } else {
                startService(hangupIntent)
            }
        } ?: run {
            android.util.Log.w(TAG, "declineCall: No callSid available")
        }
        
        // If declining during call waiting, bring back the main activity
        // so the user can see the active call screen
        if (hasActiveCall) {
            android.util.Log.d(TAG, "declineCall: Has active call, launching main activity to restore call UI")
            launchMainActivityForActiveCall()
        }
        finishAndRemoveTask()
    }

    /**
     * Bring main activity to front to restore the active call UI.
     * Used when declining the incoming call during call waiting.
     * Does NOT pass call data extras to avoid resetting Flutter call state (timer, connecting status).
     */
    private fun launchMainActivityForActiveCall() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            startActivity(it)
            android.util.Log.d(TAG, "launchMainActivityForActiveCall: Brought main activity to front for active call - handle=$activeCallHandle")
        }
    }

    /**
     * Bring main activity to front for call-waiting answer scenarios (hold+answer, end+answer).
     * Uses SINGLE_TOP + REORDER_TO_FRONT instead of CLEAR_TOP to avoid destroying the
     * existing Flutter activity and its BLoC state (active call screen, timer, etc.).
     * Passes call data via extras so Flutter can update to show the new call.
     * MainActivity.onNewIntent() handles receiving this data.
     */
    private fun launchMainActivityForCallWaiting() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            // Add extras to tell MainActivity to show over lock screen
            it.putExtra("SHOW_OVER_LOCK_SCREEN", true)
            it.putExtra("CALL_ANSWERED", true)
            it.putExtra("CALL_SID", callSid)
            // Pass call data so Flutter can display it immediately
            it.putExtra("CALLER_NAME", callerName)
            it.putExtra("CALLER_NUMBER", callerNumber)
            it.putExtra("MY_NUMBER", myNumber)
            it.putExtra("CALL_DIRECTION", "incoming")
            startActivity(it)
            android.util.Log.d(TAG, "launchMainActivityForCallWaiting: Brought main activity to front with call data - caller: $callerName, number: $callerNumber")
        }
    }

    private fun launchMainActivity() {
        // Get the main launcher activity
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            // Use SINGLE_TOP + REORDER_TO_FRONT to preserve existing Flutter activity
            // CLEAR_TOP was destroying and recreating MainActivity, killing the Flutter engine
            // and causing surface destroy/recreate (32 frame skip, dual onNewIntent, etc.)
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or 
                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            // Add extras to tell MainActivity to show over lock screen
            it.putExtra("SHOW_OVER_LOCK_SCREEN", true)
            it.putExtra("CALL_ANSWERED", true)
            it.putExtra("CALL_SID", callSid)
            // Pass call data so Flutter can display it immediately without waiting for plugin sync
            it.putExtra("CALLER_NAME", callerName)
            it.putExtra("CALLER_NUMBER", callerNumber)
            it.putExtra("MY_NUMBER", myNumber)
            it.putExtra("CALL_DIRECTION", "incoming")
            startActivity(it)
            android.util.Log.d(TAG, "launchMainActivity: Launched with call data - caller: $callerName, number: $callerNumber, myNumber: $myNumber")
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        val newCallSid = intent?.getStringExtra(EXTRA_CALL_SID)
        android.util.Log.d(TAG, "onNewIntent called with action=${intent?.getStringExtra("action")}, newCallSid=$newCallSid, currentCallSid=$callSid")
        
        // CRITICAL: If we already have a valid call showing, IGNORE any new calls
        // This prevents the second incoming call from updating the UI
        if (!callSid.isNullOrEmpty() && newCallSid != null && newCallSid != callSid) {
            android.util.Log.d(TAG, "onNewIntent: IGNORING new call $newCallSid - already showing call $callSid")
            // Do NOT update intent or stored values - keep showing the first call
            return
        }
        
        // Update the intent only if it's the same call or we don't have a call yet
        setIntent(intent)
        
        intent?.let {
            // Check if this is an answer action from notification
            val action = it.getStringExtra("action")
            if (action == "answer") {
                // Only process if this answer is for our current call
                if (newCallSid == null || newCallSid == callSid) {
                    android.util.Log.d(TAG, "onNewIntent: Handling answer action from notification for call $callSid")
                    // Update the stored values before handling
                    callInvite = it.getParcelableExtra(EXTRA_CALL_INVITE)
                    callSid = it.getStringExtra(EXTRA_CALL_SID)
                    callerName = it.getStringExtra(EXTRA_CALLER_NAME) ?: callerName
                    callerNumber = it.getStringExtra(EXTRA_CALLER_NUMBER) ?: callerNumber
                    myNumber = it.getStringExtra("extra_my_number") ?: myNumber
                    handleAnswerFromNotification()
                } else {
                    android.util.Log.d(TAG, "onNewIntent: IGNORING answer action for different call $newCallSid (current: $callSid)")
                }
                return
            }
            
            // Handle if a new call comes in while this activity is showing
            // Only update if same call or we don't have one yet
            if (callSid.isNullOrEmpty() || newCallSid == callSid) {
                callInvite = it.getParcelableExtra(EXTRA_CALL_INVITE)
                callSid = it.getStringExtra(EXTRA_CALL_SID)
                android.util.Log.d(TAG, "onNewIntent: Updated call to $callSid")
            } else {
                android.util.Log.d(TAG, "onNewIntent: Keeping current call $callSid, ignoring $newCallSid")
            }
        }
    }

    /**
     * Setup swipe animation for button gestures (swipe to accept/decline)
     * Provides haptic feedback and visual scaling during drag with enhanced effects
     */
    private fun setupButtonSwipeAnimation(
        buttonContainer: FrameLayout,
        buttonBg: View,
        buttonIcon: ImageView,
        onSwipeComplete: () -> Unit
    ) {
        var startX = 0f
        var startY = 0f
        var isDragging = false
        var hasSwipeCompleted = false
        
        buttonContainer.setOnTouchListener { _, event ->
            when (event.action) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    startX = event.x
                    startY = event.y
                    isDragging = false
                    hasSwipeCompleted = false
                    
                    // Start pulse animation on button with icon scale
                    buttonContainer.animate()
                        .scaleX(1.15f)
                        .scaleY(1.15f)
                        .setDuration(120)
                        .start()
                    
                    buttonIcon.animate()
                        .scaleX(1.2f)
                        .scaleY(1.2f)
                        .setDuration(120)
                        .start()
                    
                    // Slight alpha change for depth
                    buttonBg.animate()
                        .alpha(0.9f)
                        .setDuration(120)
                        .start()
                    
                    true
                }
                
                android.view.MotionEvent.ACTION_MOVE -> {
                    val deltaX = kotlin.math.abs(event.x - startX)
                    val deltaY = kotlin.math.abs(event.y - startY)
                    val totalDelta = kotlin.math.sqrt((deltaX * deltaX + deltaY * deltaY).toDouble()).toFloat()
                    
                    // If moved more than 40dp in any direction, consider it a drag
                    if (deltaX > 40 || deltaY > 40) {
                        isDragging = true
                        
                        // Scale button during drag for visual feedback (limited to 1.3x max to prevent overflow)
                        val scale = 1.15f + (totalDelta / 300f).coerceAtMost(0.15f)
                        buttonContainer.scaleX = scale
                        buttonContainer.scaleY = scale
                        
                        // Scale icon during drag
                        val iconScale = 1.2f + (totalDelta / 300f).coerceAtMost(0.3f)
                        buttonIcon.scaleX = iconScale
                        buttonIcon.scaleY = iconScale
                        
                        // Increase alpha during drag for emphasis
                        val alphaDrag = 0.9f + (totalDelta / 500f).coerceAtMost(0.1f)
                        buttonBg.alpha = alphaDrag
                        
                        // If dragged more than 120dp, trigger action (only once per gesture)
                        if (totalDelta > 120 && !hasSwipeCompleted) {
                            hasSwipeCompleted = true
                            // Haptic feedback
                            buttonContainer.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)
                            buttonContainer.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                            
                            // Animate back to normal with success effect
                            buttonContainer.animate()
                                .scaleX(0.9f)
                                .scaleY(0.9f)
                                .setDuration(80)
                                .withEndAction {
                                    buttonContainer.animate()
                                        .scaleX(1.0f)
                                        .scaleY(1.0f)
                                        .setDuration(100)
                                        .start()
                                }
                                .start()
                            
                            // Icon bounce animation
                            buttonIcon.animate()
                                .scaleX(0.95f)
                                .scaleY(0.95f)
                                .setDuration(80)
                                .withEndAction {
                                    buttonIcon.animate()
                                        .scaleX(1.0f)
                                        .scaleY(1.0f)
                                        .setDuration(100)
                                        .start()
                                }
                                .start()
                            
                            // Reset button background
                            buttonBg.animate()
                                .alpha(1.0f)
                                .setDuration(200)
                                .start()
                            
                            onSwipeComplete()
                            isDragging = false
                            return@setOnTouchListener true
                        }
                    }
                    true
                }
                
                android.view.MotionEvent.ACTION_UP,
                android.view.MotionEvent.ACTION_CANCEL -> {
                    if (!isDragging && !hasSwipeCompleted) {
                        hasSwipeCompleted = true
                        // Simple tap detected - immediate action
                        buttonContainer.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                        
                        // Bounce effect on tap
                        buttonContainer.animate()
                            .scaleX(0.95f)
                            .scaleY(0.95f)
                            .setDuration(100)
                            .withEndAction {
                                buttonContainer.animate()
                                    .scaleX(1.0f)
                                    .scaleY(1.0f)
                                    .setDuration(100)
                                    .start()
                            }
                            .start()
                        
                        onSwipeComplete()
                    }
                    
                    // Reset button scales
                    buttonContainer.animate()
                        .scaleX(1f)
                        .scaleY(1f)
                        .setDuration(200)
                        .start()
                    
                    buttonIcon.animate()
                        .scaleX(1f)
                        .scaleY(1f)
                        .setDuration(200)
                        .start()
                    
                    // Reset button background alpha
                    buttonBg.animate()
                        .alpha(1.0f)
                        .setDuration(200)
                        .start()
                    
                    true
                }
                
                else -> false
            }
        }
    }

    override fun onBackPressed() {
        // Prevent back button from dismissing the incoming call UI
        // User must answer or decline
    }

    /**
     * Format phone number to a readable format
     * Examples:
     * +12034098827 -> +1 (203) 409-8827
     * 2034098827 -> (203) 409-8827
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
}

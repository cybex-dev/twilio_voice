package com.twilio.twilio_voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
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

    companion object {
        private const val TAG = "IncomingCallActivity"
        const val EXTRA_CALL_INVITE = "EXTRA_CALL_INVITE"
        const val EXTRA_CALLER_NAME = "EXTRA_CALLER_NAME"
        const val EXTRA_CALLER_NUMBER = "EXTRA_CALLER_NUMBER"
        const val EXTRA_CALL_SID = "EXTRA_CALL_SID"
        private const val REQUEST_RECORD_AUDIO_PERMISSION = 200

        fun createIntent(context: Context, callInvite: CallInvite): Intent {
            return Intent(context, IncomingCallActivity::class.java).apply {
                // Minimal flags for lock screen incoming call - let manifest attributes handle the rest
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
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
    
    // Ringtone and vibration for incoming call
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false
    
    // Idempotency flag to prevent double-handling of answer/decline
    @Volatile
    private var callHandled = false
    
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
        android.util.Log.d(TAG, "onCreate: STARTED - IncomingCallActivity created")
        // Set window flags before super.onCreate()
        showOverLockScreen()
        
        super.onCreate(savedInstanceState)
        
        // Wake up the screen after onCreate
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

        // Get call info from intent
        callInvite = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        callSid = intent.getStringExtra(EXTRA_CALL_SID)
        callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown"
        callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
        
        // Extract the "to" number (the number receiving the call)
        myNumber = callInvite?.to ?: ""

        // Set caller info
        findViewById<TextView>(R.id.callerName).text = callerName
        findViewById<TextView>(R.id.callerNumber).text = formatPhoneNumber(callerNumber)

        // Load Easify logo from Flutter assets using SvgPicture-like approach
        // For now, keep the vector drawable but make it more visible
        val easifyLogo = findViewById<ImageView>(R.id.easifyLogo)
        easifyLogo.elevation = 8f

        // Add animated avatar ring to container
        val avatarContainer = findViewById<FrameLayout>(R.id.avatarContainer)
        val animatedRing = com.twilio.twilio_voice.ui.AnimatedCallAvatarView(this)
        avatarContainer.addView(animatedRing)

        // Handle caller initials or person icon
        val initialsView = findViewById<TextView>(R.id.callerInitials)
        val personIconView = findViewById<ImageView>(R.id.personIcon)
        
        // Extract initials from caller name (skip phone numbers)
        if (!callerName.isNullOrEmpty() && callerName != "Unknown" && !callerName!!.matches(Regex("^[+\\d\\s()-]*$"))) {
            // This is a real name, not just a phone number
            val initials = callerName!!.split(" ").take(2).map { it.firstOrNull()?.uppercaseChar() ?: "" }.joinToString("")
            if (initials.isNotEmpty()) {
                initialsView.text = initials
                initialsView.visibility = android.view.View.VISIBLE
                personIconView.visibility = android.view.View.GONE
            } else {
                // Show person icon for phone number or empty name
                initialsView.visibility = android.view.View.GONE
                personIconView.visibility = android.view.View.VISIBLE
            }
        } else {
            // Show person icon for unknown caller or phone number
            initialsView.visibility = android.view.View.GONE
            personIconView.visibility = android.view.View.VISIBLE
        }

        // Set up answer button with swipe animation
        val acceptButtonContainer = findViewById<FrameLayout>(R.id.acceptButton)
        val acceptButtonBg = findViewById<View>(R.id.acceptButtonBg)
        val acceptButtonCircle = findViewById<ImageView>(R.id.acceptButtonCircle)
        
        // Add elevation to buttons for more visibility
        acceptButtonContainer.elevation = 12f
        acceptButtonBg.elevation = 10f
        
        setupButtonSwipeAnimation(acceptButtonContainer, acceptButtonBg, acceptButtonCircle) {
            answerCall()
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
        
        // For Android O_MR1+ (API 27+) use the newer API methods - these are REQUIRED on newer Android
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            android.util.Log.d(TAG, "showOverLockScreen: setShowWhenLocked and setTurnScreenOn called")
        }
        
        // Add window flags for lock screen display
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )
        
        // Handle display cutout for notched devices (Android P+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode = 
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }
    
    override fun onResume() {
        super.onResume()
        android.util.Log.d(TAG, "onResume: Activity resumed")
    }
    
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        android.util.Log.d(TAG, "onWindowFocusChanged: hasFocus=$hasFocus")
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRinging()
        unregisterCallEndedReceiver()
        releaseWakeLock()
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
        android.util.Log.d(TAG, "proceedWithAnswer: STARTED - Answering call with callSid: $callSid, hasCallInvite: ${callInvite != null}")
        releaseWakeLock()
        callSid?.let { sid ->
            android.util.Log.d(TAG, "proceedWithAnswer: Creating ACTION_ANSWER intent for TVConnectionService")
            // Send answer intent to TVConnectionService - include CallInvite for terminated state recovery
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
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
        finishAndRemoveTask()
    }

    private fun launchMainActivity() {
        // Get the main launcher activity
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
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
        android.util.Log.d(TAG, "onNewIntent called with action=${intent?.getStringExtra("action")}")
        
        // Update the intent
        setIntent(intent)
        
        intent?.let {
            // Check if this is an answer action from notification
            val action = it.getStringExtra("action")
            if (action == "answer") {
                android.util.Log.d(TAG, "onNewIntent: Handling answer action from notification")
                // Update the stored values before handling
                callInvite = it.getParcelableExtra(EXTRA_CALL_INVITE)
                callSid = it.getStringExtra(EXTRA_CALL_SID)
                callerName = it.getStringExtra(EXTRA_CALLER_NAME) ?: callerName
                callerNumber = it.getStringExtra(EXTRA_CALLER_NUMBER) ?: callerNumber
                myNumber = it.getStringExtra("extra_my_number") ?: myNumber
                handleAnswerFromNotification()
                return
            }
            
            // Handle if a new call comes in while this activity is showing
            callInvite = it.getParcelableExtra(EXTRA_CALL_INVITE)
            callSid = it.getStringExtra(EXTRA_CALL_SID)
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
        
        buttonContainer.setOnTouchListener { _, event ->
            when (event.action) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    startX = event.x
                    startY = event.y
                    isDragging = false
                    
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
                        
                        // If dragged more than 120dp, trigger action
                        if (totalDelta > 120) {
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
                    if (!isDragging) {
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

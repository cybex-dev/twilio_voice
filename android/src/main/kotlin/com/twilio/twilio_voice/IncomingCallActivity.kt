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
import android.widget.Button
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
    private var wakeLock: PowerManager.WakeLock? = null
    
    // Ringtone and vibration for incoming call
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false
    
    // Idempotency flag to prevent double-handling of answer/decline
    @Volatile
    private var callHandled = false
    
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
        // Set window flags before super.onCreate()
        showOverLockScreen()
        
        super.onCreate(savedInstanceState)
        
        // Wake up the screen after onCreate
        wakeUpScreen()
        
        // Check if this is an answer action from notification
        val action = intent.getStringExtra("action")
        if (action == "answer") {
            // Direct answer from notification - answer and launch main app
            handleAnswerFromNotification()
            return
        }
        
        setContentView(R.layout.activity_incoming_call)

        // Get call info from intent
        callInvite = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        callSid = intent.getStringExtra(EXTRA_CALL_SID)
        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown"
        val callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""

        // Set caller info
        findViewById<TextView>(R.id.tv_caller_name).text = callerName
        findViewById<TextView>(R.id.tv_caller_number).text = callerNumber

        // Set up answer button
        findViewById<Button>(R.id.btn_answer).setOnClickListener {
            answerCall()
        }

        // Set up decline button
        val declineButton = findViewById<Button>(R.id.btn_decline)
        declineButton.setOnClickListener {
            declineButton.isEnabled = false // Prevent double tap
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
        // Mark as handled immediately to prevent any race conditions
        callHandled = true
        val sid = intent.getStringExtra(EXTRA_CALL_SID)
        // Try to get CallInvite from intent
        val invite: CallInvite? = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        
        // Store invite for permission callback
        if (invite != null) {
            callInvite = invite
        }
        if (sid != null) {
            callSid = sid
        }
        
        // Check for RECORD_AUDIO permission before answering
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.d(TAG, "handleAnswerFromNotification: Requesting RECORD_AUDIO permission")
            // Reset callHandled so proceedWithAnswer can set it again
            callHandled = false
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return
        }
        
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
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            
            // Launch the main Flutter activity
            launchMainActivity()
        }
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
        android.util.Log.d(TAG, "proceedWithAnswer: Answering call with callSid: $callSid")
        releaseWakeLock()
        callSid?.let { sid ->
            // Send answer intent to TVConnectionService - include CallInvite for terminated state recovery
            val answerIntent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                callInvite?.let { invite ->
                    putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, invite)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            
            // Launch the main Flutter activity
            launchMainActivity()
        }
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
            startActivity(it)
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        // Handle if a new call comes in while this activity is showing
        intent?.let {
            callInvite = it.getParcelableExtra(EXTRA_CALL_INVITE)
            callSid = it.getStringExtra(EXTRA_CALL_SID)
        }
    }

    override fun onBackPressed() {
        // Prevent back button from dismissing the incoming call UI
        // User must answer or decline
    }
}

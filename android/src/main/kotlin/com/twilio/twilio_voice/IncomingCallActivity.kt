package com.twilio.twilio_voice

import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
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

        fun createIntent(context: Context, callInvite: CallInvite): Intent {
            return Intent(context, IncomingCallActivity::class.java).apply {
                // Flags that work best for full-screen incoming call UI
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
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

    @SuppressLint("WakelockTimeout")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Wake up the screen first
        wakeUpScreen()
        
        // Enable showing over lock screen
        showOverLockScreen()
        
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
        findViewById<Button>(R.id.btn_decline).setOnClickListener {
            declineCall()
        }
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
        // Always add window flags first (works on all versions)
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )
        
        // For Android O_MR1+ also use the newer API
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
    }

    private fun answerCall() {
        releaseWakeLock()
        callSid?.let { sid ->
            // Send answer intent to TVConnectionService
            Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(this)
                } else {
                    startService(this)
                }
            }
            
            // Launch the main Flutter activity
            launchMainActivity()
        }
        finish()
    }

    private fun declineCall() {
        releaseWakeLock()
        callSid?.let { sid ->
            // Send hangup intent to TVConnectionService
            Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(this)
                } else {
                    startService(this)
                }
            }
        }
        finish()
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

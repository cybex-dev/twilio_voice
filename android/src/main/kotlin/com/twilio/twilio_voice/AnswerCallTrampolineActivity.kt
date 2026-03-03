package com.twilio.twilio_voice

import android.Manifest
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.twilio.voice.CallInvite
import com.twilio.twilio_voice.service.TVConnectionService

/**
 * A completely invisible trampoline activity that answers an incoming call and
 * launches MainActivity.
 *
 * WHY THIS EXISTS:
 * On Android 12+ (especially Samsung SDK 36 / Android 16), calling startActivity()
 * from a foreground service (even with FLAG_ACTIVITY_NEW_TASK) may silently fail
 * to bring the app to the foreground due to background activity start restrictions.
 * By using a PendingIntent.getActivity() in the notification Answer button, the
 * system grants this activity an activity-start token. This activity then:
 *   1. Checks RECORD_AUDIO permission (required before accepting the Twilio call)
 *   2. If missing, requests it natively — the permission dialog appears over the
 *      notification/lock screen with no black screen (trampoline is translucent)
 *   3. On grant (or if already granted), sends ACTION_ANSWER to TVConnectionService
 *   4. Launches MainActivity from an activity context (always reliable)
 *   5. Finishes itself immediately
 *
 * The activity uses Theme.CallWaitingSheet (windowIsTranslucent=true, no animation)
 * so it's completely invisible — the user only sees the permission dialog (if needed)
 * and then the app coming to the foreground.
 *
 * Used ONLY for the no-active-call case. When there IS an active call, the
 * notification Answer button launches CallWaitingSheetActivity instead.
 */
class AnswerCallTrampolineActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "AnswerTrampoline"
        private const val REQUEST_RECORD_AUDIO_PERMISSION = 201

        const val EXTRA_CALL_SID = "extra_call_sid"
        const val EXTRA_CALL_INVITE = "extra_call_invite"
        const val EXTRA_CALLER_NAME = "extra_caller_name"
        const val EXTRA_CALLER_NUMBER = "extra_caller_number"
        const val EXTRA_MY_NUMBER = "extra_my_number"
    }

    // Cached intent data for use after permission callback
    private var callSid: String? = null
    private var callerNumber: String = ""
    private var myNumber: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No layout — this activity is completely invisible (translucent theme)

        Log.d(TAG, "onCreate: Trampoline started")

        callSid = intent.getStringExtra(EXTRA_CALL_SID)
        callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
        myNumber = intent.getStringExtra(EXTRA_MY_NUMBER) ?: ""

        if (callSid == null) {
            Log.e(TAG, "onCreate: Missing EXTRA_CALL_SID — finishing")
            finish()
            return
        }

        // Check RECORD_AUDIO permission BEFORE sending ACTION_ANSWER.
        // This prevents the Twilio SDK from crashing when callInvite.accept()
        // is called without microphone access.
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.d(TAG, "onCreate: RECORD_AUDIO not granted — requesting permission")
            // The permission dialog will appear over the notification/home screen.
            // Since this activity is translucent, there's no black screen behind it.
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO_PERMISSION)
            return  // Wait for onRequestPermissionsResult
        }

        // Permission already granted — proceed immediately
        Log.d(TAG, "onCreate: RECORD_AUDIO already granted — proceeding")
        proceedWithAnswer()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_RECORD_AUDIO_PERMISSION) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "onRequestPermissionsResult: RECORD_AUDIO granted — proceeding with answer")
                proceedWithAnswer()
            } else {
                Log.w(TAG, "onRequestPermissionsResult: RECORD_AUDIO denied — cannot answer call")
                Toast.makeText(this, "Microphone permission is required to answer calls", Toast.LENGTH_LONG).show()
                finish()
            }
        }
    }

    /**
     * Sends ACTION_ANSWER to TVConnectionService and launches MainActivity.
     * Called only when RECORD_AUDIO permission is confirmed granted.
     */
    private fun proceedWithAnswer() {
        val sid = callSid ?: run {
            Log.e(TAG, "proceedWithAnswer: callSid is null — finishing")
            finish()
            return
        }

        // Step 1: Send ACTION_ANSWER to the service
        val answerIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_ANSWER
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
            // Pass the CallInvite if available (needed for terminated-state recovery)
            val callInvite = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_CALL_INVITE, CallInvite::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<CallInvite>(EXTRA_CALL_INVITE)
            }
            callInvite?.let {
                putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, it)
            }
            // Tell the service that we (the activity) will handle launching MainActivity
            putExtra("LAUNCHED_FROM_ACTIVITY", true)
            data = android.net.Uri.parse("twilio://answer-trampoline/$sid")
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            Log.d(TAG, "proceedWithAnswer: Sent ACTION_ANSWER to service for $sid")
        } catch (e: Exception) {
            Log.e(TAG, "proceedWithAnswer: Failed to send ACTION_ANSWER: ${e.message}")
        }

        // Step 2: Launch MainActivity (from activity context — always works)
        val keyguardMgr = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val isLocked = keyguardMgr?.isKeyguardLocked == true

        if (isLocked) {
            // Device is locked — store pending data for MainActivity.onResume()
            Log.d(TAG, "proceedWithAnswer: Device is locked — storing pendingAnsweredCallData")
            IncomingCallActivity.pendingAnsweredCallData = mapOf(
                "callerName" to callerNumber,
                "callerNumber" to callerNumber,
                "myNumber" to myNumber,
                "callSid" to sid,
                "callDirection" to "incoming",
                "isCallAnswered" to true
            )
        } else {
            // Device is unlocked — launch MainActivity directly
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                launchIntent?.let {
                    it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                               Intent.FLAG_ACTIVITY_SINGLE_TOP or
                               Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    it.putExtra("fromIncomingCall", true)
                    it.putExtra("callHandle", sid)
                    it.putExtra("callAnswered", true)
                    it.putExtra("CALL_ANSWERED", true)
                    it.putExtra("CALL_SID", sid)
                    it.putExtra("CALLER_NAME", callerNumber)
                    it.putExtra("CALLER_NUMBER", callerNumber)
                    it.putExtra("MY_NUMBER", myNumber)
                    it.putExtra("CALL_DIRECTION", "incoming")
                    startActivity(it)
                    Log.d(TAG, "proceedWithAnswer: Launched MainActivity (UNLOCKED) — caller: $callerNumber")
                }
            } catch (e: Exception) {
                Log.w(TAG, "proceedWithAnswer: Failed to launch MainActivity: ${e.message}")
            }
        }

        // Step 3: Finish immediately — trampoline done
        Log.d(TAG, "proceedWithAnswer: Trampoline finishing")
        finish()
    }
}

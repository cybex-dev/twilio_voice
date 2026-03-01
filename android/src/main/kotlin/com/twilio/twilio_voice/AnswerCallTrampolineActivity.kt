package com.twilio.twilio_voice

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
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
 *   1. Sends ACTION_ANSWER to TVConnectionService (to accept the Twilio call)
 *   2. Launches MainActivity from an activity context (always reliable)
 *   3. Finishes itself immediately
 *
 * The activity uses Theme.CallWaitingSheet (windowIsTranslucent=true, no animation)
 * so it's completely invisible — the user only sees the app coming to the foreground.
 *
 * Used ONLY for the no-active-call case. When there IS an active call, the
 * notification Answer button launches CallWaitingSheetActivity instead.
 */
class AnswerCallTrampolineActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "AnswerTrampoline"

        const val EXTRA_CALL_SID = "extra_call_sid"
        const val EXTRA_CALL_INVITE = "extra_call_invite"
        const val EXTRA_CALLER_NAME = "extra_caller_name"
        const val EXTRA_CALLER_NUMBER = "extra_caller_number"
        const val EXTRA_MY_NUMBER = "extra_my_number"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No layout — this activity is completely invisible

        Log.d(TAG, "onCreate: Trampoline started")

        val callSid = intent.getStringExtra(EXTRA_CALL_SID)
        val callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
        val myNumber = intent.getStringExtra(EXTRA_MY_NUMBER) ?: ""

        if (callSid == null) {
            Log.e(TAG, "onCreate: Missing EXTRA_CALL_SID — finishing")
            finish()
            return
        }

        // Step 1: Send ACTION_ANSWER to the service
        val answerIntent = Intent(applicationContext, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_ANSWER
            putExtra(TVConnectionService.EXTRA_CALL_HANDLE, callSid)
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
            data = android.net.Uri.parse("twilio://answer-trampoline/$callSid")
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(answerIntent)
            } else {
                startService(answerIntent)
            }
            Log.d(TAG, "onCreate: Sent ACTION_ANSWER to service for $callSid")
        } catch (e: Exception) {
            Log.e(TAG, "onCreate: Failed to send ACTION_ANSWER: ${e.message}")
        }

        // Step 2: Launch MainActivity (from activity context — always works)
        val keyguardMgr = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val isLocked = keyguardMgr?.isKeyguardLocked == true

        if (isLocked) {
            // Device is locked — store pending data for MainActivity.onResume()
            Log.d(TAG, "onCreate: Device is locked — storing pendingAnsweredCallData")
            IncomingCallActivity.pendingAnsweredCallData = mapOf(
                "callerName" to callerNumber,
                "callerNumber" to callerNumber,
                "myNumber" to myNumber,
                "callSid" to callSid,
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
                    it.putExtra("callHandle", callSid)
                    it.putExtra("callAnswered", true)
                    it.putExtra("CALL_ANSWERED", true)
                    it.putExtra("CALL_SID", callSid)
                    it.putExtra("CALLER_NAME", callerNumber)
                    it.putExtra("CALLER_NUMBER", callerNumber)
                    it.putExtra("MY_NUMBER", myNumber)
                    it.putExtra("CALL_DIRECTION", "incoming")
                    startActivity(it)
                    Log.d(TAG, "onCreate: Launched MainActivity (UNLOCKED) — caller: $callerNumber")
                }
            } catch (e: Exception) {
                Log.w(TAG, "onCreate: Failed to launch MainActivity: ${e.message}")
            }
        }

        // Step 3: Finish immediately — trampoline done
        Log.d(TAG, "onCreate: Trampoline finishing")
        finish()
    }
}

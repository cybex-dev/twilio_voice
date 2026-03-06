package com.twilio.twilio_voice

import android.Manifest
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.twilio.voice.CallInvite
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver

/**
 * A lightweight, truly translucent activity that shows the call-waiting bottom sheet
 * as an overlay on top of whatever is currently visible (Flutter app, home screen, etc.).
 *
 * Launched from the notification "Answer" button when there's already an active call.
 * Unlike IncomingCallActivity (which has windowIsTranslucent=false for lock-screen support),
 * this activity uses windowIsTranslucent=true + windowAnimationStyle=none so it appears
 * instantly as an overlay with NO visible screen transition.
 *
 * The user sees 3 options:
 *   1. Hold & Answer — puts active call on hold, answers new call
 *   2. End & Answer  — ends active call, answers new call
 *   3. Decline       — rejects the incoming call
 */
class CallWaitingSheetActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "CallWaitingSheet"
        private const val REQUEST_RECORD_AUDIO = 200

        /** Permissions required to answer a call */
        private val REQUIRED_CALL_PERMISSIONS = arrayOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.READ_PHONE_STATE,
        )

        // Intent extras — same keys as IncomingCallActivity for consistency
        const val EXTRA_CALL_SID = "extra_call_sid"
        const val EXTRA_CALL_INVITE = "extra_call_invite"
        const val EXTRA_CALLER_NAME = "extra_caller_name"
        const val EXTRA_CALLER_NUMBER = "extra_caller_number"
        const val EXTRA_MY_NUMBER = "extra_my_number"
        const val EXTRA_ACTIVE_CALL_HANDLE = "extra_active_call_handle"
        const val EXTRA_ACTIVE_CALLER_NAME = "extra_active_caller_name"
        const val EXTRA_ACTIVE_CALLER_NUMBER = "extra_active_caller_number"
    }

    private var callSid: String? = null
    private var callInvite: CallInvite? = null
    private var callerName: String? = null
    private var callerNumber: String? = null
    private var myNumber: String? = null
    private var activeCallHandle: String? = null
    private var activeCallerName: String? = null
    private var activeCallerNumber: String? = null

    @Volatile
    private var callHandled = false

    // Which action was the user trying when we requested mic permission
    private var pendingAction: PendingAction = PendingAction.NONE

    private enum class PendingAction { NONE, HOLD_AND_ANSWER, END_AND_ANSWER }

    // Listen for call-ended broadcast so we auto-dismiss if the incoming call is
    // cancelled (caller hung up) while the sheet is showing.
    private val callEndedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == TVBroadcastReceiver.ACTION_CALL_ENDED) {
                val endedHandle = intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE)
                if (endedHandle != null && endedHandle == callSid) {
                    android.util.Log.d(TAG, "Incoming call $callSid ended externally — dismissing sheet")
                    if (!callHandled) {
                        callHandled = true
                        finishAndRemoveTask()
                    }
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        android.util.Log.d(TAG, "onCreate")

        // Extract all data from intent
        intent.setExtrasClassLoader(CallInvite::class.java.classLoader)
        callSid = intent.getStringExtra(EXTRA_CALL_SID)
        callInvite = intent.getParcelableExtra(EXTRA_CALL_INVITE)
        callerName = intent.getStringExtra(EXTRA_CALLER_NAME)
        callerNumber = intent.getStringExtra(EXTRA_CALLER_NUMBER)
        myNumber = intent.getStringExtra(EXTRA_MY_NUMBER)
        activeCallHandle = intent.getStringExtra(EXTRA_ACTIVE_CALL_HANDLE)
        activeCallerName = intent.getStringExtra(EXTRA_ACTIVE_CALLER_NAME)
        activeCallerNumber = intent.getStringExtra(EXTRA_ACTIVE_CALLER_NUMBER)

        android.util.Log.d(TAG, "onCreate: callSid=$callSid, caller=$callerName/$callerNumber, activeHandle=$activeCallHandle, activeName=$activeCallerName")

        // Verify the active call still exists (PendingIntent extras are baked at creation time)
        if (activeCallHandle != null) {
            val stillActive = TVConnectionService.activeConnections.containsKey(activeCallHandle)
            if (!stillActive) {
                android.util.Log.d(TAG, "onCreate: Active call $activeCallHandle no longer exists — answering directly via service")
                answerDirectly()
                return
            }
        }

        setContentView(R.layout.activity_call_waiting_sheet)

        setupUI()
        registerCallEndedReceiver()
    }

    // ── UI Setup ─────────────────────────────────────────────────────────────

    private fun setupUI() {
        // Caller info chip
        findViewById<TextView>(R.id.sheetCallerName)?.text = callerName ?: "Unknown"
        val formatted = formatPhoneNumber(callerNumber ?: "")
        findViewById<TextView>(R.id.sheetCallerNumber)?.text = if (formatted.isNotEmpty()) formatted else ""

        // Animate caller chip fade-in
        findViewById<View>(R.id.callerInfoChip)?.animate()
            ?.alpha(1f)
            ?.setDuration(300)
            ?.setStartDelay(100)
            ?.start()

        // Dynamic text with the active caller's name
        val displayName = when {
            !activeCallerName.isNullOrEmpty() && activeCallerName != "Unknown" -> activeCallerName!!
            !activeCallerNumber.isNullOrEmpty() -> formatPhoneNumber(activeCallerNumber)
            else -> "active call"
        }
        findViewById<TextView>(R.id.put_1_222_3)?.text = "Put $displayName on hold"
        findViewById<TextView>(R.id.end_call_wi)?.text = "End call with $displayName"

        // Navigation bar safe-area padding
        val sheet = findViewById<View>(R.id.callWaitingBottomSheet)
        val navBarHeight = getNavigationBarHeight()
        if (navBarHeight > 0 && sheet != null) {
            val basePadding = (28 * resources.displayMetrics.density).toInt()
            sheet.setPadding(sheet.paddingLeft, sheet.paddingTop, sheet.paddingRight, basePadding + navBarHeight)
        }

        // Slide-up animation for the sheet
        sheet?.let { s ->
            s.translationY = 2000f
            s.post {
                s.translationY = s.height.toFloat()
                s.animate()
                    .translationY(0f)
                    .setDuration(300)
                    .setInterpolator(android.view.animation.DecelerateInterpolator())
                    .start()
            }
        }

        // ── Click listeners ──

        // Scrim tap = decline
        findViewById<View>(R.id.callWaitingScrim)?.setOnClickListener {
            declineIncoming()
        }

        findViewById<View>(R.id.optionHoldAndAnswer)?.setOnClickListener {
            android.util.Log.d(TAG, "Option: Hold & Answer")
            holdAndAnswer()
        }

        findViewById<View>(R.id.optionEndAndAnswer)?.setOnClickListener {
            android.util.Log.d(TAG, "Option: End & Answer")
            endAndAnswer()
        }

        findViewById<View>(R.id.optionDecline)?.setOnClickListener {
            android.util.Log.d(TAG, "Option: Decline")
            declineIncoming()
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private fun holdAndAnswer() {
        if (callHandled) return
        if (!ensureMicPermission(PendingAction.HOLD_AND_ANSWER)) return
        callHandled = true
        android.util.Log.d(TAG, "holdAndAnswer: callSid=$callSid, activeCallHandle=$activeCallHandle")

        callSid?.let { sid ->
            val intent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER_WITH_HOLD
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                putExtra("EXTRA_ACTIVE_CALL_HANDLE", activeCallHandle)
                // Tell the service this was launched from an activity so it doesn't
                // launch MainActivity again — we handle that ourselves below.
                putExtra("LAUNCHED_FROM_ACTIVITY", true)
                callInvite?.let { inv -> putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, inv) }
            }
            startForegroundServiceCompat(intent)
            launchMainActivityForCallWaiting()
        }
        finishAndRemoveTask()
    }

    private fun endAndAnswer() {
        if (callHandled) return
        if (!ensureMicPermission(PendingAction.END_AND_ANSWER)) return
        callHandled = true
        android.util.Log.d(TAG, "endAndAnswer: callSid=$callSid, activeCallHandle=$activeCallHandle")

        callSid?.let { sid ->
            val intent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER_WITH_END_FIRST
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                putExtra("EXTRA_ACTIVE_CALL_HANDLE", activeCallHandle)
                putExtra("LAUNCHED_FROM_ACTIVITY", true)
                callInvite?.let { inv -> putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, inv) }
            }
            startForegroundServiceCompat(intent)
            launchMainActivityForCallWaiting()
        }
        finishAndRemoveTask()
    }

    private fun declineIncoming() {
        if (callHandled) return
        callHandled = true
        android.util.Log.d(TAG, "declineIncoming: callSid=$callSid")

        callSid?.let { sid ->
            val intent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_HANGUP
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                callInvite?.let { inv -> putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, inv) }
            }
            startForegroundServiceCompat(intent)
        }
        // Bring main activity back so the user sees the active call UI
        launchMainActivityForActiveCall()
        finishAndRemoveTask()
    }

    /**
     * Fallback: active call no longer exists — answer directly via ACTION_ANSWER.
     */
    private fun answerDirectly() {
        callHandled = true
        callSid?.let { sid ->
            val intent = Intent(this, TVConnectionService::class.java).apply {
                action = TVConnectionService.ACTION_ANSWER
                putExtra(TVConnectionService.EXTRA_CALL_HANDLE, sid)
                putExtra("LAUNCHED_FROM_ACTIVITY", false) // let service launch main activity
                callInvite?.let { inv -> putExtra(TVConnectionService.EXTRA_INCOMING_CALL_INVITE, inv) }
            }
            startForegroundServiceCompat(intent)
        }
        finishAndRemoveTask()
    }

    // ── Call permissions (mic + phone state) ───────────────────────────────

    private fun ensureMicPermission(action: PendingAction): Boolean {
        val missing = REQUIRED_CALL_PERMISSIONS.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return true

        // Check for permanently denied permissions
        val prefs = getSharedPreferences("easify_permissions", Context.MODE_PRIVATE)
        val permanentlyDenied = missing.filter {
            !ActivityCompat.shouldShowRequestPermissionRationale(this, it) &&
                prefs.getBoolean("requested_$it", false)
        }
        if (permanentlyDenied.size == missing.size) {
            android.util.Log.d(TAG, "ensureMicPermission: All missing permissions permanently denied — opening settings")
            openAppSettings()
            return false
        }

        // Track that we've requested these
        prefs.edit().apply {
            missing.forEach { putBoolean("requested_$it", true) }
            apply()
        }

        pendingAction = action
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), REQUEST_RECORD_AUDIO)
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_RECORD_AUDIO) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (allGranted) {
                when (pendingAction) {
                    PendingAction.HOLD_AND_ANSWER -> holdAndAnswer()
                    PendingAction.END_AND_ANSWER -> endAndAnswer()
                    PendingAction.NONE -> {}
                }
            } else {
                // Check if any permission is now permanently denied
                val permanentlyDenied = permissions.filterIndexed { index, _ ->
                    grantResults[index] != PackageManager.PERMISSION_GRANTED
                }.filter { !ActivityCompat.shouldShowRequestPermissionRationale(this, it) }

                if (permanentlyDenied.isNotEmpty()) {
                    android.util.Log.d(TAG, "onRequestPermissionsResult: Permanently denied: $permanentlyDenied — opening settings")
                    openAppSettings()
                } else {
                    android.widget.Toast.makeText(this, "Microphone and Phone State permissions are required to answer calls", android.widget.Toast.LENGTH_LONG).show()
                }
            }
            pendingAction = PendingAction.NONE
        }
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            android.widget.Toast.makeText(this, "Please enable the required permissions and try again", android.widget.Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            android.util.Log.e(TAG, "openAppSettings: Failed to open settings", e)
        }
    }

    // ── Launch helpers ────────────────────────────────────────────────────────

    /**
     * Bring main activity to front for call-waiting answer (hold+answer, end+answer).
     * Uses REORDER_TO_FRONT to preserve existing Flutter state.
     */
    private fun launchMainActivityForCallWaiting() {
        val deviceLocked = isDeviceLocked()
        android.util.Log.d(TAG, "launchMainActivityForCallWaiting: isDeviceLocked=$deviceLocked")

        if (deviceLocked) {
            // Store pending data — user will see the call after unlocking.
            storePendingCallDataForMainActivity()
            return
        }

        // Dismiss non-secure keyguard if showing
        dismissKeyguardIfNeeded()

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            it.putExtra("CALL_ANSWERED", true)
            it.putExtra("CALL_SID", callSid)
            it.putExtra("CALLER_NAME", callerName)
            it.putExtra("CALLER_NUMBER", callerNumber)
            it.putExtra("MY_NUMBER", myNumber)
            it.putExtra("CALL_DIRECTION", "incoming")
            startActivity(it)
            android.util.Log.d(TAG, "launchMainActivityForCallWaiting: Launched (UNLOCKED) - caller=$callerName")
        }
    }

    /**
     * Bring main activity to front to restore the active call UI after declining.
     * Does NOT pass call extras to avoid resetting Flutter state.
     */
    private fun launchMainActivityForActiveCall() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                       Intent.FLAG_ACTIVITY_SINGLE_TOP or
                       Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            startActivity(it)
            android.util.Log.d(TAG, "launchMainActivityForActiveCall: Brought main activity to front")
        }
    }

    // ── Utility helpers ──────────────────────────────────────────────────────

    private fun startForegroundServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun isDeviceLocked(): Boolean {
        val keyguardMgr = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        return keyguardMgr?.isKeyguardLocked == true
    }

    private fun dismissKeyguardIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            if (km?.isKeyguardLocked == true) {
                km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        android.util.Log.d(TAG, "Keyguard dismissed")
                    }
                    override fun onDismissCancelled() {
                        android.util.Log.d(TAG, "Keyguard dismiss cancelled")
                    }
                    override fun onDismissError() {
                        android.util.Log.d(TAG, "Keyguard dismiss error")
                    }
                })
            }
        } else {
            @Suppress("DEPRECATION")
            val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            km?.newKeyguardLock("CallWaitingSheet")?.disableKeyguard()
        }
    }

    private fun storePendingCallDataForMainActivity() {
        IncomingCallActivity.pendingAnsweredCallData = mapOf(
            "callerName" to callerName,
            "callerNumber" to callerNumber,
            "myNumber" to myNumber,
            "callSid" to callSid,
            "callDirection" to "incoming",
            "isCallAnswered" to true
        )
        android.util.Log.d(TAG, "storePendingCallDataForMainActivity: Stored pending data")
    }

    private fun getNavigationBarHeight(): Int {
        val id = resources.getIdentifier("navigation_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    private fun formatPhoneNumber(phoneNumber: String?): String {
        if (phoneNumber.isNullOrEmpty()) return ""
        val cleaned = phoneNumber.replace(Regex("[^\\d+]"), "")
        if (cleaned.isEmpty()) return phoneNumber
        val hasPlus = cleaned.startsWith("+")
        val digits = if (hasPlus) cleaned.substring(1) else cleaned
        return when {
            hasPlus && digits.length >= 11 -> {
                "+${digits[0]} (${digits.substring(1,4)}) ${digits.substring(4,7)}-${digits.substring(7,11)}"
            }
            !hasPlus && digits.length == 10 -> {
                "(${digits.substring(0,3)}) ${digits.substring(3,6)}-${digits.substring(6,10)}"
            }
            else -> phoneNumber
        }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    private fun registerCallEndedReceiver() {
        try {
            val filter = IntentFilter(TVBroadcastReceiver.ACTION_CALL_ENDED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(callEndedReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(callEndedReceiver, filter)
            }
            android.util.Log.d(TAG, "Registered callEndedReceiver")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Failed to register callEndedReceiver: $e")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(callEndedReceiver)
        } catch (_: Exception) { }
    }

    override fun onBackPressed() {
        // Block back button — user must choose an option
    }
}

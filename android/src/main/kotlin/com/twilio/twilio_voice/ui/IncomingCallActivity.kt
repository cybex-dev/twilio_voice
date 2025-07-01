package com.twilio.twilio_voice.ui

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.view.WindowManager
import android.os.Build
import android.widget.FrameLayout
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.twilio.twilio_voice.receivers.TVBroadcastReceiver
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.types.TVNativeCallActions
import com.twilio.twilio_voice.types.TVNativeCallEvents

class IncomingCallActivity : Activity() {
    private val finishReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (!isFinishing && (intent?.action != TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED || intent.getStringExtra(TVBroadcastReceiver.EXTRA_CALL_HANDLE).isNullOrEmpty())) {
                    finishAndRemoveTask()
                    overridePendingTransition(0, 0)
                }
            }, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        LocalBroadcastManager.getInstance(this).registerReceiver(finishReceiver, IntentFilter().apply {
            addAction(TVBroadcastReceiver.ACTION_CALL_ENDED)
            addAction(TVBroadcastReceiver.ACTION_INCOMING_CALL_IGNORED)
            addAction(TVNativeCallActions.ACTION_ABORT)
            addAction(TVNativeCallActions.ACTION_REJECTED)
            addAction(TVNativeCallEvents.EVENT_CONNECT_FAILURE)
            addAction(TVNativeCallEvents.EVENT_DISCONNECTED_LOCAL)
            addAction(TVNativeCallEvents.EVENT_DISCONNECTED_REMOTE)
            addAction(TVNativeCallEvents.EVENT_MISSED)
            addAction(TVBroadcastReceiver.ACTION_ACTIVE_CALL_CHANGED)
            addAction(TVNativeCallEvents.EVENT_CONNECTED)
        })

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        
        window.addFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        )
        
        setContentView(FrameLayout(this))
    }

    override fun onResume() {
        super.onResume()

        Intent(this, TVConnectionService::class.java).apply {
            action = TVConnectionService.ACTION_INCOMING_CALL_UI_READY
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    this@IncomingCallActivity.startForegroundService(this)
                } catch (e: Exception) {
                    this@IncomingCallActivity.startService(this)
                }
            } else {
                this@IncomingCallActivity.startService(this)
            }
        }
    }

    override fun onDestroy() {
        LocalBroadcastManager.getInstance(this).unregisterReceiver(finishReceiver)
        super.onDestroy()
    }

    override fun onBackPressed() {
        moveTaskToBack(true)
    }
}
package com.twilio.twilio_voice.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging

/**
 * BroadcastReceiver that handles device boot completed events.
 * This ensures that Firebase Messaging is properly initialized after device restart,
 * allowing the app to receive push notifications even before the user opens the app.
 */
class BootCompletedReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootCompletedReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON" ||
            intent.action == "com.htc.intent.action.QUICKBOOT_POWERON") {
            
            Log.d(TAG, "Boot completed received, initializing Firebase Messaging")
            
            try {
                // Get FCM token to ensure Firebase Messaging is initialized
                // This triggers the Firebase service to start and register for push notifications
                FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                    if (task.isSuccessful) {
                        val token = task.result
                        Log.d(TAG, "FCM Token retrieved successfully after boot: ${token?.take(20)}...")
                    } else {
                        Log.e(TAG, "Failed to get FCM token after boot", task.exception)
                    }
                }
                
                // Also ensure auto-init is enabled
                FirebaseMessaging.getInstance().isAutoInitEnabled = true
                
                Log.d(TAG, "Firebase Messaging initialization triggered after boot")
            } catch (e: Exception) {
                Log.e(TAG, "Error initializing Firebase after boot", e)
            }
        }
    }
}

package com.twilio.twilio_voice.types

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.content.PermissionChecker
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.types.ContextExtension.appName
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneNumbersPermission
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneStatePermission
import com.twilio.twilio_voice.R
import com.twilio.twilio_voice.call.TVParameters

object TelecomManagerExtension {

    /**
     *  Register a phone account with the system telecom manager
     *  @param ctx application context
     *  @param phoneAccountHandle The handle for the phone account
     *  @param label The label for the phone account
     *  @param shortDescription The short description for the phone account
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.registerPhoneAccount(ctx: Context, phoneAccountHandle: PhoneAccountHandle) {
        if (hasCallCapableAccount(ctx, phoneAccountHandle.componentName.className)) {
            // phone account already registered
            Log.d("TelecomManager", "registerPhoneAccount: phone account already re-registering.")
//            return
        }

        val label = ctx.getString(R.string.phone_account_name).apply {
            this.ifEmpty {
                ctx.appName
            }
        }
        val description = ctx.getString(R.string.phone_account_desc).apply {
            this.ifEmpty {
                "Provides calling services for $label"
            }
        }

        // register phone account
        val phoneAccount = PhoneAccount.builder(phoneAccountHandle, label)
            .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER or PhoneAccount.CAPABILITY_CONNECTION_MANAGER or PhoneAccount.CAPABILITY_CALL_SUBJECT)
            .setShortDescription(description)
//            .addSupportedUriScheme(TVConnectionService.TWI_SCHEME)
            .setIcon(Icon.createWithResource(ctx, ctx.applicationInfo.icon))
            .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
            .build()

        registerPhoneAccount(phoneAccount)
    }

    fun TelecomManager.openPhoneAccountSettings(activity: Activity) {
        if (Build.MANUFACTURER.equals("Samsung", ignoreCase = true)|| Build.MANUFACTURER.equals("OnePlus", ignoreCase = true)) {
            try {
                val intent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS)
                intent.component = ComponentName(
                    "com.android.server.telecom",
                    "com.android.server.telecom.settings.EnableAccountPreferenceActivity"
                )
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                activity.startActivity(intent, null)
            } catch (e: Exception) {
                Log.e("TelecomManager", "openPhoneAccountSettings: ${e.message}")

                // use fallback method
                val intent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS)
                activity.startActivity(intent, null)
            }

        } else {
            val intent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS)
            activity.startActivity(intent, null)
        }
    }


    /**
     * Check if a phone account has been registered with the system telecom manager
     * @param ctx application context
     * @param name The name of the componentName Class (i.e. ConnectionService)
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.hasCallCapableAccount(ctx: Context, name: String): Boolean {
        if (!canReadPhoneState(ctx)) return false
        return callCapablePhoneAccounts.any { it.componentName.className == name }
    }

    /**
     * Get the [PhoneAccountHandle] for the app
     * @param ctx application context
     * @return PhoneAccountHandle The phone account handle for the app
     */
    fun TelecomManager.getPhoneAccountHandle(ctx: Context): PhoneAccountHandle {
        val appName = ctx.appName
        val componentName = ComponentName(ctx, TVConnectionService::class.java)

        Log.d(TVConnectionService.TAG, "getPhoneAccountHandle: Get PhoneAccountHandle with name: $appName, componentName: $componentName")
        return PhoneAccountHandle(componentName, appName)
    }

    /**
     * Check if the app has the READ_PHONE_STATE permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_STATE permission
     */
    fun TelecomManager.canReadPhoneState(ctx: Context): Boolean {
        return ctx.hasReadPhoneStatePermission()
    }

    /**
     * Check if the app has the READ_PHONE_NUMBERS permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_NUMBERS permission
     */
    fun TelecomManager.canReadPhoneNumbers(ctx: Context): Boolean {
        return ctx.hasReadPhoneNumbersPermission()
    }

    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.isOnCall(ctx: Context): Boolean {
        if (!canReadPhoneState(ctx)) return false
        return if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.O) isInCall else isInManagedCall
    }
}
package com.twilio.twilio_voice.types

import android.content.Context
import android.content.pm.PackageManager
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneNumbersPermission
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneStatePermission

object ContextExtension {

    val Context.appName: String
        get() {
            return applicationInfo.loadLabel(packageManager).toString()
        }

    val Context.packageName: String
        get() {
            val stringId = applicationInfo.labelRes
            return if (stringId == 0) applicationInfo.nonLocalizedLabel.toString() else getString(stringId)
        }

    /**
     * Check if the app has the RECORD_AUDIO permission
     * @return Boolean True if the app has the RECORD_AUDIO permission
     */
    fun Context.hasMicrophoneAccess(): Boolean {
        return checkPermission(android.Manifest.permission.RECORD_AUDIO)
    }

    /**
     * Check if the app has the READ_PHONE_NUMBERS permission
     * @return Boolean True if the app has the READ_PHONE_NUMBERS permission
     */
    fun Context.hasReadPhoneNumbersPermission(): Boolean {
        return checkPermission(android.Manifest.permission.READ_PHONE_NUMBERS)
    }

    /**
     * Check if the app has the READ_PHONE_STATE permission
     * @return Boolean True if the app has the READ_PHONE_STATE permission
     */
    fun Context.hasReadPhoneStatePermission(): Boolean {
        return checkPermission(android.Manifest.permission.READ_PHONE_STATE)
    }

    /**
     * Check if the app has the MANAGE_OWN_CALLS permission
     * @return Boolean True if the app has the MANAGE_OWN_CALLS permission
     */
    fun Context.hasManageOwnCallsPermission(): Boolean {
        return checkPermission(android.Manifest.permission.MANAGE_OWN_CALLS)
    }

    /**
     * Check if the app has the CALL_PHONE permission
     * @return Boolean True if the app has the CALL_PHONE permission
     */
    fun Context.hasCallPhonePermission(): Boolean {
        return checkPermission(android.Manifest.permission.CALL_PHONE)
    }

    /**
     * Check if a permission is granted.
     * Uses ContextCompat.checkSelfPermission() instead of PermissionChecker.checkSelfPermission()
     * because PermissionChecker also checks AppOps state, which can return PERMISSION_DENIED_APP_OP
     * on Samsung devices (especially SDK 36/Android 16) when called from a service context without
     * a foreground activity — even though the runtime permission is granted.
     * ContextCompat only checks the runtime permission grant, which is reliable from any context.
     *
     * @param permission The permission to check
     * @return Boolean True if the permission is granted
     */
    fun Context.checkPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }
}
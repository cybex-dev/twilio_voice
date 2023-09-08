package com.twilio.twilio_voice.types

import android.content.Context
import android.telecom.TelecomManager
import androidx.core.content.PermissionChecker
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
     * Check if the app has the CALL_PHONE permission
     * @return Boolean True if the app has the CALL_PHONE permission
     */
    fun Context.hasCallPhonePermission(): Boolean {
        return checkPermission(android.Manifest.permission.CALL_PHONE)
    }

    /**
     * Check if a permission is granted
     * @param ctx application context
     * @param permission The permission to check
     * @return Boolean True if the permission is granted
     */
    fun Context.checkPermission(permission: String): Boolean {
        return PermissionChecker.checkSelfPermission(this, permission) == PermissionChecker.PERMISSION_GRANTED
    }
}
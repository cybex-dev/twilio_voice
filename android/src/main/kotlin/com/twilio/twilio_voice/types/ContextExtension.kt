package com.twilio.twilio_voice.types

import android.content.Context

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
}
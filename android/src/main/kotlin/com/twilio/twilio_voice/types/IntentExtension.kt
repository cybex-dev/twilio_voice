package com.twilio.twilio_voice.types

import android.content.Intent
import android.os.Build
import android.os.Parcelable

object IntentExtension {
    inline fun <reified T: Parcelable> Intent.getParcelableExtraSafe(key: String): T? {
        return if(Build.VERSION.SDK_INT <= Build.VERSION_CODES.TIRAMISU) {
            this.getParcelableExtra<T>(key)
        } else {
            this.getParcelableExtra(key, T::class.java)
        }
    }
}
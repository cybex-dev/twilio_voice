package com.twilio.twilio_voice.types

import android.os.Build
import android.os.Bundle
import android.os.Parcelable

object BundleExtensions {
    inline fun <reified T: Parcelable> Bundle.getParcelableSafe(key: String): T? {
        return if(Build.VERSION.SDK_INT <= Build.VERSION_CODES.TIRAMISU) {
            this.getParcelable<T>(key)
        } else {
            this.getParcelable(key, T::class.java)
        }
    }
}
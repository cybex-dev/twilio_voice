package com.twilio.twilio_voice.types

import android.os.Bundle

@FunctionalInterface
fun interface ValueBundleChanged<T> {
    fun onChange(t: T?, extra: Bundle?)
}
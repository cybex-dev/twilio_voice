package com.twilio.twilio_voice.types

import java.util.Locale

object StringExtension {
    fun String.capitalize(): String {
        return this.lowercase(Locale.ROOT).replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.getDefault()) else it.toString() }
    }
}
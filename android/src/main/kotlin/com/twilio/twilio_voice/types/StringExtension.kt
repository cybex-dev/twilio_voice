package com.twilio.twilio_voice.types

import java.util.Locale

object StringExtension {
    fun capitalize(): String {
        val value = this.toString()
        return value.lowercase(Locale.ROOT).replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.getDefault()) else it.toString() }
    }
}
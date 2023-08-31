package com.twilio.twilio_voice.call

interface TVCallParameters {
    val from: String

    val to: String

    val customParameters: Map<String, String>

    val callSid: String

    fun hasCustomParameters(): Boolean

    fun getExtra(key: String, defaultValue: String?): String?

    fun hasExtra(key: String): Boolean

    fun resolveHumanReadableName(name: String): String
}
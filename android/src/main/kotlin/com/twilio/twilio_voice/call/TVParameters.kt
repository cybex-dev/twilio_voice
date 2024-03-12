package com.twilio.twilio_voice.call

interface TVParameters {

    val fromRaw: String

    val from: String

    val toRaw: String

    val to: String

    val customParameters: Map<String, String>

    val callSid: String

    fun hasCustomParameters(): Boolean

    fun getExtra(key: String, defaultValue: String?): String?

    fun hasExtra(key: String): Boolean

    fun resolveHumanReadableName(name: String): String

    companion object {
        val PARAM_CALLER_ID: String = "__TWI_CALLER_ID"
        val PARAM_CALLER_NAME: String = "__TWI_CALLER_NAME"

        val PARAM_RECIPIENT_ID: String = "__TWI_RECIPIENT_ID"
        val PARAM_RECIPIENT_NAME: String = "__TWI_RECIPIENT_NAME"

        val PARAM_CALLER_URL: String = "__TWI_CALLER_URL"
        val PARAM_RECIPIENT_URL: String = "__TWI_RECIPIENT_URL"
        val PARAM_SUBJECT: String = "__TWI_SUBJECT"
    }
}
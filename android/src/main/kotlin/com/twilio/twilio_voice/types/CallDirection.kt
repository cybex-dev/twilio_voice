package com.twilio.twilio_voice.types

import com.twilio.twilio_voice.types.StringExtension.capitalize

enum class CallDirection(val value: String, val id: Int, val label: String) {
    INCOMING("INCOMING", 0, "Incoming"),
    OUTGOING("OUTGOING", 1, "Outgoing");

    companion object {
        private val mapValues = values().associateBy(CallDirection::label)
        private val mapIds = values().associateBy(CallDirection::id)
        fun fromValue(method: String) = mapValues[method]
        fun fromId(id: Int) = mapIds[id]
    }

    override fun toString(): String {
        return capitalize()
    }
}
package com.twilio.twilio_voice.types

@FunctionalInterface
fun interface CompletionHandler<T> {
    fun withValue(t: T?)
}
package com.twilio.twilio_voice.types

import android.os.Bundle
import com.twilio.voice.CallException

object CallExceptionExtension {

    /**
     * Exception code
     */
    val EXTRA_CODE = "code"

    /**
     * Exception message
     */
    val EXTRA_MESSAGE = "message"

    /**
     * Exception explanation
     */
    val EXTRA_EXPLANATION = "explanation"

    fun CallException.toBundle(): Bundle {
        return Bundle().apply {
            putInt(EXTRA_CODE, errorCode)
            putString(EXTRA_MESSAGE, message)
            putString(EXTRA_EXPLANATION, explanation)
        }
    }
}
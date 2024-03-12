package com.twilio.twilio_voice.types

import com.twilio.voice.Call

/**
 * The events that can be received from Twilio's native SDK [Call.Listener] interface, a convenience class for [Call.State] with additional call events.
 */
object TVNativeCallEvents {

    /**
     * The event name for when a call is connected (outbound, inbound)
     */
    val EVENT_CONNECTING: String = "com.twilio.EVENT_CONNECTING"

    /**
     * The event name for when a call is incoming (inbound)
     */
    val EVENT_INCOMING: String = "com.twilio.EVENT_INCOMING"

    /**
     * The event name for when a call is ringing (incoming)
     */
    val EVENT_RINGING: String = "com.twilio.EVENT_RINGING"

    /**
     * The event name for when a call is connected (outbound, inbound)
     */
    val EVENT_CONNECTED: String = "com.twilio.EVENT_CONNECTED"

    /**
     * The event name for when a call is connected (outbound, inbound)
     */
    val EVENT_CONNECT_FAILURE: String = "com.twilio.EVENT_CONNECT_FAILURE"

    /**
     * The event name for when a call is reconnecting (outbound, inbound)
     */
    val EVENT_RECONNECTING: String = "com.twilio.EVENT_RECONNECTING"

    /**
     * The event name for when a call is reconnected (outbound, inbound)
     */
    val EVENT_RECONNECTED: String = "com.twilio.EVENT_RECONNECTED"

    /**
     * The event name for when a call is disconnected locally
     */
    val EVENT_DISCONNECTED_LOCAL: String = "com.twilio.EVENT_DISCONNECTED_LOCAL"

    /**
     * The event name for when a call is disconnected locally
     */
    val EVENT_DISCONNECTED_REMOTE: String = "com.twilio.EVENT_DISCONNECTED_REMOTE"

    /**
     * The event name for when a call is missed
     */
    val EVENT_MISSED: String = "com.twilio.EVENT_MISSED"
}

/**
 * The events that can be received from Twilio's native SDK [Call.Listener] interface, a convenience class for [Call.State] with additional call events.
 */
object TVNativeCallActions {

    /**
     * Action when a call is answered
     */
    val ACTION_ANSWERED: String = "com.twilio.ACTION_ANSWERED"

    /**
     * Action when a call is answered
     */
    val ACTION_REJECTED: String = "com.twilio.ACTION_REJECTED"

    /**
     * Action when a call is answered
     */
    val ACTION_DTMF: String = "com.twilio.ACTION_DTMF"

    /**
     * Action when a call has been aborted
     */
    val ACTION_ABORT: String = "com.twilio.ACTION_ABORT"

    /**
     * Action when user placed a call on hold
     */
    val ACTION_HOLD: String = "com.twilio.ACTION_HOLD"

    /**
     * Action when user has removed a call from hold
     */
    val ACTION_UNHOLD: String = "com.twilio.ACTION_UNHOLD"

//    val ACTION_MUTE = "ACTION_MUTE"

    /**
     * (optional) Extra sent with [ACTION_REJECTED]
     */
    val EXTRA_REJECT_REASON: String = "EXTRA_REJECT_REASON"

    /**
     * (optional) Extra sent with [ACTION_DTMF]
     */
    val EXTRA_DTMF_TONE: String = "EXTRA_DTMF_TONE"
}
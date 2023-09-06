package com.twilio.twilio_voice.call

import com.twilio.twilio_voice.call.TVParameters.Companion.PARAM_CALLER_ID
import com.twilio.twilio_voice.call.TVParameters.Companion.PARAM_CALLER_NAME
import com.twilio.twilio_voice.call.TVParameters.Companion.PARAM_RECIPIENT_ID
import com.twilio.twilio_voice.call.TVParameters.Companion.PARAM_RECIPIENT_NAME
import com.twilio.twilio_voice.storage.Storage
import com.twilio.voice.Call
import com.twilio.voice.CallInvite

class TVCallInviteParametersImpl(storage: Storage, callInvite: CallInvite) : TVParametersImpl(storage, callInvite.callSid, callInvite.customParameters) {

    private val mCallInvite: CallInvite

    init {
        mCallInvite = callInvite
    }

    override val from: String
        get() {
            val mFrom = mCallInvite.from ?: ""
            if (mFrom.isEmpty()) {
                return mStorage.defaultCaller
            }

            if (!mFrom.startsWith("client:")) {
                // we have a number, return as is
                return mFrom
            }

            val mToName = mFrom.replace("client:", "")
            return customParameters[PARAM_RECIPIENT_NAME]
                ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
                ?: resolveHumanReadableName(mToName)
        }

    override val to: String
        get() {
            val mTo = mCallInvite.to
            if (!mTo.startsWith("client:")) {
                // we have a number, return as is
                return mTo
            }

            val mToName = mTo.replace("client:", "")
            return customParameters[PARAM_RECIPIENT_NAME]
                ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
                ?: resolveHumanReadableName(mToName)
        }
}

class TVCallParametersImpl(storage: Storage, call: Call, callTo: String, callFrom: String, customParameters: Map<String, String> = emptyMap()) : TVParametersImpl(storage) {
    private var mCallSid: String? = null

    private val mCall: Call
    private val mFrom: String
    private val mTo: String
    override var callSid: String
        get() = mCallSid ?: ""
        set(value) {
            mCallSid = value
        }

    init {
        mCall = call
        mFrom = callFrom
        mTo = callTo
    }

    override val from: String
        get() {
            if (mFrom.isEmpty()) {
                return mStorage.defaultCaller
            }

            if (!mFrom.startsWith("client:")) {
                // we have a number, return as is
                return mFrom
            }

            val mFromName = mFrom.replace("client:", "")
            return customParameters[PARAM_RECIPIENT_NAME]
                ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
                ?: resolveHumanReadableName(mFromName)
        }

    override val to: String
        get() {
            if (mTo.isEmpty()) {
                return mStorage.defaultCaller
            }

            if (!mTo.startsWith("client:")) {
                // we have a number, return as is
                return mTo
            }

            val mToName = mTo.replace("client:", "")
            return customParameters[PARAM_RECIPIENT_NAME]
                ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
                ?: resolveHumanReadableName(mToName)
        }

    override val fromRaw: String
        get() = mFrom

    override val toRaw: String
        get() = mTo
}

open class TVParametersImpl(storage: Storage, override val callSid: String = "", override val customParameters: Map<String, String> = emptyMap()) : TVParameters {
    private val TAG = javaClass.name

    val mStorage: Storage

    init {
        this.mStorage = storage
    }

    override val fromRaw: String
        get() = ""

    override val from: String
        get() = customParameters[PARAM_CALLER_NAME]
            ?: customParameters[PARAM_CALLER_ID]?.let { resolveHumanReadableName(it) }
            ?: mStorage.defaultCaller

    override val toRaw: String
        get() = ""

    override val to: String
        get() = customParameters[PARAM_RECIPIENT_NAME]
            ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
            ?: mStorage.defaultCaller

    override fun hasCustomParameters(): Boolean {
        return customParameters.isNotEmpty()
    }

    override fun getExtra(key: String, defaultValue: String?): String? {
        return customParameters[key]
    }

    override fun hasExtra(key: String): Boolean {
        return customParameters.containsKey(key)
    }

    /**
     * Resolve the human readable name for the given name.
     * @param name the name to resolve, e.g. id, client name, caller name, etc
     * @return the human readable name
     */
    override fun resolveHumanReadableName(name: String): String {
        val id = name.replace("client:", "")
        return mStorage.getRegisteredClient(id) ?: mStorage.defaultCaller
    }
}
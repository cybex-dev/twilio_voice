package com.twilio.twilio_voice.call

import com.twilio.twilio_voice.storage.Storage
import com.twilio.voice.CallInvite

class TVCallParametersImpl(callInvite: CallInvite, storage: Storage) : TVCallParameters {
    private val TAG = javaClass.name

    private val mCallInvite: CallInvite
    private val mStorage: Storage

    private val PARAM_CALLER_ID: String = "_TWI_CALLER_ID"
    private val PARAM_CALLER_NAME: String = "_TWI_CALLER_NAME"
    private val PARAM_RECIPIENT_ID: String = "_TWI_RECIPIENT_ID"
    private val PARAM_RECIPIENT_NAME: String = "_TWI_RECIPIENT_NAME"

    private val PARAM_CALLER_URL: String = "_TWI_CALLER_URL"
    private val PARAM_RECIPIENT_URL: String = "_TWI_RECIPIENT_URL"
    private val PARAM_SUBJECT: String = "_TWI_SUBJECT"

    init {
        mCallInvite = callInvite
        this.mStorage = storage
    }

    override val from: String
        get() = customParameters[PARAM_CALLER_NAME]
            ?: customParameters[PARAM_CALLER_ID]?.let { resolveHumanReadableName(it) }
            ?: mCallInvite.from?.let { resolveHumanReadableName(it) }
            ?: mStorage.defaultCaller

    override val to: String
        get() = customParameters[PARAM_RECIPIENT_NAME]
            ?: customParameters[PARAM_RECIPIENT_ID]?.let { resolveHumanReadableName(it) }
            ?: mCallInvite.from?.let { resolveHumanReadableName(it) }
            ?: mStorage.defaultCaller

    override val customParameters: Map<String, String>
        get() = mCallInvite.customParameters

    override val callSid: String
        get() = mCallInvite.callSid

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
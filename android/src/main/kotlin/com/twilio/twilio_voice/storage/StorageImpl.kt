package com.twilio.twilio_voice.storage

import android.content.Context
import android.content.SharedPreferences
import com.twilio.twilio_voice.constants.Constants

class StorageImpl(ctx: Context) : Storage {

    val TAG: String = javaClass.name

    private val kDefaultCaller: String = "defaultCaller"
    private val kRejectOnNoPermissions: String = "rejectOnNoPermissions"
    private val kShowNotifications: String = "show-notifications"

    override var defaultCaller
        get() = prefs.getString(kDefaultCaller, null)
            ?: Constants.DEFAULT_UNKNOWN_CALLER
        set(value) {
            val editor = prefs.edit()
            editor.putString(kDefaultCaller, value)
            editor.apply()
        }

    override var rejectOnNoPermissions
        get() = prefs.getBoolean(kRejectOnNoPermissions, false)
        set(value) {
            val editor = prefs.edit()
            editor.putBoolean(kRejectOnNoPermissions, value)
            editor.apply()
        }

    private val kStoragePreferences: String = "com.twilio.twilio_voicePreferences"
    private val prefs: SharedPreferences

    init {
        prefs = getSharedPreferences(ctx, kStoragePreferences)
    }

    override fun getSharedPreferences(
        ctx: Context,
        name: String,
        openMode: Int
    ): SharedPreferences {
        return ctx.getSharedPreferences(name, openMode)
    }

    override var showNotifications: Boolean
        get() = prefs.getBoolean(kShowNotifications, true)
        set(value) {
            prefs.edit().let {
                it.putBoolean(kShowNotifications, value)
                it.apply()
            }
        }

    override fun hasDefaultCaller(): Boolean {
        return prefs.contains(kDefaultCaller)
    }

    override fun hasRegisteredClient(id: String): Boolean {
        assert(id.isNotEmpty()) { "hasRegisteredClient: id cannot be empty" }
        return prefs.contains(id)
    }

    /**
     * Get a registered client [id] from storage, returns null if not found.
     * @param id: the id of the registered client
     * @return the name of the registered client, null if not found
     */
    override fun getRegisteredClient(id: String): String? {
        if (id.isEmpty()) {
            return null
        }
        return prefs.getString(id, null)
    }

    override fun addRegisteredClient(id: String, name: String): Boolean {
        // TODO: remove this assert, it's not needed now.
//        assert(id.isNotEmpty()) { "addRegisteredClient: id cannot be empty" }
        prefs.let {
            val editor = it.edit()
            return editor.putString(id, name).commit()
        }
    }

    override fun removeRegisteredClient(id: String): Boolean {
        // TODO: remove this assert, it's not needed now.
//        assert(id.isNotEmpty()) { "removeRegisteredClient: id cannot be empty" }
        prefs.let {
            val editor = it.edit()
            return editor.remove(id).commit()
        }
    }

    override fun clearStorage(): Boolean {
        val editor = prefs.edit()
        editor.clear()
        return editor.commit()
    }
}
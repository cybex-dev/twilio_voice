package com.twilio.twilio_voice.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.appcompat.app.AppCompatActivity
import com.twilio.twilio_voice.constants.Constants

interface Storage {

    fun getSharedPreferences(
        ctx: Context,
        name: String,
        openMode: Int = AppCompatActivity.MODE_PRIVATE
    ): SharedPreferences

    /**
     * Get/set the show notifications preference.
     * Default is true.
     */
    var showNotifications: Boolean

    /**
     * True if default caller name been set
     * @return the default caller name
     */
    fun hasDefaultCaller(): Boolean

    /**
     * Get the default caller name, if not set, return the default [Constants.DEFAULT_UNKNOWN_CALLER]
     * @return the default caller name
     */
    var defaultCaller: String

    /**
     * If true, reject incoming calls if the app does not have the required permissions. Default is false.
     * @return true to reject on no permissions, false to ignore.
     */
    var rejectOnNoPermissions: Boolean

    /**
     * Get the default caller name, if not set, return the default [Constants.DEFAULT_UNKNOWN_CALLER]
     * @param id: the id of the registered client
     * @return the default caller name
     */
    fun hasRegisteredClient(id: String): Boolean

    /**
     * Get a registered client [id] from storage, returns null if not found.
     * @param id: the id of the registered client
     * @return the name of the registered client, null if not found
     */
    fun getRegisteredClient(id: String): String?

    /**
     * Add a registered client to the storage, if the [id] already exists, the [name] is updated, else a new entry is created. Returns true if added.
     * @param id: the id of the registered client
     * @param name: the name of the registered client
     * @return true if added
     */
    fun addRegisteredClient(id: String, name: String): Boolean

    /**
     * Remove a registered client [id] from storage, returns true if removed.
     * @param id: the id of the registered client
     */
    fun removeRegisteredClient(id: String): Boolean

    /**
     * Clear the storage of all entries, including registered users and default caller name.
     */
    fun clearStorage(): Boolean
}
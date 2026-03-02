package com.twilio.twilio_voice.types

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import java.util.Locale
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.content.PermissionChecker
import com.twilio.twilio_voice.service.TVConnectionService
import com.twilio.twilio_voice.types.ContextExtension.appName
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneNumbersPermission
import com.twilio.twilio_voice.types.ContextExtension.hasReadPhoneStatePermission
import com.twilio.twilio_voice.R
import com.twilio.twilio_voice.call.TVParameters

object TelecomManagerExtension {

    /**
     *  Register a phone account with the system telecom manager
     *  @param ctx application context
     *  @param phoneAccountHandle The handle for the phone account
     *  @param label The label for the phone account
     *  @param shortDescription The short description for the phone account
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.registerPhoneAccount(ctx: Context, phoneAccountHandle: PhoneAccountHandle) {
        if (hasCallCapableAccount(ctx, phoneAccountHandle.componentName.className)) {
            // phone account already registered
            Log.d("TelecomManager", "registerPhoneAccount: phone account already re-registering.")
//            return
        }

        buildAndRegisterPhoneAccount(ctx, phoneAccountHandle)
    }

    /**
     * Ensure the PhoneAccount is registered with the system.
     * Does NOT require READ_PHONE_STATE — safe to call from ConnectionService
     * before addNewIncomingCall(). Uses getPhoneAccount() (no permission needed
     * for self-managed accounts) to check, and registers if missing or stale.
     */
    fun TelecomManager.ensurePhoneAccountRegistered(ctx: Context): PhoneAccountHandle {
        val phoneAccountHandle = getPhoneAccountHandle(ctx)
        try {
            val existing = getPhoneAccount(phoneAccountHandle)
            if (existing != null && existing.capabilities == PhoneAccount.CAPABILITY_SELF_MANAGED) {
                Log.d("TelecomManager", "ensurePhoneAccountRegistered: Already registered with SELF_MANAGED")
                return phoneAccountHandle
            }
            if (existing != null) {
                Log.w("TelecomManager", "ensurePhoneAccountRegistered: Stale capabilities=${existing.capabilities}, re-registering")
            } else {
                Log.w("TelecomManager", "ensurePhoneAccountRegistered: Not registered, registering now")
            }
        } catch (e: Exception) {
            Log.w("TelecomManager", "ensurePhoneAccountRegistered: Cannot check account (${e.message}), registering anyway")
        }
        buildAndRegisterPhoneAccount(ctx, phoneAccountHandle)
        return phoneAccountHandle
    }

    /**
     * Build and register the PhoneAccount. Shared by registerPhoneAccount() and
     * ensurePhoneAccountRegistered().
     */
    private fun TelecomManager.buildAndRegisterPhoneAccount(ctx: Context, phoneAccountHandle: PhoneAccountHandle) {
        val label = ctx.getString(R.string.phone_account_name).apply {
            this.ifEmpty {
                ctx.appName
            }
        }
        val description = ctx.getString(R.string.phone_account_desc).apply {
            this.ifEmpty {
                "Provides calling services for $label"
            }
        }

        // register phone account as SELF_MANAGED
        // Self-managed ConnectionService handles its own UI (IncomingCallActivity)
        // but gets system Bluetooth button→answer/reject integration,
        // audio routing, and car Bluetooth support for free.
        val phoneAccount = PhoneAccount.builder(phoneAccountHandle, label)
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setShortDescription(description)
            .setIcon(Icon.createWithResource(ctx, ctx.applicationInfo.icon))
            .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
            .build()

        registerPhoneAccount(phoneAccount)
        Log.d("TelecomManager", "buildAndRegisterPhoneAccount: Registered successfully")
    }

    fun TelecomManager.openPhoneAccountSettings(activity: Activity) {
        if (launchTelecomEnablePreference(activity)) {
            return
        }

        val packageManager = activity.packageManager
        val candidateIntents = buildList {
            addAll(manufacturerSpecificIntents(activity))
            add(Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                add(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
            }
            add(Intent(Settings.ACTION_SETTINGS))
        }

        candidateIntents.forEach { baseIntent ->
            val intent = Intent(baseIntent).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                if (component == null) {
                    resolveSystemComponent(packageManager, baseIntent)?.let { component = it }
                }
            }

            if (canHandleIntent(packageManager, intent)) {
                try {
                    activity.startActivity(intent)
                    return
                } catch (error: Exception) {
                    Log.w("TelecomManager", "openPhoneAccountSettings: failed to launch ${intent.action}: ${error.message}")
                }
            }
        }

        Log.e("TelecomManager", "openPhoneAccountSettings: Unable to find compatible settings activity.")
    }

    private fun TelecomManager.launchTelecomEnablePreference(activity: Activity): Boolean {
        val manufacturer = Build.MANUFACTURER?.lowercase(Locale.US).orEmpty()
        val brand = Build.BRAND?.lowercase(Locale.US).orEmpty()
        val targets = setOf("samsung", "oneplus", "realme", "oppo")

        if (manufacturer !in targets && brand !in targets) {
            return false
        }

        val baseIntent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
            component = ComponentName(
                "com.android.server.telecom",
                "com.android.server.telecom.settings.EnableAccountPreferenceActivity"
            )
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        return try {
            activity.startActivity(baseIntent)
            true
        } catch (error: Exception) {
            Log.w(
                "TelecomManager",
                "launchTelecomEnablePreference: primary component failed: ${error.message}"
            )

            tryLegacyTelecomIntent(activity)
        }
    }

    private fun tryLegacyTelecomIntent(activity: Activity): Boolean {
        return try {
            val fallbackIntent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            activity.startActivity(fallbackIntent)
            true
        } catch (fallbackError: Exception) {
            Log.w(
                "TelecomManager",
                "tryLegacyTelecomIntent: fallback intent failed: ${fallbackError.message}"
            )
            false
        }
    }

    private fun manufacturerSpecificIntents(activity: Activity): List<Intent> {
        val manufacturer = Build.MANUFACTURER?.lowercase(Locale.US).orEmpty()
        val brand = Build.BRAND?.lowercase(Locale.US).orEmpty()

        if (manufacturer !in setOf("oppo", "realme") && brand !in setOf("oppo", "realme")) {
            return emptyList()
        }

        val components = listOf(
            ComponentName("com.android.settings", "com.android.settings.Settings\$DefaultAppSettingsActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppManagerActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppListActivity"),
            ComponentName("com.coloros.phonemanager", "com.coloros.phonemanager.defaultapp.DefaultAppEntryActivity")
        )

        val explicitIntents = components.map { componentName ->
            Intent(Intent.ACTION_VIEW).apply { component = componentName }
        }

        val packagedDefaultAppsIntent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS).apply {
            `package` = "com.android.settings"
        }

        return explicitIntents + packagedDefaultAppsIntent
    }

    private fun resolveSystemComponent(packageManager: PackageManager, intent: Intent): ComponentName? {
        val matches = packageManager.queryIntentActivities(intent, 0)
        val preferred = matches.firstOrNull { resolveInfo ->
            resolveInfo.activityInfo?.applicationInfo?.flags?.and(ApplicationInfo.FLAG_SYSTEM) != 0
        } ?: matches.firstOrNull()

        return preferred?.activityInfo?.let { activityInfo ->
            ComponentName(activityInfo.packageName, activityInfo.name)
        }
    }

    private fun canHandleIntent(packageManager: PackageManager, intent: Intent): Boolean {
        return intent.resolveActivity(packageManager) != null
    }


    /**
     * Check if a phone account has been registered with the system telecom manager
     * For SELF_MANAGED accounts, uses getPhoneAccount() since they don't appear
     * in callCapablePhoneAccounts.
     * @param ctx application context
     * @param name The name of the componentName Class (i.e. ConnectionService)
     */
    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.hasCallCapableAccount(ctx: Context, name: String): Boolean {
        if (!canReadPhoneState(ctx)) return false
        // Self-managed accounts don't appear in callCapablePhoneAccounts.
        // Check via getPhoneAccount() instead.
        val handle = getPhoneAccountHandle(ctx)
        return try {
            getPhoneAccount(handle) != null
        } catch (e: Exception) {
            Log.w("TelecomManagerExtension", "hasCallCapableAccount: ${e.message}")
            false
        }
    }

    /**
     * Check if phone account is registered without requiring READ_PHONE_STATE
     * For SELF_MANAGED accounts, uses getPhoneAccount() since they don't appear
     * in callCapablePhoneAccounts.
     * @param ctx application context
     * @param componentClassName The name of the componentName Class (i.e. ConnectionService)
     * @return Boolean True if the account is registered, or true if we can't check (assumes registered)
     */
    fun TelecomManager.hasCallCapableAccountSafe(ctx: Context, componentClassName: String): Boolean {
        return try {
            val handle = getPhoneAccountHandle(ctx)
            getPhoneAccount(handle) != null
        } catch (e: SecurityException) {
            Log.w("TelecomManagerExtension", "Cannot check call capable accounts: ${e.message}")
            true
        } catch (e: Exception) {
            Log.w("TelecomManagerExtension", "Cannot check call capable accounts: ${e.message}")
            true
        }
    }

    /**
     * Check if currently on a call without requiring READ_PHONE_STATE
     * Falls back to checking TVConnectionService for active calls
     * @param ctx application context
     * @return Boolean True if on a call
     */
    fun TelecomManager.isOnCallSafe(ctx: Context): Boolean {
        return try {
            // For self-managed ConnectionService, we track our own calls directly
            // since isInSelfManagedCall is not a public TelecomManager API.
            // Fallback to isInCall for legacy compatibility on older APIs.
            if (ctx.hasReadPhoneStatePermission() && Build.VERSION.SDK_INT <= Build.VERSION_CODES.O) {
                isInCall
            } else {
                TVConnectionService.hasActiveCalls()
            }
        } catch (e: SecurityException) {
            Log.w("TelecomManagerExtension", "Cannot check if on call: ${e.message}")
            TVConnectionService.hasActiveCalls()
        }
    }

    /**
     * Get the [PhoneAccountHandle] for the app
     * @param ctx application context
     * @return PhoneAccountHandle The phone account handle for the app
     */
    fun TelecomManager.getPhoneAccountHandle(ctx: Context): PhoneAccountHandle {
        val appName = ctx.appName
        val componentName = ComponentName(ctx, TVConnectionService::class.java)

        Log.d(TVConnectionService.TAG, "getPhoneAccountHandle: Get PhoneAccountHandle with name: $appName, componentName: $componentName")
        return PhoneAccountHandle(componentName, appName)
    }

    /**
     * Check if the app has the READ_PHONE_STATE permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_STATE permission
     */
    fun TelecomManager.canReadPhoneState(ctx: Context): Boolean {
        return ctx.hasReadPhoneStatePermission()
    }

    /**
     * Check if the app has the READ_PHONE_NUMBERS permission
     * @param ctx application context
     * @return Boolean True if the app has the READ_PHONE_NUMBERS permission
     */
    fun TelecomManager.canReadPhoneNumbers(ctx: Context): Boolean {
        return ctx.hasReadPhoneNumbersPermission()
    }

    @RequiresPermission(value = "android.permission.READ_PHONE_STATE")
    fun TelecomManager.isOnCall(ctx: Context): Boolean {
        if (!canReadPhoneState(ctx)) return false
        // For self-managed ConnectionService, we track our own calls directly
        return if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.O) isInCall
               else TVConnectionService.hasActiveCalls()
    }
}
package com.twilio.twilio_voice.types

enum class TVMethodChannels(val method: String) {
    TOKENS("tokens"),
    SEND_DIGITS("sendDigits"),
    HANGUP("hangUp"),
    TOGGLE_SPEAKER("toggleSpeaker"),
    IS_ON_SPEAKER("isOnSpeaker"),
    TOGGLE_BLUETOOTH("toggleBluetooth"),
    IS_BLUETOOTH_ON("isBluetoothOn"),
    TOGGLE_MUTE("toggleMute"),
    IS_MUTED("isMuted"),
    CALL_SID("call-sid"),
    IS_ON_CALL("isOnCall"),
    HOLD_CALL("holdCall"),
    IS_HOLDING("isHolding"),
    ANSWER("answer"),
    UNREGISTER("unregister"),
    MAKE_CALL("makeCall"),
    REGISTER_CLIENT("registerClient"),
    UNREGISTER_CLIENT("unregisterClient"),
    DEFAULT_CALLER("defaultCaller"),
    HAS_REGISTERED_PHONE_ACCOUNT("hasRegisteredPhoneAccount"), //aka has call capable account
    REGISTER_PHONE_ACCOUNT("registerPhoneAccount"),
    OPEN_PHONE_ACCOUNT_SETTINGS("openPhoneAccountSettings"),
    HAS_MIC_PERMISSION("hasMicPermission"),
    REQUEST_MIC_PERMISSION("requestMicPermission"),
    @Deprecated("Deprecated in favour of native call screen handling these permissions")
    HAS_BLUETOOTH_PERMISSION("hasBluetoothPermission"),
    @Deprecated("Deprecated in favour of native call screen handling these permissions")
    REQUEST_BLUETOOTH_PERMISSION("requestBluetoothPermission"),
    HAS_READ_PHONE_STATE_PERMISSION("hasReadPhoneStatePermission"),
    REQUEST_READ_PHONE_STATE_PERMISSION("requestReadPhoneStatePermission"),
    HAS_CALL_PHONE_PERMISSION("hasCallPhonePermission"),
    REQUEST_CALL_PHONE_PERMISSION("requestCallPhonePermission"),
    @Deprecated("No longer required due to Custom UI replaced with native call screen")
    BACKGROUND_CALL_UI("backgroundCallUi"),
    SHOW_NOTIFICATIONS("showNotifications"),
    HAS_READ_PHONE_NUMBERS_PERMISSION("hasReadPhoneNumbersPermission"),
    @Deprecated("No longer required due to Custom UI replaced with native call screen")
    REQUIRES_BACKGROUND_PERMISSIONS("requiresBackgroundPermissions"),
    REQUEST_READ_PHONE_NUMBERS_PERMISSION("requestReadPhoneNumbersPermission"),
    @Deprecated("No longer required due to Custom UI replaced with native call screen")
    REQUEST_BACKGROUND_PERMISSIONS("requestBackgroundPermissions"),
    IS_PHONE_ACCOUNT_ENABLED("isPhoneAccountEnabled"),
    REJECT_CALL_ON_NO_PERMISSIONS("rejectCallOnNoPermissions"),
    IS_REJECTING_CALL_ON_NO_PERMISSIONS("isRejectingCallOnNoPermissions"),
    UPDATE_CALLKIT_ICON("updateCallKitIcon");

    companion object {
        private val map = TVMethodChannels.values().associateBy(TVMethodChannels::method)
        fun fromValue(method: String) = map[method]
    }
}
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
    CALL_SID("callSid"),
    IS_ON_CALL("isOnCall"),
    HOLD_CALL("holdCall"),
    IS_HOLDING("isHolding"),
    ANSWER("answer"),
    UNREGISTER("unregister"),
    MAKE_CALL("makeCall"),
    REGISTER_CLIENT("registerClient"),
    UNREGISTER_CLIENT("unregisterClient"),
    DEFAULT_CALLER("defaultCaller"),
    HAS_REGISTERED_PHONE_ACCOUNT("hasRegisteredPhoneAccount"),
    REGISTER_PHONE_ACCOUNT("registerPhoneAccount"),
    OPEN_PHONE_ACCOUNT_SETTINGS("openPhoneAccountSettings"),
    HAS_MIC_PERMISSION("hasMicPermission"),
    REQUEST_MIC_PERMISSION("requestMicPermission"),
    HAS_BLUETOOTH_PERMISSION("hasBluetoothPermission"),
    REQUEST_BLUETOOTH_PERMISSION("requestBluetoothPermission"),
    HAS_READ_PHONE_STATE_PERMISSION("hasReadPhoneStatePermission"),
    REQUEST_READ_PHONE_STATE_PERMISSION("requestReadPhoneStatePermission"),
    HAS_CALL_PHONE_PERMISSION("hasCallPhonePermission"),
    REQUEST_CALL_PHONE_PERMISSION("requestCallPhonePermission"),
    BACKGROUND_CALL_UI("backgroundCallUi"),
    SHOW_NOTIFICATIONS("showNotifications"),
    REQUIRES_BACKGROUND_PERMISSIONS("requiresBackgroundPermissions"),
    REQUEST_BACKGROUND_PERMISSIONS("requestBackgroundPermissions"),
    UPDATE_CALLKIT_ICON("updateCallKitIcon");

    companion object {
        private val map = TVMethodChannels.values().associateBy(TVMethodChannels::method)
        fun fromValue(method: String) = map[method]
    }
}
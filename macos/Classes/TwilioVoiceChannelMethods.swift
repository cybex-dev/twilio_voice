import Foundation

public enum TwilioVoiceChannelMethods: String {
    case tokens = "tokens"
    case makeCall = "makeCall"
    case toggleMute = "toggleMute"
    case toggleSpeaker = "toggleSpeaker"
    case callSid = "call-sid"
    case isOnCall = "isOnCall"
    case sendDigits = "sendDigits"
    case holdCall = "holdCall"
    case answer = "answer"
    case unregister = "unregister"
    case hangUp = "hangUp"
    case registerClient = "registerClient"
    case unregisterClient = "unregisterClient"
    case defaultCaller = "defaultCaller"
    case hasMicPermission = "hasMicPermission"
    case requestMicPermission = "requestMicPermission"
    case requiresBackgroundPermissions = "requiresBackgroundPermissions"
    case requestBackgroundPermissions = "requestBackgroundPermissions"
    case showNotifications = "show-notifications"
}

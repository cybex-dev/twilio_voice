import Foundation

public enum TVCallEvent: String {
    case accept = "accept"
    case cancel = "cancel"
//    case connected = "connected"
    case disconnect = "disconnect"
    case error = "error"
//    case messageReceived = "messageReceived"
//    case messageSent = "messageSent"
//    case mute = "mute"
    case reconnected = "reconnected"
    case reconnecting = "reconnecting"
    case reject = "reject"
    case status = "status"
//    case sample = "sample"
//    case warning = "warning"
//    case warningCleared = "warningCleared"
}

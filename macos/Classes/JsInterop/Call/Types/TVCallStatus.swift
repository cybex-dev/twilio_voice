import Foundation

public enum TVCallStatus: String {
    case closed = "closed"
    case connecting = "connecting"
    case open = "open"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case reconnected = "reconnected"
    case ringing = "ringing"
    case pending = "pending"
    case rejected = "rejected"
    case answer = "answer"
}

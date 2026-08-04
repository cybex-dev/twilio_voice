import Foundation

/// The [TVCall] delegate. Describes the events that can be triggered by a [TVCall]
/// Status descriptions for [TVCall.status()] are [Events](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callstatus)
public enum TVCallStatus: String {
    // The media session associated with the call has been disconnected.
    case closed = "closed"

    // The call was accepted by or initiated by the local Device instance and the media session is being set up.
    case connecting = "connecting"

    // The media session associated with the call has been established.
    case open = "open"
    // (unofficial) Same as 'open'
    case connected = "connected"

    // The ICE connection was disconnected and a reconnection has been triggered.
    case reconnecting = "reconnecting"

    // (unofficial) The ICE connection has been reestablished.
    case reconnected = "reconnected"

    // The callee has been notified of the call but has not yet responded.
    case ringing = "ringing"

    // The call is incoming and hasn't yet been accepted.
    case pending = "pending"

    // (unofficial) The call was canceled before being accepted.
    case rejected = "rejected"

    // (unofficial) The call was canceled after being accepted.
    case answer = "answer"
}

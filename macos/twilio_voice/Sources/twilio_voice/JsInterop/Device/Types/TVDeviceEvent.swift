import Foundation

public enum TVDeviceEvent: String {
    case error = "error"
    case incoming = "incoming"
    case registered = "registered"
    case registering = "registering"
    case tokenWillExpire = "tokenWillExpire"
    case unregistered = "unregistered"
}

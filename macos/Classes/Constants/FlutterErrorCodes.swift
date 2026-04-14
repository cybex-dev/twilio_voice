import Foundation

/// Codes associated with FlutterError(code:, ...)
class FlutterErrorCodes {
    /// Associated with unexpected, malformed or missing arguments
    static let MALFORMED_ARGUMENTS: String = "arguments";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let INTERNAL_STATE_ERROR: String = "internal-state-error";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let UNAVAILABLE_ERROR: String = "unavailable";

    /// Twilio Voice JS SDK did not become ready in time (macOS WKWebView).
    static let SDK_LOAD_TIMEOUT: String = "sdk-load-timeout";

    /// Twilio Voice JS SDK failed to load or initialize (macOS WKWebView).
    static let SDK_LOAD_FAILED: String = "sdk-load-failed";
}

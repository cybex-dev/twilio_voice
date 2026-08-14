import Foundation

/// Codes associated with FlutterError(code:, ...)
class FlutterErrorCodes {
    /// Associated with unexpected, malformed or missing arguments
    static let MALFORMED_ARGUMENTS: String = "arguments";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let INTERNAL_STATE_ERROR: String = "internal-state-error";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let UNAVAILABLE_ERROR: String = "unavailable";
}

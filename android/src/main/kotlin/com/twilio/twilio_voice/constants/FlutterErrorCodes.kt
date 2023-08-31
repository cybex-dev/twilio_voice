package com.twilio.twilio_voice.constants

/// <summary>
/// FlutterErrorCodes contains the error codes that are returned by the plugin. e.g. result.error(FlutterErrorCodes.X, ...);
/// </summary>
object FlutterErrorCodes {

    /// <summary>
    /// Associated with unexpected, malformed or missing arguments
    /// </summary>
    const val MALFORMED_ARGUMENTS: String = "MALFORMED_ARGUMENTS"

    /// <summary>
    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    /// </summary>
    const val INTERNAL_STATE_ERROR = "INTERNAL_STATE_ERROR"

    /// <summary>
    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    /// </summary>
    const val UNAVAILABLE_ERROR = "UNAVAILABLE_ERROR"
}
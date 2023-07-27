import Foundation

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
public class DeviceInitOptions: JSONArgumentSerializer {

    /// The Voice JavaScript SDK exposes a loglevel-based logger to allow for runtime logging configuration.
    ///
    /// You can set this property to a number which corresponds to the log levels shown below.
    /// 0 = "trace"
    /// 1 = "debug"
    /// 2 = "info"
    /// 3 = "warn"
    /// 4 = "error"
    /// 5 = "silent"
    ///
    /// Default is 1 "trace"
    let logLevel: Int

    /// An array of codec names ordered from most-preferred to least-preferred.
    /// Opus and PCMU are the two codecs currently supported by Twilio Voice JS SDK. Opus can provide better quality for lower bandwidth, particularly noticeable in poor network conditions.
    /// Default: ["pcmu", "opus"]
    let codecPreferences: [String]

    /// Setting this property to true will enable a dialog prompt with the text "A call is currently in progress. Leaving or reloading the page will end the call." when closing a page which has an active connection.
    /// Setting the property to a string will create a custom message prompt with that string. If custom text is not supported by the browser, Twilio will display the browser's default dialog.
    let closeProtection: Bool

    /// Not implemented yet
    /// Whether the Device instance should raise the 'incoming' event when a new call invite is received while already on an active call.
    /// set to false by default
    let allowIncomingWhileBusy: Bool

    init(logLevel: Int = 1, codecPreferences: [String] = ["opus", "pcmu"], closeProtection: Bool = false, allowIncomingWhileBusy: Bool = true) {
        self.logLevel = logLevel
        self.codecPreferences = codecPreferences
        self.closeProtection = closeProtection
        self.allowIncomingWhileBusy = allowIncomingWhileBusy
    }

    public override func toDictionary() -> [String: Any] {
        return [Constants.PARAM_LOG_LEVEL: logLevel, Constants.PARAM_CODEC_PREFERENCES: codecPreferences, Constants.PARAM_CLOSE_PROTECTION: closeProtection, Constants.PARAM_ALLOW_INCOMING_WHILE_BUSY: allowIncomingWhileBusy]
    }
}

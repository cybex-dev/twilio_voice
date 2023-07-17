import Foundation
import WebKit

/// Pre-major version update including breaking changes.
/// Flutter/Dart version update required.
public enum TwilioDeviceEvents: String {
    case error = "error"
    case incoming = "incoming"
    case registered = "registered"
    case registering = "registering"
    case tokenWillExpire = "tokenWillExpire"
    case unregistered = "unregistered"
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
public class DeviceInitOptions {

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
}

/// Device Connect options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connectoptions
public class DeviceConnectOptions {
    let params: Dictionary<String, Any>

    init(params: Dictionary<String, Any>) {
        self.params = params
    }
}

protocol ITwilioDevice: JSObject {

    init(_ token: String, options: DeviceInitOptions, webView: TVWebView)

    /// Returns array of active calls
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicecalls
    //    func calls() -> [Any]

    /// Returns true if the token has been updated
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceupdatetokentoken
    func updateToken(token: String, completionHandler: OnCompletionErrorHandler?) -> Void

    /// Get current device token
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicetoken
    func token(completionHandler: @escaping OnCompletionHandler<String>) -> Void

    /// Returns true if the device is on an active call
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceisbusy
    func isBusy(completionHandler: OnCompletionHandler<Bool>) -> Void

    /// Connect to Twilio Voice Client
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connect
    func connect(_ options: DeviceConnectOptions?, completionHandler: OnCompletionHandler<TwilioCall>?) -> Void

    /// Register device token with Twilio Voice Client
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceregister
    func register(completionHandler: OnCompletionErrorHandler?) -> Void

    /// Unregister device token with Twilio Voice Client
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceunregister
    func unregister(completionHandler: OnCompletionErrorHandler?) -> Void

    /// Attach event listener for Twilio Device object. See [TwilioDeviceEvents]
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
    /// possibly use js interop here
    func on<T>(ofType: T.Type, event: TwilioDeviceEvents, completionHandler: @escaping OnCompletionHandler<T>) -> Void
    func on(event: TwilioDeviceEvents, completionHandler: @escaping OnCompletionErrorHandler) -> Void

    /// Detach event listener for Twilio Device object. See [TwilioDeviceEvents]
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
    /// possibly use js interop here
    func off(event: String, completionHandler: OnCompletionErrorHandler?) -> Void
}

//public class TwilioDevice: ITwilioDevice, JSObject {
public class TwilioDevice: JSObject {
    var jsObjectName: String

    var webView: TVWebView

    required init(_ token: String, options: DeviceInitOptions = DeviceInitOptions(logLevel: 1, codecPreferences: ["pcmu", "opus"], closeProtection: false, allowIncomingWhileBusy: false), webView: TVWebView) {
        self.webView = webView
        jsObjectName = "_device"

        let JS = """
                   const \(jsObjectName) = new Twilio.Device('\(token)', {
                       codecPreferences: \(options.codecPreferences),
                       closeProtection: \(options.closeProtection),
                       allowIncomingWhileBusy: \(options.allowIncomingWhileBusy)
                   });
                 """
        webView.evaluateJavaScript(ofType: Void.self, javascript: JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func token(completionHandler: @escaping OnCompletionHandler<String>) -> Void{
        let JS = """
                        \(jsObjectName).token;
                 """
        webView.evaluateJavaScript(ofType: String.self, javascript: JS) { (result, error) in
            if let error = error {
                completionHandler("", error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    func isBusy(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        let JS = """
                   \(jsObjectName).isBusy;
                 """
        webView.evaluateJavaScript(ofType: Bool.self, javascript: JS) { (result, error) in
            if let error = error {
                completionHandler(false, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    func updateToken(token: String, completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        let JS = """
                        \(jsObjectName).updateToken('\(token)');
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                completionHandler?(error.localizedDescription)
            }
        }

    }

    func connect(_ options: DeviceConnectOptions?, completionHandler: OnCompletionHandler<TwilioCall>? = nil) -> Void {
        let JS = """
                        \(jsObjectName).connect(\(options?.params ?? [:]));
                 """
        webView.evaluateJavaScript(ofType: TwilioCall.self, javascript: JS) { (result, error) in
            if let error = error {
                print(error)
                completionHandler?(nil, error)
            }

            if let result = result {
                completionHandler?(result, nil)
            }
        }
    }

    func register(completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        let JS = """
                        var _ = \(jsObjectName).register();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                completionHandler?(error.localizedDescription)
            }
        }
    }

    func unregister(completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        let JS = """
                        \(jsObjectName).unregister();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                completionHandler?(error.localizedDescription)
            }
        }
    }

    func on<T>(ofType: T.Type = T.self, event: TwilioDeviceEvents, completionHandler: @escaping (T?, String?) -> Void) {
        // if event is not defined, then define it.
        let JS = """
                        if (typeof _\(jsObjectName)_\(event.rawValue) === 'undefined') {
                            const _\(jsObjectName)_\(event) = function(data) {
                                window.webkit.messageHandlers.\(event).postMessage(data);
                            };
                            \(jsObjectName).on('\(event)', _\(jsObjectName)_\(event));
                        }
                 """
        webView.evaluateJavaScript(ofType: T.self, javascript: JS) { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    func on(event: TwilioDeviceEvents, completionHandler: @escaping (String?) -> Void) {
        // if event is not defined, then define it.
        let JS = """
                        if (typeof _\(jsObjectName)_\(event.rawValue) === 'undefined') {
                            const _\(jsObjectName)_\(event) = function(data) {
                                window.webkit.messageHandlers.\(event).postMessage(data);
                            };
                            \(jsObjectName).on('\(event)', _\(jsObjectName)_\(event));
                        }
                 """
        webView.evaluateJavaScript(JS) { (_, error) in
            if let error = error {
                completionHandler(error.localizedDescription)
            }
        }
    }

    func off(event: TwilioDeviceEvents, completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        // if event is not defined, ignore else remove it.
        let JS = """
                        if (typeof _\(jsObjectName)_\(event) !== 'undefined') {
                            \(jsObjectName).off('\(event)', _\(jsObjectName)_\(event));
                        }
                 """

        // result is ignored
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                completionHandler?(error.localizedDescription)
            }
        }
    }
}

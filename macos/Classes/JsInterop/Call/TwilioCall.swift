import Foundation

/// Pre-major version update including breaking changes.
public enum TwilioCallEvents: String {
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

public enum CallStatus: String {
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

public enum CallDirection: String {
    case incoming = "INCOMING"
    case outgoing = "OUTGOING"
}

public class CallParams {
    let to: String?
    let from: String?
    let callSid: String?
    let customParameters: [String: Any]

    init(parameters: [String: Any]) {
        self.customParameters = parameters
        self.to = parameters["To"] as? String
        self.from = parameters["From"] as? String
        self.callSid = parameters["CallSid"] as? String
    }

    init(parameters: [String: Any], customParameters: [String: Any]) {
        self.customParameters = customParameters.merging(parameters) { (first, _) in
            first
        }
        self.to = parameters["To"] as? String
        self.from = parameters["From"] as? String
        self.callSid = parameters["CallSid"] as? String
    }
}

protocol ITwilioCall {

    /// Mute active Twilio Call
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callismuted
    func isMuted(completionHandler: OnCompletionHandler<Bool>) -> Void

    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callmuteshouldmute
    func mute(shouldMute: Bool) -> Void

    /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callparameters
    func parameters(completionHandler: OnCompletionHandler<[String: Any]>) -> Void

    /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callcustomparameters
    func customParameters(completionHandler: OnCompletionHandler<[String: Any]>) -> Void

    /// Get the direction of call, either "INCOMING" or "OUTGOING"
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldirection
    func direction(completionHandler: OnCompletionHandler<CallDirection>) -> Void

    /// Get current call status, see [TwilioCallStatus]
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callstatus
    func status(completionHandler: OnCompletionHandler<CallStatus>) -> CallStatus

    /// Disconnect active Twilio Call.
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldisconnect
    func disconnect() -> Void

    /// Reject incoming call Twilio Call.
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callreject
    func reject() -> Void

    /// Ignore placed call, does not alert dialing party.
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callignore
    func ignore() -> Void

    /// Attach event listener for Twilio Call object. See [TwilioCallEvents]
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events
    /// possibly use js interop here
    func on<T>(ofType: T.Type, event: TwilioDeviceEvents, completionHandler: @escaping OnCompletionHandler<T>) -> Void
    func on(event: TwilioDeviceEvents, completionHandler: @escaping OnCompletionErrorHandler) -> Void

    /// Deattach event listener for Twilio Call object. See [TwilioCallEvents]
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events
    /// possibly use js interop here
    func off(event: String, completionHandler: OnCompletionErrorHandler?) -> Void

    /// Send digits to active Twilio Call
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callsenddigitsdigits
    func sendDigits(digits: String) -> Void

    /// Accepts a call
    /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callacceptacceptoptions
    func accept() -> Void

    func resolveParams() -> CallParams
}

//public class TwilioCall: ITwilioCall, JSObject {
public class TwilioCall: JSObject {
    func isMuted(completionHandler: @escaping (Bool?, String?) -> Void) {
        let JS = """
                        \(jsObjectName).isMuted();
                 """
        webView.evaluateJavaScript(ofType: Bool.self, javascript: JS) { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            }

            completionHandler(result, nil)
        }
    }

    func mute(shouldMute: Bool) {
        let JS = """
                        \(jsObjectName).mute(\(shouldMute));
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func parameters(completionHandler: @escaping ([String: Any]?, String?) -> Void) -> Void {
        let JS = """
                        \(jsObjectName).parameters;
                 """
        webView.evaluateJavaScript(ofType: [String: Any].self, javascript: JS) { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    func customParameters(completionHandler: @escaping ([String: Any]?, String?) -> Void) {
        let JS = """
                        \(jsObjectName).customParameters;
                 """
        webView.evaluateJavaScript(ofType: [String: Any].self, javascript: JS) { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }

            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    func direction(completionHandler: @escaping (CallDirection?, String?) -> Void) {
        let JS = """
                        \(jsObjectName).direction();
                 """
        webView.evaluateJavaScript(ofType: CallDirection.self, javascript: JS) { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            }

            if let result = result {
                completionHandler(result, nil)
            }
        }
    }


    var jsObjectName: String

    var webView: TVWebView

    init(webView: TVWebView) {
        self.jsObjectName = "_call"
        self.webView = webView
    }

    func status(completionHandler: @escaping OnCompletionHandler<CallStatus>) -> Void {
        let JS = """
                        \(jsObjectName).status();
                 """
        webView.evaluateJavaScript(ofType: String.self, javascript: JS) { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }

            if let result = result {
                completionHandler(CallStatus(rawValue: result), nil)
            }
        }
    }

    func disconnect() {
        let JS = """
                        \(jsObjectName).disconnect();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func reject() {
        let JS = """
                        \(jsObjectName).reject();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func ignore() {
        let JS = """
                        \(jsObjectName).ignore();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func on<T>(ofType: T.Type = T.self, event: TwilioCallEvents, completionHandler: @escaping (T?, String?) -> Void) {
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

    func on(event: TwilioCallEvents, completionHandler: @escaping (String?) -> Void) {
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

    func off(event: TwilioCallEvents, completionHandler: OnCompletionErrorHandler? = nil) -> Void {
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

    func sendDigits(digits: String) {
        let JS = """
                        \(jsObjectName).sendDigits('\(digits)');
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func accept() {
        let JS = """
                        \(jsObjectName).accept();
                 """
        webView.evaluateJavaScript(JS) { (result, error) in
            if let error = error {
                print(error)
            }
        }
    }

    func resolveParams() -> CallParams {
        var params: [String:Any] = [:]
        self.parameters() { dictionary, s in
            if let dictionary = dictionary {
                dictionary.forEach({ (key, value) in
                    params[key] = value
                })
            }
        }
        self.customParameters() { dictionary, s in
            if let dictionary = dictionary {
                dictionary.forEach({ (key, value) in
                    params[key] = value
                })
            }
        }
        return CallParams(parameters: params);
    }
}

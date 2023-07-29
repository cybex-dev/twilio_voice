import Foundation
import WebKit

/// Object describing a Twilio Call. Implement protocol [TVCallDelegate](x-source-tag://TVCallDelegate) to receive call events.
public class TVCall: JSObject, TVCallDelegate, JSMessageHandlerDelegate {

    weak var callDelegate: TVCallDelegate?

    required init(overrideJSObjectName: String = "_call", webView: TVWebView) {
        super.init(jsObjectName: overrideJSObjectName, webView: webView, initialize: true)
        super.jsObjectDelegate = self
    }

    /// Mute active [TVCall]
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.isMuted](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callismuted)
    public func isMuted(completionHandler: @escaping OnCompletionHandler<Bool>) {
        call(method: "isMuted") { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(result as? Bool, nil)
            }
        }
    }

    /// Get muted [TVCall] state
    /// - Parameters:
    ///   - shouldMute: should mute
    ///   - completionHandler: completion handler
    /// - SeeAlso Twilio [Call.isMuted](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callmuteshouldmute)
    func mute(_ shouldMute: Bool, completionHandler: OnCompletionErrorHandler? = nil) {
        call(method: "mute", withArgs: [shouldMute]) { _, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Get call parameters from [TVCall], sent via outgoing call or received from [TVCall] (via TwiML app)
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.parameters](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callparameters)
    func parameters(completionHandler: @escaping OnCompletionHandler<[String: Any]>) -> Void {
        property(ofType: Dictionary<String, Any>.self, name: "parameters") { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    /// Get [customParameters] from [TVCall], send via outgoing call or received from incoming call (via TwiML app)
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.customParameters](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callcustomparameters)
    func customParameters(completionHandler: @escaping OnCompletionHandler<[String: Any]>) {
        property(ofType: Dictionary<String, Any>.self, name: "customParameters") { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    /// Get the direction of active [TVCall]
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.direction](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldirection)
    func direction(completionHandler: @escaping OnCompletionHandler<CallDirection>) {
        property(ofType: String.self, name: "direction") { (result, error) in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(CallDirection.init(rawValue: result), nil)
            }
        }
    }

    /// Get current call status, see [TVCallStatus]
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.status](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callstatus)
    func status(completionHandler: @escaping OnCompletionHandler<TVCallStatus>) -> Void {
        call(method: "status") { result, error in
            if let error = error {
                print(error)
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(TVCallStatus(rawValue: result as! String), nil)
            }
        }
    }

    /// End/Disconnect active [TVCall].
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.disconnect](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldisconnect)
    func disconnect(completionHandler: OnCompletionErrorHandler? = nil) {
        call(method: "disconnect") { result, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Reject incoming call Twilio Call.
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.reject](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callreject)
    func reject(completionHandler: OnCompletionErrorHandler? = nil) {
        call(method: "reject") { result, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Ignore incoming [TVCall].
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.ignore](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callignore)
    func ignore(completionHandler: OnCompletionErrorHandler? = nil) {
        call(method: "ignore") { result, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Attach event listeners to JS [TVCall] events. Apply when [TVCall] is placed, or incoming call received via [TVDeviceDelegate.onIncoming]
    /// - SeeAlso Twilio [Call.Events](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events)
    func attachEventListeners() {
        print("Attaching event listeners to [TVCall]")
        let events: [TVCallEvent] = [.accept, .cancel, .disconnect, .error, .reconnected, .reconnected, .reject, .status]
        events.map {
                    $0.rawValue
                }
                .forEach { event in
                    addEventListener(event) { (result, error) in
                        if let error = error {
                            NSLog("[TVCall:\(event)] Error adding event listener: \(error)")
                        }
                    }
                }
    }

    /// Detach event listeners from JS [TVCall] events. Apply when [TVCall] is ended, or incoming call rejected/ignored or destroyed
    ///
    /// NOTE(cybex-dev): JS .off() function not defined, so we cannot detach event listeners [Error] TypeError: _call.off is not a function. (In '_call.off('reconnected', _on_event__call_reconnected)', '_call.off' is undefined)
    ///
    /// - SeeAlso Twilio [Call.Events](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events)
    func detachEventListeners() {
        print("Detaching event listeners from [TVCall]")
        detachMessageHandler()
        return;
        let events: [TVCallEvent] = [.accept, .cancel, .disconnect, .error, .reconnected, .reconnected, .reject, .status]
        events.map {
                    $0.rawValue
                }
                .forEach { event in
                    removeEventListener(event)
                }
    }

    /// Send digits to active [TVCall].
    /// - Parameters:
    ///   - digits: <#digits description#>
    ///   - completionHandler: <#completionHandler description#>
    /// - SeeAlso Twilio [Call.sendDigits](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callsenddigits)
    func sendDigits(digits: String, completionHandler: @escaping OnCompletionErrorHandler) {
        call(method: "sendDigits", withArgs: [digits]) { result, error in
            if let error = error {
                print(error)
                completionHandler(error)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Accepts an incoming [TVCall]
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso Twilio [Call.accept](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callacceptacceptoptions)
    func accept(completionHandler: @escaping OnCompletionErrorHandler) {
        call(method: "accept") { result, error in
            if let error = error {
                print(error)
                completionHandler(error)
            } else {
                completionHandler(nil)
            }
        }
    }


    /// <#Description#>
    /// - Parameter completionHandler: <#completionHandler description#>
    /// - Returns: <#description#>
    func resolveParams(completionHandler: @escaping OnCompletionHandler<TVCallParams>) -> Void {
        var params: [String: Any] = [:]
        parameters { dictionary, error in
            if let dictionary = dictionary {
                dictionary.forEach({ (key, value) in
                    params[key] = value
                })
            }

            self.customParameters { dictionary, s in
                if let dictionary = dictionary {
                    dictionary.forEach({ (key, value) in
                        params[key] = value
                    })
                }

                completionHandler(TVCallParams(parameters: params), nil)
            }
        }
    }

    // MARK: - TVCallDelegate

    public func onCallAccept(_ call: TVCall) {
        callDelegate?.onCallAccept(call)
    }

    public func onCallCancel(_ call: TVCall) {
        callDelegate?.onCallCancel(call)
    }

    public func onCallDisconnect(_ call: TVCall) {
        callDelegate?.onCallDisconnect(call)
    }

    public func onCallError(_ error: TVError) {
        callDelegate?.onCallError(error)
    }

    public func onCallReconnecting(_ error: TVError) {
        callDelegate?.onCallReconnecting(error)
    }

    public func onCallReconnected() {
        callDelegate?.onCallReconnected()
    }

    public func onCallReject() {
        callDelegate?.onCallReject()
    }

    public func onCallStatus(_ status: TVCallStatus) {
        callDelegate?.onCallStatus(status)
    }

    // MARK: - JSMessageHandlerDelegate

    func onJSMessageReceived(_ jsObject: JSObject, message: TVScriptMessage) {
//        print("TVCall onJSMessageReceived: [\(message.name)] \(String(describing: message.body))")

        if let event = TVCallEvent(rawValue: message.type) {
            switch event {
            case .cancel:
                onCallCancel(self)
                break
            case .accept:
                onCallAccept(self)
                break
            case .disconnect:
                onCallDisconnect(self)
                break
            case .error:
                if let error = message.args[0] as? [String: Any] {
                    let error = TVError(dict: error)
                    onCallError(error)
                }
                break
            case .reconnecting:
                if let error = message.args[0] as? [String: Any] {
                    let error = TVError(dict: error)
                    onCallError(error)
                }
                break
            case .reconnected:
                onCallReconnected()
                break
            case .reject:
                onCallReject()
                break
            case .status:
                if (message.args.count > 0) {
                    let status = message.args[0] as? String
                    if let statusString = status, let status = TVCallStatus(rawValue: statusString) {
                        onCallStatus(status)
                    }
                }
                break
            default:
                print("Unhandled event: \(event)")
            }
        }
    }

    // MARK: - Disposable

    public override func dispose() {
        detachEventListeners()
        callDelegate = nil
        jsObjectDelegate = nil
        // clean up JS object
        super.dispose()
    }

    deinit {
        print("TVCall deinit")
    }
}

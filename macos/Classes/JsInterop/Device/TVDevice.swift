import Foundation
import WebKit

public class EventMessageHandler: NSObject, WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[WebView:\(message.name)] \(message.body)");
    }
}

/// Object describing a Twilio Device. Integrate [TVDeviceDelegate](x-source-tag://TVDeviceDelegate) to receive device events.
public class TVDevice: JSObject, TVDeviceDelegate, JSMessageHandlerDelegate {

    weak var deviceDelegate: TVDeviceDelegate?

    required init(_ token: String, options: DeviceInitOptions, webView: TVWebView, createdCompletionHandler: @escaping OnCompletionHandler<TVDevice>) {
        super.init(jsObjectName: "_device", webView: webView)
        super.jsObjectDelegate = self
        JSObject.assign(webView: webView, objectName: "Twilio.Device", withArgs: [token, options], assignTo: jsObjectName, mutatable: true) { result, error in
            if let error = error {
                print(String(describing: error))
            }
            createdCompletionHandler(self, nil)
        }
    }

    /// Get the current [TVDevice](x-source-tag://TVDevice) access token.
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.token](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicetoken)
    func token(completionHandler: @escaping OnCompletionHandler<String>) -> Void {
        property(ofType: String.self, name: "token") { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            }
            if let result = result {
                completionHandler(result, nil)
            }
        }
    }

    /// Returns the current status of an [TVCall](x-source-tag://TVCall) on the [TVDevice](x-source-tag://TVDevice).
    /// Defaults to false.
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.status](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceisbusy)
    func isBusy(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        property(ofType: Bool.self, name: "isBusy") { (result, error) in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(result ?? false, nil)
            }
        }
    }

    /// Update the token used to connect to Twilio Application. This should be used with [TVDeviceDelegate.onTokenWillExpire](x-source-tag://TVDeviceDelegate.onTokenWillExpire).
    /// - Parameters:
    ///   - token: new token
    ///   - completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.updateToken](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceupdatetokentoken)
    func updateToken(_ token: String, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        assert(token.isNotEmpty(), "Access token cannot be empty")

        call(method: "updateToken", withArgs: [token]) { result, error in
            if let error = error {
                print("Error TVDevice:updateToken : \(String(describing: error))")
            }
            completionHandler(result as? Bool ?? false)
        }
    }

    /// Connect this device to Twilio Application to engage in a call
    /// - Parameters
    ///   - options: connect options, includes params [Constants.PARAM_TO, Constants.PARAM_FROM, Constants.PARAM_CUSTOM_PARAMETERS]
    ///   - assignTo: variable name to assign the [TVCall](x-source-tag://TVCall) object to
    ///   - completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.connect](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceconnectconnectoptions)
    func connect(_ options: TVDeviceConnectOptions, assignTo: String = "_call", completionHandler: OnCompletionHandler<TVCall>? = nil) -> Void {
        callPromise(method: "connect", withArgs: [options], assignOnSuccess: assignTo) { error in
            if let error = error {
                print(error)
                completionHandler?(nil, error)
            } else {
                let call = TVCall(overrideJSObjectName: assignTo, webView: self.webView)
                completionHandler?(call, nil)
            }
        }
    }

    /// Register the device with Twilio, it will receive incoming calls if successfully registered
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.register](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceregister)
    func register(completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        call(method: "register", assignTo: "_") { result, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Unregister the device from Twilio, it will not receive further incoming calls
    /// - Parameter completionHandler: completion handler
    /// - SeeAlso: Twilio [Device.unregister](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceunregister)
    func unregister(completionHandler: OnCompletionErrorHandler? = nil) -> Void {
        call(method: "unregister") { result, error in
            if let error = error {
                print(error)
                completionHandler?(error)
            } else {
                completionHandler?(nil)
            }
        }
    }

    /// Attach event listeners to JS [TVDevice] when it is created
    func attachEventListeners() {
        let events: [TVDeviceEvent] = [.registered, .error, .tokenWillExpire, .unregistered]
        events.map {
                    $0.rawValue
                }
                .forEach { event in
                    addEventListener(event) { any, error in
                        if (error != nil) {
                            NSLog("Error adding event listener: \(event)")
                        }
                    }
                }

        // params are given by args (Array), reassign call to _call
        let _INCOMING_JS = """
                           if(!!args && args.length > 0) {
                               log("Incoming call: " + args[0]);
                               _call = args[0];
                           }
                           """
        let event = TVDeviceEvent.incoming.rawValue
        addEventListener(event, onTriggeredAction: _INCOMING_JS) { any, error in
            if (error != nil) {
                NSLog("Error adding event listener: \(event)")
            }
        }
    }

    /// Detach event listeners from JS [TVDevice] when it is destroyed
    func detachEventListeners() {
        let events: [TVDeviceEvent] = [.registered, .error, .incoming, .tokenWillExpire, .unregistered]
        events.map {
                    $0.rawValue
                }
                .forEach { event in
                    removeEventListener(event)
                }
    }

    // MARK: - TVDeviceDelegate

    func onDeviceIncoming(_ call: TVCall) {
        deviceDelegate?.onDeviceIncoming(call)
    }

    func onDeviceRegistered() {
        deviceDelegate?.onDeviceRegistered()
    }

    func onDeviceRegistering() {
        deviceDelegate?.onDeviceRegistering()
    }

    func onDeviceUnregistered() {
        deviceDelegate?.onDeviceUnregistered()
    }

    func onDeviceTokenWillExpire(_ device: TVDevice) {
        deviceDelegate?.onDeviceTokenWillExpire(device)
    }

    func onDeviceError(_ error: TVError) {
        deviceDelegate?.onDeviceError(error)
    }

    // MARK: - JSMessageHandlerDelegate

    func onJSMessageReceived(_ jsObject: JSObject, message: TVScriptMessage) {
//        print("[TVDevice:onJSMessageReceived]: [\(message.name)] \(String(describing: message.body))")

        if let event = TVDeviceEvent(rawValue: message.type) {
            switch event {
            case .error:
                if let error = message.args[0] as? [String: Any] {
                    let error = TVError(dict: error)
                    onDeviceError(error)
                }
                break
            case .incoming:
                let call = TVCall(webView: webView)
                onDeviceIncoming(call)
                break
            case .tokenWillExpire:
                onDeviceTokenWillExpire(self)
                break
            case .registered:
                onDeviceRegistered()
                break
            case .unregistered:
                onDeviceUnregistered()
                break
            case .registering:
                onDeviceRegistering()
                break
            default:
                print("Unhandled event: \(event)")
            }
        }
    }

    // MARK: - Disposable

    public override func dispose() {
        unregister()
        detachEventListeners()
        deviceDelegate = nil
        jsObjectDelegate = nil
        // clean up JS object
        delete(jsObjectName)
    }

    deinit {
        print("TVDevice deinit")
        dispose()
    }
}

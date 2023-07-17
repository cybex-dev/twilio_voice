import Cocoa
import FlutterMacOS
import WebKit
import SwiftUI
import UserNotifications


// Each Twilio.Device / Call gets a seperate evaluate javascript funcrtion
// For properties, use a simple evaluate javscript function
// Every listen event requires a seperate evaluate JS function, with an event handller evaluateing each of those using sperate names for each function i.e. messagehanler.on(eventname).postMessage()
// mediaDevices.getusermedia issues

// Future Work
// - CallKit (https://developer.apple.com/documentation/callkit) - support in macOS 13.0+

public enum NotificationAction: String {
    case incoming = "incoming"
    case accept = "accept"
    case reject = "reject"
}

public class TwilioVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var _result: FlutterResult?
    private var eventSink: FlutterEventSink?

    let kRegistrationTTLInDays = 365

    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String: String]!

    var identity = "alice"
    var to: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get {
            UserDefaults.standard.data(forKey: kCachedDeviceToken)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken)
        }
    }
    var jsCall: TwilioCall?
    var jsDevice: TwilioDevice?
    var webView: TVWebView
    private var twilioCall: TwilioCall?
    private var twilioDevice: TwilioDevice?

    private var test: Bool = false

    static var appName: String {
        get {
            (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }

    /// Given a file name, loads and returns the content of that file
    /// - Parameter file: file name
    /// - Parameter ofType: file extension
    /// - Returns: content of file
    private func loadFileContent(file: String, ofType: String) -> String? {
        let bundle: Bundle? = Bundle(for: TwilioVoicePlugin.self)
        if let bundle, let filePath = bundle.path(forResource: file, ofType: ofType) {
            let content: String? = try? String(contentsOfFile: filePath)
            return content;
        } else {
            return nil;
        }
    }

    /// Given a javascript file, attempts to load file content then return a WKUserScript object
    /// - Parameter file: javascript file name
    /// - Returns: WKUserScript object, nil otherwise
    private func loadUserScript(file: String) -> WKUserScript? {
        guard let content = loadFileContent(file: file, ofType: "js") else {
            print("Failed to load user script file \(file)")
            return nil
        }

        return WKUserScript(source: content, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    private func loadTwilio(webView: TVWebView) -> Void {
        if let twilioLib = loadFileContent(file: "Resources/twilio.min", ofType: "js") {
            webView.evaluateJavaScript(twilioLib) { (any: Any?, error: Error?) in
                if let error = error {
                    print("Error loading twilio library: \(error)")
                }
            }
        }
    }

    public override init() {
        self.webView = TVWebView(messageHandler: "twilio_voice")
        super.init()
        self.clients = UserDefaults.standard.object(forKey: kClientList) as? [String: String] ?? [:]

        let app = NSApplication.shared
        guard let window = app.windows.first else {
            fatalError("no mainWindow to grab")
        }
        guard let viewController = window.contentViewController as? FlutterViewController else {
            fatalError("rootViewController is not type FlutterViewController")
        }
        let registrar = viewController.registrar(forPlugin: "twilio_voice")
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(self)
        loadTwilio(webView: webView)
    }


    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
    }


    public static func register(with registrar: FlutterPluginRegistrar) {

        let instance = TwilioVoicePlugin()
        let methodChannel = FlutterMethodChannel(name: "twilio_voice/messages", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        //        registrar.addApplicationDelegate(instance)
    }

    private func attachDeviceListeners(_ device: TwilioDevice) {
        device.on(ofType: TwilioCall.self, event: .incoming, completionHandler: onDeviceIncoming)
        device.on(event: .registered, completionHandler: onDeviceRegistered)
        device.on(event: .unregistered, completionHandler: onDeviceUnregistered)
        device.on(event: .error, completionHandler: onDeviceError)
        device.on(event: .tokenWillExpire, completionHandler: onTokenWillExpire)
    }

    private func detachDeviceListeners(_ device: TwilioDevice) {
        device.off(event: .incoming)
        device.off(event: .registered)
        device.off(event: .unregistered)
        device.off(event: .error)
        device.off(event: .tokenWillExpire)
    }

    private func onDeviceIncoming(call: TwilioCall?, error: String?) {
        if let error = error {
            print("Error: \(error)")
        }
        let _ = requestMicAccess()
        if let call = call {
            let params = call.resolveParams()
            let from = params.from ?? ""
            let to = params.to ?? ""
            logEvents(prefix: "", descriptions: ["Incoming", from, to, "Incoming", formatCustomParams(params: params.customParameters)])
            logEvents(prefix: "", descriptions: ["Ringing", from, to, "Incoming", formatCustomParams(params: params.customParameters)])
            showIncomingCallNotification(call: call)
        }
    }

    private func onDeviceRegistered(error: String?) {
        if let error = error {
            print("Error: \(error)")
        }
        print("Device registered for callInvites")
    }

    private func onDeviceUnregistered(error: String?) {
        if let error = error {
            print("Error: \(error)")
        }
        print("Device unregistered, won't receive no more callInvites")
    }

    private func onDeviceError(error: String?) {
        logEvent(description: error ?? "Unknown Error")
    }

    private func onTokenWillExpire(error: String?) {
        if let device = jsDevice {
            device.token() { s, s2 in
                if let token = s {
                    self.logEvents(prefix: "", descriptions: ["DEVICETOKEN", token])
                }
            }
        }
    }

    private func onCallAccept(call: TwilioCall?, error: String?) {
        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let call = call else {
            return
        }
        let params = call.resolveParams();
        let from = params.from ?? ""
        let to = params.to ?? ""
        let extra = self.formatCustomParams(params: params.customParameters)
        self.logEvents(prefix: "", descriptions: [
            "Answer",
            from,
            to,
            extra,
        ])
    }

    private func onCallDisconnect(call: TwilioCall?, error: String?) {
        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let call = call else {
            return
        }

        call.status() { status, error in
            if let error = error {
                print("Error: \(error)")
                return
            }

            self.attachCallEventListeners(call)
            if(status == .closed && self.jsCall != nil) {
                self.logEvent(prefix: "", description: "Call Ended")
            }
            self.jsCall = nil
        }
    }

    private func onCallCancel(error: String?) {
        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let call = self.jsCall else {
            return
        }
        let params = call.resolveParams()

        detachCallEventListeners(call)
        self.jsCall = nil

        if let callSid = params.callSid {
            cancelNotification(callSid)

            let from = params.from ?? ""
            let to = params.to ?? ""
            showMissedCallNotification(from: from, to: to)
        }

        logEvent(prefix: "", description: "Missed Call")
        logEvent(prefix: "", description: "Call Ended")
    }

    private func onCallError(twilioError: String?) {
        logEvent(description: "Call Error: \(twilioError ?? "Unknown Error")")
    }

    private func onCallReconnecting(twilioError: String?) {
        logEvent(description: "Reconnecting")
    }

    private func onCallReconnected(twilioError: String?) {
        logEvent(description: "Reconnected")
    }

    private func onCallStatusChanged(call: TwilioCall?, error: String?) {
        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let call = call else {
            return
        }

        call.status() { status, error in
            if let error = error {
                print("Error: \(error)")
                return
            }

            if(status == .connected) {
                self.onCallConnected(call)
            } else if (status == .ringing) {
                self.onCallRinging()
            }
        }
    }

    private func onCallConnected(_ call: TwilioCall) {
        jsCall = call

        let params = call.resolveParams()
        let from = params.from ?? ""
        let to = params.to ?? ""
        call.direction() { direction, error in
            if let error = error {
                print("Error: \(error)")
                return
            }
            guard let direction = direction else {
                return
            }

            self.logEvents(prefix: "", descriptions: [
                "Connected",
                from,
                to,
                direction.rawValue.capitalized
            ])
        }
    }

    private func onCallRinging() {
        guard let call = self.jsCall else {
            return
        }
        let params = call.resolveParams()
        let from = params.from ?? ""
        let to = params.to ?? ""
        call.direction() { direction, error in
            if let error = error {
                print("Error: \(error)")
                return
            }

            guard let direction = direction?.rawValue.capitalized else {
                return
            }

            self.logEvents(prefix: "", descriptions: [
                "Ringing",
                from,
                to,
                direction,
            ])
        }
    }

    private func onCallReject(error: String?) {
        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let call = self.jsCall else {
            return
        }
        detachCallEventListeners(call)
        self.jsCall = nil

        logEvent(prefix: "", description: "Call Rejected")
    }

    private func cancelNotification(_ callSid: String) {
        // Cancel the notification
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [callSid])
    }

    private func showIncomingCallNotification(call: TwilioCall) {
        if requestBackgroundPermissions() {
            let params = call.resolveParams()
            let title = resolveCallerName(callParams: params)
            let body = "Incoming Call"

            showNotification(title: title, subtitle: body, action: .incoming, params: params.customParameters)
        }
    }

    private func resolveCallerName(callParams: CallParams) -> String {
        let from = callParams.from
        if (from ?? "").starts(with: "client:") {
            let clientName = from?.replacingOccurrences(of: "client:", with: "")
            return clients[clientName ?? defaultCaller] ?? clientName ?? defaultCaller
        } else {
            return from ?? defaultCaller
        }
    }

    /// Flutter  method call handler for 'tokens' action
    /// - Parameter arguments: arguments
    private func handleTokens(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let token = arguments["accessToken"] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No 'accessToken' argument provided or invalid type", details: nil)
            _result!(ferror)
            return
        }

        logEvent(description: "Attempting to register with twilio")

        let codecs: [String] = ["opus", "pcmu"]
        let options: DeviceInitOptions = DeviceInitOptions(codecPreferences: codecs, closeProtection: true)
        twilioDevice = TwilioDevice(token, options: options, webView: webView)

        if let device = twilioDevice {
//            attachDeviceListeners(device);
            device.register() {  error in
                if let error = error {
                    print(String(describing: error))
                }
            }
        }

        _result!(true)
    }


    /// Flutter method call handler for 'makeCall' action
    /// - Parameter arguments: arguments
    private func handleMakeCall(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let to = arguments[Constants.PARAM_TO] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No '\(Constants.PARAM_TO)' argument provided or invalid type", details: nil)
            _result!(ferror)
            return
        }
        guard let from = arguments[Constants.PARAM_FROM] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No '\(Constants.PARAM_FROM)' argument provided or invalid type", details: nil)
            _result!(ferror)
            return
        }
        // TODO? - set outgoing call parameter?
//        if let accessToken = arguments["accessToken"] as? String{
//            print("Found 'accessToken' parameter in 'makeCall' arguments, updating device")
//            updateToken(accessToken)
//        }
        // TODO? - stop active call
        var params: [String: Any] = [:]
        arguments.forEach({ (key, value) in
            if key != Constants.PARAM_TO && key != Constants.PARAM_FROM {
                params[key] = value
            }
        })

        makeCall(to: to, from: identity, extraOptions: params) { call, error in
            if let error = error {
                print("Error: \(error)")
                self._result!(false)
            }

            if let call = call {
                self.jsCall = call
                self._result!(true)
                self.attachCallEventListeners(call)
            }
        }
    }

    private func attachCallEventListeners(_ call: TwilioCall) {
        call.on(ofType: TwilioCall.self, event: .accept, completionHandler: onCallAccept)
        call.on(ofType: TwilioCall.self, event: .disconnect, completionHandler: onCallDisconnect)
        call.on(event: .cancel, completionHandler: onCallCancel)
        call.on(event: .reject, completionHandler: onCallReject)
        call.on(event: .error, completionHandler: onCallError)
        call.on(event: .reconnecting, completionHandler: onCallReconnecting)
        call.on(event: .reconnected, completionHandler: onCallReconnected)
        call.on(event: .status, completionHandler: onCallStatusChanged)
    }

    private func detachCallEventListeners(_ call: TwilioCall) {
        call.off(event: .accept)
        call.off(event: .disconnect)
        call.off(event: .cancel)
        call.off(event: .reject)
        call.off(event: .error)
        call.off(event: .reconnecting)
        call.off(event: .reconnected)
        call.off(event: .status)
    }

    /// Flutter method call handler for 'toggleMute' action
    /// - Parameter arguments: arguments
    private func handleToggleMute(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let muted = arguments["muted"] as? Bool else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No 'muted' argument provided", details: nil)
            _result!(ferror)
            return
        }
        // TODO - JS device interface
        guard let activeCall = self.jsCall else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No call to be muted", details: nil)
            _result!(ferror)
            return
        }
        activeCall.mute(shouldMute: muted)
        logEvent(description: muted ? "Mute" : "Unmute")
        _result!(true)
    }

    /// Flutter method call handler for 'toggleSpeaker' action
    /// - Parameter arguments: arguments
    private func handleToggleSpeaker(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No 'speakerIsOn' argument provided", details: nil)
            _result!(ferror)
            return
        }
        // TODO - JS device interface
        guard let activeCall = self.jsCall else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No call to toggle speaker", details: nil)
            _result!(ferror)
            return
        }
        //        activeCall.isSpeakerOn = speakerIsOn
        //        toggleAudioRoute(toSpeaker: speakerIsOn)
        logEvent(description: speakerIsOn ? "Speaker On" : "Speaker Off")
        _result!(true)
    }

    /// Flutter method call handler for 'call-sid' action
    /// - Parameter arguments: arguments
    private func handleCallSid(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS call sid
        guard let call = self.jsCall else {
            _result!(nil)
            return
        }
        let params = call.resolveParams()
        _result!(params.callSid)
    }

    /// Flutter method call handler for 'isOnCall' action
    /// - Parameter arguments: arguments
    private func handleIsOnCall(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let device = jsDevice else {
            _result!(false)
            return
        }
        device.isBusy() { (result, error) in
            if let error = error {
                print("Error checking if device is busy: \(error)")
                self._result!(false)
            } else {
                self._result!(result)
            }
        }
    }

    /// Flutter method call handler for 'sendDigits' action
    /// - Parameter arguments: arguments
    private func handleSendDigits(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let digits = arguments["digits"] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No 'digits' argument provided", details: nil)
            _result!(ferror)
            return
        }
        // TODO - JS call interface
        guard let activeCall = self.jsCall else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No active call", details: nil)
            _result!(ferror)
            return
        }
        activeCall.sendDigits(digits: digits);
        _result!(true)
    }

    /// Flutter method call handler for 'holdCall' action
    /// - Parameter arguments: arguments
    private func handleHoldCall(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let shouldHold = arguments["shouldHold"] as? Bool else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "No 'shouldHold' argument provided", details: nil)
            _result!(ferror)
            return
        }
        // TODO - JS call interface
        guard let activeCall = self.jsCall else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No active call to hold", details: nil)
            _result!(ferror)
            return
        }
        logEvent(description: shouldHold ? "Hold" : "Unhold")
        _result!(true)
    }

    /// Flutter method call handler for 'answer' action
    /// - Parameter arguments: arguments
    private func handleAnswer(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS call interface
        guard let call = self.jsCall else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No incoming call to answer", details: nil)
            _result!(ferror)
            return
        }
        call.accept()
        _result!(true)
    }

    /// Flutter method call handler for 'unregister' action
    /// - Parameter arguments: arguments
    private func handleUnregister(arguments: Dictionary<String, AnyObject>) -> Void {
        let success: Bool = unregisterToken()
        _result!(success)
    }

    /// Flutter method call handler for 'hangUp' action
    /// - Parameter arguments: arguments
    private func handleHangUp(arguments: Dictionary<String, AnyObject>) -> Void {
        if self.jsCall == nil {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.INTERNAL_STATE_ERROR, message: "No active call to hang up on", details: nil)
            _result!(ferror)
            return
        }
        _result!(hangUp())
    }

    /// Flutter method call handler for 'registerClient' action
    /// - Parameter arguments: arguments
    private func handleRegisterClient(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let clientId = arguments["id"] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'id' missing or incorrect type", details: nil)
            _result!(ferror)
            return
        }
        guard let clientName = arguments["name"] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'name' missing or incorrect type", details: nil)
            _result!(ferror)
            return
        }

        updateClient(id: clientId, name: clientName)
        _result!(true)
    }

    /// Flutter method call handler for 'unregisterClient' action
    /// - Parameter arguments: arguments
    private func handleUnregisterClient(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS Device interop
        guard let clientId = arguments["id"] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'id' missing or incorrect type", details: nil)
            _result!(ferror)
            return
        }

        _result!(removeClient(id: clientId))
    }

    /// Flutter method call handler for 'defaultCaller' action
    /// - Parameter arguments: arguments
    private func handleDefaultCaller(arguments: Dictionary<String, AnyObject>) -> Void {
        guard let caller = arguments[Constants.kDefaultCaller] as? String else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'defaultCaller' missing or incorrect type", details: nil)
            _result!(ferror)
            return
        }
        defaultCaller = caller
        updateClient(id: Constants.kDefaultCaller, name: caller)
        _result!(true)
    }

    /// Flutter method call handler for 'hasMicPermission' action
    /// - Parameter arguments: arguments
    private func handleHasMicPermission(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS Device interop
        // TODO - check mic permission
        let permission: Bool = hasMicAccess();
        _result!(permission)
    }

    /// Flutter method call handler for 'requestMicPermission' action
    /// - Parameter arguments: arguments
    private func handleRequestMicPermission(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS Device interop

        // TODO - request permission
        let permission: Bool = requestMicAccess();
        _result!(permission)
    }

    /// Flutter method call handler for 'show-notifications' action
    /// - Parameter arguments: arguments
    private func handleShowNotifications(arguments: Dictionary<String, AnyObject>) -> Void {
        // TODO - JS Device interop
        // TODO - show notifications
        guard let show = arguments["show"] as? Bool else {
            let ferror: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'show' missing or incorrect type", details: nil)
            _result!(ferror)
            return
        }
        let prefsShow = UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true
        if show != prefsShow {
            UserDefaults.standard.setValue(show, forKey: "show-notifications")
        }
        _result!(true)
    }

    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        _result = result
        guard let arguments = flutterCall.arguments as? Dictionary<String, AnyObject> else {
            let error: FlutterError = FlutterError(code: ErrorCodes.MALFORMED_ARGUMENTS, message: "Arguments must be a Dictionary<String, AnyObject>", details: nil);
            result(error)
            return;
        }

        guard let method = TwilioVoiceChannelMethods.init(rawValue: flutterCall.method) else {
            result(FlutterMethodNotImplemented)
            return
        }

        switch method {
        case .tokens:
            handleTokens(arguments: arguments)
            break
        case .makeCall:
            handleMakeCall(arguments: arguments)
            break
        case .toggleMute:
            handleToggleMute(arguments: arguments);
            break
        case .toggleSpeaker:
            handleToggleSpeaker(arguments: arguments);
            break
        case .callSid:
            handleCallSid(arguments: arguments);
            break
        case .isOnCall:
            handleIsOnCall(arguments: arguments);
            break
        case .sendDigits:
            handleSendDigits(arguments: arguments);
            break
        case .holdCall:
            handleHoldCall(arguments: arguments);
            break
        case .answer:
            handleAnswer(arguments: arguments);
            break
        case .unregister:
            handleUnregister(arguments: arguments);
            break
        case .hangUp:
            handleHangUp(arguments: arguments);
            break
        case .registerClient:
            handleRegisterClient(arguments: arguments);
            break
        case .unregisterClient:
            handleUnregisterClient(arguments: arguments);
            break
        case .defaultCaller:
            handleDefaultCaller(arguments: arguments);
            break
        case .hasMicPermission:
            handleHasMicPermission(arguments: arguments);
            break
        case .requestMicPermission:
            handleRequestMicPermission(arguments: arguments);
            break
        case .showNotifications:
            handleShowNotifications(arguments: arguments);
            break
        default:
            result(false)
        }
    }


    /// Hang up active call
    /// - Returns: True if successful
    private func hangUp() -> Bool {
        guard let activeCall = self.jsCall else {
            return false;
        }
        activeCall.disconnect()
        return true
    }


    /// Place a call to 'to'
    /// - Parameter to: client Id, identifier or number
    /// - Parameter from: client calling
    /// - Parameter extraOptions: additional custom call parameters
    /// - Parameter completionHandler: completion handler
    /// - Returns: True if call was placed successfully
    private func makeCall(to: String, from: String, extraOptions: [String: Any]?, completionHandler: @escaping (_ call: TwilioCall?, _ error: String?) -> Void) -> Void {
        if self.jsCall != nil {
            print("Active call ongoing, hanging up")
            if (!hangUp()) {
                print("Failed to end active call")
                return;
            }
            self.jsCall = nil
        }

        guard let device = self.jsDevice else {
            print("No active JS device")
            return;
        }

        logEvent(description: "Making new call")

        var params : [String: Any] = [Constants.PARAM_TO: to, Constants.PARAM_FROM: self.identity]
        if let extra = extraOptions {
            extra.forEach({ (key, value) in
                params[key] = value
            })
        }
        let options: DeviceConnectOptions = DeviceConnectOptions(params: params)
        device.connect(options) { call, s in
            if let error = s {
                print("Error making call: \(error)")
                completionHandler(nil, error)
                return
            }
            if let call = call {
                print("Call successfully placed")
                self.jsCall = call
                completionHandler(call, nil)
                return
            }
        }
    }

    /// Unregister Twilio Access Token via JS interop
    /// - Returns: True if successfully unregistered
    private func unregisterToken() -> Bool {
        // TODO - JS device interop
        guard let device = self.jsDevice else {
            print("No active JS device")
            return false;
        }
        // TODO - destroy device? destroy() & set nil
        device.unregister() { (error) in
            print(String(describing: error))
        }
        return true;
    }

    func formatCustomParams(params: [String: Any]?) -> String {
        guard let customParameters = params else {
            return ""
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                return "|\(jsonStr)"
            }
        } catch {
            print("unable to send custom parameters")
        }
        return ""
    }

    private func requestMicAccess() -> Bool {
        // TODO - JS Device interop
        // TODO - request mic access
        true
    }

    private func hasMicAccess() -> Bool {
        // TODO - JS Device interop
        // TODO - check mic access
        true
    }

    private func requestBackgroundPermissions() -> Bool {
        // TODO - JS Device interop
        // TODO - request background permissions
        true
    }

    private func requiresBackgroundPermissions() -> Bool {
        // TODO - JS Device interop
        // TODO - check background permissions
        true
    }

    private func showMissedCallNotification(from: String?, to: String?) {
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else {
            return
        }

        let content = UNMutableNotificationContent()
        var userName: String?
        if var from = from {
            from = from.replacingOccurrences(of: "client:", with: "")
            content.userInfo = ["type": "twilio-missed-call", Constants.PARAM_FROM: from]
            if let to = to {
                content.userInfo[Constants.PARAM_TO] = to
            }
            userName = self.clients[from]
        }

        let title = userName ?? self.clients[Constants.kDefaultCaller] ?? self.defaultCaller
        content.title = String(format: NSLocalizedString("notification_missed_call", comment: ""), title)

//        showNotification(title: <#T##String##Swift.String#>, action: <#T##String##Swift.String#>, params: <#T##Dictionary<String, Any>##Swift.Dictionary<Swift.String, Any>#>)
    }

    /// Show notification with title & body, using default trigger (1 second, no repeat)
    /// - Parameters:
    ///   - title: Notification title
    ///   - subtitle: Notification body/message
    ///   - uuid: (optional) UUID of notification, else one is generated
    ///   - action: Action to perform when notification is tapped
    ///   - params: Call parameters
    /// - Returns: [Void]
    private func showNotification(title: String, subtitle: String = "", _ uuid: UUID? = nil, action: NotificationAction, params: Dictionary<String, Any>) -> Void {
        let notificationCenter = UNUserNotificationCenter.current()

        notificationCenter.getNotificationSettings { (settings) in
            if settings.authorizationStatus == .authorized {
                let content = UNMutableNotificationContent()
                content.title = title
                content.subtitle = subtitle
                content.userInfo = ["type": action].merging(params) { (_, new) in
                    new
                }

                let id: UUID = uuid ?? UUID()
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(
                        identifier: id.uuidString,
                        content: content,
                        trigger: trigger)

                notificationCenter.add(request) { (error) in
                    if let error = error {
                        print("Notification Error: ", error)
                    }
                }

            }
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink

        // TODO - review
        //        NotificationCenter.default.addObserver(
        //            self,
        //            selector: #selector(CallDelegate.callDidDisconnect),
        //            name: NSNotification.Name(rawValue: "PhoneCallEvent"),
        //            object: nil)

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }

    /// Send multiple log events to Flutter plugin handler via the [eventSink]
    /// - Parameters:
    ///   - prefix: prefix e.g. "LOG"
    ///   - separator: message seperator e.g. "|"
    ///   - descriptionSeparator: (optional) seperator for descriptions e.g. ","
    ///   - descriptions: List of descriptions or events to send
    ///   - isError: true if error
    private func logEvents(prefix: String = "LOG", separator: String = "|", descriptionSeparator: String? = ",", descriptions: Array<String>, isError: Bool = false) {
        logEvent(prefix: prefix, separator: separator, description: descriptions.joined(separator: descriptionSeparator ?? ","), isError: isError)
    }

    /// Send log event to Flutter plugin handler via the [eventSink]
    /// - Parameters:
    ///   - prefix: prefix e.g. "LOG"
    ///   - separator: message seperator e.g. "|"
    ///   - description: Description or event to send
    ///   - isError: true if error
    private func logEvent(prefix: String = "LOG", separator: String = "|", description: String, isError: Bool = false) {
        NSLog(description)
        guard let eventSink = eventSink else {
            return
        }

        if isError {
            let flutterError = FlutterError(code: ErrorCodes.UNAVAILABLE_ERROR, message: description, details: nil)
            eventSink(flutterError)
        } else {
            var message = "";
            if (prefix.isEmpty) {
                message = description;
            } else {
                message = prefix + separator + description;
            }

            eventSink(message)
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // TODO(cybex-dev) - Review macOS & iOS code below
        let userInfo = response.notification.request.content.userInfo

        if let type = userInfo["type"] as? String, type == "twilio-missed-call", let user = userInfo[Constants.PARAM_FROM] as? String {
            self.to = user
            if let to = userInfo[Constants.PARAM_TO] as? String {
                self.identity = to
            }
            makeCall(to: to, from: identity, extraOptions: [:]) { (call, error) in
                if let error = error {
                    self.logEvent(prefix: "Call Error", description: error, isError: true)
                }
            }
            completionHandler()
            self.logEvents(prefix: "", descriptions: [])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call" {
            completionHandler([.banner])
        }
    }


    /// Create or update a client in [clients] for id resolution
    /// - Parameters:
    ///   - id: client identifier e.g. firebase Id
    ///   - name: client human readable name provided the id resolves to
    /// - Returns: [Void]
    private func updateClient(id: String, name: String) -> Void {
        if id.isEmpty {
            return;
        }

        if clients[id] == nil || clients[id] != name {
            clients[id] = name
            UserDefaults.standard.set(clients, forKey: kClientList)
        }
    }


    /// Remove client id/name store in [clients]
    /// - Parameter id: client id
    /// - Returns: true if removed
    private func removeClient(id: String) -> Bool {
        if id.isEmpty {
            return false;
        }

        if !clients.keys.contains(id) {
            return false
        }

        clients.removeValue(forKey: id);
        UserDefaults.standard.set(clients, forKey: kClientList)
        return true;
    }
}

extension UserDefaults {
    public func optionalBool(forKey defaultName: String) -> Bool? {
        if let value = value(forKey: defaultName) {
            return value as? Bool
        }
        return nil
    }
}

extension String {
    func localized(bundle: Bundle = .main, tableName: String = "Localizable") -> String {
        return NSLocalizedString(self, tableName: tableName, value: "\(self)", comment: "")
    }
}

class ErrorCodes {

    /// Associated with unexpected, malformed or missing arguments
    static let MALFORMED_ARGUMENTS: String = "arguments";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let INTERNAL_STATE_ERROR: String = "internal-state-error";

    /// Used in cases when attempting to modify an object that doesn't exist, is nil or is immutable
    static let UNAVAILABLE_ERROR: String = "unavailable";
}

class Constants {
    static let PARAM_FROM: String = "From"
    static let PARAM_TO: String = "To"
    static let kDefaultCaller: String = "defaultCaller"
}

class ActiveCall {
    var isOnHold: Bool = false
    var isMuted: Bool = false
    var sid: String = ""

    init() {

    }

    func sendDigits(digits: String) -> Bool {
        return true
    }

    func hangUp() -> Bool {
        return true
    }

    func answer() -> Bool {
        return true
    }
}

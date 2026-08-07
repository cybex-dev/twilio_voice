import Cocoa
import FlutterMacOS
@preconcurrency import WebKit
import SwiftUI
import UserNotifications
import AVFoundation

// Future Work
// - CallKit (https://developer.apple.com/documentation/callkit) - support in macOS 13.0+

public enum NotificationAction: String {
    case accept = "accept-call"
    case reject = "reject-call"
    case returnCall = "return-call"
    case dismiss = "dismiss"
}

public enum NotificationCategory: String {
    case missed = "missed-call"
    case incoming = "incoming-call"
}

public class TwilioVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, TVDeviceDelegate, TVCallDelegate, UNUserNotificationCenterDelegate, WKUIDelegate {

//    private var _result: FlutterResult?
    private var eventSink: FlutterEventSink?

    /// Events raised before the Dart listener attached, held here and flushed in `onListen` rather
    /// than being dropped. Bounded so a long-running app cannot grow this without limit.
    private var pendingEvents: [String] = []
    private let maxPendingEvents = 50

    /// Event prefixes that describe call state, used to tell whether the buffered events already
    /// told Dart about the call in progress.
    private let callStateEventPrefixes = ["Incoming|", "Ringing|", "Answer|", "Connected|"]

    /// Whether this event describes the state of a call, as opposed to a log or status flag.
    private func isCallStateEvent(_ message: String) -> Bool {
        callStateEventPrefixes.contains(where: message.hasPrefix)
    }

    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String: String]!

    var defaultCaller = "Unknown Caller"

    /// Storage key for [allowIncomingWhileBusy].
    private let allowIncomingWhileBusyKey = "TV_ALLOW_INCOMING_WHILE_BUSY"

    /// Whether the Twilio Device raises `incoming` while already on a call. Defaults to true; see `setAllowIncomingWhileBusy`.
    private var allowIncomingWhileBusy: Bool {
        get {
            UserDefaults.standard.optionalBool(forKey: allowIncomingWhileBusyKey) ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: allowIncomingWhileBusyKey)
        }
    }
    var deviceToken: Data? {
        get {
            UserDefaults.standard.data(forKey: kCachedDeviceToken)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken)
        }
    }
    var webView: TVWebView?
    private var twilioCall: TVCall? = nil {
        willSet {
            // dispose old call
            if let call = twilioCall {
                call.dispose()
            }
        }
        didSet {
            activeCallSid = nil
            activeQualityWarnings.removeAll()
            twilioCall?.resolveParams { [weak self] params, _ in
                self?.activeCallSid = params?.callSid
            }
            // attach event listeners to new call
            if let call = twilioCall {
                call.attachEventListeners()
                call.callDelegate = self
            }
        }
    }
    private var twilioDevice: TVDevice?

    private var test: Bool = false

    static var appName: String {
        get {
            (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }

    private func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        let answer = UNNotificationAction(identifier: NotificationAction.accept.rawValue, title: "Accept", options: [.foreground])
        let reject = UNNotificationAction(identifier: NotificationAction.reject.rawValue, title: "Reject", options: [])
        let incomingCallCategory = UNNotificationCategory(identifier: NotificationCategory.incoming.rawValue, actions: [answer, reject], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: "Incoming Calls", options: [])

        let dismiss = UNNotificationAction(identifier: NotificationAction.dismiss.rawValue, title: "Dismiss", options: [])
        let returnCall = UNNotificationAction(identifier: NotificationAction.returnCall.rawValue, title: "Return Call", options: [.foreground])
        let missedCallCategory = UNNotificationCategory(identifier: NotificationCategory.missed.rawValue, actions: [dismiss, returnCall], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: "Missed Calls", options: [])
        center.setNotificationCategories([incomingCallCategory, missedCallCategory])
    }

    public override init() {
        super.init()
        webView = TVWebView(messageHandler: "twilio_voice")
        webView?.uiDelegate = self
        #if DEBUG
        webView?.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        clients = UserDefaults.standard.object(forKey: kClientList) as? [String: String] ?? [:]

        // Register notification categories
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        // Attach the hidden webview (it runs the Twilio JS SDK) to the Flutter view.
        // Best-effort: on non-standard hosts (add-to-app, custom window setup, or a window
        // not yet ready) log and skip instead of crashing the app at launch - the previous
        // fatalError guards took down any app without a plain FlutterViewController root.
        // Note: the method/event channels are wired in register(with:); the init-time event
        // channel here was a duplicate and has been removed. The previous 1s Thread.sleep
        // (blocking the main thread during launch) has also been removed - nothing in init
        // depends on the webview finishing its async load.
        if let webView = webView,
           let viewController = NSApplication.shared.windows.first?.contentViewController as? FlutterViewController {
            webView.alphaValue = 0.0
            viewController.view.addSubview(webView)
        } else {
            NSLog("[TwilioVoice] WARNING: could not attach the plugin webview to a FlutterViewController window; VoIP functionality will be unavailable. Ensure a standard Flutter macOS window setup.")
        }
    }


    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
        twilioDevice?.dispose()
        twilioDevice = nil
        twilioCall = nil
    }


    public static func register(with registrar: FlutterPluginRegistrar) {

        let instance = TwilioVoicePlugin()
        let methodChannel = FlutterMethodChannel(name: "twilio_voice/messages", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        //        registrar.addApplicationDelegate(instance)
    }

    private func cancelNotification(_ callSid: String) {
        // Cancel the notification
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [callSid])
        center.removePendingNotificationRequests(withIdentifiers: [callSid])
    }

    private func showIncomingCallNotification(_ from: String, _ customParameters: [String: Any] = [:]) {
        showNotification(title: from, subtitle: "Incoming Call", action: .incoming, params: customParameters)
    }

    /// Resolves the name shown for a call, per the Interpreting Parameters contract:
    /// `__TWI_CALLER_NAME` -> resolve(`__TWI_CALLER_ID`) -> phone number -> registered client ->
    /// default caller name.
    ///
    /// - Parameter from: the raw handle, e.g. `client:alice` or `+15551234567`.
    /// - Parameter params: the call's custom parameters.
    private func resolveCallerName(_ from: String, _ params: [String: Any]? = nil) -> String {
        if let name = params?["__TWI_CALLER_NAME"] as? String, !name.isEmpty {
            return name
        }
        if let id = params?["__TWI_CALLER_ID"] as? String, !id.isEmpty {
            return resolveRegisteredClient(id)
        }
        if from.isEmpty {
            return defaultCaller
        }
        // A number is shown as-is; only client identities are looked up.
        if !from.starts(with: "client:") {
            return from
        }
        return resolveRegisteredClient(from)
    }

    /// Registered client name for an id, or the default caller name if it is not registered.
    private func resolveRegisteredClient(_ id: String) -> String {
        let clientId = id.replacingOccurrences(of: "client:", with: "")
        return clients[clientId] ?? defaultCaller
    }

    /// Register device token with Twilio. If an active TwilioDevice is found, it attempts to update the token instead. Completion handler completes with true if successful
    ///
    /// - Parameter token: device token
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func setTokens(token: String, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        assert(token.isNotEmpty(), "Access token cannot be empty")

        let codecs: [String] = ["opus", "pcmu"]
        let options: DeviceInitOptions = DeviceInitOptions(logLevel: 1, codecPreferences: codecs, closeProtection: false, allowIncomingWhileBusy: allowIncomingWhileBusy)
        if let device = twilioDevice {
            device.updateToken(token) { (value) in
                completionHandler(value ?? false)
            }
        } else {
            guard let webView = webView else {
                completionHandler(false)
                return
            }

            // Wait until the webview has loaded and the Twilio JS SDK is available before
            // creating the device. The SDK is bundled and injected at document start, but the
            // webview loads index.html asynchronously - a setTokens called right after launch
            // would otherwise run `new Twilio.Device(...)` against an undefined Twilio.Device.
            webView.whenSDKReady { [weak self] ready in
                guard let self = self else {
                    completionHandler(false)
                    return
                }
                guard ready else {
                    self.logEvent(description: "Twilio JS SDK is not available; cannot register. Ensure the plugin's webview initialised correctly.")
                    completionHandler(false)
                    return
                }

                self.twilioDevice = TVDevice(token, options: options, webView: webView) { (device, error) in
                    if let error = error {
                        print("Error TVDevice:init : \(String(describing: error))")
                        self.twilioDevice = nil
                        completionHandler(false)
                        return
                    }

                    if let device = self.twilioDevice {
                        self.twilioDevice = device
                        device.deviceDelegate = self
                        device.attachEventListeners();
                        device.register { error in
                            if let error = error {
                                print("Registering Error: \(String(describing: error))")
                                completionHandler(false)
                            } else {
                                completionHandler(true)
                            }
                        }
                    }
                }
            }
        }
    }


    /// Place outgoing call `from` to `to`. Returns true if successful, false otherwise. Completion handler completes with true if successful
    ///
    /// Generally accepted format is e164 (e.g. US number +15555555555)
    /// alternatively, use 'client:${clientId}' to call a Twilio Client connection
    ///
    /// Parameters send to Twilio's REST API endpoint `makeCall` can be passed in [extraOptions];
    /// Parameters are reduced to this format
    ///
    /// ```
    /// {
    ///  "From": from,
    ///  "To": to,
    ///  ...extraOptions
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - from: caller
    ///   - to: recipient
    ///   - extraOptions: extra options
    ///   - completionHandler: completion handler -> (Bool?)
    private func place(from: String?, to: String?, extraOptions: [String: Any]?, connect: Bool = false, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        // Raw connect() calls may omit To/From entirely (the TwiML app decides routing);
        // only regular makeCall requires them. Mirrors the Android placeCall(connect:)
        // contract: assert(connect || !isNullOrEmpty).
        assert(connect || (from?.isNotEmpty() ?? false), "\(Constants.PARAM_FROM) cannot be empty")
        assert(connect || (to?.isNotEmpty() ?? false), "\(Constants.PARAM_TO) cannot be empty")
//        assert(extraOptions?.keys.contains(Constants.PARAM_FROM) ?? true, "\(Constants.PARAM_FROM) cannot be passed in extraOptions")
//        assert(extraOptions?.keys.contains(Constants.PARAM_TO) ?? true, "\(Constants.PARAM_TO) cannot be passed in extraOptions")
//        assert(twilioDevice != nil, "Twilio Device must be initialized before making calls")

        logEvent(description: "Making new call")

        var params: [String: Any] = [:]
        if let from = from {
            params[Constants.PARAM_FROM] = from
        }
        if let to = to {
            params[Constants.PARAM_TO] = to
        }
        if let extraOptions = extraOptions {
            params.merge(extraOptions) { (_, new) in
                new
            }
        }

        if let device = twilioDevice {
            let options = TVDeviceConnectOptions(to: to, from: from, customParameters: params)
            device.connect(options, assignTo: "_call") { call, s in
                if let error = s {
                    print("[TVPlugin:place] Error resolving call params: \(error)")
                    completionHandler(nil)
                    return
                }
                if let call = call {
                    self.twilioCall = call
                    completionHandler(true)
                    return
                }
                // Neither a call nor an error: complete rather than leaving the Dart
                // Future hanging.
                completionHandler(false)
            }
        } else {
            // Device not initialized (setTokens not called): complete with failure
            // rather than leaving the Dart Future hanging with no log.
            logEvent(description: "Cannot place call: Twilio Device not initialized, call `setTokens` first")
            completionHandler(false)
        }
    }

    /// Toggle mute on active call. Completion handler completes with true if successful.
    ///
    /// Not currently implemented in macOS
    ///
    /// - Parameter shouldMute: true if should mute, false otherwise
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func toggleMute(_ shouldMute: Bool, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        if let call = twilioCall {
            call.mute(shouldMute) { error in
                if let error = error {
                    print("TVCall mute: \(String(describing: error))")
                    completionHandler(false)
                    return
                }
                self.logEvent(prefix: "", description: shouldMute ? "Mute" : "Unmute")
                completionHandler(true)
            }
        } else {
            completionHandler(false)
        }
    }

    /// Check if active call is muted. Completion handler completes with true if successful.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func isMuted(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        if let call = twilioCall {
            call.isMuted { (value, error) in
                if let error = error {
                    print("TVCall isMuted: \(String(describing: error))")
                    completionHandler(false)
                    return
                }
                completionHandler(value ?? false)
            }
        } else {
            completionHandler(false)
        }
    }

    /// Toggle speaker on active call. Completion handler completes with true if successful.
    ///
    /// Not currently implemented in macOS
    ///
    /// - Parameter speakerIsOn: should toggle to speaker mode, if true
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func toggleSpeaker(_ speakerIsOn: Bool, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        logEvent(prefix: "", description: speakerIsOn ? "Speaker On" : "Speaker Off")
        completionHandler(false)
    }

    /// Query if audio is on speaker. Completion handler completes with true if on speaker.
    ///
    /// Not currently implemented in macOS
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func isOnSpeaker(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        completionHandler(false)
    }

    /// Get call Sid from active call parameters. Completion handler provides the active call SID or nil if unavailable.
    ///
    /// - Parameter completionHandler: completion handler -> (String?)
    private func callSid(completionHandler: @escaping OnCompletionValueHandler<String>) -> Void {
        guard let call = twilioCall else {
            completionHandler(nil)
            return
        }

        call.resolveParams { (params, error) in
            if let error = error {
                print("[TVPlugin:callSid] Error resolving call params: \(error)")
            }
            completionHandler(params?.callSid)
        }
    }

    /// Queries twilioCall is active (a convenience function for `self.twilioCall != nil`). Completion handler completes with true if on call.
    ///
    /// - Parameter completionHandler: completion handler
    private func isOnCall(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        guard let device = twilioDevice else {
            completionHandler(false)
            return
        }
        device.isBusy { (value, error) in
            if let error = error {
                print("[TVPlugin:isOnCall] Error checking an active call: \(error)")
            }
            completionHandler(value ?? false)
        }
    }

    /// Send digits to active call. Completion handler completes with true if successful.
    ///
    /// - Parameter digits: digits to send
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func sendDigits(_ digits: String, completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        guard let call = twilioCall else {
            completionHandler(false)
            return
        }
        call.sendDigits(digits: digits) { error in
            if let error = error {
                print("[TVPlugin:sendDigits] Error checking if device is busy: \(error)")
            }
            completionHandler(error == nil)
        }
    }

    /// Holds active call. Completion handler completes with true if successful.
    ///
    /// Not currently implemented in macOS
    ///
    /// - Parameter shouldHold: true if should hold call, false unholds
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func holdCall(_ shouldHold: Bool, completionHandler: OnCompletionValueHandler<Bool>) -> Void {
        logEvent(prefix: "", description: shouldHold ? "Hold" : "Unhold")
        completionHandler(false)
    }

    /// Queries twilioCall is on hold. Completion handler completes with true if on hold.
    ///
    /// Not currently implemented in macOS
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func isHolding(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        completionHandler(false)
    }

    /// Answer incoming call. Completion handler completes with true if successful.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func answer(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        guard let call = twilioCall else {
            completionHandler(false)
            return
        }

        call.accept { error in
            if let error = error {
                print("[TVPlugin:answer] Error answering call: \(error)")
            }
            completionHandler(error == nil)
        }
    }

    /// Unregisters an access token and device from Twilio Access Token via JS interop
    ///
    /// - Parameters completionHandler: completion handler -> (Bool?)
    private func unregisterToken(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        guard let device = twilioDevice else {
            completionHandler(false)
            return;
        }

        device.unregister { (error) in
            if let error = error {
                print("[TVPlugin::unregisterToken] Error: \(String(describing: error))]")
            }
            completionHandler(error == nil)
        }
    }

    /// Hang up active call. Completion handler completes with true if successful.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func hangUp(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        guard let activeCall = twilioCall else {
            completionHandler(false)
            return
        }
        activeCall.status { status, s in
            if let error = s {
                print("[TVPlugin:hangUp] Error getting call status: \(error)")
                completionHandler(false)
                return
            } else if let status = status {
                if status == .pending {
                    activeCall.reject { error in
                        if let error = error {
                            print("[TVPlugin:hangUp] Error rejecting call: \(error)")
                        }
                        completionHandler(error == nil)
                    }
                } else {
                    activeCall.disconnect { error in
                        if let error = error {
                            print("[TVPlugin:hangUp] Error disconnecting call: \(error)")
                        }
                        completionHandler(error == nil)
                    }
                }
            }

            // Cancel incoming call notification
            activeCall.resolveParams { (params, _) in
                if let params = params, let callSid = params.callSid {
                    // Cancel incoming call notification
                    self.cancelNotification(callSid)
                }
            }
        }
    }

    /// Registered a client name & identifier in local storage, interprets incoming call parameters and resolves the caller & recipient ID automatically.
    ///
    /// - Parameters:
    ///   - clientId: client id e.g. "user_1234"
    ///   - clientName: client human readable name e.g. "John Doe"
    private func registerClient(_ clientId: String, _ clientName: String) -> Bool {
        logEvent(description: "Registering client \(clientId):\(clientName)")
        return updateClient(id: clientId, name: clientName)
    }

    /// Unregistered a client identifier from local storage.
    ///
    /// - Parameter clientId: client id e.g. "user_1234"
    private func unregisterClient(_ clientId: String) -> Bool {
        logEvent(description: "Unregistering \(clientId)")
        return removeClient(id: clientId)
    }

    /// Sets the default caller name for incoming callers. This is displayed if the caller name is not found in local storage or provided by the server.
    ///
    /// - Parameter defaultName: new default caller name
    private func setDefaultCaller(_ defaultName: String) -> Bool {
        logEvent(description: "defaultCaller is \(defaultName)")
        defaultCaller = defaultName
        return updateClient(id: Constants.kDefaultCaller, name: defaultName)
    }

    /// Queries application's microphone permissions. Completion handler completes with true if microphone is available, false otherwise.
    /// Note: if this returns true, this does not mean the webview (the important one) does in fact have access to the microphone.
    /// If denied permission here (webview), the webview will not have access and should be changed within Safari browser.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func hasMicPermission(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        logEvent(description: "checkPermissionForMicrophone")

        hasMicAccess { granted, error in
            if let error = error {
                print("[TVPlugin:hasMicPermission] Error querying microphone permissions: \(error)")
            }
            completionHandler(granted ?? false)
        }
    }

    /// Requests application microphone permissions. Completion handler completes with true if microphone is available, false otherwise.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func requestMicPermission(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        logEvent(description: "requesting mic permission")
        requestMicAccess { granted, error in
            if let error = error {
                print("[TVPlugin:requestMicPermission] Error requesting microphone permissions: \(error)")
            }
            completionHandler(granted ?? false)
        }
    }

    /// Queries application's notification permissions. Completion handler completes with true if permissions are available, false otherwise.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func hasBackgroundPermission(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        logEvent(description: "hasBackgroundPermission")

        requiresBackgroundPermissions { granted, error in
            if let error = error {
                print("[TVPlugin:hasBackgroundPermission] Error querying background notification permissions: \(error)")
            }
            completionHandler(granted ?? false)
        }
    }

    /// Requests application background notification permissions. Completion handler completes with true if permissions are available, false otherwise.
    ///
    /// - Parameter completionHandler: completion handler -> (Bool?)
    private func requestBackgroundPermission(completionHandler: @escaping OnCompletionValueHandler<Bool>) -> Void {
        logEvent(description: "requesting background permissions")

        requestBackgroundPermissions { granted, error in
            if let error = error {
                print("[TVPlugin:requestBackgroundPermission] Error requesting background permissions: \(error)")
            }
            completionHandler(granted ?? false)
        }
    }

    /// Set show app notifications (incoming, missed calls, etc).
    ///
    /// - Parameter show: true if notifications should be shown, false otherwise
    /// - Returns: true if successful
    private func showNotifications(_ show: Bool) -> Bool {
        let prefsShow = UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true
        if show != prefsShow {
            UserDefaults.standard.setValue(show, forKey: "show-notifications")
        }
        return true
    }

    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = flutterCall.arguments as? Dictionary<String, AnyObject> else {
            let error: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Arguments must be a Dictionary<String, AnyObject>", details: nil);
            result(error)
            return;
        }

        guard let method = TwilioVoiceChannelMethods.init(rawValue: flutterCall.method) else {
            result(FlutterMethodNotImplemented)
            return
        }

        switch method {
        case .tokens:
            guard let token = arguments["accessToken"] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'accessToken' argument provided or invalid type", details: nil)
                result(ferror)
                return
            }
            logEvent(description: "Attempting to register with twilio")
            setTokens(token: token) { success in
                result(success ?? false)
            }
            break

        case .makeCall:
            guard let to = arguments[Constants.PARAM_TO] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No '\(Constants.PARAM_TO)' argument provided or invalid type", details: nil)
                result(ferror)
                return
            }
            guard let from = arguments[Constants.PARAM_FROM] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No '\(Constants.PARAM_FROM)' argument provided or invalid type", details: nil)
                result(ferror)
                return
            }

            var params: [String: Any] = [:]
            arguments.forEach { (key, value) in
                if key != Constants.PARAM_TO && key != Constants.PARAM_FROM {
                    params[key] = value
                }
            }

            place(from: from, to: to, extraOptions: params) { success in
                result(success ?? false)
            }
            break
        case .connect:
            // Raw connect: To/From are optional (aligned with the iOS implementation) -
            // routing parameters travel in the remaining arguments and the TwiML
            // application decides the destination.
            let to = arguments[Constants.PARAM_TO] as? String
            let from = arguments[Constants.PARAM_FROM] as? String

            var params: [String: Any] = [:]
            arguments.forEach { (key, value) in
                if key != Constants.PARAM_TO && key != Constants.PARAM_FROM {
                    params[key] = value
                }
            }

            place(from: from, to: to, extraOptions: params, connect: true) { success in
                result(success ?? false)
            }
            break
        case .toggleMute:
            guard let muted = arguments["muted"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'muted' argument provided", details: nil)
                result(ferror)
                return
            }

            guard twilioCall != nil else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.INTERNAL_STATE_ERROR, message: "No call to be muted", details: nil)
                result(ferror)
                return
            }

            toggleMute(muted) { muted in
                result(muted)
            };
            break

        case .isMuted:
            guard twilioCall != nil else {
                result(false)
                return
            }

            isMuted { muted in
                result(muted ?? false)
            }
            break

        case .toggleSpeaker:
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'speakerIsOn' argument provided", details: nil)
                result(ferror)
                return
            }

            guard twilioCall != nil else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.INTERNAL_STATE_ERROR, message: "No call to toggle speaker", details: nil)
                result(ferror)
                return
            }

            toggleSpeaker(speakerIsOn) { success in
                result(success ?? false)
            }
            break

        case .isOnSpeaker:
            guard twilioCall != nil else {
                result(false)
                return
            }

            isOnSpeaker { speakerIsOn in
                result(speakerIsOn ?? false)
            }
            break

        case .toggleBluetooth:
            // Not supported on macOS
            guard let bluetoothOn = arguments["bluetoothOn"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'bluetoothOn' argument provided", details: nil)
                result(ferror)
                return
            }

            // TODO: implement bluetooth audio-route toggling if/when supported on macOS.
            // toggleAudioRoute(toSpeaker: speakerIsOn)
            logEvent(prefix: "", description: bluetoothOn ? "Bluetooth On" : "Bluetooth Off")
            result(bluetoothOn)
            break;

        case .isBluetoothOn:
            // Not supported on macOS
            result(false)
            break

        case .callSid:
            guard twilioCall != nil else {
                result(nil)
                return
            }

            callSid { sid in
                result(sid ?? nil)
            }
            break

        case .isOnCall:
            guard twilioDevice != nil else {
                result(false)
                return
            }

            isOnCall { success in
                result(success ?? false)
            }
            break

        case .sendDigits:
            guard let digits = arguments["digits"] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'digits' argument provided", details: nil)
                result(ferror)
                return
            }

            guard twilioCall != nil else {
                result(false)
                return
            }

            sendDigits(digits) { success in
                result(success ?? false)
            }
            break

        case .holdCall:
            guard let shouldHold = arguments["shouldHold"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "No 'shouldHold' argument provided", details: nil)
                result(ferror)
                return
            }

            guard twilioCall != nil else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.INTERNAL_STATE_ERROR, message: "No active call to hold", details: nil)
                result(ferror)
                return
            }

            holdCall(shouldHold) { success in
                result(success ?? false)
            }
            break

        case .isHolding:
            guard twilioCall != nil else {
                result(false)
                return
            }

            isHolding { success in
                result(success ?? false)
            }
            break

        case .answer:
            guard twilioCall != nil else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.INTERNAL_STATE_ERROR, message: "No incoming call to answer", details: nil)
                result(ferror)
                return
            }

            answer { success in
                result(success ?? false)
            }
            break

        case .unregister:
            guard twilioDevice != nil else {
                result(false)
                return;
            }

            unregisterToken { success in
                result(success ?? false)
            }
            break

        case .hangUp:
            guard twilioCall != nil else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.INTERNAL_STATE_ERROR, message: "No active call to hang up on", details: nil)
                result(ferror)
                return
            }

            hangUp { success in
                result(success ?? false)
            }
            break

        case .registerClient:
            guard let clientId = arguments["id"] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'id' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            guard let clientName = arguments["name"] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'name' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            result(registerClient(clientId, clientName))
            break

        case .unregisterClient:
            guard let clientId = arguments["id"] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'id' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            result(unregisterClient(clientId))
            break

        case .defaultCaller:
            guard let caller = arguments[Constants.kDefaultCaller] as? String else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'defaultCaller' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            result(setDefaultCaller(caller))
            break

        case .hasMicPermission:
            hasMicPermission { success in
                result(success ?? false)
            }
            break

        case .requestMicPermission:
            requestMicPermission { success in
                result(success ?? false)
            }
            break

        case .hasBluetoothPermission:
            result(true)
            break

        case .requestBluetoothPermission:
            result(true)
            break

        case .requiresBackgroundPermissions:
            hasBackgroundPermission { success in
                result(success ?? false)
            }
            break

        case .requestBackgroundPermissions:
            requestBackgroundPermission { success in
                result(success ?? false)
            }
            break

        case .showNotifications:
            guard let show = arguments["show"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'show' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            result(showNotifications(show))
            break

        case .setAllowIncomingWhileBusy:
            guard let allow = arguments["allow"] as? Bool else {
                let ferror: FlutterError = FlutterError(code: FlutterErrorCodes.MALFORMED_ARGUMENTS, message: "Argument 'allow' missing or incorrect type", details: nil)
                result(ferror)
                return
            }

            allowIncomingWhileBusy = allow
            // Apply to the active device, if any; otherwise it is picked up on the next setTokens.
            if let device = twilioDevice {
                let codecs: [String] = ["opus", "pcmu"]
                device.updateOptions(DeviceInitOptions(logLevel: 1, codecPreferences: codecs, closeProtection: false, allowIncomingWhileBusy: allow)) { _ in }
            }
            result(true)
            break

        case .getAllowIncomingWhileBusy:
            result(allowIncomingWhileBusy)
            break

        case .updateCallKitIcon:
            // macOS has no CallKit, so there is no call icon to update. Handle as a graceful
            // no-op (success) rather than falling through to FlutterMethodNotImplemented.
            result(true)
            break
        }
    }

    func formatCustomParams(params: [String: Any]?) -> String {
        guard let customParameters = params else {
            return ""
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                return "\(jsonStr)"
            }
        } catch {
            print("unable to send custom parameters")
        }
        return ""
    }

    /// Request mic permissions via WKWebView's getUserMedia function, as this is required for Twilio Voice SDK to work.
    ///
    /// - Parameter completionHandler: true if successfully executed, false otherwise
    private func requestMicAccess(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        // NOTE(cybex-dev)
        // Since Safari doesn't expose the Notifications API, we are unable to detect if the user has already granted mic permissions.
        // Further, getUserMedia() will prompt the user for mic permissions, we will just assume that the user has not granted permissions yet.
        // Thus, we will always ask for 'getUserMedia' permissions, and then check if the user has granted permissions to the mic.
        // This isn't a reliable workaround, but should work for most cases.

        // AVCaptureDevice.requestAccess(for: .audio) { granted in
        //     if granted {
        //         completionHandler(true, nil)
        //     } else {
        //         completionHandler(false, nil)
        //     }
        // }
        guard let webView = webView else {
            completionHandler(false, nil)
            return
        }

        webView.getUserMedia(completionHandler: completionHandler)
    }

    private func hasMicAccess(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: // The user has previously granted access to the microphone.
            completionHandler(true, nil)
            break

        case .notDetermined: // The user has not yet been asked for microphone access
            requestMicAccess { (granted, error) in
                completionHandler(granted, error)
            }
            break

        case .denied:
            completionHandler(false, nil)
            break


        case .restricted: // The user can't grant access due to restrictions.
            print("Mic Access restricted")
            completionHandler(false, nil)
            break
        default:
            completionHandler(false, nil)
            break
        }
    }

    private func requestBackgroundPermissions(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.onMain {
            if let error = error {
                    completionHandler(false, error.localizedDescription)
                } else {
                    completionHandler(granted, nil)
                }
            }
        }
    }

    private func requiresBackgroundPermissions(completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            self.onMain {
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    completionHandler(true, nil)
                } else {
                    completionHandler(false, nil)
                }
            }
        }
    }

    // Notify missed call from [From] to [To]
    private func showMissedCallNotification(from: String?, to: String?, params: [String: Any]? = nil) -> Void {
        let callerName = resolveCallerName(from ?? "")
        var params: [String: Any] = params ?? [:]
        params[Constants.PARAM_FROM] = from
        params[Constants.PARAM_TO] = to ?? ""
        showNotification(title: callerName, subtitle: "Missed Call", action: .missed, params: params)
    }

    /// Show notification with title & body, using default trigger (1 second, no repeat)
    /// - Parameters:
    ///   - title: Notification title
    ///   - subtitle: Notification body/message
    ///   - uuid: (optional) UUID of notification, else one is generated
    ///   - action: Action to perform when notification is tapped
    ///   - params: additional [UNMutableNotificationContent.userInfo] parameters
    /// - Returns: [Void]
    private func showNotification(title: String, subtitle: String = "", _ uuid: UUID? = nil, action: NotificationCategory, params: Dictionary<String, Any> = [:]) -> Void {
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else {
            return
        }

        let notificationCenter = UNUserNotificationCenter.current()

        notificationCenter.getNotificationSettings { (settings) in
            if settings.authorizationStatus == .authorized {
                let data: [String: Any] = [Constants.PARAM_TYPE: action.rawValue].merging(params) { (_, new) in
                    new
                };
                let callSid = data[Constants.PARAM_CALL_SID] as? String

                let content = UNMutableNotificationContent()
                content.title = title
                content.subtitle = subtitle
                content.userInfo = data
                content.categoryIdentifier = action.rawValue
                if #available(macOS 12.0, *) {
                    content.interruptionLevel = action == .incoming ? .timeSensitive : .active
                }

                let id: UUID = uuid ?? UUID()
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(
                        identifier: callSid ?? id.uuidString,
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

        // Deliver anything raised before Dart subscribed (see logEvent).
        let buffered = pendingEvents
        if !buffered.isEmpty {
            NSLog("Flushing \(buffered.count) buffered event(s)")
            pendingEvents.removeAll()
            onMain { buffered.forEach { eventSink($0) } }
        }

        if !buffered.contains(where: isCallStateEvent) {
            emitActiveCallState()
        }

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
    ///   - separator: message separator e.g. "|"
    ///   - descriptionSeparator: (optional) separator for descriptions e.g. ","
    ///   - descriptions: List of descriptions or events to send
    ///   - isError: true if error
    private func logEvents(prefix: String = "LOG", separator: String = "|", descriptionSeparator: String = "|", descriptions: Array<String>, isError: Bool = false) {
        logEvent(prefix: prefix, separator: separator, description: descriptions.joined(separator: descriptionSeparator), isError: isError)
    }

    /// Send log event to Flutter plugin handler via the [eventSink]
    /// - Parameters:
    ///   - prefix: prefix e.g. "LOG"
    ///   - separator: message separator e.g. "|"
    ///   - description: Description or event to send
    ///   - isError: true if error
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func logEvent(prefix: String = "LOG", separator: String = "|", description: String, isError: Bool = false) {
        NSLog(description)
        guard let eventSink = eventSink else {
            if !isError {
                let message = buildMessage(prefix: prefix, separator: separator, description: description)
                if isCallStateEvent(message) {
                    pendingEvents.removeAll(where: isCallStateEvent)
                }
                if pendingEvents.count >= maxPendingEvents {
                    pendingEvents.removeFirst()
                }
                pendingEvents.append(message)
            }
            return
        }

        if isError {
            let flutterError = FlutterError(code: FlutterErrorCodes.UNAVAILABLE_ERROR, message: description, details: nil)
            onMain { eventSink(flutterError) }
        } else {
            onMain { eventSink(self.buildMessage(prefix: prefix, separator: separator, description: description)) }
        }
    }

    /// Builds the wire message sent over the event channel: `<prefix><separator><description>`, or
    /// just the description when there is no prefix (call state events carry no prefix).
    private func buildMessage(prefix: String, separator: String, description: String) -> String {
        prefix.isEmpty ? description : prefix + separator + description
    }

    /// Emits the current state of the call in progress, if any.
    private func emitActiveCallState() {
        guard let activeCall = twilioCall else { return }

        activeCall.status { [weak self] status, _ in
            guard let self = self, let status = status else { return }
            activeCall.resolveParams { params, _ in
                activeCall.direction { direction, _ in
                    let from = params?.from ?? ""
                    let to = params?.to ?? ""
                    let customParams = self.formatCustomParams(params: params?.customParameters)

                    switch status {
                    case .pending, .ringing:
                        NSLog("Emitting state of ringing call for the new listener")
                        self.logEvents(prefix: "", descriptions: ["Incoming", from, to, "Incoming", customParams])

                    case .open, .connected, .reconnecting, .reconnected:
                        NSLog("Emitting state of active call for the new listener")
                        self.logEvents(prefix: "", descriptions: [
                            "Connected",
                            from,
                            to,
                            (direction ?? .outgoing).rawValue.capitalized,
                            customParams,
                        ])

                        if status == .reconnecting {
                            self.logEvents(prefix: "", descriptions: ["Reconnecting"])
                        }

                    default:
                        NSLog("Nothing to emit for call status '\(status.rawValue)'")
                    }
                }
            }
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // TODO(cybex-dev) - Review macOS & iOS code below
        let action = response.actionIdentifier
        let uuid = response.notification.request.identifier

        if let action = NotificationAction(rawValue: action) {
            switch action {
            case .accept:
                if let twilioCall = twilioCall {
                    twilioCall.accept { error in
                        if let error = error {
                            print("Error: \(error)")
                        }
                    }
                } else {
                    print("Twilio call not found")
                }
                break

            case .reject:
                if let twilioCall = twilioCall {
                    twilioCall.reject { error in
                        if let error = error {
                            print("Error: \(error)")
                        }
                    }
                } else {
                    print("Twilio call not found")
                }
                break

            case .dismiss:
                cancelNotification(uuid)
                break

            case .returnCall:
                cancelNotification(uuid)

                // remove notification type from parameters, pass on the rest.
                var userInfo = response.notification.request.content.userInfo
                userInfo.removeValue(forKey: Constants.PARAM_TYPE)

                var params: [String: Any] = [:]
                userInfo.forEach({ (key, value) in
                    if let key = key as? String {
                        params[key] = value
                    }
                })

                let from = params[Constants.PARAM_FROM] as? String
                let to = params[Constants.PARAM_TO] as? String

                if let from = from, let to = to {
                    // we swap from and to here because we are returning the call
                    place(from: to, to: from, extraOptions: params) { success in
                        if let success = success, success {
                            print("Successfully placed return call")
                            self.logEvents(prefix: "", descriptions: ["ReturningCall", from, to, self.formatCustomParams(params: params)])
                        } else {
                            print("Failed to place return call")
                        }
                    }
                } else {
                    print("Failed to place return call, from or to not found")
                }
//            default:
//                print("Notification type not found")
//                completionHandler()
            }
        } else {
            print("Notification type not found")
            completionHandler()
        }
    }

    /// Handle notification when app is in foreground
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let category = NotificationCategory(rawValue: notification.request.content.categoryIdentifier) {
            switch category {
            case .incoming:
                completionHandler([.banner, .sound])
            case .missed:
                completionHandler([.banner, .sound])
//            default:
//                completionHandler([])
            }
        } else {
            completionHandler([])
        }
    }


    /// Create or update a client in [clients] for id resolution
    /// - Parameters:
    ///   - id: client identifier e.g. firebase Id
    ///   - name: client human readable name provided the id resolves to
    /// - Returns: [Void]
    private func updateClient(id: String, name: String) -> Bool {
        if id.isEmpty {
            return false
        }

        if clients[id] == nil || clients[id] != name {
            clients[id] = name
            UserDefaults.standard.set(clients, forKey: kClientList)
            return true
        } else {
            return false
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

    // MARK: - TVDeviceDelegate

    func onDeviceIncoming(_ call: TVCall) {
        logEvent(description: "Incoming call")
        twilioCall = call
        requestMicAccess { _, error in
            if let error = error {
                print("Error: \(error)")
            }

            call.resolveParams { (params, error) in
                if let error = error {
                    print("Error: \(error)")
                }
                if let params = params {
                    let from = params.from ?? ""
                    let to = params.to ?? ""
                    self.logEvents(prefix: "", descriptions: ["Incoming", from, to, "Incoming", self.formatCustomParams(params: params.customParameters)])
                    self.logEvents(prefix: "", descriptions: ["Ringing", from, to, "Incoming", self.formatCustomParams(params: params.customParameters)])
                    // The event carries the raw handle; only the notification shows the resolved name.
                    self.showIncomingCallNotification(self.resolveCallerName(from, params.customParameters), params.customParameters)
                }
            }
        }
    }

    func onDeviceRegistered() {
        logEvent(description: "Device registered for call invites")
    }

    // ignore
    func onDeviceRegistering() {
        logEvent(description: "Device registering for call invites")
    }

    func onDeviceUnregistered() {
        logEvent(description: "Device unregistered, won't receive any more call invites")
    }

    func onDeviceTokenWillExpire(_ device: TVDevice) {
        logEvent(description: "Device token will expire")
        device.token { (token, error) in
            if let error = error {
                print("Error: \(error)")
            }
            if let token = token {
                self.logEvents(prefix: "", descriptions: [Constants.kDEVICETOKEN, token])
            }
        }
    }

    func onDeviceError(_ error: TVError) {
        logEvent(description: "Device error: \(error.code) \(error.message)")
    }

    // MARK: - TVCallDelegate

    public func onCallAccept(_ call: TVCall) {
        call.direction { direction, error in
            if let error = error {
                print("Error: \(error)")
            }

            if let direction = direction, direction == .incoming {
                call.resolveParams { (params, error) in
                    if let error = error {
                        print("Error: \(error)")
                    }
                    if let params = params {
                        let from = params.from ?? ""
                        let to = params.to ?? ""

                        self.logEvents(prefix: "", descriptions: ["Answer", from, to, self.formatCustomParams(params: params.customParameters)])

                        // Cancel incoming call notification
                        if let callSid = params.callSid {
                            self.cancelNotification(callSid)
                        }
                    }
                }
            }
        }
    }

    public func onCallCancel(_ call: TVCall) {
        // Notify missed call notification
        call.resolveParams { (params, error) in
            if let error = error {
                print("Error: \(error)")
            }

            if let params = params {
                if let callSid = params.callSid {
                    self.cancelNotification(callSid)
                }
                if let from = params.from, let to = params.to {
                    self.showMissedCallNotification(from: from, to: to, params: params.customParameters)
                }
            }
        }

        twilioCall = nil
        logEvent(prefix: "", description: "Missed Call")
        logEvent(prefix: "", description: "Call Ended")
    }

    public func onCallDisconnect(_ call: TVCall) {
        call.status { status, error in
            if let error = error {
                print("Error: \(error)")
            }

//            if status == .closed && self.twilioCall != nil {
            if status == .closed {
                self.logEvent(prefix: "", description: "Call Ended")
            }
        }

        twilioCall = nil
    }

    public func onCallError(_ error: TVError) {
        logEvent(description: "Call Error: \(error.code) \(error.message)")
    }

    public func onCallReconnecting(_ error: TVError) {
        logEvent(prefix: "", description: "Reconnecting: \(error.code) \(error.message)")
    }
    private var activeCallSid: String?

    private var activeQualityWarnings: [String: Set<String>] = [:]

    public func onCallQualityWarning(_ name: String, isCleared: Bool) {
        let sid = activeCallSid ?? ""
        let previous = activeQualityWarnings[sid] ?? []
        var current = previous
        if isCleared {
            current.remove(name)
        } else {
            current.insert(name)
        }
        activeQualityWarnings[sid] = current
        logEvent(prefix: "", description: "Quality|\(current.joined(separator: ","))|\(previous.joined(separator: ","))")
    }

    public func onCallReconnected() {
        logEvent(prefix: "", description: "Reconnected")
    }

    public func onCallReject() {
        if twilioCall != nil {
            twilioCall = nil
        }
        logEvent(description: "Call Rejected")
    }

    public func onCallStatus(_ status: TVCallStatus) {
        if (status == .connected) {
            if let call = twilioCall {
                onCallConnected(call)
            }
        } else if (status == .ringing) {
            onCallRinging()
        }
    }

    private func onCallConnected(_ call: TVCall) {
        call.resolveParams { params, error in
            if let error = error {
                print("Error: \(error)")
                return
            }
            if let params = params {
                let from = params.from ?? ""
                let to = params.to ?? ""

                call.direction { direction, error in
                    if let error = error {
                        print("Error: \(error)")
                        return
                    }

                    guard let direction = direction?.rawValue.capitalized else {
                        return
                    }

                    self.logEvents(prefix: "", descriptions: [
                        "Connected",
                        from,
                        to,
                        direction,
                    ])
                }
            }
        }

    }

    private func onCallRinging() {
        guard let call = twilioCall else {
            return
        }
        call.resolveParams { params, error in
            if let error = error {
                print("Error: \(error)")
                return
            }
            if let params = params {
                let from = params.from ?? ""
                let to = params.to ?? ""

                call.direction { direction, error in
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
        }
    }

    // MARK -

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Ok")
        alert.alertStyle = NSAlert.Style.informational

        let modalResponse = alert.runModal()
        let alertButton = modalResponse.rawValue
        let _ = NSApplication.ModalResponse(rawValue: alertButton)
        completionHandler()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = NSAlert.Style.informational

        let modalResponse = alert.runModal()
        let alertButton = modalResponse.rawValue
        let result = NSApplication.ModalResponse(rawValue: alertButton)
        completionHandler(result == NSApplication.ModalResponse.alertFirstButtonReturn)
    }

    @available(macOS 12.0, *)
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        switch type {
        case .microphone:
            // For microphone access, we'll check the current permission status
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                decisionHandler(.grant)
            case .notDetermined:
                // Request permission and handle the result
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        decisionHandler(granted ? .grant : .deny)
                    }
                }
            case .denied, .restricted:
                decisionHandler(.deny)
            @unknown default:
                decisionHandler(.deny)
            }
        case .camera:
            // We don't need camera access for Twilio Voice
            decisionHandler(.deny)
        case .cameraAndMicrophone:
            // We don't need camera and microphone access for Twilio Voice
            decisionHandler(.deny)
        @unknown default:
            decisionHandler(.deny)
        }
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
        NSLocalizedString(self, tableName: tableName, value: "\(self)", comment: "")
    }

    func isNotEmpty() -> Bool {
        !isEmpty
    }
}





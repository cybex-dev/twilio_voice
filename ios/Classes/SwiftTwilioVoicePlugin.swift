import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit
import UserNotifications

public class SwiftTwilioVoicePlugin: NSObject, FlutterPlugin,  FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate, CXCallObserverDelegate {
    
    /// Shared instance for AppDelegate to forward PushKit events.
    /// Set during register(with:) so the AppDelegate can access the plugin.
    public static var sharedInstance: SwiftTwilioVoicePlugin?
    
    // MARK: - TwilioPushBridge helpers (ObjC runtime)
    // TwilioPushBridge is defined in the Runner target. The plugin accesses it
    // via NSClassFromString to avoid cross-module import issues.
    
    /// Get the TwilioPushBridge class via ObjC runtime
    private static var bridgeClass: NSObject.Type? {
        return NSClassFromString("Runner.TwilioPushBridge") as? NSObject.Type
            ?? NSClassFromString("TwilioPushBridge") as? NSObject.Type
    }
    
    /// Check if PushKit was set up by AppDelegate (via TwilioPushBridge.pushKitSetupByAppDelegate)
    private static var pushKitSetupByAppDelegate: Bool {
        guard let cls = bridgeClass else { return false }
        return (cls.value(forKey: "pushKitSetupByAppDelegate") as? Bool) ?? false
    }
    
    /// Register this plugin as the TwilioPushBridge delegate
    private static func registerAsBridgeDelegate(_ instance: SwiftTwilioVoicePlugin) {
        guard let cls = bridgeClass else { return }
        cls.setValue(instance, forKey: "delegate")
    }
    
    /// Get and clear the pending device token from TwilioPushBridge
    private static func takePendingDeviceToken() -> Data? {
        guard let cls = bridgeClass else { return nil }
        guard let token = cls.value(forKey: "pendingDeviceToken") as? Data else { return nil }
        cls.setValue(nil, forKey: "pendingDeviceToken")
        return token
    }
    
    /// Get and clear the pending call invite from TwilioPushBridge
    private static func takePendingCallInvite() -> CallInvite? {
        guard let cls = bridgeClass else { return nil }
        guard let invite = cls.value(forKey: "pendingCallInvite") as? CallInvite else { return nil }
        cls.setValue(nil, forKey: "pendingCallInvite")
        return invite
    }
    
    let callObserver = CXCallObserver()
    
    final let defaultCallKitIcon = "callkit_icon"
    var callKitIcon: String?

    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?
    
    let kRegistrationTTLInDays = 365
    
    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kClientList = "TwilioContactList"
    private var clients: [String:String]!
    
    var accessToken:String?
    var identity = "alice"
    var callTo: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get{UserDefaults.standard.data(forKey: kCachedDeviceToken)}
        set{UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken)}
    }
    var callArgs: Dictionary<String, AnyObject> = [String: AnyObject]()
    
    var voipRegistry: PKPushRegistry
    var incomingPushCompletionCallback: (()->Swift.Void?)? = nil
    
    // MULTI-CALL SUPPORT: Dictionaries keyed by UUID instead of single variables
    var callInvites: [UUID: CallInvite] = [:]
    var calls: [UUID: Call] = [:]
    /// The UUID of the currently active (foreground) call
    var activeCallUUID: UUID?
    
    // Legacy single-call accessors for backward compatibility in audio/misc code
    var call: Call? {
        get {
            if let uuid = activeCallUUID { return calls[uuid] }
            return calls.values.first
        }
    }
    var callInvite: CallInvite? {
        get { return callInvites.values.first }
    }
    
    var callKitCompletionCallback: ((Bool)->Swift.Void?)? = nil
    var audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callOutgoing: Bool = false
    var outgoingCallerName = ""

    private var activeCXCalls: [UUID: CXCall] = [:]
    
    // Audio route state management - tracks what we've SET, not what system reports
    private var desiredSpeakerState: Bool = false
    private var desiredBluetoothState: Bool = false
    // Track if user explicitly changed audio route - prevents auto-switching back
    private var userExplicitlyChangedAudioRoute: Bool = false
    // Cache Bluetooth availability to avoid triggering route changes during active calls
    private var cachedBluetoothAvailable: Bool = false
    private var hasCheckedBluetoothOnCallStart: Bool = false
    // Cancellable work items for delayed audio route operations
    // These MUST be cancelled on hangup to prevent AVAudioSession changes during call teardown
    private var pendingAudioRouteWorkItems: [DispatchWorkItem] = []
    // Dedicated serial queue for AVAudioSession operations.
    // AVAudioSession.setCategory() and overrideOutputAudioPort() can block for 1-4+ seconds,
    // which freezes the Flutter UI if called on the main thread.
    // All audio session changes MUST happen on this queue, with only eventSink dispatches
    // going back to the main thread.
    private let audioSessionQueue = DispatchQueue(label: "com.twilio.voice.audioSession", qos: .userInitiated)
    // Reentrancy guard: prevents handleAudioRouteChange from reacting to our own category changes
    private var isChangingAudioRoute: Bool = false
    // Suppress guard: prevents handleAudioRouteChange from sending AudioRoute events to Dart
    // during call setup. CallKit configures the audio session with .allowBluetooth which can
    // make phantom BT appear in currentRoute. We suppress events until applyInitialAudioRoute
    // has run and sent its definitive AudioRoute event.
    private var suppressAudioRouteEvents: Bool = false
    // Event queue: buffers critical call events when eventSink is nil (app in background/terminated)
    // Events are replayed in order when Flutter re-establishes the event channel via onListen
    private var pendingEvents: [Any] = []
    // Maximum number of queued events to prevent unbounded memory growth
    private static let maxPendingEvents = 50
    // Timestamp of last Bluetooth disconnect — used to ignore stale availableInputs
    // AirPods in their case still appear in availableInputs for several seconds after disconnect
    private var lastBluetoothDisconnectTime: Date? = nil
    // Duration to distrust availableInputs after a BT disconnect (seconds)
    private static let btDisconnectGuardDuration: TimeInterval = 5.0

    static var appName: String {
        get {
            return (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }
    
    public override init() {
        //isSpinning = false
        voipRegistry = PKPushRegistry.init(queue: DispatchQueue.main)
        let configuration = CXProviderConfiguration(localizedName: SwiftTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 2
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber,.generic]
        let defaultIcon = UserDefaults.standard.string(forKey: defaultCallKitIcon) ?? defaultCallKitIcon
        
        clients = UserDefaults.standard.object(forKey: kClientList)  as? [String:String] ?? [:]
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        //super.init(coder: aDecoder)
        super.init()
        callObserver.setDelegate(self, queue: DispatchQueue.main)

        callKitProvider.setDelegate(self, queue: nil)
        _ = updateCallKitIcon(icon: defaultIcon)
        
        // NOTE: PKPushRegistry delegate and desiredPushTypes are set up in the AppDelegate
        // (BEFORE plugin registration) to ensure VoIP pushes are handled immediately at app launch.
        // This follows Apple's PushKit guidelines: "Your app must initialize PKPushRegistry with
        // PushKit push type VoIP at the launch time." The AppDelegate forwards push events to this
        // plugin instance via SwiftTwilioVoicePlugin.sharedInstance.

        // NOTE: Event channel is set up in register(with:), NOT here.
        // Setting it up here with a different messenger causes duplicate/conflicting channels.
        
        // NOTE: Do NOT configure AVAudioSession here in init().
        // In terminated state, iOS manages the audio session until CallKit activates it.
        // Configuring it prematurely can interfere with CallKit's incoming call flow.
        // Audio session will be configured when:
        // 1. provider:didActivateAudioSession: is called (incoming/outgoing call answered)
        // 2. applyInitialAudioRoute() is called at call start
        
        // Listen for audio route changes (e.g., Bluetooth connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    /// Configure AVAudioSession to support Bluetooth devices
    private func configureAudioSessionForBluetooth() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Set category to allow Bluetooth audio input/output
            // Note: We DON'T use .defaultToSpeaker here because:
            // 1. If Bluetooth is connected, we want to use it naturally (not speaker)
            // 2. If Bluetooth is not connected, earpiece is the default anyway
            // 3. User can explicitly select speaker if needed
            try audioSession.setCategory(
                AVAudioSession.Category.playAndRecord,
                options: [.duckOthers, .allowBluetoothA2DP, .allowBluetooth]
            )
            
            // Set mode to voiceChat for VoIP calls
            try audioSession.setMode(.voiceChat)
            
            // Enable/disable Bluetooth audio input and output
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
            
            self.sendPhoneCallEvents(
                description: "LOG|AVAudioSession configured for Bluetooth support",
                isError: false
            )
        } catch {
            self.sendPhoneCallEvents(
                description: "LOG|Failed to configure AVAudioSession for Bluetooth: \(error.localizedDescription)",
                isError: false
            )
        }
    }
    
    /// Handle audio route changes (Bluetooth connections/disconnections)
    @objc private func handleAudioRouteChange(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo["AVAudioSessionRouteChangeReasonKey"] as? UInt else {
            return
        }
        
        // REENTRANCY GUARD: Skip if we ourselves are changing the audio route.
        // Without this, forceEarpieceRoute/forceSpeakerRoute/checkBluetoothAvailableFresh
        // each change the AVAudioSession category, which fires this notification again,
        // creating a cascading loop of audio session changes that can crash or block CallKit.
        guard !isChangingAudioRoute else {
            return
        }
        
        // SUPPRESS GUARD: During call setup, CallKit activates the audio session with
        // .allowBluetooth which can make phantom BT appear in currentRoute.
        // We suppress AudioRoute events until applyInitialAudioRoute sends the definitive event.
        // Exception: oldDeviceUnavailable (device physically disconnected) should always be handled.
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        let reasonStr = reason.map { String($0.rawValue) } ?? "unknown"
        
        if suppressAudioRouteEvents && reason != .oldDeviceUnavailable {
            self.sendPhoneCallEvents(description: "LOG|Audio route changed. Reason: \(reasonStr) — SUPPRESSED (waiting for applyInitialAudioRoute)", isError: false)
            return
        }
        
        self.sendPhoneCallEvents(description: "LOG|Audio route changed. Reason: \(reasonStr)", isError: false)
        
        // Check if we're in an active call
        guard !self.calls.isEmpty else {
            return
        }
        
        // Check the new audio route and emit events if Bluetooth status changed
        switch reason {
        case .oldDeviceUnavailable:
            // A device was disconnected (e.g., Bluetooth headset)
            self.sendPhoneCallEvents(description: "LOG|=== ROUTE CHANGE: oldDeviceUnavailable (device disconnected) ===", isError: false)
            
            self.scheduleAudioRouteWorkItem(delay: 0.2) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                
                // Check if the disconnected device was Bluetooth
                let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
                var wasBluetoothDisconnected = false
                
                if let previousRoute = previousRoute {
                    for output in previousRoute.outputs {
                        if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                            wasBluetoothDisconnected = true
                            self.sendPhoneCallEvents(description: "LOG|Bluetooth device was disconnected: \(output.portName)", isError: false)
                            break
                        }
                    }
                }
                
                // Record the disconnect time so isBluetoothAvailable() won't trust
                // stale availableInputs for the next few seconds
                if wasBluetoothDisconnected {
                    self.lastBluetoothDisconnectTime = Date()
                }
                
                // Use safe check (no category change) — afterDisconnect: true ensures
                // we only trust current route outputs, NOT availableInputs.
                // AirPods in their case still appear in availableInputs but can't output audio.
                self.cachedBluetoothAvailable = false
                self.hasCheckedBluetoothOnCallStart = false
                let bluetoothAvailableNow = self.isBluetoothAvailableSafe(afterDisconnect: true)
                
                self.sendPhoneCallEvents(description: "LOG|oldDeviceUnavailable: wasBluetoothDisconnected=\(wasBluetoothDisconnected), btAvailableNow=\(bluetoothAvailableNow), desiredBT=\(self.desiredBluetoothState)", isError: false)
                
                // If Bluetooth was disconnected OR we were using Bluetooth and it's no longer available
                if wasBluetoothDisconnected || (self.desiredBluetoothState && !bluetoothAvailableNow) {
                    self.sendPhoneCallEvents(description: "LOG|Bluetooth disconnected - forcing switch to earpiece", isError: false)
                    
                    // Update our state trackers to reflect reality
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    // Force earpiece route to ensure audio continues
                    if !self.desiredSpeakerState {
                        self.isChangingAudioRoute = true
                        self.forceEarpieceRoute()
                        self.isChangingAudioRoute = false
                    }
                    
                    // Notify Dart layer with updated state
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(bluetoothAvailableNow)",
                        isError: false
                    )
                } else {
                    // Some other device disconnected, just report current state
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(bluetoothAvailableNow)",
                        isError: false
                    )
                }
            }
            
        case .newDeviceAvailable:
            // A device was connected (e.g., Bluetooth headset)
            self.sendPhoneCallEvents(description: "LOG|=== ROUTE CHANGE: newDeviceAvailable ===", isError: false)
            
            self.cachedBluetoothAvailable = false
            // Clear disconnect guard — a new device just connected
            self.lastBluetoothDisconnectTime = nil
            
            self.scheduleAudioRouteWorkItem(delay: 0.3) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                
                // Use clean-category verification to distinguish real BT from phantom.
                // When a real BT device connects, iOS routes audio through it automatically,
                // so it will persist in currentRoute even without .allowBluetooth.
                let isBluetoothAvailable = self.isBluetoothAvailableClean()
                
                self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: btAvailable=\(isBluetoothAvailable), desiredBT=\(self.desiredBluetoothState), desiredSpeaker=\(self.desiredSpeakerState), userExplicitlyChanged=\(self.userExplicitlyChangedAudioRoute)", isError: false)
                
                self.cachedBluetoothAvailable = isBluetoothAvailable
                
                if isBluetoothAvailable {
                    // ALWAYS auto-switch to Bluetooth when a real BT device connects,
                    // regardless of current audio route (earpiece OR speaker).
                    // This matches standard iOS/Android phone behavior.
                    self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: Auto-switching to Bluetooth (from desiredSpeaker=\(self.desiredSpeakerState))...", isError: false)
                    
                    self.userExplicitlyChangedAudioRoute = false
                    self.desiredBluetoothState = true
                    self.desiredSpeakerState = false
                    
                    self.isChangingAudioRoute = true
                    self.applyBluetoothRoute()
                    self.isChangingAudioRoute = false
                    
                    // Notify Dart after a short delay to let route settle
                    self.scheduleAudioRouteWorkItem(delay: 0.3) { [weak self] in
                        guard let self = self, !self.calls.isEmpty else { return }
                        let currentRoute = self.getAudioRoute()
                        // Use clean check for the notification too
                        let btAvailable = self.isBluetoothAvailableClean()
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(btAvailable)",
                            isError: false
                        )
                    }
                } else {
                    self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: NOT auto-switching (no real BT found)", isError: false)
                    
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                        isError: false
                    )
                }
            }
            
        case .categoryChange:
            // Category changed - often triggered by OUR changes, skip if so
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: categoryChange detected", isError: false)
            self.scheduleAudioRouteWorkItem(delay: 0.2) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                
                let isBluetoothAvailable = self.isBluetoothAvailableClean()
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange categoryChange: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
                
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|categoryChange: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.isChangingAudioRoute = true
                        self.forceEarpieceRoute()
                        self.isChangingAudioRoute = false
                    }
                }
                
                let currentRoute = self.getAudioRoute()
                self.sendPhoneCallEvents(
                    description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
            }
            
        case .override:
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: override detected", isError: false)
            self.scheduleAudioRouteWorkItem(delay: 0.2) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                
                let isBluetoothAvailable = self.isBluetoothAvailableClean()
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange override: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
                
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|override: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.isChangingAudioRoute = true
                        self.forceEarpieceRoute()
                        self.isChangingAudioRoute = false
                    }
                }
                
                let currentRoute = self.getAudioRoute()
                self.sendPhoneCallEvents(
                    description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
            }
            
        default:
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: unhandled reason \(reasonStr)", isError: false)
            self.scheduleAudioRouteWorkItem(delay: 0.2) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                
                let isBluetoothAvailable = self.isBluetoothAvailableClean()
                
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|default handler: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.isChangingAudioRoute = true
                        self.forceEarpieceRoute()
                        self.isChangingAudioRoute = false
                    }
                }
            }
        }
    }
    
    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
    }
    
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftTwilioVoicePlugin()
        let methodChannel = FlutterMethodChannel(name: "twilio_voice/messages", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        registrar.addApplicationDelegate(instance)
        
        // Store the shared instance so the AppDelegate can forward PushKit events
        SwiftTwilioVoicePlugin.sharedInstance = instance
        
        // Register as the TwilioPushBridge delegate so AppDelegate can forward PushKit events
        SwiftTwilioVoicePlugin.registerAsBridgeDelegate(instance)
        
        // Check if the AppDelegate already set up PKPushRegistry.
        // If so, do NOT set up a second one (would cause duplicate push handling).
        // The AppDelegate will forward push events to us via the bridge.
        if SwiftTwilioVoicePlugin.pushKitSetupByAppDelegate {
            // AppDelegate handles PushKit — skip plugin PKPushRegistry to avoid duplicates
        } else {
            // Fallback: AppDelegate didn't set up PushKit (older integration)
            instance.voipRegistry.delegate = instance
            instance.voipRegistry.desiredPushTypes = Set([PKPushType.voIP])
        }
        
        // Pick up any early call invite that arrived before the plugin was ready
        if let earlyInvite = SwiftTwilioVoicePlugin.takePendingCallInvite() {
            instance.callInvites[earlyInvite.uuid] = earlyInvite
        }
        
        // Pick up device token if it was received before the plugin was ready
        if let pendingToken = SwiftTwilioVoicePlugin.takePendingDeviceToken() {
            instance.deviceToken = pendingToken
        }
    }
    
    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        _result = result
        
        let arguments:Dictionary<String, AnyObject> = flutterCall.arguments as! Dictionary<String, AnyObject>;
        
        if flutterCall.method == "tokens" {
            guard let token = arguments["accessToken"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing accessToken", details: nil))
                return
            }
            self.accessToken = token;
            guard let deviceToken = deviceToken else {
                self.sendPhoneCallEvents(description: "LOG|Device token is nil. Cannot register for VoIP push notifications.", isError: false)
                return
            }
            if let token = accessToken {
                self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
                
                // CRITICAL: Set our custom audio device before registering
                TwilioVoiceSDK.audioDevice = self.audioDevice
                self.sendPhoneCallEvents(description: "LOG|TwilioVoiceSDK.audioDevice set to custom audioDevice", isError: false)
                
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { (error) in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    }
                    else {
                        self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                    }
                }
            }
        } else if flutterCall.method == "makeCall" {
            guard let callTo = arguments["To"] as? String else {return}
            guard let callFrom = arguments["From"] as? String else {return}
            let callerName = arguments["CallerName"] as? String
            outgoingCallerName = callerName ?? ""
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String{
                self.accessToken = accessToken
            }
            self.callTo = callTo
            self.identity = callFrom
            makeCall(to: callTo)
        } else if flutterCall.method == "connect" {
            guard let callTo = arguments["To"] as? String? else {
                return
            }
            guard let callFrom = arguments["From"] as? String? else {
                return
            }
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String{
                self.accessToken = accessToken
            }
            self.callTo = callTo ?? ""
            self.identity = callFrom ?? ""
            makeCall(to: self.callTo)
        }
        else if flutterCall.method == "toggleMute"
        {
            guard let muted = arguments["muted"] as? Bool else {return}
            // Get the active call (current foreground call)
            let activeCall = self.call
            if (activeCall != nil) {
                activeCall!.isMuted = muted
                guard let eventSink = eventSink else {
                    return
                }
                eventSink(muted ? "Mute" : "Unmute")
            } else {
                let ferror: FlutterError = FlutterError(code: "MUTE_ERROR", message: "No call to be muted", details: nil)
                _result!(ferror)
            }
        }
        else if flutterCall.method == "isMuted"
        {
            if let activeCall = self.call {
                result(activeCall.isMuted);
            } else {
                result(false);
            }
        }
        else if flutterCall.method == "toggleSpeaker"
        {
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {return}
            self.sendPhoneCallEvents(description: "LOG|METHOD_CHANNEL: toggleSpeaker called with speakerIsOn=\(speakerIsOn)", isError: false)
            toggleAudioRoute(toSpeaker: speakerIsOn)
            
            // Send response to method call immediately (non-blocking)
            result(true)
            
            guard let eventSink = eventSink else {
                return
            }
            // Use the desired state directly since the actual route change is async
            // (applySpeakerSetting runs on audioSessionQueue). isSpeakerOn() would read
            // the old route before the change completes.
            DispatchQueue.main.async {
                eventSink(speakerIsOn ? "Speaker On" : "Speaker Off")
            }
        }
        else if flutterCall.method == "isOnSpeaker"
        {
            let isOnSpeaker: Bool = isSpeakerOn();
            result(isOnSpeaker);
        }
        else if flutterCall.method == "toggleBluetooth"
        {
            guard let bluetoothOn = arguments["bluetoothOn"] as? Bool else {return}
            self.sendPhoneCallEvents(description: "LOG|METHOD_CHANNEL: toggleBluetooth called with bluetoothOn=\(bluetoothOn)", isError: false)
            toggleBluetoothAudio(bluetoothOn: bluetoothOn)
            
            // Send response to method call
            result(true)
            
            // Also send event notification
            guard let eventSink = eventSink else {
                return
            }
            eventSink(bluetoothOn ? "Bluetooth On" : "Bluetooth Off")
        }
        else if flutterCall.method == "isBluetoothOn"
        {
            let isBluetoothOn: Bool = isBluetoothOn();
            result(isBluetoothOn);
        }
        else if flutterCall.method == "getAudioRoute"
        {
            // During call setup, suppress — phantom BT may be in currentRoute.
            // Return "earpiece" as safe default until applyInitialAudioRoute sends definitive state.
            if self.suppressAudioRouteEvents {
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute METHOD CHANNEL: returning 'earpiece' (suppressed during call setup)", isError: false)
                result("earpiece")
                return
            }
            let audioRoute = getAudioRoute()
            result(audioRoute)
        }
        else if flutterCall.method == "isBluetoothAvailable"
        {
            // During call setup, suppress BT availability to prevent phantom BT.
            // CallKit activates the audio session with .allowBluetooth which can make
            // phantom BT appear in currentRoute. We suppress until applyInitialAudioRoute
            // has done the clean-category check and sent the definitive AudioRoute event.
            if self.suppressAudioRouteEvents {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable METHOD CHANNEL: returning false (suppressed during call setup)", isError: false)
                result(false)
                return
            }
            
            // Dispatch to audioSessionQueue to ensure thread-safe access to audio session state.
            // Use clean-category verification to reject phantom BT entries.
            audioSessionQueue.async { [weak self] in
                guard let self = self else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                let bluetoothAvailable = self.isBluetoothAvailableClean()
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable METHOD CHANNEL: clean check returned \(bluetoothAvailable)", isError: false)
                // Dispatch result back to main thread — FlutterResult must be called
                // on the platform thread to avoid race conditions with concurrent
                // method channel calls.
                DispatchQueue.main.async {
                    result(bluetoothAvailable)
                }
            }
        }
        else if flutterCall.method == "call-sid"
        {
            result(self.call?.sid);
            return;
        }
        else if flutterCall.method == "isOnCall"
        {
            result(!self.calls.isEmpty);
            return;
        }
        else if flutterCall.method == "sendDigits"
        {
            guard let digits = arguments["digits"] as? String else {return}
            if let activeCall = self.call {
                activeCall.sendDigits(digits);
            }
        }
         else if flutterCall.method == "getActiveCallOnResumeFromTerminatedState"
        {
            let isCallAnswered = self.call != nil
            if let activeCall = self.call {
                let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
                let from = extractUserNumber(from: activeCall.from ?? self.identity)
                let to = activeCall.to ?? self.callTo
                self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)
            }
            result(true)
        }


        /* else if flutterCall.method == "receiveCalls"
         {
         guard let clientIdentity = arguments["clientIdentifier"] as? String else {return}
         self.identity = clientIdentity;
         } */
        else if flutterCall.method == "holdCall" {
            guard let shouldHold = arguments["shouldHold"] as? Bool else {return}
            
            if let activeCall = self.call {
                let hold = activeCall.isOnHold
                if(shouldHold && !hold) {
                    activeCall.isOnHold = true
                    guard let eventSink = eventSink else {
                        return
                    }
                    eventSink("Hold")
                } else if(!shouldHold && hold) {
                    activeCall.isOnHold = false
                    guard let eventSink = eventSink else {
                        return
                    }
                    eventSink("Unhold")
                }
            }
        }
        else if flutterCall.method == "isHolding" {
            // guard call not nil
            guard let activeCall = self.call else {
                return;
            }
            
            // toggle state current state
            let isOnHold = activeCall.isOnHold;
            activeCall.isOnHold = !isOnHold;
            
            // guard event sink not nil & post update
            guard let eventSink = eventSink else {
                return
            }
            eventSink(!isOnHold ? "Hold" : "Unhold")
        }
        else if flutterCall.method == "answer" {
            // Find the most recent call invite to answer
            if let (_, ci) = self.callInvites.first {
                self.sendPhoneCallEvents(description: "LOG|answer method invoked, uuid=\(ci.uuid)", isError: false)
                self.answerCall(callInvite: ci)
            } else {
                let ferror: FlutterError = FlutterError(code: "ANSWER_ERROR", message: "No call invite to answer", details: nil)
                _result!(ferror)
            }
        }
        else if flutterCall.method == "unregister" {
            guard let deviceToken = deviceToken else {
                return
            }
            if let token = arguments["accessToken"] as? String{
                self.unregisterTokens(token: token, deviceToken: deviceToken)
            }else if let token = accessToken{
                self.unregisterTokens(token: token, deviceToken: deviceToken)
            }
            
        }else if flutterCall.method == "hangUp"{
            // Hang up on-going/active call
            // IMPORTANT: Cancel any pending audio route operations first.
            // Delayed audio session changes (from toggleBluetooth/toggleSpeaker) can
            // interfere with CallKit's end-call transaction and cause hangup to fail.
            cancelPendingAudioRouteWorkItems()
            
            if let activeCall = self.call, let uuid = activeCall.uuid {
                self.sendPhoneCallEvents(description: "LOG|hangUp method invoked, uuid=\(uuid)", isError: false)
                self.userInitiatedDisconnect = true
                performEndCallAction(uuid: uuid)
            } else if let (_, ci) = self.callInvites.first {
                // Reject pending call invite
                performEndCallAction(uuid: ci.uuid)
            }
        }else if flutterCall.method == "registerClient"{
            guard let clientId = arguments["id"] as? String, let clientName =  arguments["name"] as? String else {return}
            if clients[clientId] == nil || clients[clientId] != clientName{
                clients[clientId] = clientName
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
            
        }else if flutterCall.method == "unregisterClient"{
            guard let clientId = arguments["id"] as? String else {return}
            clients.removeValue(forKey: clientId)
            UserDefaults.standard.set(clients, forKey: kClientList)
            
        }else if flutterCall.method == "defaultCaller"{
            guard let caller = arguments["defaultCaller"] as? String else {return}
            defaultCaller = caller
            if(clients["defaultCaller"] == nil || clients["defaultCaller"] != defaultCaller){
                clients["defaultCaller"] = defaultCaller
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
        }else if flutterCall.method == "hasMicPermission" {
            let permission = AVAudioSession.sharedInstance().recordPermission
            result(permission == .granted)
            return
        }else if flutterCall.method == "requestMicPermission"{
            switch(AVAudioSession.sharedInstance().recordPermission){
            case .granted:
                result(true)
            case .denied:
                result(false)
            case .undetermined:
                AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                    result(granted)
                })
            @unknown default:
                result(false)
            }
            return
        } else if flutterCall.method == "hasBluetoothPermission" {
            result(true)
            return
        }else if flutterCall.method == "requestBluetoothPermission"{
            result(true)
            return
        } else if flutterCall.method == "showNotifications" {
            guard let show = arguments["show"] as? Bool else{return}
            let prefsShow = UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true
            if show != prefsShow{
                UserDefaults.standard.setValue(show, forKey: "show-notifications")
            }
            result(true)
            return
        } else if flutterCall.method == "updateCallKitIcon" {
            let newIcon = arguments["icon"] as? String ?? defaultCallKitIcon
            
            // update icon & persist
            result(updateCallKitIcon(icon: newIcon))
            return
        }
        result(true)
    }
    
    /// Updates the CallkitProvider configuration with a new icon, and saves this change to future use.
    /// - Parameter icon: icon path / name
    /// - Returns: true if succesful
    func updateCallKitIcon(icon: String) -> Bool {
        if let newIcon = UIImage(named: icon) {
            let configuration = callKitProvider.configuration;
            
            // set new callkit icon
            configuration.iconTemplateImageData = newIcon.pngData()
            callKitProvider.configuration = configuration
         
            // save new icon to persist across sessions
            UserDefaults.standard.set(icon, forKey: defaultCallKitIcon)
            
            return true;
        }
        
        return false;
    }

    func answerCall(callInvite: CallInvite) {
        let answerCallAction = CXAnswerCallAction(call: callInvite.uuid)
        let transaction = CXTransaction(action: answerCallAction)

        callKitCallController.request(transaction)  { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|AnswerCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
        }
    }

    func makeCall(to: String)
    {
        // Check if there's a pending call invite
        if !self.callInvites.isEmpty {
            self.sendPhoneCallEvents(description: "LOG|Cannot make call - there's a pending incoming call", isError: false)
            let ferror: FlutterError = FlutterError(code: "CALL_IN_PROGRESS", message: "Cannot make call while there's a pending incoming call", details: nil)
            _result?(ferror)
            return
        }
        
        // Cancel the previous call before making another one.
        if let activeCall = self.call, let uuid = activeCall.uuid {
            self.userInitiatedDisconnect = true
            performEndCallAction(uuid: uuid)            
        } else {
            let uuid = UUID()
            
            self.checkRecordPermission { (permissionGranted) in
                if (!permissionGranted) {
                    let alertController: UIAlertController = UIAlertController(title: String(format:  NSLocalizedString("mic_permission_title", comment: "") , SwiftTwilioVoicePlugin.appName),
                                                                               message: NSLocalizedString( "mic_permission_subtitle", comment: ""),
                                                                               preferredStyle: .alert)
                    
                    let continueWithMic: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_continue_no_mic", comment: ""),
                                                                       style: .default,
                                                                       handler: { (action) in
                                                                        self.performStartCallAction(uuid: uuid, handle: to)
                                                                       })
                    alertController.addAction(continueWithMic)
                    
                    let goToSettings: UIAlertAction = UIAlertAction(title:NSLocalizedString("btn_settings", comment: ""),
                                                                    style: .default,
                                                                    handler: { (action) in
                                                                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                                  options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: false],
                                                                                                  completionHandler: nil)
                                                                    })
                    alertController.addAction(goToSettings)
                    
                    let cancel: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_cancel", comment: ""),
                                                              style: .cancel,
                                                              handler: { (action) in
                                                                //self.toggleUIState(isEnabled: true, showCallControl: false)
                                                                //self.stopSpin()
                                                              })
                    alertController.addAction(cancel)
                    guard let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() else {
                        return
                    }
                    currentViewController.present(alertController, animated: true, completion: nil)
                    
                } else {
                    self.performStartCallAction(uuid: uuid, handle: to)
                }
            }
        }
    }
    
    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            // Record permission already granted.
            completion(true)
            break
        case .denied:
            // Record permission denied.
            completion(false)
            break
        case .undetermined:
            // Requesting record permission.
            // Optional: pop up app dialog to let the users know if they want to request.
            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                completion(granted)
            })
            break
        default:
            completion(false)
            break
        }
    }
    
    
    // MARK: PKPushRegistryDelegate
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        guard registrationRequired() || deviceToken != credentials.token else {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials device token unchanged, no update needed.", isError: false)
            return
        }

        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType: device token updated", isError: false)
        let deviceToken = credentials.token
        
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
        if let token = accessToken {
            // CRITICAL: Ensure our custom audio device is set
            TwilioVoiceSDK.audioDevice = self.audioDevice
            
            TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { (error) in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    self.sendPhoneCallEvents(description: "DEVICETOKEN|\(String(decoding: deviceToken, as: UTF8.self))", isError: false)
                }
                else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        }
        self.deviceToken = deviceToken
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)

    }
    
    /**
      * The TTL of a registration is 1 year. The TTL for registration for this device/identity pair is reset to
      * 1 year whenever a new registration occurs or a push notification is sent to this device/identity pair.
      * This method checks if binding exists in UserDefaults, and if half of TTL has been passed then the method
      * will return true, else false.
      */
     func registrationRequired() -> Bool {
         guard let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate) else {
             self.sendPhoneCallEvents(description: "LOG|Registration required: true, last binding date not found", isError: false)
             return true
         }

         let date = Date()
         var components = DateComponents()
         components.setValue(kRegistrationTTLInDays/2, for: .day)
         let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated as! Date)!

         if expirationDate.compare(date) == ComparisonResult.orderedDescending {
             self.sendPhoneCallEvents(description: "LOG|Registration required: false, half of TTL not passed", isError: false)
             return false
         }
         return true;
     }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didInvalidatePushTokenForType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        self.unregister()
    }
    
    func unregister() {
        
        guard let deviceToken = deviceToken, let token = accessToken else {
            self.sendPhoneCallEvents(description: "LOG|Missing required parameters to unregister", isError: false)
            return
        }
        
        self.unregisterTokens(token: token, deviceToken: deviceToken)
    }
    
    func unregisterTokens(token: String, deviceToken: Data) {
        TwilioVoiceSDK.unregister(accessToken: token, deviceToken: deviceToken) { (error) in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|An error occurred while unregistering: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Successfully unregistered from VoIP push notifications.", isError: false)
            }
        }
        //DO NOT REMOVE DEVICE TOKEN , AS IT IS UNNECESSARY AND USER WILL HAVE TO RESTART THE APP TO GET NEW DEVICE TOKEN
        //IF WE REMOVED FROM HERE , WHICH WILL CAUSE TO FAILURE IN REGISTRATION
        //UserDefaults.standard.removeObject(forKey: kCachedDeviceToken)

        // Remove the cached binding as credentials are invalidated
        //UserDefaults.standard.removeObject(forKey: kCachedBindingDate)
    }
    
    /**
     * Try using the `pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:` method if
     * your application is targeting iOS 11. According to the docs, this delegate method is deprecated by Apple.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:", isError: false)
        
        if (type == PKPushType.voIP) {
            // Ensure custom audio device is set before handling notification
            TwilioVoiceSDK.audioDevice = self.audioDevice
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
    }
    
    /**
     * This delegate method is available on iOS 11 and above. Call the completion handler once the
     * notification payload is passed to the `TwilioVoice.handleNotification()` method.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:completion:", isError: false)
        
        // Save for later when the notification is properly handled.
//        self.incomingPushCompletionCallback = completion
        
        if (type == PKPushType.voIP) {
            // Ensure custom audio device is set before handling notification
            // Critical for terminated state where the SDK might not have been configured yet
            TwilioVoiceSDK.audioDevice = self.audioDevice
            TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
        
        if let version = Float(UIDevice.current.systemVersion), version < 13.0 {
            // Save for later when the notification is properly handled.
            self.incomingPushCompletionCallback = completion
        } else {
            /**
             * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
             * CallKit and fulfill the completion before exiting this callback method.
             */
            completion()
        }
    }

    // MARK: CXCallObserverDelegate
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let uuid = call.uuid

        if call.hasEnded {
            activeCXCalls.removeValue(forKey: uuid) // Remove ended calls
        } else {
            activeCXCalls[uuid] = call // Add or update call
        }
    }

    // Check if a call with a given UUID exists
    func isCallActive(uuid: UUID) -> Bool {
        return activeCXCalls[uuid] != nil
    }

    func incomingPushHandled() {
        if let completion = self.incomingPushCompletionCallback {
            self.incomingPushCompletionCallback = nil
            completion()
        }
    }
    
    // MARK: TVONotificaitonDelegate
    public func callInviteReceived(callInvite: CallInvite) {
        self.sendPhoneCallEvents(description: "LOG|callInviteReceived: uuid=\(callInvite.uuid)", isError: false)
        
        /**
         * The TTL of a registration is 1 year. The TTL for registration for this device/identity
         * pair is reset to 1 year whenever a new registration occurs or a push notification is
         * sent to this device/identity pair.
         */
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        let incomingCallerDetails:String = callInvite.from ?? defaultCaller
        let userNumber:String = extractUserNumber(from: incomingCallerDetails)
        let client:String = callInvite.customParameters?["client_name"] ?? userNumber
         var from:String = callInvite.from ?? defaultCaller
         from = userNumber

        // If there's already an active call, send IncomingWhileActive instead of Ringing
        // This prevents the Dart parser from overwriting call.activeCall with the new call's data
        // Matches Android behavior which also sends IncomingWhileActive when callSid != null
        if !self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: active call exists, sending IncomingWhileActive", isError: false)
            self.sendPhoneCallEvents(description: "IncomingWhileActive|\(from)|\(callInvite.to ?? "")|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to ?? "")|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        }
         reportIncomingCall(from: client, uuid: callInvite.uuid)
         self.callInvites[callInvite.uuid] = callInvite
     }

    func extractUserNumber(from input: String) -> String {
        // Define the regular expression pattern to match the user_number part
        let pattern = #"user_number:([^\s:]+)"#

        // Create a regular expression object
        let regex = try? NSRegularExpression(pattern: pattern)

        // Search for the first match in the input string
        if let match = regex?.firstMatch(in: input, range: NSRange(location: 0, length: input.utf16.count)) {
            // Extract the matched part (user_number:+11230123)
            if let range = Range(match.range(at: 1), in: input) {
                return String(input[range])
            }
        }
        // Return the input if no match is found
        return input
    }


    func formatCustomParams(params: [String:Any]?)->String{
        guard let customParameters = params else{return ""}
        do{
            let jsonData = try JSONSerialization.data(withJSONObject: customParameters)
            if let jsonStr = String(data: jsonData, encoding: .utf8){
                return "|\(jsonStr )"
            }
        }catch{
            print("unable to send custom parameters")
        }
        return ""
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|cancelledCallInviteCanceled:", isError: false)
        
        // Find and remove the matching call invite by comparing callSid
        var matchingUUID: UUID? = nil
        for (uuid, invite) in self.callInvites {
            if invite.callSid == cancelledCallInvite.callSid {
                matchingUUID = uuid
                break
            }
        }
        
        if let uuid = matchingUUID {
            self.callInvites.removeValue(forKey: uuid)
            performEndCallAction(uuid: uuid)
        } else {
            self.sendPhoneCallEvents(description: "LOG|No pending call invite matching cancelled invite", isError: false)
        }
        
        // Only send "Missed Call" if no other active calls remain
        if self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "Missed Call", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "LOG|Cancelled call invite but other calls active, suppressing Missed Call event", isError: false)
        }
    }
    
    func showMissedCallNotification(from:String?, to:String?){
        guard UserDefaults.standard.optionalBool(forKey: "show-notifications") ?? true else{return}
        let notificationCenter = UNUserNotificationCenter.current()

       
        notificationCenter.getNotificationSettings { (settings) in
          if settings.authorizationStatus == .authorized {
            let content = UNMutableNotificationContent()
            var userName:String?
            if var from = from{
                from = from.replacingOccurrences(of: "client:", with: "")
                content.userInfo = ["type":"twilio-missed-call", "From":from]
                if let to = to{
                    content.userInfo["To"] = to
                }
                userName = self.clients[from]
            }
            
            let title = userName ?? self.clients["defaultCaller"] ?? self.defaultCaller
            content.title = String(format:  NSLocalizedString("notification_missed_call", comment: ""),title)

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString,
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
    
    // MARK: TVOCallDelegate
    public func callDidStartRinging(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = self.callOutgoing ? call.from ?? self.identity : extractUserNumber(from: (call.from ?? ""))
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Ringing|\(String(describing: from))|\(to)|\(direction)", isError: false)
        
        // Try to apply speaker setting early if audio session is ready
        if audioDevice.isEnabled && desiredSpeakerState {
            applySpeakerSetting(toSpeaker: desiredSpeakerState)
        }
    }
    
    public func callDidConnect(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = extractUserNumber(from:(call.from ?? self.identity))
        let to = (call.to ?? self.callTo)
        
        // Track this call as the active call
        if let uuid = call.uuid {
            self.activeCallUUID = uuid
            self.calls[uuid] = call
        }
        
        self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)
        
        if let callKitCompletionCallback = callKitCompletionCallback {
            callKitCompletionCallback(true)
        }
        
        // Mark that we've done the initial Bluetooth check for this call
        hasCheckedBluetoothOnCallStart = true
        
        // DO NOT report Bluetooth availability here — the audio session may have
        // phantom BT in currentRoute due to CallKit's default .allowBluetooth setup.
        // applyInitialAudioRoute() (called from didActivateAudioSession) will handle
        // proper BT detection and send the correct AudioRoute event to Dart.
        // Just log for debugging.
        let currentRoute = getAudioRoute()
        self.sendPhoneCallEvents(description: "LOG|Call connected. Current audio route: \(currentRoute) (NOT sending AudioRoute event — deferred to applyInitialAudioRoute)", isError: false)
    }
    
    public func call(call: Call, isReconnectingWithError error: Error) {
        self.sendPhoneCallEvents(description: "Reconnecting", isError: false)
        
    }
    
    public func callDidReconnect(call: Call) {
        self.sendPhoneCallEvents(description: "Reconnected", isError: false)
    }
    
    public func callDidFailToConnect(call: Call, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|Call failed to connect: \(error.localizedDescription)", isError: false)
        
        if(error.localizedDescription.contains("Access Token expired")){
            self.sendPhoneCallEvents(description: "DEVICETOKEN", isError: false)
        }
        if let completion = self.callKitCompletionCallback {
            completion(false)
        }
        
        if let uuid = call.uuid {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: CXCallEndedReason.failed)
            callDisconnected(uuid: uuid)
        }
        
        // Only send "Call Ended" if no other calls remain
        if self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "LOG|Call failed but other calls remain, suppressing Call Ended", isError: false)
            // Unhold the remaining call
            unholdRemainingCall()
        }
    }
    
    public func callDidDisconnect(call: Call, error: Error?) {
        if let error = error {
            // IMPORTANT: Send as normal event, NOT isError:true.
            // isError:true wraps in FlutterError which crashes the Dart event stream
            // listener (no onError handler). The Dart parser handles "Call Ended" below.
            self.sendPhoneCallEvents(description: "LOG|Call Failed: \(error.localizedDescription)", isError: false)
        }
        
        if !self.userInitiatedDisconnect {
            var reason = CXCallEndedReason.remoteEnded
            self.sendPhoneCallEvents(description: "LOG|Remote disconnect", isError: false)
            if error != nil {
                reason = .failed
            }
            
            if let uuid = call.uuid {
                self.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            }
        }
        
        // IMPORTANT: Capture activeCallUUID BEFORE callDisconnected() clears it.
        // callDisconnected sets activeCallUUID = nil when the ending call IS the
        // active call. We need the original value to correctly determine whether
        // the ending call was the active call (Call B) or the held call (Call A).
        let wasActiveCallUUID = self.activeCallUUID
        
        if let uuid = call.uuid {
            callDisconnected(uuid: uuid)
        }
        
        // Only send "Call Ended" if no other calls remain
        if self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "LOG|Call disconnected but other calls remain, suppressing Call Ended", isError: false)
            
            // Check if the disconnected call was the held call (not the active one).
            // Use the SAVED wasActiveCallUUID — not self.activeCallUUID which was
            // already cleared by callDisconnected(). Without this, the check would
            // always pass (uuid != nil) and incorrectly send "Held Call Ended" even
            // when the ACTIVE call (Call B) ended, which would clear the saved
            // held-call data (Call A) before the Unhold event can restore it.
            if let uuid = call.uuid, uuid != wasActiveCallUUID {
                // The held call ended remotely - notify Flutter to clear the held call banner
                self.sendPhoneCallEvents(description: "Held Call Ended", isError: false)
            }
            
            // Unhold the remaining call and restore its info
            unholdRemainingCall()
        }
    }
    
    /// Unhold the remaining call after the other call ends
    private func unholdRemainingCall() {
        guard let remainingUUID = self.calls.keys.first,
              let remainingCall = self.calls[remainingUUID] else {
            return
        }
        
        self.activeCallUUID = remainingUUID
        
        if remainingCall.isOnHold {
            self.sendPhoneCallEvents(description: "LOG|Unholding remaining call via CallKit uuid=\(remainingUUID)", isError: false)
            
            // Use CallKit to unhold so the audio session is properly restored
            // Directly setting call.isOnHold = false on Twilio SDK does NOT restore audio
            // because CallKit manages the iOS audio session for VoIP calls.
            let unholdAction = CXSetHeldCallAction(call: remainingUUID, onHold: false)
            let transaction = CXTransaction(action: unholdAction)
            callKitCallController.request(transaction) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|Unhold via CallKit failed: \(error.localizedDescription), falling back to direct unhold", isError: false)
                    // Fallback: set unhold directly on Twilio SDK
                    remainingCall.isOnHold = false
                    self.sendPhoneCallEvents(description: "Unhold", isError: false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|Unhold via CallKit succeeded for \(remainingUUID)", isError: false)
                    // Note: The CXSetHeldCallAction delegate (provider:performSetHeldCallAction:)
                    // will handle setting call.isOnHold = false and sending "Unhold" event to Flutter
                }
            }
        }
    }
    
    func callDisconnected(uuid: UUID) {
        self.sendPhoneCallEvents(description: "LOG|Call Disconnected uuid=\(uuid)", isError: false)
        
        // Remove this specific call from dictionaries
        self.calls.removeValue(forKey: uuid)
        self.callInvites.removeValue(forKey: uuid)
        
        // If this was the active call, clear activeCallUUID
        if self.activeCallUUID == uuid {
            self.activeCallUUID = nil
        }
        
        // Only reset global state if no calls remain
        if self.calls.isEmpty && self.callInvites.isEmpty {
            self.callOutgoing = false
            self.userInitiatedDisconnect = false
            
            // Cancel any remaining pending audio route operations
            cancelPendingAudioRouteWorkItems()
            
            // Reset audio state when ALL calls end
            desiredSpeakerState = false
            desiredBluetoothState = false
            userExplicitlyChangedAudioRoute = false
            cachedBluetoothAvailable = false
            hasCheckedBluetoothOnCallStart = false
            lastBluetoothDisconnectTime = nil
            suppressAudioRouteEvents = false
        } else {
            // Reset just userInitiatedDisconnect for next action
            self.userInitiatedDisconnect = false
        }
    }
    
    func isSpeakerOn() -> Bool {
        // If no active call, return the desired state
        guard !self.calls.isEmpty else {
            return desiredSpeakerState
        }
        
        // Source: https://stackoverflow.com/a/51759708/4628115
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        for output in currentRoute.outputs {
            switch output.portType {
                case AVAudioSession.Port.builtInSpeaker:
                    return true;
                default:
                    continue; // Check other outputs
            }
        }
        return false;
    }

    // TODO
    func isBluetoothOn() -> Bool {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        for output in currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                return true
            }
        }
        return false
    }

    /// Get the current audio route: 'earpiece', 'speaker', 'bluetooth', or 'wired_headset'
    /// Checks actual system route first, then falls back to desired state for speaker.
    /// For Bluetooth, ONLY reports 'bluetooth' if BT is in the actual currentRoute.
    func getAudioRoute() -> String {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        // First: check actual system route for Bluetooth (most reliable)
        for output in currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'bluetooth' from actual currentRoute output", isError: false)
                return "bluetooth"
            }
        }
        
        // Check inputs too (BT mic might be the indicator)
        for input in currentRoute.inputs {
            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'bluetooth' from actual currentRoute input", isError: false)
                return "bluetooth"
            }
        }
        
        // If desiredBluetoothState was true but BT is not in currentRoute,
        // it's phantom or disconnected — clear the stale flag
        if desiredBluetoothState {
            self.sendPhoneCallEvents(description: "LOG|getAudioRoute: desiredBluetoothState=true but no BT in currentRoute — clearing stale flag", isError: false)
            desiredBluetoothState = false
        }
        
        // Check for speaker — trust desiredSpeakerState since speaker is reliable
        if desiredSpeakerState {
            self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'speaker' from desiredSpeakerState", isError: false)
            return "speaker"
        }
        
        // Check actual system route for speaker as fallback
        for output in currentRoute.outputs {
            if output.portType == .builtInSpeaker {
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'speaker' from actual currentRoute", isError: false)
                return "speaker"
            }
        }
        
        // Default: earpiece
        self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'earpiece'", isError: false)
        return "earpiece"
    }
    
    /// Get the ACTUAL system audio route (not the desired state)
    func getActualSystemAudioRoute() -> String {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        
        for output in currentRoute.outputs {
            switch output.portType {
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
                return "bluetooth"
            case .builtInSpeaker:
                return "speaker"
            case .headphones, .headsetMic:
                return "wired_headset"
            case .builtInReceiver:
                return "earpiece"
            default:
                break
            }
        }
        
        // Default to earpiece if no outputs found
        return "earpiece"
    }

    /// Force a fresh Bluetooth availability check by temporarily enabling Bluetooth options.
    /// After adding .allowBluetooth to the category, checks currentRoute (not availableInputs).
    /// Then switches to a CLEAN category (NO BT options) to verify — if BT disappears,
    /// it was phantom. Finally restores original category.
    private func checkBluetoothAvailableFresh() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // First: Check current route - if we're already on Bluetooth, it's available
        for output in audioSession.currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Found in current route outputs", isError: false)
                return true
            }
        }
        for input in audioSession.currentRoute.inputs {
            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Found in current route inputs", isError: false)
                return true
            }
        }
        
        // Second: Temporarily enable Bluetooth options to detect newly connected devices
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            let originalCategory = audioSession.category
            let originalMode = audioSession.mode
            let originalOptions = audioSession.categoryOptions
            
            // Enable Bluetooth options temporarily
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            Thread.sleep(forTimeInterval: 0.05)
            
            // Check if BT now appears in currentRoute
            var foundBluetoothDuringTempCategory = false
            for output in audioSession.currentRoute.outputs {
                if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                    self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: BT found in route during temp category: \(output.portName)", isError: false)
                    foundBluetoothDuringTempCategory = true
                    break
                }
            }
            if !foundBluetoothDuringTempCategory {
                for input in audioSession.currentRoute.inputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: BT found in inputs during temp category: \(input.portName)", isError: false)
                        foundBluetoothDuringTempCategory = true
                        break
                    }
                }
            }
            
            if !foundBluetoothDuringTempCategory {
                // No BT even with .allowBluetooth — restore and return false
                try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: No BT device found", isError: false)
                return false
            }
            
            // VERIFICATION: Switch to clean category (NO BT options) to check
            // if BT persists. Phantom BT only exists with .allowBluetooth.
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            Thread.sleep(forTimeInterval: 0.05)
            
            var stillHasBluetooth = false
            for output in audioSession.currentRoute.outputs {
                if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                    stillHasBluetooth = true
                    break
                }
            }
            if !stillHasBluetooth {
                for input in audioSession.currentRoute.inputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        stillHasBluetooth = true
                        break
                    }
                }
            }
            
            // Restore original category
            try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            
            if stillHasBluetooth {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: VERIFIED — BT persists without .allowBluetooth → REAL", isError: false)
                return true
            } else {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: BT DISAPPEARED without .allowBluetooth → PHANTOM, rejecting", isError: false)
                return false
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Error - \(error.localizedDescription)", isError: false)
            return false
        }
    }

    /// Check whether a Bluetooth port represents a real external audio device.
    /// On iOS, when Bluetooth radio is ON but no audio device is connected/paired,
    /// some devices still list phantom .bluetoothHFP entries in availableInputs.
    ///
    /// NOTE: We previously used a `dataSources` heuristic (real devices have non-empty
    /// dataSources). This turned out to be WRONG — many real TWS earbuds (e.g. boAt
    /// Airdopes 91) report dataSources=0 even when connected and actively paired.
    /// The dataSources check was incorrectly rejecting real connected devices.
    ///
    /// Now we simply accept any BT port found in availableInputs. The phantom BT
    /// filtering is handled at a higher level by `isBluetoothAvailableClean()` which
    /// uses `checkBluetoothWithCategoryChange()` — the definitive test that temporarily
    /// removes .allowBluetooth from the category to see if BT persists in currentRoute.
    private func isRealBluetoothDevice(_ port: AVAudioSessionPortDescription) -> Bool {
        self.sendPhoneCallEvents(
            description: "LOG|isRealBluetoothDevice: port=\(port.portType.rawValue), name=\(port.portName), uid=\(port.uid), dataSources=\(port.dataSources?.count ?? 0) — ACCEPTED",
            isError: false
        )
        return true
    }

    /// Check if Bluetooth is available WITHOUT changing the AVAudioSession category.
    /// SAFE to call from handleAudioRouteChange — will NOT trigger cascading notifications.
    /// Only checks current route (outputs + inputs) — does NOT check availableInputs
    /// because that can list phantom BT entries when radio is on but no device connected.
    private func isBluetoothAvailableSafe(afterDisconnect: Bool = false) -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Check current route outputs — most reliable indicator of active BT audio
        for output in audioSession.currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                cachedBluetoothAvailable = true
                return true
            }
        }
        
        // Check current route inputs — BT mic might be active
        for input in audioSession.currentRoute.inputs {
            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                cachedBluetoothAvailable = true
                return true
            }
        }
        
        // DO NOT trust desiredBluetoothState for AVAILABILITY — it can be set by phantom BT
        // during checkBluetoothWithCategoryChange(). Only currentRoute is reliable.
        // desiredBluetoothState is ONLY used for getAudioRoute() to report the desired route.
        self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableSafe: No BT in currentRoute (desiredBT=\(desiredBluetoothState), afterDisconnect=\(afterDisconnect))", isError: false)
        
        cachedBluetoothAvailable = false
        return false
    }

    /// Deep check for Bluetooth availability using a temporary category change.
    /// Used at call start and when a new device connects.
    /// After temporarily adding .allowBluetooth to the category, checks if BT appears
    /// in currentRoute. Then switches to a CLEAN category (NO BT options) to verify —
    /// if BT disappears from currentRoute without BT options, it was a phantom entry.
    /// Finally restores the original category.
    private func checkBluetoothWithCategoryChange() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Use reentrancy guard to prevent cascading route change notifications
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            // Save current category settings so we can restore them at the end
            let originalCategory = audioSession.category
            let originalMode = audioSession.mode
            let originalOptions = audioSession.categoryOptions
            
            // Step 1: Temporarily set category WITH Bluetooth options to reveal BT devices
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            
            // Give iOS a brief moment to update the route after category change
            Thread.sleep(forTimeInterval: 0.05)
            
            // Step 2: Check if BT appears in currentRoute during temp category
            var foundBluetoothDuringTempCategory = false
            // Track whether BT was found via setPreferredInput — if so, we skip
            // the Step 3 destructive verification (remove .allowBluetooth) because
            // TWS earbuds that required setPreferredInput will definitely disappear
            // from currentRoute when .allowBluetooth is removed, but they ARE real.
            var foundViaPreferredInput = false
            
            for output in audioSession.currentRoute.outputs {
                if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                    self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT found in outputs during temp category: \(output.portType.rawValue) - \(output.portName)", isError: false)
                    foundBluetoothDuringTempCategory = true
                    break
                }
            }
            
            if !foundBluetoothDuringTempCategory {
                for input in audioSession.currentRoute.inputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT found in inputs during temp category: \(input.portType.rawValue) - \(input.portName)", isError: false)
                        foundBluetoothDuringTempCategory = true
                        break
                    }
                }
            }
            
            if !foundBluetoothDuringTempCategory {
                // BT didn't auto-appear in currentRoute with .allowBluetooth.
                // Many TWS earbuds (e.g. boAt Airdopes 91) don't auto-route just
                // because .allowBluetooth is in the category — they need
                // setPreferredInput to be called first. Try that now.
                if let availableInputs = audioSession.availableInputs {
                    let btInputs = availableInputs.filter {
                        $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
                    }
                    if let btInput = btInputs.first {
                        self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT NOT in currentRoute, trying setPreferredInput for \(btInput.portType.rawValue):\(btInput.portName)", isError: false)
                        do {
                            try audioSession.setPreferredInput(btInput)
                            try audioSession.overrideOutputAudioPort(.none)
                            // Give iOS time to route audio to the BT device
                            Thread.sleep(forTimeInterval: 0.1)
                            
                            // Check if BT now appears in currentRoute
                            for output in audioSession.currentRoute.outputs {
                                if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                                    self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT appeared after setPreferredInput → REAL device: \(output.portType.rawValue) - \(output.portName)", isError: false)
                                    foundBluetoothDuringTempCategory = true
                                    foundViaPreferredInput = true
                                    break
                                }
                            }
                            if !foundBluetoothDuringTempCategory {
                                for input in audioSession.currentRoute.inputs {
                                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                                        self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT appeared in inputs after setPreferredInput → REAL device: \(input.portType.rawValue) - \(input.portName)", isError: false)
                                        foundBluetoothDuringTempCategory = true
                                        foundViaPreferredInput = true
                                        break
                                    }
                                }
                            }
                            
                            // Clear preferred input so we don't force BT route
                            try? audioSession.setPreferredInput(nil)
                        } catch {
                            self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: setPreferredInput failed: \(error.localizedDescription)", isError: false)
                        }
                    }
                    
                    if !foundBluetoothDuringTempCategory {
                        if !btInputs.isEmpty {
                            self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT in availableInputs but NOT in currentRoute even after setPreferredInput — PHANTOM: \(btInputs.map { "\($0.portType.rawValue):\($0.portName):ds=\($0.dataSources?.count ?? 0)" })", isError: false)
                        } else {
                            self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: No BT found anywhere", isError: false)
                        }
                        
                        // Restore original category and return false
                        try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
                        cachedBluetoothAvailable = false
                        return false
                    }
                } else {
                    self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: No availableInputs", isError: false)
                    // Restore original category and return false
                    try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
                    cachedBluetoothAvailable = false
                    return false
                }
            }
            
            // Step 3: VERIFICATION — Switch to a CLEAN category with NO Bluetooth options.
            // Skip this for devices confirmed via setPreferredInput — those are
            // definitively REAL (audio was actually routed to them), but they will
            // disappear from currentRoute when .allowBluetooth is removed because
            // TWS earbuds like boAt Airdopes only stay routed when the category
            // explicitly allows BT. This step is only needed for devices that
            // auto-appeared in currentRoute with .allowBluetooth (could be phantom).
            if foundViaPreferredInput {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: SKIPPING Step 3 — device confirmed REAL via setPreferredInput (audio was actually routed)", isError: false)
                // Restore original category settings
                try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
                cachedBluetoothAvailable = true
                return true
            }
            
            // This is critical: we must NOT restore the original category for verification
            // because the original might already have .allowBluetooth (from a previous
            // applyBluetoothRoute call), which would keep phantom BT in the route.
            // Instead, use a category that explicitly excludes BT to test if the device
            // is truly connected or just a phantom that exists only with .allowBluetooth.
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            
            // Brief pause to let iOS update route after removing BT options
            Thread.sleep(forTimeInterval: 0.05)
            
            var stillHasBluetooth = false
            
            for output in audioSession.currentRoute.outputs {
                if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                    stillHasBluetooth = true
                    break
                }
            }
            
            if !stillHasBluetooth {
                for input in audioSession.currentRoute.inputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        stillHasBluetooth = true
                        break
                    }
                }
            }
            
            // Step 4: Restore original category settings
            try audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            
            if stillHasBluetooth {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: VERIFIED — BT persists even without .allowBluetooth → REAL device", isError: false)
                cachedBluetoothAvailable = true
                return true
            } else {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: BT DISAPPEARED without .allowBluetooth → PHANTOM, rejecting", isError: false)
                cachedBluetoothAvailable = false
                return false
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|checkBluetoothWithCategoryChange: Error - \(error.localizedDescription)", isError: false)
            return false
        }
    }

    /// Check if a Bluetooth device is available/connected.
    /// Called from method channel (Dart) to decide whether to show BT in audio popup.
    ///
    /// ONLY checks currentRoute — does NOT use availableInputs or category changes.
    /// Phantom BT entries can appear in availableInputs with dataSources populated,
    /// and can briefly appear in currentRoute during category changes with .allowBluetooth.
    /// The only 100% reliable indicator is the CURRENT active audio route.
    ///
    /// This means BT only shows in popup when audio is actively routed through it.
    /// If user switches to speaker/earpiece, BT won't show — this is acceptable
    /// because the user explicitly chose a different route.
    func isBluetoothAvailable() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        // Check outputs — most reliable indicator of active BT audio
        for output in currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable: BT in OUTPUT route: \(output.portType.rawValue) - \(output.portName)", isError: false)
                cachedBluetoothAvailable = true
                lastBluetoothDisconnectTime = nil
                return true
            }
        }
        
        // Check inputs — BT mic might be active
        for input in currentRoute.inputs {
            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable: BT in INPUT route: \(input.portType.rawValue) - \(input.portName)", isError: false)
                cachedBluetoothAvailable = true
                lastBluetoothDisconnectTime = nil
                return true
            }
        }
        
        self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable: No BT in currentRoute → false", isError: false)
        cachedBluetoothAvailable = false
        return false
    }
    
    /// Check if a REAL Bluetooth device is available — NON-DESTRUCTIVE.
    /// This method NEVER changes the audio session category, so it's safe to call
    /// at any time, including during an active call.
    ///
    /// How it works:
    /// 1. Check currentRoute outputs/inputs — if BT is the active route, it's definitely real
    /// 2. If BT is NOT in currentRoute, check availableInputs with isRealBluetoothDevice()
    ///    filter — real devices have dataSources, phantom entries don't
    /// 3. Also respect lastBluetoothDisconnectTime — after disconnect, stale BT entries
    ///    can linger in availableInputs for a few seconds
    func isBluetoothAvailableClean() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Check 1: Is BT currently the active output route? (most reliable)
        for output in audioSession.currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT in OUTPUT route: \(output.portType.rawValue) - \(output.portName) → true", isError: false)
                cachedBluetoothAvailable = true
                lastBluetoothDisconnectTime = nil
                return true
            }
        }
        
        // Check 2: Is BT currently the active input route?
        for input in audioSession.currentRoute.inputs {
            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT in INPUT route: \(input.portType.rawValue) - \(input.portName) → true", isError: false)
                cachedBluetoothAvailable = true
                lastBluetoothDisconnectTime = nil
                return true
            }
        }
        
        // Check 3: BT is not the active route, but is a real device available?
        // Since isRealBluetoothDevice() no longer filters by dataSources (some real
        // devices like boAt Airdopes report dataSources=0), we first check if ANY
        // BT entry exists in availableInputs. If found, we use the definitive
        // checkBluetoothWithCategoryChange() test to verify it's real and not phantom.
        //
        // GUARD: If BT was recently disconnected, don't trust availableInputs —
        // stale BT entries can linger for several seconds after disconnect.
        if let disconnectTime = lastBluetoothDisconnectTime {
            let elapsed = Date().timeIntervalSince(disconnectTime)
            if elapsed < 3.0 {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT recently disconnected (\(String(format: "%.1f", elapsed))s ago), not trusting availableInputs → false", isError: false)
                cachedBluetoothAvailable = false
                return false
            }
        }
        
        // Check if any BT entry exists in availableInputs
        var hasBtInAvailableInputs = false
        if let availableInputs = audioSession.availableInputs {
            for input in availableInputs {
                if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                    hasBtInAvailableInputs = true
                    self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT found in availableInputs: \(input.portType.rawValue) - \(input.portName) (dataSources=\(input.dataSources?.count ?? 0))", isError: false)
                    break
                }
            }
        }
        
        if hasBtInAvailableInputs {
            // BT is in availableInputs but NOT in currentRoute — this could be either:
            // (a) A real connected device that's just not the active route (user on earpiece/speaker)
            // (b) A phantom entry from BT radio being on but no device actually connected
            // Use the definitive category-change test to distinguish
            let isReal = self.checkBluetoothWithCategoryChange()
            self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT in availableInputs, category-change verification → \(isReal ? "REAL" : "PHANTOM")", isError: false)
            cachedBluetoothAvailable = isReal
            return isReal
        }
        
        self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: No real BT found → false", isError: false)
        cachedBluetoothAvailable = false
        return false
    }
    
    /// DEBUG: Log current audio session state
    private func logAudioSessionState(label: String) {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        var outputPorts = "["
        for (index, output) in currentRoute.outputs.enumerated() {
            if index > 0 { outputPorts += ", " }
            outputPorts += output.portType.rawValue
        }
        outputPorts += "]"
        
        let categoryStr = audioSession.category.rawValue
        let categoryOptions = audioSession.categoryOptions
        let modeStr = audioSession.mode.rawValue
        
        self.sendPhoneCallEvents(
            description: "LOG|[\(label)] Category: \(categoryStr), Mode: \(modeStr), Options: \(categoryOptions.rawValue), CurrentOutputs: \(outputPorts), DesiredBT: \(desiredBluetoothState), DesiredSpeaker: \(desiredSpeakerState)",
            isError: false
        )
    }

    /// Toggle Bluetooth audio routing
    func toggleBluetoothAudio(bluetoothOn: Bool) {
        self.sendPhoneCallEvents(description: "LOG|toggleBluetoothAudio: bluetoothOn=\(bluetoothOn)", isError: false)
        
        guard !self.calls.isEmpty else {
            self.sendPhoneCallEvents(description: "LOG|toggleBluetoothAudio: No active call", isError: false)
            return
        }
        
        // Cancel any previously scheduled audio route work items
        cancelPendingAudioRouteWorkItems()
        
        // Track state immediately (just Bool flags, safe on any thread)
        if bluetoothOn {
            self.desiredBluetoothState = true
            self.desiredSpeakerState = false
        } else {
            self.desiredBluetoothState = false
            self.desiredSpeakerState = false
            self.userExplicitlyChangedAudioRoute = true
        }
        
        // Move ALL AVAudioSession operations to background queue to avoid blocking the main/UI thread
        audioSessionQueue.async { [weak self] in
            guard let self = self else { return }
            let audioSession = AVAudioSession.sharedInstance()
            
            if bluetoothOn {
                // Enable Bluetooth
                self.logAudioSessionState(label: "BEFORE Bluetooth Toggle ON")
                
                do {
                    // Step 1: FIRST set category with Bluetooth options to make BT available again
                    self.isChangingAudioRoute = true
                    defer { self.isChangingAudioRoute = false }
                    try audioSession.setCategory(
                        AVAudioSession.Category.playAndRecord,
                        options: [.allowBluetoothA2DP, .allowBluetooth]
                    )
                    self.sendPhoneCallEvents(description: "LOG|Category set with Bluetooth options", isError: false)
                    
                    // Step 2: Wait a tiny bit for iOS to recognize BT devices after category change
                    // then find and set the Bluetooth input
                    self.scheduleAudioRouteWorkItem(delay: 0.1) { [weak self] in
                        guard let self = self, !self.calls.isEmpty else { return }
                        do {
                            // Re-fetch available inputs after category change
                            if let availableInputs = audioSession.availableInputs {
                                self.sendPhoneCallEvents(description: "LOG|Available inputs after category change: \(availableInputs.map { $0.portType.rawValue })", isError: false)
                                
                                var bluetoothFound = false
                                for input in availableInputs {
                                    if (input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE)
                                        && self.isRealBluetoothDevice(input) {
                                        try audioSession.setPreferredInput(input)
                                        self.sendPhoneCallEvents(description: "LOG|Set preferred input to Bluetooth: \(input.portName) (\(input.portType.rawValue))", isError: false)
                                        bluetoothFound = true
                                        break
                                    }
                                }
                                
                                if !bluetoothFound {
                                    self.sendPhoneCallEvents(description: "LOG|WARNING: No Bluetooth input found in available inputs!", isError: false)
                                }
                            }
                            
                            // Step 3: Make sure override is .none to use the Bluetooth route
                            try audioSession.overrideOutputAudioPort(.none)
                            
                            self.sendPhoneCallEvents(description: "LOG|Bluetooth enabled: category + preferred input + override(.none)", isError: false)
                            self.logAudioSessionState(label: "AFTER Bluetooth Toggle ON")
                        } catch {
                            self.sendPhoneCallEvents(description: "LOG|Failed to set Bluetooth input: \(error.localizedDescription)", isError: false)
                        }
                    }
                } catch {
                    self.sendPhoneCallEvents(description: "LOG|Failed to set category for Bluetooth: \(error.localizedDescription)", isError: false)
                }
            } else {
                // Disable Bluetooth - route to earpiece
                self.sendPhoneCallEvents(description: "LOG|=== EARPIECE SWITCH START ===", isError: false)
                
                // Step 1: Immediate audio switch via setPreferredInput + overrideOutputAudioPort
                self.forceEarpieceRoute()
                
                // Step 2: Apply category options to lock in earpiece (deferred to avoid audio lag)
                // NOTE: We do NOT restore BT options afterward — that would cause a second
                // setCategory() which disrupts audio and exposes phantom BT ports.
                // BT options are only added when the user explicitly selects Bluetooth.
                self.scheduleAudioRouteWorkItem(delay: 0.5) { [weak self] in
                    guard let self = self, !self.calls.isEmpty else { return }
                    self.applyEarpieceCategoryOptions()
                }
            }
        }
    }
    
    // MARK: - Cancellable Audio Route Work Items
    
    /// Schedule a delayed audio route operation that can be cancelled on hangup.
    /// Each work item also checks if calls are still active before executing.
    /// Runs on the dedicated audioSessionQueue to avoid blocking the main/UI thread.
    private func scheduleAudioRouteWorkItem(delay: TimeInterval, block: @escaping () -> Void) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Double-check: skip if no calls remain (hangup already happened)
            guard !self.calls.isEmpty else {
                self.sendPhoneCallEvents(description: "LOG|Audio route work item skipped - no active calls", isError: false)
                return
            }
            block()
        }
        pendingAudioRouteWorkItems.append(workItem)
        audioSessionQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    /// Cancel all pending delayed audio route operations.
    /// Called before hangup to prevent AVAudioSession changes during CallKit teardown.
    private func cancelPendingAudioRouteWorkItems() {
        if !pendingAudioRouteWorkItems.isEmpty {
            self.sendPhoneCallEvents(description: "LOG|Cancelling \(pendingAudioRouteWorkItems.count) pending audio route work items", isError: false)
            for item in pendingAudioRouteWorkItems {
                item.cancel()
            }
            pendingAudioRouteWorkItems.removeAll()
        }
    }
    
    /// Force audio to earpiece using overrideOutputAudioPort and setPreferredInput ONLY.
    /// Does NOT call setCategory() because that tears down and rebuilds the entire audio
    /// pipeline, causing a 1-4s lag where audio still comes from the old output device.
    /// Category options (to remove BT) are changed separately in a delayed work item.
    private func forceEarpieceRoute() {
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Log current state
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: Current outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
            
            // Step 1: Set built-in mic as preferred to steer away from Bluetooth
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try session.setPreferredInput(input)
                        self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: Set preferredInput to builtInMic", isError: false)
                        break
                    }
                }
            }
            
            // Step 2: Override to earpiece (not speaker) — takes effect immediately
            try session.overrideOutputAudioPort(.none)
            
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: After - outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute FAILED: \(error.localizedDescription)", isError: false)
        }
    }
    
    /// Set category options for earpiece mode (removes BT to prevent auto-switch back).
    /// This is called with a delay AFTER forceEarpieceRoute() has already switched audio output.
    /// Separating this from the route change prevents the setCategory() audio pipeline rebuild
    /// from causing audible lag during the switch.
    private func applyEarpieceCategoryOptions() {
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Set category WITHOUT Bluetooth options to prevent iOS auto-switching back to BT
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: []  // NO Bluetooth - forces built-in devices
            )
            
            // Re-apply earpiece route after category change (category change can reset route)
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try session.setPreferredInput(input)
                        break
                    }
                }
            }
            try session.overrideOutputAudioPort(.none)
            
            self.sendPhoneCallEvents(description: "LOG|applyEarpieceCategoryOptions: category set, earpiece re-applied", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applyEarpieceCategoryOptions FAILED: \(error.localizedDescription)", isError: false)
        }
    }
    
    /// Restore Bluetooth options in category while keeping current route (earpiece or speaker)
    /// NOTE: We no longer restore Bluetooth options automatically because iOS auto-switches
    /// to Bluetooth when .allowBluetooth is in category options, even with preferredInput set.
    /// Instead, Bluetooth options are only added when user explicitly selects Bluetooth.
    private func restoreBluetoothOptionsKeepingCurrentRoute() {
        // Restore Bluetooth category options so BT devices appear in availableInputs,
        // but maintain the current audio route (speaker/earpiece) so iOS doesn't auto-switch to BT.
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        let session = AVAudioSession.sharedInstance()
        let currentOutputs = session.currentRoute.outputs.map { $0.portType.rawValue }
        self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: Restoring BT category options. Current outputs = \(currentOutputs)", isError: false)
        
        do {
            if desiredSpeakerState {
                // On speaker: Add BT options alongside speaker, then re-apply speaker override
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth]
                )
                // Re-apply speaker override to prevent iOS from switching to BT
                try session.overrideOutputAudioPort(.speaker)
                self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: BT options restored, speaker override re-applied", isError: false)
            } else {
                // On earpiece: Add BT options, set built-in mic as preferred to stay on earpiece
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothA2DP, .allowBluetooth]
                )
                // Set built-in mic as preferred to prevent auto-switch to BT
                if let availableInputs = session.availableInputs {
                    for input in availableInputs {
                        if input.portType == .builtInMic {
                            try session.setPreferredInput(input)
                            break
                        }
                    }
                }
                try session.overrideOutputAudioPort(.none)
                self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: BT options restored, earpiece maintained", isError: false)
            }
            
            // Update cache: check if BT is now visible in availableInputs
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if (input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE)
                        && isRealBluetoothDevice(input) {
                        cachedBluetoothAvailable = true
                        self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: BT device found in inputs after restore: \(input.portName)", isError: false)
                        return
                    }
                }
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: Failed - \(error.localizedDescription)", isError: false)
        }
    }

    // MARK: AVAudioSession
    func toggleAudioRoute(toSpeaker: Bool) {
        // Store the desired speaker state
        desiredSpeakerState = toSpeaker
        
        // If no active call, just store the preference
        guard !self.calls.isEmpty else {
            self.sendPhoneCallEvents(description: "LOG|Storing speaker preference: \(toSpeaker) - no active call", isError: false)
            return
        }
        
        // Apply the speaker setting immediately
        applySpeakerSetting(toSpeaker: toSpeaker)
    }
    
    private func applySpeakerSetting(toSpeaker: Bool) {
        // Cancel any previously scheduled audio route work items
        cancelPendingAudioRouteWorkItems()
        
        // Track the desired audio state immediately (these are just Bool flags, safe on any thread)
        self.desiredSpeakerState = toSpeaker
        self.desiredBluetoothState = false
        self.userExplicitlyChangedAudioRoute = true
        
        // Move ALL AVAudioSession operations to background queue to avoid blocking the main/UI thread.
        audioSessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.logAudioSessionState(label: "BEFORE applySpeakerSetting toSpeaker=\(toSpeaker)")
            
            if toSpeaker {
                // === SPEAKER SWITCH ===
                // Step 1: Immediate audio switch via overrideOutputAudioPort (no setCategory!)
                // This takes effect within milliseconds — audio moves to speaker instantly.
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER START ===", isError: false)
                self.forceSpeakerRoute()
                
                // Step 2: After a short delay, apply category options to lock in speaker.
                // The setCategory() call rebuilds the audio pipeline, but since speaker
                // override is already active, the user won't hear any route change.
                // NOTE: We do NOT restore BT options afterward — that would cause a second
                // setCategory() which disrupts audio and exposes phantom BT ports.
                // BT options are only added when the user explicitly selects Bluetooth.
                self.scheduleAudioRouteWorkItem(delay: 0.5) { [weak self] in
                    guard let self = self, !self.calls.isEmpty else { return }
                    self.applySpeakerCategoryOptions()
                }
                
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER COMPLETE ===", isError: false)
            } else {
                // === EARPIECE SWITCH ===
                // Step 1: Immediate audio switch via setPreferredInput + overrideOutputAudioPort
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE START ===", isError: false)
                self.forceEarpieceRoute()
                
                // Step 2: After a short delay, apply category options to remove BT.
                // NOTE: We do NOT restore BT options afterward — that would cause a second
                // setCategory() which disrupts audio and exposes phantom BT ports.
                // BT options are only added when the user explicitly selects Bluetooth.
                self.scheduleAudioRouteWorkItem(delay: 0.5) { [weak self] in
                    guard let self = self, !self.calls.isEmpty else { return }
                    self.applyEarpieceCategoryOptions()
                }
                
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE COMPLETE ===", isError: false)
            }
            
            self.logAudioSessionState(label: "AFTER applySpeakerSetting toSpeaker=\(toSpeaker)")
        }
    }
    
    /// Force audio to speaker using overrideOutputAudioPort ONLY.
    /// Does NOT call setCategory() because that tears down and rebuilds the entire audio
    /// pipeline, causing a 1-4s lag where audio still comes from the old output device.
    /// Category options (to remove BT) are changed separately in a delayed work item.
    private func forceSpeakerRoute() {
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Log current state
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute: Current outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
            
            // overrideOutputAudioPort(.speaker) is the ONLY call needed for immediate speaker switch.
            // It takes effect within milliseconds without rebuilding the audio pipeline.
            try session.overrideOutputAudioPort(.speaker)
            
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute: After - outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute FAILED: \(error.localizedDescription)", isError: false)
        }
    }
    
    /// Set category options for speaker mode (removes BT to prevent auto-switch).
    /// This is called with a delay AFTER forceSpeakerRoute() has already switched audio output.
    /// Separating this from the override prevents the setCategory() audio pipeline rebuild
    /// from causing audible lag during the switch.
    private func applySpeakerCategoryOptions() {
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }
        
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Set category WITHOUT Bluetooth to prevent iOS from auto-switching to BT
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker]  // Speaker but NO Bluetooth
            )
            
            // Re-apply override after category change (category change can reset override)
            try session.overrideOutputAudioPort(.speaker)
            
            self.sendPhoneCallEvents(description: "LOG|applySpeakerCategoryOptions: category set, override re-applied", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applySpeakerCategoryOptions FAILED: \(error.localizedDescription)", isError: false)
        }
    }
    
    // MARK: CXProviderDelegate
    public func providerDidReset(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidReset:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func providerDidBegin(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|providerDidBegin", isError: false)
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didActivateAudioSession:", isError: false)
        audioDevice.isEnabled = true
        
        // Check if Bluetooth is available and apply it if we haven't customized the audio yet
        if !self.calls.isEmpty {
            // Suppress AudioRoute events from handleAudioRouteChange during call setup.
            // CallKit activates the audio session with .allowBluetooth, which can make
            // phantom BT appear in currentRoute. We suppress until applyInitialAudioRoute
            // sends the definitive AudioRoute event to Dart.
            self.suppressAudioRouteEvents = true
            
            // Add a small delay to ensure audio session is fully initialized and Bluetooth device is detected
            self.scheduleAudioRouteWorkItem(delay: 0.3) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }
                self.applyInitialAudioRoute()
                // NOTE: suppress is lifted INSIDE applyInitialAudioRoute's delayed
                // notification callback — NOT here. This ensures Dart can't query
                // native isBluetoothAvailable() while phantom BT may still be in route.
            }
        }
    }
    
    /// Apply initial audio route based on available devices.
    /// IMPORTANT: This method is responsible for lifting suppressAudioRouteEvents
    /// after sending the definitive AudioRoute event to Dart.
    private func applyInitialAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        self.logAudioSessionState(label: "BEFORE applyInitialAudioRoute")
        
        // CRITICAL: If user explicitly changed audio route, re-apply their choice.
        // CallKit may have reset the AVAudioSession during hold/unhold transitions,
        // so we must actively restore the desired route — not just skip.
        if self.userExplicitlyChangedAudioRoute {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User explicitly changed route, re-applying their choice", isError: false)
            if self.desiredSpeakerState {
                self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: Restoring speaker route", isError: false)
                self.applySpeakerRoute()
            } else if self.desiredBluetoothState {
                // Only restore bluetooth if a BT device is still available
                if self.isBluetoothAvailableSafe(afterDisconnect: false) {
                    self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: Restoring bluetooth route", isError: false)
                    self.applyBluetoothRoute()
                } else {
                    self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: Bluetooth no longer available, falling back to earpiece", isError: false)
                    self.desiredBluetoothState = false
                }
            } else {
                self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User chose earpiece, no action needed", isError: false)
            }
            // Send definitive AudioRoute event and lift suppress for early-return path
            self.sendDefinitiveAudioRouteAndLiftSuppress(delay: 0.5)
            return
        }
        
        // If user already explicitly set speaker or bluetooth, respect that
        if self.desiredSpeakerState {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User wants speaker, applying speaker", isError: false)
            self.applySpeakerRoute()
            self.sendDefinitiveAudioRouteAndLiftSuppress(delay: 0.5)
            return
        }
        
        if self.desiredBluetoothState {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User wants bluetooth, applying bluetooth", isError: false)
            self.applyBluetoothRoute()
            self.sendDefinitiveAudioRouteAndLiftSuppress(delay: 0.5)
            return
        }
        
        // Check if a real BT device is available using non-destructive approach.
        // Instead of stripping .allowBluetooth (which can confuse iOS routing),
        // we check availableInputs with isRealBluetoothDevice() — real devices
        // have dataSources, phantom entries don't.
        let bluetoothInRoute = self.isBluetoothAvailableClean()
        
        if bluetoothInRoute {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: Real Bluetooth device found → applying Bluetooth route", isError: false)
            self.desiredBluetoothState = true
            self.applyBluetoothRoute()
        } else {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: No Bluetooth in currentRoute after clean category, using earpiece", isError: false)
            // Default to earpiece - no action needed, it's the default
        }
        
        self.logAudioSessionState(label: "AFTER applyInitialAudioRoute")
        
        // Send definitive AudioRoute event and lift suppress
        self.sendDefinitiveAudioRouteAndLiftSuppress(delay: 0.5)
    }
    
    /// Send the definitive AudioRoute event to Dart and THEN lift suppressAudioRouteEvents.
    /// This ensures Dart cannot query native isBluetoothAvailable() during the gap
    /// between applyInitialAudioRoute returning and the delayed event firing.
    private func sendDefinitiveAudioRouteAndLiftSuppress(delay: TimeInterval) {
        self.scheduleAudioRouteWorkItem(delay: delay) { [weak self] in
            guard let self = self, !self.calls.isEmpty else {
                self?.suppressAudioRouteEvents = false
                return
            }
            
            // Use non-destructive BT check — no category changes during active call
            let btAvailable = self.isBluetoothAvailableClean()
            
            let currentRoute = self.getAudioRoute()
            // If currentRoute says bluetooth but check says no BT → phantom, report earpiece
            let reportedRoute = (currentRoute == "bluetooth" && !btAvailable) ? "earpiece" : currentRoute
            let reportedBtAvailable = btAvailable
            
            self.sendPhoneCallEvents(
                description: "LOG|sendDefinitiveAudioRoute: route=\(currentRoute), btAvailable=\(btAvailable), reportedRoute=\(reportedRoute), reportedBT=\(reportedBtAvailable)",
                isError: false
            )
            
            self.sendPhoneCallEvents(
                description: "AudioRoute|\(reportedRoute)|bluetoothAvailable=\(reportedBtAvailable)",
                isError: false
            )
            
            // NOW lift suppress — Dart has the definitive state
            self.suppressAudioRouteEvents = false
        }
    }
    
    /// Apply Bluetooth audio route
    private func applyBluetoothRoute() {
        isChangingAudioRoute = true
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // Step 1: Set category with Bluetooth options FIRST
            try audioSession.setCategory(
                AVAudioSession.Category.playAndRecord,
                options: [.allowBluetoothA2DP, .allowBluetooth]
            )
            self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: Category set with BT options", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: FAILED to set category - \(error.localizedDescription)", isError: false)
            isChangingAudioRoute = false
            return
        }
        isChangingAudioRoute = false
        
        // Step 2: Wait a tiny bit for iOS to recognize BT devices, then set preferred input
        self.scheduleAudioRouteWorkItem(delay: 0.1) { [weak self] in
            guard let self = self, !self.calls.isEmpty else { return }
            do {
                // Find the Bluetooth input and set it as preferred
                if let availableInputs = audioSession.availableInputs {
                    self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: Available inputs: \(availableInputs.map { "\($0.portType.rawValue):\($0.portName)" })", isError: false)
                    
                    var bluetoothFound = false
                    for input in availableInputs {
                        if (input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE)
                            && self.isRealBluetoothDevice(input) {
                            try audioSession.setPreferredInput(input)
                            self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: Set preferred input to: \(input.portName) (\(input.portType.rawValue))", isError: false)
                            bluetoothFound = true
                            break
                        }
                    }
                    
                    if !bluetoothFound {
                        self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: WARNING - No Bluetooth input found!", isError: false)
                    }
                }
                
                // Step 3: Override to .none to use the Bluetooth route
                try audioSession.overrideOutputAudioPort(.none)
                
                self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: SUCCESS", isError: false)
                self.logAudioSessionState(label: "AFTER applyBluetoothRoute")
            } catch {
                self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: FAILED - \(error.localizedDescription)", isError: false)
            }
        }
    }
    
    /// Apply Speaker audio route
    private func applySpeakerRoute() {
        isChangingAudioRoute = true
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // Step 1: Remove Bluetooth from category to force switch
            try audioSession.setCategory(
                AVAudioSession.Category.playAndRecord,
                options: [.defaultToSpeaker]  // NO Bluetooth options
            )
            
            // Step 2: Set built-in mic as preferred input
            if let availableInputs = audioSession.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try audioSession.setPreferredInput(input)
                        self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: Set preferred input to built-in mic", isError: false)
                        break
                    }
                }
            }
            
            // Step 3: Override to speaker
            try audioSession.overrideOutputAudioPort(.speaker)
            self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: FORCED (no BT options)", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: FAILED - \(error.localizedDescription)", isError: false)
        }
        isChangingAudioRoute = false
        
        // NOTE: We do NOT restore BT options. Adding .allowBluetooth to the category
        // causes phantom BT ports to appear in availableInputs when BT radio is on
        // but no device is connected. BT options are only added when user selects BT.
    }
    
    /// Apply Earpiece audio route
    private func applyEarpieceRoute() {
        isChangingAudioRoute = true
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // Step 1: Remove Bluetooth from category to force switch
            try audioSession.setCategory(
                AVAudioSession.Category.playAndRecord,
                options: []  // NO options - forces earpiece
            )
            
            // Step 2: Set built-in mic as preferred
            if let availableInputs = audioSession.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try audioSession.setPreferredInput(input)
                        self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: Set preferred input to built-in mic", isError: false)
                        break
                    }
                }
            }
            
            // Step 3: Override to .none
            try audioSession.overrideOutputAudioPort(.none)
            self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: FORCED (no options)", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: FAILED - \(error.localizedDescription)", isError: false)
        }
        isChangingAudioRoute = false
        
        // NOTE: We do NOT restore BT options. Adding .allowBluetooth to the category
        // causes phantom BT ports to appear in availableInputs when BT radio is on
        // but no device is connected. BT options are only added when user selects BT.
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|provider:didDeactivateAudioSession:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:timedOutPerformingAction:", isError: false)
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performStartCallAction:", isError: false)
        
        
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        
        self.performVoiceCall(uuid: action.callUUID, client: "") { (success) in
            if (success) {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() successful", isError: false)
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            } else {
                self.sendPhoneCallEvents(description: "LOG|provider:performVoiceCall() failed", isError: false)
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performAnswerCallAction: uuid=\(action.callUUID)", isError: false)
        
        // If there's an active call, hold it before answering the new one
        // IMPORTANT: We must send "Hold" to Flutter SYNCHRONOUSLY (before answering)
        // so the BLoC saves Test1's caller data BEFORE the Connected event for Test2
        // overwrites state.activeCall. The CXSetHeldCallAction via CallKit is async
        // and would arrive too late (after Connected), causing the BLoC to save
        // Test2's data instead of Test1's.
        if let currentActiveUUID = self.activeCallUUID,
           let currentCall = self.calls[currentActiveUUID] {
            
            // Only send Hold if the call isn't already on hold.
            // When the user goes through the Flutter "Hold & Accept" flow,
            // holdCall() already set isOnHold = true and sent "Hold" to Flutter.
            // Sending a SECOND "Hold" here would cause the BLoC to re-save
            // the held-call data AFTER Caller B's info has been emitted into
            // state, corrupting the saved Caller A data.
            if !currentCall.isOnHold {
                self.sendPhoneCallEvents(description: "LOG|Holding current call \(currentActiveUUID) before answering new call", isError: false)
                
                // 1. Set hold on Twilio SDK immediately
                currentCall.isOnHold = true
                
                // 2. Send Hold event to Flutter IMMEDIATELY so BLoC saves caller data before Connected arrives
                self.sendPhoneCallEvents(description: "Hold", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Current call \(currentActiveUUID) already on hold, skipping duplicate Hold event", isError: false)
            }
            
            // 3. Also request hold through CallKit for proper audio session management
            // The delegate will skip sending duplicate "Hold" since call.isOnHold is already true
            let holdAction = CXSetHeldCallAction(call: currentActiveUUID, onHold: true)
            let transaction = CXTransaction(action: holdAction)
            callKitCallController.request(transaction) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|Hold via CallKit failed: \(error.localizedDescription) (direct hold already applied)", isError: false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|Hold via CallKit succeeded for \(currentActiveUUID)", isError: false)
                }
            }
        }
        
        self.performAnswerVoiceCall(uuid: action.callUUID) { (success) in
            if success {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() successful", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|provider:performAnswerVoiceCall() failed:", isError: false)
            }
        }
        
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: uuid=\(action.callUUID)", isError: false)
        
        // Check if it's a call invite (reject/decline it)
        if let invite = self.callInvites[action.callUUID] {
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: declining call invite", isError: false)
            invite.reject()
            self.callInvites.removeValue(forKey: action.callUUID)
            
            // Only send "Declined" if there are no other active calls
            if self.calls.isEmpty {
                self.sendPhoneCallEvents(description: "Declined", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Call invite declined but other calls remain, suppressing Declined event", isError: false)
            }
        } else if let call = self.calls[action.callUUID] {
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: disconnecting call", isError: false)
            call.disconnect()
        } else {
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: no call or invite found for uuid", isError: false)
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction: uuid=\(action.callUUID) isOnHold=\(action.isOnHold)", isError: false)
        if let call = self.calls[action.callUUID] {
            let wasAlreadyInTargetState = (call.isOnHold == action.isOnHold)
            call.isOnHold = action.isOnHold
            
            // Only notify Flutter if the state actually changed
            // Avoids duplicate Hold/Unhold events when we already sent one synchronously
            // (e.g., in CXAnswerCallAction we send Hold immediately before the async CallKit request)
            if !wasAlreadyInTargetState {
                self.sendPhoneCallEvents(description: action.isOnHold ? "Hold" : "Unhold", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: skipping duplicate \(action.isOnHold ? "Hold" : "Unhold") event (already in target state)", isError: false)
            }
            
            // Update activeCallUUID
            if !action.isOnHold {
                self.activeCallUUID = action.callUUID
            }
            
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetMutedAction: uuid=\(action.callUUID)", isError: false)
        
        if let call = self.calls[action.callUUID] {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    // MARK: Call Kit Actions
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
            
            self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request successful", isError: false)
            
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.localizedCallerName = self.outgoingCallerName
            callUpdate.supportsDTMF = false
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            
            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
        }
    }
    
    func reportIncomingCall(from: String, uuid: UUID) {
        let callHandle = CXHandle(type: .generic, value: from)
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        // If the client is not registered, USE THE THE FROM NUMBER
        callUpdate.localizedCallerName = formatUSPhoneNumber(from)
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|Failed to report incoming call successfully: \(error.localizedDescription).", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|Incoming call successfully reported.", isError: false)
            }
        }
    }
    
    // Format the phone number to US format if it is a valid US number else return the number as is
    func formatUSPhoneNumber(_ number: String) -> String {
        // Ensure the number starts with "+1" and has exactly 12 characters
        guard number.hasPrefix("+1"), number.count == 12 else {
            return number
        }

        // Extract the digits after "+1"
        let digits = number.suffix(10)

        // Check if all characters are digits
        guard digits.allSatisfy({ $0.isNumber }) else {
            return number
        }

        // Format the number
        let areaCode = digits.prefix(3)
        let middle = digits.dropFirst(3).prefix(3)
        let last = digits.suffix(4)

        return "+1 (\(areaCode)) \(middle)-\(last)"
    }

    func performEndCallAction(uuid: UUID) {
        
        self.sendPhoneCallEvents(description: "LOG|performEndCallAction method invoked uuid=\(uuid)", isError: false)
        
        // check if call is still active, preventing a race condition ending the call throwing an End Call Failed transaction error 4 error
        guard isCallActive(uuid: uuid) else {
            print("Call not found or already ended. Skipping end request.")
            // Only send Call Ended if no other calls remain
            if self.calls.isEmpty && self.callInvites.isEmpty {
                self.sendPhoneCallEvents(description: "Call Ended", isError: false)
            }
            return
        }

        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        callKitCallController.request(transaction) { error in
            if let error = error {
                // IMPORTANT: Send as normal LOG event, NOT isError:true.
                // isError:true wraps in FlutterError which crashes the Dart event stream.
                self.sendPhoneCallEvents(description: "LOG|End Call Failed: \(error.localizedDescription).", isError: false)
            } else {
                // Don't send "Call Ended" here - let callDidDisconnect handle it
                // It will check if other calls remain before sending
                self.sendPhoneCallEvents(description: "LOG|EndCallAction transaction successful for uuid=\(uuid)", isError: false)
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
        // Suppress audio route events during call setup (same as answer path)
        self.suppressAudioRouteEvents = true
        
        // Safety: auto-lift suppress after 3s in case applyInitialAudioRoute never runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.suppressAudioRouteEvents == true {
                self?.sendPhoneCallEvents(description: "LOG|performVoiceCall: Safety timeout — lifting suppressAudioRouteEvents", isError: false)
                self?.suppressAudioRouteEvents = false
            }
        }
        
        guard let token = accessToken else {
            completionHandler(false)
            return
        }
        
        // Send Connecting event before initiating the call
        let from = self.identity
        let to = self.callTo
        self.sendPhoneCallEvents(description: "Connecting|\(from)|\(to)|Outgoing", isError: false)
        
        let connectOptions: ConnectOptions = ConnectOptions(accessToken: token) { (builder) in
            for (key, value) in self.callArgs {
                if (key != "From") {
                    builder.params[key] = "\(value)"
                }
            }
            builder.uuid = uuid
        }
        let theCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        self.calls[uuid] = theCall
        self.activeCallUUID = uuid
        self.userExplicitlyChangedAudioRoute = false  // Reset for new call
        self.callKitCompletionCallback = completionHandler
    }
    
    func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
        // Suppress audio route events immediately when answering a call.
        // CallKit will activate the audio session with .allowBluetooth which can
        // create phantom BT in currentRoute. The suppress flag prevents both
        // handleAudioRouteChange and method channel calls from reporting phantom BT.
        // It will be lifted after applyInitialAudioRoute completes.
        self.suppressAudioRouteEvents = true
        
        // Safety: auto-lift suppress after 3s in case applyInitialAudioRoute never runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.suppressAudioRouteEvents == true {
                self?.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: Safety timeout — lifting suppressAudioRouteEvents", isError: false)
                self?.suppressAudioRouteEvents = false
            }
        }
        
        // Look up the call invite by UUID
        if let ci = self.callInvites[uuid] {
            let acceptOptions: AcceptOptions = AcceptOptions(callInvite: ci) { (builder) in
                builder.uuid = ci.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call uuid=\(uuid)", isError: false)
            let theCall = ci.accept(options: acceptOptions, delegate: self)
            let answerFrom = extractUserNumber(from: theCall.from ?? self.identity)
            let answerTo = theCall.to ?? self.callTo
            self.sendPhoneCallEvents(description: "Answer|\(answerFrom)|\(answerTo)|Incoming\(formatCustomParams(params: ci.customParameters))", isError:false)
            self.calls[uuid] = theCall
            self.activeCallUUID = uuid
            self.userExplicitlyChangedAudioRoute = false  // Reset for new call
            self.callKitCompletionCallback = completionHandler
            self.callInvites.removeValue(forKey: uuid)
            
            guard #available(iOS 13, *) else {
                self.incomingPushHandled()
                return
            }
        } else {
            self.sendPhoneCallEvents(description: "LOG|No CallInvite matches the UUID \(uuid)", isError: false)
        }
    }
    
    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(CallDelegate.callDidDisconnect),
            name: NSNotification.Name(rawValue: "PhoneCallEvent"),
            object: nil)
        
        // Replay any events that were queued while eventSink was nil
        // This ensures Ringing|, Answer|, Connected| events are delivered
        // when Flutter re-establishes the event channel after background/termination
        if !pendingEvents.isEmpty {
            let eventsToReplay = pendingEvents
            pendingEvents.removeAll()
            for event in eventsToReplay {
                DispatchQueue.main.async {
                    eventSink(event)
                }
            }
        }
        
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }
    
    private func sendPhoneCallEvents(description: String, isError: Bool) {
        NSLog(description)
        
        if isError
        {
            let err = FlutterError(code: "unavailable", message: description, details: nil);
            sendEvent(err)
        }
        else
        {
            sendEvent(description)
        }
    }
    
    private func sendEvent(_ event: Any) {
        guard let eventSink = eventSink else {
            // Queue critical call events so they can be replayed when Flutter reconnects
            // Only queue non-LOG events (Ringing|, Answer|, Connected|, Call Ended, etc.)
            if let strEvent = event as? String, !strEvent.hasPrefix("LOG|") {
                if pendingEvents.count < SwiftTwilioVoicePlugin.maxPendingEvents {
                    pendingEvents.append(event)
                } else {
                    pendingEvents.removeFirst()
                    pendingEvents.append(event)
                }
            }
            return
        }
        DispatchQueue.main.async {
            eventSink(event)
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String, type == "twilio-missed-call", let user = userInfo["From"] as? String{
            self.callTo = user
            if let to = userInfo["To"] as? String{
                self.identity = to
            }
            makeCall(to: callTo)
            completionHandler()
            self.sendPhoneCallEvents(description: "ReturningCall|\(identity)|\(user)|Outgoing", isError: false)
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "twilio-missed-call"{
            completionHandler([.alert])
        }
    }
    
}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else {
            return nil
        }
        return topViewController(for: rootViewController)
    }
    
    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else {
            return nil
        }
        guard let presentedViewController = rootViewController.presentedViewController else {
            return rootViewController
        }
        switch presentedViewController {
        case is UINavigationController:
            let navigationController = presentedViewController as! UINavigationController
            return topViewController(for: navigationController.viewControllers.last)
        case is UITabBarController:
            let tabBarController = presentedViewController as! UITabBarController
            return topViewController(for: tabBarController.selectedViewController)
        default:
            return topViewController(for: presentedViewController)
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

import Flutter
import UIKit
import AVFoundation
import AVKit
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
    // MARK: Ringback Tone Management
    private var ringbackPlayer: AVAudioPlayer?
    private var isPlayingRingback: Bool = false
    // Transitional state: set to true when we've removed .allowBluetooth from category
    // options (to prevent auto-switch) but BT is still physically connected.
    // During this window, isBluetoothAvailableClean() cannot see the BT device because
    // the category doesn't allow it. The flag is cleared when the user switches back
    // to Bluetooth (toggleBluetoothAudio(true)), which restores .allowBluetooth options.
    private var btOptionsTemporarilyRemoved: Bool = false
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
    // Pre-suppression snapshots: cached audio route and BT availability from BEFORE
    // suppressAudioRouteEvents was set. During suppression, method channel queries return
    // these values instead of hardcoded earpiece/false, preventing the UI from flickering
    // to "Phone" when BT was already active during the ringing phase.
    private var preSuppressAudioRoute: String? = nil
    private var preSuppressBtAvailable: Bool? = nil
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

                // When the user explicitly changed the audio route (e.g. BT → speaker),
                // our code intentionally changes the category (via applyEarpieceCategoryOptions)
                // which triggers this categoryChange notification. During this transitional
                // window the toggle methods already sent correct events. Skip to avoid
                // duplicate/conflicting events.
                if self.userExplicitlyChangedAudioRoute {
                    self.sendPhoneCallEvents(
                        description: "LOG|handleAudioRouteChange categoryChange: SKIPPED — user explicitly changed route, events already sent by toggle methods",
                        isError: false
                    )
                    return
                }

                // For categoryChange during an active call, use non-destructive check
                // to avoid interfering with the audio session. The destructive
                // checkBluetoothWithCategoryChange() can cause audio disruptions.
                let btInRoute = self.isBluetoothAvailableSafe()
                var isBluetoothAvailable = btInRoute
                if !btInRoute && !self.calls.isEmpty {
                    // Check availableInputs for connected BT device (non-destructive)
                    if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                        for input in availableInputs {
                            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                                isBluetoothAvailable = true
                                break
                            }
                        }
                    }
                }
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange categoryChange: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btInRoute=\(btInRoute), btAvailable=\(isBluetoothAvailable)",
                    isError: false
                )

                if self.desiredBluetoothState && !btInRoute && !isBluetoothAvailable {
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

                // When the user explicitly changed the audio route (e.g. BT → speaker),
                // the category may temporarily have NO .allowBluetooth options (set by
                // applyEarpieceCategoryOptions to prevent iOS from auto-switching back
                // to BT). In this state, isBluetoothAvailableClean() cannot find the BT
                // device and would falsely report btAvailable=false. The toggle methods
                // already sent their own events, and btOptionsTemporarilyRemoved ensures
                // cached BT availability is used. Skip sending AudioRoute here to avoid
                // the Dart layer losing track of the BT device.
                if self.userExplicitlyChangedAudioRoute {
                    self.sendPhoneCallEvents(
                        description: "LOG|handleAudioRouteChange override: SKIPPED — user explicitly changed route, events already sent by toggle methods",
                        isError: false
                    )
                    return
                }

                // For override events (system picker, CallKit route change), use the
                // NON-DESTRUCTIVE isBluetoothAvailableSafe() check which only looks at
                // currentRoute. The destructive isBluetoothAvailableClean() test can
                // interfere with the audio session during route changes (calls setCategory
                // and setPreferredInput), causing the route to bounce back. Additionally,
                // it can falsely report PHANTOM during CallKit-managed sessions.
                // Also check availableInputs as a supplementary signal — if BT is in
                // availableInputs, the device is physically connected even if not the
                // active route (user may have switched to speaker).
                let btInRoute = self.isBluetoothAvailableSafe()
                var btDeviceConnected = btInRoute
                if !btInRoute {
                    // Check availableInputs for connected BT device (non-destructive)
                    if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                        for input in availableInputs {
                            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                                btDeviceConnected = true
                                break
                            }
                        }
                    }
                }
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange override: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btInRoute=\(btInRoute), btDeviceConnected=\(btDeviceConnected)",
                    isError: false
                )

                // Update desired state based on actual system route after override
                // The system picker or CallKit changed the route — respect it
                if actualSystemRoute == "bluetooth" {
                    self.desiredBluetoothState = true
                    self.desiredSpeakerState = false
                } else if actualSystemRoute == "speaker" {
                    self.desiredBluetoothState = false
                    self.desiredSpeakerState = true
                } else {
                    // earpiece or other
                    if self.desiredBluetoothState && !btInRoute {
                        // BT was desired but system moved away — accept it
                        self.desiredBluetoothState = false
                    }
                    self.desiredSpeakerState = false
                }

                let currentRoute = self.getAudioRoute()
                self.sendPhoneCallEvents(
                    description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(btDeviceConnected)",
                    isError: false
                )

                // DEFERRED CORRECTION: When the system picker fires an override,
                // iOS may show a TRANSITIONAL route (e.g. builtInSpeaker) before
                // settling on the final route (e.g. builtInReceiver/earpiece).
                // This means picking "iPhone" from the system picker initially
                // appears as "speaker" in currentRoute.outputs.
                // Schedule a delayed re-check to read the SETTLED route and correct
                // desiredSpeakerState if the route has changed.
                if actualSystemRoute == "speaker" {
                    self.scheduleAudioRouteWorkItem(delay: 0.5) { [weak self] in
                        guard let self = self, !self.calls.isEmpty else { return }
                        let settledRoute = self.getActualSystemAudioRoute()
                        if settledRoute != "speaker" && self.desiredSpeakerState {
                            self.sendPhoneCallEvents(
                                description: "LOG|override deferred correction: route settled to '\(settledRoute)' (was 'speaker') — correcting desiredSpeakerState to false",
                                isError: false
                            )
                            self.desiredSpeakerState = false

                            // Re-check BT availability for the corrected event
                            let btInRouteNow = self.isBluetoothAvailableSafe()
                            var btAvailNow = btInRouteNow
                            if !btInRouteNow {
                                if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                                    for input in availableInputs {
                                        if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                                            btAvailNow = true
                                            break
                                        }
                                    }
                                }
                            }

                            let correctedRoute = self.getAudioRoute()
                            self.sendPhoneCallEvents(
                                description: "AudioRoute|\(correctedRoute)|bluetoothAvailable=\(btAvailNow)",
                                isError: false
                            )
                        }
                    }
                }
            }
            
        default:
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: unhandled reason \(reasonStr)", isError: false)
            self.scheduleAudioRouteWorkItem(delay: 0.2) { [weak self] in
                guard let self = self, !self.calls.isEmpty else { return }

                // Use non-destructive check during active call
                let btInRoute = self.isBluetoothAvailableSafe()
                var isBluetoothAvailable = btInRoute
                if !btInRoute {
                    if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                        for input in availableInputs {
                            if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                                isBluetoothAvailable = true
                                break
                            }
                        }
                    }
                }

                if self.desiredBluetoothState && !btInRoute && !isBluetoothAvailable {
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
            // Return the pre-suppression snapshot (last known good state) so Dart UI
            // doesn't flicker to "Phone" when BT was already active during ringing.
            if self.suppressAudioRouteEvents {
                let cached = self.preSuppressAudioRoute ?? "earpiece"
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute METHOD CHANNEL: returning '\(cached)' (suppressed, using pre-suppress snapshot)", isError: false)
                result(cached)
                return
            }
            let audioRoute = getAudioRoute()
            result(audioRoute)
        }
        else if flutterCall.method == "isBluetoothAvailable"
        {
            // During call setup, suppress BT availability to prevent phantom BT.
            // Return the pre-suppression snapshot (last known good state) so Dart UI
            // doesn't flicker to "Phone" when BT was already active during ringing.
            if self.suppressAudioRouteEvents {
                let cached = self.preSuppressBtAvailable ?? false
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable METHOD CHANNEL: returning \(cached) (suppressed, using pre-suppress snapshot)", isError: false)
                result(cached)
                return
            }

            // During the transitional window when .allowBluetooth has been temporarily
            // removed from category options (to prevent auto-switch back to BT),
            // isBluetoothAvailableClean() cannot see the BT device. Use the cached value
            // instead — it reflects the last known BT availability before the category change.
            if self.btOptionsTemporarilyRemoved {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailable METHOD CHANNEL: returning cached \(self.cachedBluetoothAvailable) (BT options temporarily removed)", isError: false)
                result(self.cachedBluetoothAvailable)
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
                let activeSid = activeCall.sid
                let from = extractUserNumber(from: activeCall.from ?? self.identity)
                let to = activeCall.to ?? self.callTo
                self.sendPhoneCallEvents(description: "Connected|\(activeSid)|\(from)|\(to)|\(direction)", isError: false)
            }

            // Emit HeldCallData for any held call(s) so Flutter can recover multi-call state
            if self.calls.count >= 2, let currentActiveUUID = self.activeCallUUID {
                for (uuid, heldCall) in self.calls {
                    if uuid == currentActiveUUID { continue }
                    // This is a held call — emit its data
                    let heldSid = heldCall.sid
                    let heldFrom = extractUserNumber(from: heldCall.from ?? self.identity)
                    let heldTo = heldCall.to ?? ""
                    // Infer direction: if the held call was the first call and the active call was outgoing,
                    // then the held call was likely incoming (and vice versa). However, since we don't track
                    // per-call direction, default to Incoming as most call-waiting scenarios are incoming.
                    let heldDirection = "Incoming"
                    NSLog("getActiveCallOnResumeFromTerminatedState: emitting HeldCallData for held call - sid=\(heldSid), from=\(heldFrom), to=\(heldTo)")
                    self.sendPhoneCallEvents(description: "HeldCallData|\(heldSid)|\(heldFrom)|\(heldTo)|\(heldDirection)", isError: false)
                }
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
                    eventSink("Hold|\(activeCall.sid)")
                } else if(!shouldHold && hold) {
                    activeCall.isOnHold = false
                    guard let eventSink = eventSink else {
                        return
                    }
                    eventSink("Unhold|\(activeCall.sid)")
                }
            }
        }
        else if flutterCall.method == "swapCalls" {
            // Swap active and held calls via CallKit so native UI reflects the change.
            // Find the currently active call UUID and the held call UUID.
            guard self.calls.count >= 2 else {
                self.sendPhoneCallEvents(description: "LOG|swapCalls: need 2+ calls to swap, have \(self.calls.count)", isError: false)
                _result?(false)
                return
            }
            guard let currentActiveUUID = self.activeCallUUID,
                  let _ = self.calls[currentActiveUUID] else {
                self.sendPhoneCallEvents(description: "LOG|swapCalls: no active call UUID", isError: false)
                _result?(false)
                return
            }
            // Find the other (held) call UUID
            guard let heldUUID = self.calls.keys.first(where: { $0 != currentActiveUUID }) else {
                self.sendPhoneCallEvents(description: "LOG|swapCalls: no held call found", isError: false)
                _result?(false)
                return
            }

            self.sendPhoneCallEvents(description: "LOG|swapCalls: swapping active=\(currentActiveUUID) with held=\(heldUUID)", isError: false)

            // Create a CXTransaction with two actions:
            // 1. Hold the currently active call
            // 2. Unhold the currently held call
            // This will trigger provider:performSetHeldCallAction: for each,
            // which already has swap detection via pendingSwapHoldUUID.
            let holdAction = CXSetHeldCallAction(call: currentActiveUUID, onHold: true)
            let unholdAction = CXSetHeldCallAction(call: heldUUID, onHold: false)
            let transaction = CXTransaction(actions: [holdAction, unholdAction])

            self.callKitCallController.request(transaction) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|swapCalls: CXTransaction failed - \(error.localizedDescription)", isError: true)
                    self._result?(false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|swapCalls: CXTransaction succeeded", isError: false)
                    self._result?(true)
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
        } else if flutterCall.method == "showAudioRoutePicker" {
            // Show the native iOS system audio route picker (AVRoutePickerView).
            // This picker has visibility into ALL audio routes including:
            // - BT devices connected to other Apple devices (iCloud automatic switching)
            // - AirPlay devices
            // - Wired headphones
            // Unlike AVAudioSession.availableInputs, the system picker can "steal"
            // audio from BT devices connected to other iCloud-linked devices (e.g.,
            // AirPods playing music on a Mac).
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                      let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first
                else {
                    self.sendPhoneCallEvents(description: "LOG|showAudioRoutePicker: no active window found", isError: false)
                    result(false)
                    return
                }

                let routePickerView = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 0, height: 0))
                routePickerView.prioritizesVideoDevices = false
                routePickerView.isHidden = true
                window.addSubview(routePickerView)

                // Programmatically trigger the route picker button
                var triggered = false
                for subview in routePickerView.subviews {
                    if let button = subview as? UIButton {
                        button.sendActions(for: .touchUpInside)
                        triggered = true
                        self.sendPhoneCallEvents(description: "LOG|showAudioRoutePicker: triggered system picker", isError: false)
                        break
                    }
                }

                if !triggered {
                    self.sendPhoneCallEvents(description: "LOG|showAudioRoutePicker: could not find button in AVRoutePickerView", isError: false)
                }

                // Remove the hidden view after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    routePickerView.removeFromSuperview()
                }
            }
            result(true)
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
    
    /**
     * Checks if the device is currently on a non-Twilio (system/cellular) call.
     * Uses CXCallObserver to get all active calls on the device, then excludes
     * calls that belong to our app (tracked in `calls` and `callInvites`).
     *
     * @return true if there is at least one active non-Twilio call on the device
     */
    private func isDeviceOnNonTwilioCall() -> Bool {
        let allSystemCalls = callObserver.calls.filter { !$0.hasEnded }

        // Get all UUIDs that belong to our Twilio calls
        let twilioCallUUIDs = Set(self.calls.keys).union(Set(self.callInvites.keys))

        // Check if any system call is NOT a Twilio call
        let nonTwilioCalls = allSystemCalls.filter { !twilioCallUUIDs.contains($0.uuid) }

        self.sendPhoneCallEvents(description: "LOG|isDeviceOnNonTwilioCall: allSystemCalls=\(allSystemCalls.count), twilioCallUUIDs=\(twilioCallUUIDs.count), nonTwilioCalls=\(nonTwilioCalls.count)", isError: false)

        return !nonTwilioCalls.isEmpty
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
        
        // ============================================================
        // SYSTEM CALL CHECK: If the device is already on a non-Twilio
        // system call (cellular/SIM), reject the incoming Twilio call.
        // We still MUST report the call to CallKit (Apple requirement
        // for PushKit), then immediately end it.
        // NOTE: If the active call is from OUR app (Twilio), we allow
        // it through for call waiting support.
        // ============================================================
        if isDeviceOnNonTwilioCall() {
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: Device is on a system call - rejecting Twilio incoming call", isError: false)
            // Must report to CallKit first (Apple PushKit requirement), then immediately end
            reportIncomingCall(from: callInvite.from ?? defaultCaller, uuid: callInvite.uuid)
            // Reject the Twilio call invite
            callInvite.reject()
            // Tell CallKit the call has ended (more reliable than performEndCallAction)
            self.callKitProvider.reportCall(with: callInvite.uuid, endedAt: Date(), reason: .declinedElsewhere)
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: Twilio call rejected (system call active)", isError: false)
            return
        }
        // ============================================================

        // ============================================================
        // 3RD CALL CHECK: If 2 Twilio calls are already active (e.g.
        // Call A active + Call B on hold), reject the 3rd incoming call.
        // We still MUST report the call to CallKit (Apple PushKit
        // requirement), then immediately end it.
        // IMPORTANT: We use reportCall(endedAt:reason:) instead of
        // performEndCallAction to avoid the isCallActive guard race
        // condition — this directly tells CallKit the call ended,
        // ensuring Call C is ended without affecting Call A or B.
        // ============================================================
        if self.calls.count >= 2 {
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: Already have \(self.calls.count) active calls (Call A + Call B) - rejecting 3rd incoming call (Call C)", isError: false)
            // Step 1: Report to CallKit (Apple PushKit requirement — must report every VoIP push)
            reportIncomingCall(from: callInvite.from ?? defaultCaller, uuid: callInvite.uuid)
            // Step 2: Reject the Twilio call invite (only rejects Call C's invite, not A or B)
            callInvite.reject()
            // Step 3: Tell CallKit that Call C has ended (uses Call C's UUID only)
            // Using reportCall(endedAt:reason:) is more reliable than performEndCallAction
            // because it doesn't depend on CXCallObserver having registered the call yet
            self.callKitProvider.reportCall(with: callInvite.uuid, endedAt: Date(), reason: .declinedElsewhere)
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: 3rd call (Call C) rejected and ended — Call A and Call B unaffected", isError: false)
            return
        }
        // ============================================================

        let incomingCallerDetails:String = callInvite.from ?? defaultCaller
        let userNumber:String = extractUserNumber(from: incomingCallerDetails)
        let client:String = callInvite.customParameters?["client_name"] ?? userNumber
         var from:String = callInvite.from ?? defaultCaller
         from = userNumber

        // If there's already an active call, send IncomingWhileActive instead of Ringing
        // This prevents the Dart parser from overwriting call.activeCall with the new call's data
        // Matches Android behavior which also sends IncomingWhileActive when callSid != null
        let incomingSid = callInvite.callSid
        if !self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived: active call exists, sending IncomingWhileActive", isError: false)
            self.sendPhoneCallEvents(description: "IncomingWhileActive|\(incomingSid)|\(from)|\(callInvite.to ?? "")|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "Ringing|\(incomingSid)|\(from)|\(callInvite.to ?? "")|Incoming\(formatCustomParams(params: callInvite.customParameters))", isError: false)
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
        let sid = call.sid
        self.sendPhoneCallEvents(description: "Ringing|\(sid)|\(String(describing: from))|\(to)|\(direction)", isError: false)
        
        // Start ringback tone for outgoing calls
        if self.callOutgoing {
            startRingbackTone()
        }

        // Try to apply speaker setting early if audio session is ready
        if audioDevice.isEnabled && desiredSpeakerState {
            applySpeakerSetting(toSpeaker: desiredSpeakerState)
        }
    }
    
    public func callDidConnect(call: Call) {
        // Stop ringback tone when call connects (callee answered)
        stopRingbackTone()

        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = extractUserNumber(from:(call.from ?? self.identity))
        let to = (call.to ?? self.callTo)
        let sid = call.sid

        // Track this call as the active call
        if let uuid = call.uuid {
            self.activeCallUUID = uuid
            self.calls[uuid] = call
        }

        self.sendPhoneCallEvents(description: "Connected|\(sid)|\(from)|\(to)|\(direction)", isError: false)
        
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
        // Stop ringback tone if playing (outgoing call failed before connecting)
        stopRingbackTone()

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
            self.sendPhoneCallEvents(description: "Call Ended|\(call.sid)", isError: false)
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
            self.sendPhoneCallEvents(description: "Call Ended|\(call.sid)", isError: false)
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
                self.sendPhoneCallEvents(description: "Held Call Ended|\(call.sid)", isError: false)
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
                    self.sendPhoneCallEvents(description: "Unhold|\(remainingCall.sid)", isError: false)
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

        // Clear pending swap state if the disconnected call was part of a pending swap
        if self.pendingSwapHoldUUID == uuid || self.pendingSwapHoldUUID != nil {
            self.sendPhoneCallEvents(description: "LOG|callDisconnected: clearing pendingSwapHoldUUID (was \(String(describing: self.pendingSwapHoldUUID)))", isError: false)
            self.pendingSwapHoldUUID = nil
            self.pendingSwapSafetyTimer?.invalidate()
            self.pendingSwapSafetyTimer = nil
        }

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

            // Stop ringback tone if still playing
            stopRingbackTone()

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
            preSuppressAudioRoute = nil
            preSuppressBtAvailable = nil
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
        // check if a BT device is still physically connected (in availableInputs).
        // CallKit controls the audio session and may not immediately move BT into
        // currentRoute.outputs even after applyBluetoothRoute succeeds. If BT is
        // in availableInputs and we desired BT, trust the desired state — audio IS
        // going through BT even if currentRoute hasn't updated yet.
        if desiredBluetoothState {
            var btStillConnected = false
            if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                for input in availableInputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        btStillConnected = true
                        break
                    }
                }
            }
            if !btStillConnected {
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute: desiredBluetoothState=true but no BT in currentRoute or availableInputs — clearing stale flag", isError: false)
                desiredBluetoothState = false
            } else {
                // BT device is connected and we desired BT — report bluetooth.
                // This handles the case where CallKit hasn't moved BT into
                // currentRoute.outputs yet (e.g. right after applyBluetoothRoute).
                self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'bluetooth' — desiredBluetoothState=true and BT in availableInputs (trusting desired state over stale currentRoute)", isError: false)
                return "bluetooth"
            }
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
        // TRANSITIONAL WINDOW CHECK:
        // When the user switches from BT to speaker/earpiece, we temporarily remove
        // .allowBluetooth from category options to prevent iOS from auto-switching
        // back. During this ~1.5s window, BT devices become invisible to
        // availableInputs and the category-change verification test. Return the
        // cached BT availability instead of performing checks that will give a
        // false negative.
        if btOptionsTemporarilyRemoved && cachedBluetoothAvailable {
            self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT options temporarily removed, returning cached=true", isError: false)
            return true
        }
        
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

            // OPTIMIZATION: During an active call, if we already know BT was real (from a
            // previous check), trust the cache instead of running the expensive destructive
            // checkBluetoothWithCategoryChange() test. That test calls setCategory() multiple
            // times with Thread.sleep, blocking the audioSessionQueue for 1-2 seconds and
            // causing audible audio lag when route switches queue behind it.
            // The phantom check is primarily important at call start — during an ongoing call,
            // if BT was previously verified as real and is still in availableInputs, it's still real.
            if cachedBluetoothAvailable && !calls.isEmpty {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT in availableInputs, SKIPPING destructive check — cached=true during active call", isError: false)
                return true
            }

            // CRITICAL FIX: During a CallKit-managed active call (audioDevice.isEnabled),
            // the destructive checkBluetoothWithCategoryChange() test is unreliable because:
            // 1. CallKit controls the audio session — setPreferredInput may not move BT
            //    into currentRoute even though audio IS going through BT (AirPods Pro case)
            // 2. Changing the category during an active CallKit session can disrupt audio
            // 3. The test concludes "PHANTOM" when BT is in availableInputs but not in
            //    currentRoute after setPreferredInput — this is a false negative
            //
            // Instead, during an active call, trust availableInputs. The phantom BT issue
            // (BT radio on but no device connected) is extremely rare during an active call
            // because CallKit wouldn't have connected BT in the first place.
            // The destructive test is still used for the initial detection when NO call
            // is active (e.g., when the call invite first arrives and we need to check if
            // BT is genuinely available before deciding the initial audio route).
            if !calls.isEmpty && audioDevice.isEnabled {
                self.sendPhoneCallEvents(description: "LOG|isBluetoothAvailableClean: BT in availableInputs during active CallKit call — trusting as REAL (skipping destructive check, CallKit controls audio session)", isError: false)
                cachedBluetoothAvailable = true
                return true
            }

            // No active call — run the full destructive verification
            // This path is for initial call setup or when checking before a call starts
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
        
        // Update ringback audio route if playing (before call is fully connected)
        if isPlayingRingback {
            // Track state before updating ringback route
            if bluetoothOn {
                self.desiredBluetoothState = true
                self.desiredSpeakerState = false
            } else {
                self.desiredBluetoothState = false
            }
            updateRingbackAudioRoute()
        }

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
            // BT options are about to be restored — clear the transitional flag
            self.btOptionsTemporarilyRemoved = false
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

                            // Send AudioRoute event to Dart layer
                            let currentRoute = self.getAudioRoute()
                            self.sendPhoneCallEvents(
                                description: "AudioRoute|\(currentRoute)|bluetoothAvailable=true",
                                isError: false
                            )
                        } catch {
                            self.sendPhoneCallEvents(description: "LOG|Failed to set Bluetooth input: \(error.localizedDescription)", isError: false)
                        }
                    }
                } catch {
                    self.sendPhoneCallEvents(description: "LOG|Failed to set category for Bluetooth: \(error.localizedDescription)", isError: false)
                }
            } else {
                // Disable Bluetooth - route to earpiece
                // Schedule with a tiny delay so it can be CANCELLED if toggleSpeaker(true)
                // follows immediately (which calls cancelPendingAudioRouteWorkItems).
                // This prevents the unnecessary BT→earpiece→speaker double-switch that
                // causes ~6s of audio lag when the Dart layer sends toggleBluetooth(false)
                // + toggleSpeaker(true) back-to-back.

                // Mark BT options as temporarily removed before scheduling
                if self.cachedBluetoothAvailable {
                    self.btOptionsTemporarilyRemoved = true
                }

                self.scheduleAudioRouteWorkItem(delay: 0.02) { [weak self] in
                    guard let self = self, !self.calls.isEmpty else { return }

                    // If desiredSpeakerState was set to true by a concurrent toggleSpeaker(true)
                    // call, skip the earpiece switch entirely — speaker path handles it.
                    if self.desiredSpeakerState {
                        self.sendPhoneCallEvents(description: "LOG|toggleBluetoothAudio(false): SKIPPED earpiece switch — speaker is desired", isError: false)
                        return
                    }

                    self.sendPhoneCallEvents(description: "LOG|=== EARPIECE SWITCH START ===", isError: false)

                    // Simple approach: forceEarpieceRoute + applyEarpieceCategoryOptions inline.
                    // No deferred category changes, no restoreBluetoothOptions — keeping it
                    // fast and simple. BT availability is tracked via cachedBluetoothAvailable.
                    self.forceEarpieceRoute()
                    self.applyEarpieceCategoryOptions()

                    // Send AudioRoute event to Dart layer since handleAudioRouteChange
                    // skips when userExplicitlyChangedAudioRoute=true.
                    let currentRoute = self.getAudioRoute()
                    let btAvailable = self.isBluetoothAvailableClean()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(btAvailable)",
                        isError: false
                    )
                    self.userExplicitlyChangedAudioRoute = false

                    self.sendPhoneCallEvents(description: "LOG|=== EARPIECE SWITCH COMPLETE ===", isError: false)
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
    /// Category options (to remove BT) are changed separately via applyEarpieceCategoryOptions().
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
    /// Called inline AFTER forceEarpieceRoute() has already switched audio output.
    /// The setCategory() call may briefly interrupt audio, but is necessary to prevent
    /// iOS from auto-routing back to Bluetooth when .allowBluetooth is in the options.
    private func applyEarpieceCategoryOptions() {
        isChangingAudioRoute = true
        defer { isChangingAudioRoute = false }

        do {
            let session = AVAudioSession.sharedInstance()

            // Mark that BT options are temporarily removed — isBluetoothAvailableClean()
            // and the method channel handler will use cachedBluetoothAvailable during this window.
            if cachedBluetoothAvailable {
                btOptionsTemporarilyRemoved = true
            }

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
        defer {
            isChangingAudioRoute = false
            // Clear the transitional flag — BT options are now restored
            btOptionsTemporarilyRemoved = false
        }

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
            var btFound = false
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if (input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE)
                        && isRealBluetoothDevice(input) {
                        cachedBluetoothAvailable = true
                        btFound = true
                        self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: BT device found in inputs after restore: \(input.portName)", isError: false)
                        break
                    }
                }
            }

            // Send updated AudioRoute event to Dart with correct BT availability
            // This corrects any earlier events that reported btAvailable=false during the
            // transitional window when .allowBluetooth was removed from the category.
            if btFound {
                let currentRoute = self.getAudioRoute()
                self.sendPhoneCallEvents(
                    description: "AudioRoute|\(currentRoute)|bluetoothAvailable=true",
                    isError: false
                )
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: Failed - \(error.localizedDescription)", isError: false)
        }
    }

    // MARK: AVAudioSession
    func toggleAudioRoute(toSpeaker: Bool) {
        // Store the desired speaker state
        desiredSpeakerState = toSpeaker
        
        // Update ringback audio route if playing (before call is fully connected)
        if isPlayingRingback {
            updateRingbackAudioRoute()
        }

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

        // Mark BT options as temporarily removed — isBluetoothAvailableClean() and the
        // method channel handler will use cachedBluetoothAvailable during the transition.
        if cachedBluetoothAvailable {
            btOptionsTemporarilyRemoved = true
        }

        // Move ALL AVAudioSession operations to background queue to avoid blocking the main/UI thread.
        audioSessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.logAudioSessionState(label: "BEFORE applySpeakerSetting toSpeaker=\(toSpeaker)")
            
            if toSpeaker {
                // === SPEAKER SWITCH ===
                // Simple approach (inspired by StackOverflow):
                // overrideOutputAudioPort(.speaker) is the ONLY call needed — takes effect
                // within milliseconds. No setCategory() needed, avoiding the 1-4s audio pipeline
                // rebuild that causes the audio lag.
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER START ===", isError: false)
                self.forceSpeakerRoute()
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER COMPLETE ===", isError: false)
            } else {
                // === EARPIECE SWITCH ===
                // Simple approach: setPreferredInput(builtInMic) + overrideOutputAudioPort(.none)
                // followed by a category change to remove .allowBluetooth (prevents iOS from
                // auto-switching back to BT). The category change is done inline because on
                // earpiece, if .allowBluetooth remains, iOS will auto-route back to BT.
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE START ===", isError: false)
                self.forceEarpieceRoute()
                
                // Apply earpiece category options immediately (not deferred) — on earpiece,
                // we MUST remove .allowBluetooth from the category to prevent iOS from
                // auto-switching back to BT. Unlike speaker (which has a hard override),
                // earpiece relies on category options to stay on the built-in receiver.
                self.applyEarpieceCategoryOptions()
                
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE COMPLETE ===", isError: false)
            }
            
            self.logAudioSessionState(label: "AFTER applySpeakerSetting toSpeaker=\(toSpeaker)")

            // Send AudioRoute event to Dart layer. Since userExplicitlyChangedAudioRoute=true,
            // the handleAudioRouteChange handlers will skip sending events. We must send it here.
            let currentRoute = self.getAudioRoute()
            let btAvailable = self.isBluetoothAvailableClean()
            self.sendPhoneCallEvents(
                description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(btAvailable)",
                isError: false
            )

            // Clear the explicit change flag so future system-initiated route changes
            // (e.g., BT disconnect) are handled normally by handleAudioRouteChange.
            self.userExplicitlyChangedAudioRoute = false
        }
    }
    
    /// Force audio to speaker using overrideOutputAudioPort ONLY.
    /// Does NOT call setCategory() — speaker override is strong enough to route audio
    /// without changing category options, avoiding the 1-4s audio pipeline rebuild lag.
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

            // Mark that BT options are temporarily removed — isBluetoothAvailableClean()
            // and the method channel handler will use cachedBluetoothAvailable during this window.
            if cachedBluetoothAvailable {
                btOptionsTemporarilyRemoved = true
            }

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
    
    // MARK: - Ringback Tone Management

    /// Starts playing the ringback tone for outgoing calls.
    /// Respects the current desired audio route (speaker, bluetooth, earpiece).
    private func startRingbackTone() {
        guard !isPlayingRingback else {
            self.sendPhoneCallEvents(description: "LOG|Ringback already playing", isError: false)
            return
        }

        // Find the ringback audio file in the plugin bundle
        guard let ringbackURL = findRingbackAudioFile() else {
            self.sendPhoneCallEvents(description: "LOG|Ringback audio file not found", isError: false)
            return
        }

        do {
            // Configure audio session for ringback playback
            try configureAudioSessionForRingback()

            // Create and configure the audio player
            ringbackPlayer = try AVAudioPlayer(contentsOf: ringbackURL)
            ringbackPlayer?.delegate = self
            ringbackPlayer?.numberOfLoops = -1 // Loop indefinitely
            ringbackPlayer?.volume = 1.0

            // Prepare and play
            ringbackPlayer?.prepareToPlay()
            ringbackPlayer?.play()
            isPlayingRingback = true

            self.sendPhoneCallEvents(description: "LOG|Started ringback tone, speaker: \(desiredSpeakerState), bluetooth: \(desiredBluetoothState)", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|Failed to start ringback: \(error.localizedDescription)", isError: false)
        }
    }

    /// Stops the ringback tone
    private func stopRingbackTone() {
        guard isPlayingRingback else { return }

        ringbackPlayer?.stop()
        ringbackPlayer = nil
        isPlayingRingback = false

        self.sendPhoneCallEvents(description: "LOG|Stopped ringback tone", isError: false)
    }

    /// Finds the ringback audio file in the plugin bundle
    /// - Returns: URL to the ringback audio file, or nil if not found
    private func findRingbackAudioFile() -> URL? {
        let supportedExtensions = ["mp3", "wav", "m4a", "caf", "aiff"]
        let fileName = "ringback"

        // First, try to find in the main bundle (for when the file is in the app)
        for ext in supportedExtensions {
            if let url = Bundle.main.url(forResource: fileName, withExtension: ext) {
                self.sendPhoneCallEvents(description: "LOG|Found ringback in main bundle: \(url.lastPathComponent)", isError: false)
                return url
            }
        }

        // Try to find in the plugin's bundle
        let pluginBundle = Bundle(for: SwiftTwilioVoicePlugin.self)
        for ext in supportedExtensions {
            if let url = pluginBundle.url(forResource: fileName, withExtension: ext) {
                self.sendPhoneCallEvents(description: "LOG|Found ringback in plugin bundle: \(url.lastPathComponent)", isError: false)
                return url
            }
        }

        // Try to find in a specific Assets folder within the plugin bundle
        if let resourcePath = pluginBundle.resourcePath {
            let assetsPath = (resourcePath as NSString).appendingPathComponent("Assets")
            for ext in supportedExtensions {
                let filePath = (assetsPath as NSString).appendingPathComponent("\(fileName).\(ext)")
                if FileManager.default.fileExists(atPath: filePath) {
                    self.sendPhoneCallEvents(description: "LOG|Found ringback in Assets: \(filePath)", isError: false)
                    return URL(fileURLWithPath: filePath)
                }
            }
        }

        return nil
    }

    /// Configures the audio session for ringback tone playback.
    /// Respects current desired audio route: speaker, bluetooth, or earpiece.
    private func configureAudioSessionForRingback() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Use playAndRecord category to allow switching between speaker, earpiece, and bluetooth.
        // Include .allowBluetooth so BT devices can be used if desired.
        // Do NOT use .defaultToSpeaker — it forces speaker mode on initially.
        var categoryOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if desiredSpeakerState {
            categoryOptions.insert(.defaultToSpeaker)
        }
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: categoryOptions)
        try audioSession.setActive(true)

        // Apply the current audio route preference
        if desiredSpeakerState {
            try audioSession.overrideOutputAudioPort(.speaker)
        } else if desiredBluetoothState {
            // Try to route to Bluetooth
            try audioSession.overrideOutputAudioPort(.none)
            if let availableInputs = audioSession.availableInputs {
                for input in availableInputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        try audioSession.setPreferredInput(input)
                        break
                    }
                }
            }
        } else {
            try audioSession.overrideOutputAudioPort(.none)
        }
    }

    /// Updates the ringback audio route when user changes audio output during ringing.
    /// Respects speaker, bluetooth, and earpiece states.
    private func updateRingbackAudioRoute() {
        guard isPlayingRingback else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            if desiredSpeakerState {
                try audioSession.overrideOutputAudioPort(.speaker)
                self.sendPhoneCallEvents(description: "LOG|Ringback switched to speaker", isError: false)
            } else if desiredBluetoothState {
                try audioSession.overrideOutputAudioPort(.none)
                if let availableInputs = audioSession.availableInputs {
                    for input in availableInputs {
                        if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                            try audioSession.setPreferredInput(input)
                            break
                        }
                    }
                }
                self.sendPhoneCallEvents(description: "LOG|Ringback switched to bluetooth", isError: false)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
                // Set preferred input to built-in mic for earpiece
                if let availableInputs = audioSession.availableInputs {
                    for input in availableInputs {
                        if input.portType == .builtInMic {
                            try audioSession.setPreferredInput(input)
                            break
                        }
                    }
                }
                self.sendPhoneCallEvents(description: "LOG|Ringback switched to earpiece", isError: false)
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|Failed to update ringback audio route: \(error.localizedDescription)", isError: false)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // This shouldn't be called since we loop indefinitely, but handle it just in case
        if player == ringbackPlayer && !flag {
            self.sendPhoneCallEvents(description: "LOG|Ringback playback finished unexpectedly", isError: false)
            isPlayingRingback = false
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if player == ringbackPlayer {
            self.sendPhoneCallEvents(description: "LOG|Ringback decode error: \(error?.localizedDescription ?? "unknown")", isError: false)
            stopRingbackTone()
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
            // Snapshot current audio state BEFORE suppressing so method channel queries
            // during the suppression window return the last known good values instead
            // of hardcoded earpiece/false. This prevents the UI from flickering to "Phone"
            // when BT was already active during the ringing phase.
            let routeSnapshot = self.getAudioRoute()
            var btSnapshot = self.isBluetoothAvailableSafe()
            
            // FALLBACK: If BT is not in currentRoute, check availableInputs.
            // During didActivateAudioSession, CallKit may not have routed audio
            // to BT yet even though BT is physically connected.
            if !btSnapshot {
                if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                    for input in availableInputs {
                        if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                            btSnapshot = true
                            self.sendPhoneCallEvents(description: "LOG|didActivateAudioSession: BT not in currentRoute but found in availableInputs — snapshot btAvailable=true", isError: false)
                            break
                        }
                    }
                }
            }
            
            self.preSuppressAudioRoute = btSnapshot ? "bluetooth" : routeSnapshot
            self.preSuppressBtAvailable = btSnapshot
            self.sendPhoneCallEvents(description: "LOG|didActivateAudioSession: pre-suppress snapshot: route=\(self.preSuppressAudioRoute ?? "nil"), btAvailable=\(self.preSuppressBtAvailable ?? false)", isError: false)

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
                self?.preSuppressAudioRoute = nil
                self?.preSuppressBtAvailable = nil
                return
            }

            // Use clean BT check — during active CallKit call this will trust
            // availableInputs (non-destructive path) instead of running the
            // destructive checkBluetoothWithCategoryChange() test
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
            self.preSuppressAudioRoute = nil
            self.preSuppressBtAvailable = nil
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
    
    /// Tracks a pending hold UUID during a swap so the unhold action can detect
    /// it's part of a swap and emit a single "Swap" event instead of separate Hold/Unhold.
    private var pendingSwapHoldUUID: UUID? = nil
    /// Safety timer: if Hold fires but Unhold never arrives, fall back to sending Hold
    private var pendingSwapSafetyTimer: Timer? = nil

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction: uuid=\(action.callUUID) isOnHold=\(action.isOnHold) callsCount=\(self.calls.count)", isError: false)
        if let call = self.calls[action.callUUID] {
            let wasAlreadyInTargetState = (call.isOnHold == action.isOnHold)
            call.isOnHold = action.isOnHold

            if action.isOnHold {
                // === HOLD ===
                if wasAlreadyInTargetState {
                    // Duplicate hold (e.g., CXAnswerCallAction already set isOnHold=true
                    // synchronously, then the async CXSetHeldCallAction arrives). Ignore.
                    self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: skipping duplicate Hold event (already in target state)", isError: false)
                } else {
                    // Check if this is part of a swap: 2+ calls exist
                    // (i.e., the user tapped "Swap" in CallKit, which holds the active call
                    //  and then unholds the held call)
                    let otherCallsExist = self.calls.values.contains(where: { $0.uuid != action.callUUID })
                    if otherCallsExist {
                        // This is the first half of a swap - remember this UUID
                        // so the upcoming Unhold can detect it and emit a "Swap" event
                        self.pendingSwapHoldUUID = action.callUUID
                        self.pendingSwapSafetyTimer?.invalidate()
                        self.pendingSwapSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                            guard let self = self, self.pendingSwapHoldUUID != nil else { return }
                            self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: Swap safety timeout - Unhold never arrived, sending fallback Hold", isError: false)
                            self.pendingSwapHoldUUID = nil
                            self.sendPhoneCallEvents(description: "Hold|\(call.sid)", isError: false)
                        }
                        self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: HOLD detected as swap (pendingSwapHoldUUID=\(action.callUUID)), deferring event", isError: false)
                        // DON'T send "Hold" to Flutter - wait for the Unhold to send "Swap"
                    } else {
                        // Single call hold (e.g., user tapped hold button)
                        self.sendPhoneCallEvents(description: "Hold|\(call.sid)", isError: false)
                    }
                }
            } else {
                // === UNHOLD ===
                // Update activeCallUUID FIRST so self.call returns the correct call
                self.activeCallUUID = action.callUUID

                if let heldUUID = self.pendingSwapHoldUUID {
                    // This Unhold completes a swap! Send a single "Swap" event
                    // with the now-active call's info so Flutter can do an atomic swap
                    self.pendingSwapHoldUUID = nil
                    self.pendingSwapSafetyTimer?.invalidate()
                    self.pendingSwapSafetyTimer = nil

                    let from = extractUserNumber(from: call.from ?? self.identity)
                    let to = call.to ?? self.callTo
                    // Determine direction: if this call's UUID was never in callOutgoing context,
                    // we check if it was originally an incoming call by checking the from field
                    // For swap, we include the now-active call's from/to so Dart can identify it
                    self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: SWAP completed - now active uuid=\(action.callUUID) from=\(from) to=\(to), held uuid=\(heldUUID)", isError: false)
                    self.sendPhoneCallEvents(description: "Swap|\(call.sid)|\(from)|\(to)", isError: false)
                } else {
                    // Regular unhold (e.g., after held call ends and remaining call is restored)
                    if !wasAlreadyInTargetState {
                        self.sendPhoneCallEvents(description: "Unhold|\(call.sid)", isError: false)
                    } else {
                        self.sendPhoneCallEvents(description: "LOG|performSetHeldAction: skipping duplicate Unhold event (already in target state)", isError: false)
                    }
                }
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
                self.sendPhoneCallEvents(description: "Call Ended|\(uuid.uuidString)", isError: false)
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
        // Snapshot current audio state BEFORE suppressing so method channel queries
        // during the suppression window return last known good values.
        self.preSuppressAudioRoute = self.getAudioRoute()
        self.preSuppressBtAvailable = self.isBluetoothAvailableClean()
        // Suppress audio route events during call setup (same as answer path)
        self.suppressAudioRouteEvents = true

        // Safety: auto-lift suppress after 3s in case applyInitialAudioRoute never runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.suppressAudioRouteEvents == true {
                self?.sendPhoneCallEvents(description: "LOG|performVoiceCall: Safety timeout — lifting suppressAudioRouteEvents", isError: false)
                self?.suppressAudioRouteEvents = false
                self?.preSuppressAudioRoute = nil
                self?.preSuppressBtAvailable = nil
            }
        }

        guard let token = accessToken else {
            completionHandler(false)
            return
        }
        
        // Send Connecting event before initiating the call
        // Note: call.sid is not available yet (call hasn't connected to Twilio)
        // Use the UUID as a temporary identifier; the real SID will arrive with Connected
        let from = self.identity
        let to = self.callTo
        self.sendPhoneCallEvents(description: "Connecting|\(uuid.uuidString)|\(from)|\(to)|Outgoing", isError: false)
        
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
        // Snapshot current audio state BEFORE suppressing so method channel queries
        // during the suppression window return last known good values.
        let routeSnapshot = self.getAudioRoute()
        var btSnapshot = self.isBluetoothAvailableSafe()
        
        // FALLBACK: If BT is not in currentRoute (safe check), also check
        // availableInputs. At answer time, CallKit hasn't activated the audio session
        // yet, so BT may be in availableInputs but not currentRoute. Without this
        // fallback, the snapshot captures earpiece/false even though AirPods are
        // physically connected, causing the UI to show "Phone" during the suppression window.
        if !btSnapshot {
            if let availableInputs = AVAudioSession.sharedInstance().availableInputs {
                for input in availableInputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        btSnapshot = true
                        self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: BT not in currentRoute but found in availableInputs — snapshot btAvailable=true", isError: false)
                        break
                    }
                }
            }
        }
        
        self.preSuppressAudioRoute = btSnapshot ? "bluetooth" : routeSnapshot
        self.preSuppressBtAvailable = btSnapshot
        // It will be lifted after applyInitialAudioRoute completes.
        self.suppressAudioRouteEvents = true

        // Safety: auto-lift suppress after 3s in case applyInitialAudioRoute never runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.suppressAudioRouteEvents == true {
                self?.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: Safety timeout — lifting suppressAudioRouteEvents", isError: false)
                self?.suppressAudioRouteEvents = false
                self?.preSuppressAudioRoute = nil
                self?.preSuppressBtAvailable = nil
            }
        }

        // Look up the call invite by UUID
        if let ci = self.callInvites[uuid] {
            let acceptOptions: AcceptOptions = AcceptOptions(callInvite: ci) { (builder) in
                builder.uuid = ci.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call uuid=\(uuid)", isError: false)
            let theCall = ci.accept(options: acceptOptions, delegate: self)
            let answerSid = ci.callSid
            let answerFrom = extractUserNumber(from: theCall.from ?? self.identity)
            let answerTo = theCall.to ?? self.callTo
            self.sendPhoneCallEvents(description: "Answer|\(answerSid)|\(answerFrom)|\(answerTo)|Incoming\(formatCustomParams(params: ci.customParameters))", isError:false)
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

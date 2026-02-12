import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit
import UserNotifications

public class SwiftTwilioVoicePlugin: NSObject, FlutterPlugin,  FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate, CXCallObserverDelegate {
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
        
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = Set([PKPushType.voIP])

        let appDelegate = UIApplication.shared.delegate
        guard let controller = appDelegate?.window??.rootViewController as? FlutterViewController else {
            fatalError("rootViewController is not type FlutterViewController")
        }
        let registrar = controller.registrar(forPlugin: "twilio_voice")
        if let unwrappedRegistrar = registrar {
            let eventChannel = FlutterEventChannel(name: "twilio_voice/events", binaryMessenger: unwrappedRegistrar.messenger())
            eventChannel.setStreamHandler(self)
        }
        
        // Configure AVAudioSession to support Bluetooth from the start
        configureAudioSessionForBluetooth()
        
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
        
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        let reasonStr = reason.map { String($0.rawValue) } ?? "unknown"
        
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
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
                
                // IMPORTANT: Force reset cached Bluetooth availability and check fresh
                self.cachedBluetoothAvailable = false
                self.hasCheckedBluetoothOnCallStart = false
                let bluetoothAvailableNow = self.checkBluetoothAvailableFresh()
                
                self.sendPhoneCallEvents(description: "LOG|oldDeviceUnavailable: wasBluetoothDisconnected=\(wasBluetoothDisconnected), btAvailableNow=\(bluetoothAvailableNow), desiredBT=\(self.desiredBluetoothState)", isError: false)
                
                // If Bluetooth was disconnected OR we were using Bluetooth and it's no longer available
                if wasBluetoothDisconnected || (self.desiredBluetoothState && !bluetoothAvailableNow) {
                    self.sendPhoneCallEvents(description: "LOG|Bluetooth disconnected - forcing switch to earpiece", isError: false)
                    
                    // Update our state trackers to reflect reality
                    self.desiredBluetoothState = false
                    // Don't change speaker state - keep it as-is
                    // Reset user explicit flag so auto-connect can work when BT reconnects
                    self.userExplicitlyChangedAudioRoute = false
                    
                    // Force earpiece route to ensure audio continues
                    if !self.desiredSpeakerState {
                        self.forceEarpieceRoute()
                    }
                    
                    // Notify Dart layer with updated state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let currentRoute = self.getAudioRoute()
                        self.sendPhoneCallEvents(description: "LOG|Bluetooth disconnect handled. New route: \(currentRoute), btAvailable: \(bluetoothAvailableNow)", isError: false)
                        
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(bluetoothAvailableNow)",
                            isError: false
                        )
                    }
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
            
            // IMPORTANT: Reset cached Bluetooth state to force fresh detection
            self.cachedBluetoothAvailable = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Force fresh Bluetooth check by temporarily enabling BT options
                let isBluetoothAvailable = self.checkBluetoothAvailableFresh()
                
                self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: btAvailable=\(isBluetoothAvailable), desiredBT=\(self.desiredBluetoothState), desiredSpeaker=\(self.desiredSpeakerState), userExplicitlyChanged=\(self.userExplicitlyChangedAudioRoute)", isError: false)
                
                // Update cache
                self.cachedBluetoothAvailable = isBluetoothAvailable
                
                // Auto-switch to Bluetooth if:
                // - Bluetooth is available
                // - User hasn't explicitly chosen speaker
                // Note: We removed the check for !desiredBluetoothState to allow reconnection
                // when Bluetooth reconnects after being disconnected
                if isBluetoothAvailable && !self.desiredSpeakerState {
                    self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: Auto-switching to Bluetooth...", isError: false)
                    
                    // Reset user explicit flag to allow auto-switching
                    self.userExplicitlyChangedAudioRoute = false
                    
                    // Auto-switch to Bluetooth
                    self.desiredBluetoothState = true
                    self.desiredSpeakerState = false
                    
                    // Use the proper Bluetooth route application
                    self.applyBluetoothRoute()
                    
                    // Notify Dart after a short delay to let route settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let currentRoute = self.getAudioRoute()
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=true",
                            isError: false
                        )
                    }
                } else {
                    self.sendPhoneCallEvents(description: "LOG|newDeviceAvailable: NOT auto-switching (user explicitly chose speaker)", isError: false)
                    
                    // Even if not auto-switching, ALWAYS notify Dart that Bluetooth is now available
                    // This ensures the Bluetooth option appears in the popup
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                        isError: false
                    )
                }
            }
            
        case .categoryChange:
            // Category changed - this is often triggered by OUR changes
            // Only report if there's a meaningful change
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: categoryChange detected", isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Force fresh Bluetooth check
                self.cachedBluetoothAvailable = false
                self.hasCheckedBluetoothOnCallStart = false
                let isBluetoothAvailable = self.checkBluetoothAvailableFresh()
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange categoryChange: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
                
                // CRITICAL: If we wanted Bluetooth but it's no longer available, switch to earpiece
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|categoryChange: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.forceEarpieceRoute()
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let currentRoute = self.getAudioRoute()
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=false",
                            isError: false
                        )
                    }
                } else {
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                        isError: false
                    )
                }
            }
            
        case .override:
            // Override happened - log it but don't change our desired state
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: override detected", isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Force fresh Bluetooth check
                self.cachedBluetoothAvailable = false
                self.hasCheckedBluetoothOnCallStart = false
                let isBluetoothAvailable = self.checkBluetoothAvailableFresh()
                let actualSystemRoute = self.getActualSystemAudioRoute()
                
                self.sendPhoneCallEvents(
                    description: "LOG|handleAudioRouteChange override: desiredBT=\(self.desiredBluetoothState), actualSystemRoute=\(actualSystemRoute), btAvailable=\(isBluetoothAvailable)",
                    isError: false
                )
                
                // CRITICAL: If we wanted Bluetooth but it's no longer available, switch to earpiece
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|override: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.forceEarpieceRoute()
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let currentRoute = self.getAudioRoute()
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=false",
                            isError: false
                        )
                    }
                } else {
                    let currentRoute = self.getAudioRoute()
                    self.sendPhoneCallEvents(
                        description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(isBluetoothAvailable)",
                        isError: false
                    )
                }
            }
            
        default:
            // Handle any other route change reason - still check if Bluetooth was lost
            self.sendPhoneCallEvents(description: "LOG|handleAudioRouteChange: unhandled reason \(reasonStr)", isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Force fresh Bluetooth check for any unhandled route change
                self.cachedBluetoothAvailable = false
                self.hasCheckedBluetoothOnCallStart = false
                let isBluetoothAvailable = self.checkBluetoothAvailableFresh()
                
                // If we wanted Bluetooth but it's no longer available, switch to earpiece
                if self.desiredBluetoothState && !isBluetoothAvailable {
                    self.sendPhoneCallEvents(description: "LOG|default handler: Bluetooth was desired but no longer available - switching to earpiece", isError: false)
                    self.desiredBluetoothState = false
                    self.userExplicitlyChangedAudioRoute = false
                    
                    if !self.desiredSpeakerState {
                        self.forceEarpieceRoute()
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let currentRoute = self.getAudioRoute()
                        self.sendPhoneCallEvents(
                            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=false",
                            isError: false
                        )
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
                self.sendPhoneCallEvents(description: "LOG|Device token is nil. Cannot register for VoIP push notifications.", isError: true)
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
            
            // Send response to method call
            result(true)
            
            guard let eventSink = eventSink else {
                return
            }
            // Return the actual state after attempting to set it
            let actualState = isSpeakerOn()
            eventSink(actualState ? "Speaker On" : "Speaker Off")
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
            let audioRoute = getAudioRoute()
            result(audioRoute)
        }
        else if flutterCall.method == "isBluetoothAvailable"
        {
            let bluetoothAvailable = isBluetoothAvailable()
            result(bluetoothAvailable)
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
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials device token unchanged, no update needed.", isError: true)
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
            self.sendPhoneCallEvents(description: "LOG|Missing required parameters to unregister", isError: true)
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
        
        // Check current audio route and Bluetooth availability and emit to Dart
        let currentRoute = getAudioRoute()
        let bluetoothAvailable = isBluetoothAvailable()
        self.sendPhoneCallEvents(
            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(bluetoothAvailable)",
            isError: false
        )
        
        self.sendPhoneCallEvents(description: "LOG|Call connected. Current audio route: \(currentRoute), Bluetooth available: \(bluetoothAvailable)", isError: false)
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
            self.sendPhoneCallEvents(description: "Call Failed: \(error.localizedDescription)", isError: true)
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
        
        if let uuid = call.uuid {
            callDisconnected(uuid: uuid)
        }
        
        // Only send "Call Ended" if no other calls remain
        if self.calls.isEmpty {
            self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        } else {
            self.sendPhoneCallEvents(description: "LOG|Call disconnected but other calls remain, suppressing Call Ended", isError: false)
            
            // Check if the disconnected call was the held call (not the active one)
            if let uuid = call.uuid, uuid != self.activeCallUUID {
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
            
            // Reset audio state when ALL calls end
            desiredSpeakerState = false
            desiredBluetoothState = false
            userExplicitlyChangedAudioRoute = false
            cachedBluetoothAvailable = false
            hasCheckedBluetoothOnCallStart = false
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
    /// First checks tracked desired state, then falls back to system state
    func getAudioRoute() -> String {
        // First priority: check if we explicitly set Bluetooth (even if system hasn't updated yet)
        if desiredBluetoothState {
            // Bluetooth was explicitly set, trust it even if system hasn't updated
            self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'bluetooth' from desiredBluetoothState", isError: false)
            return "bluetooth"
        }
        
        // Second priority: check if we explicitly set speaker
        if desiredSpeakerState {
            self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'speaker' from desiredSpeakerState", isError: false)
            return "speaker"
        }
        
        // Third priority: If neither is set, we're on earpiece
        // Don't query the system state as it may be stale or cause the route to flip back
        self.sendPhoneCallEvents(description: "LOG|getAudioRoute: returning 'earpiece' (neither bluetooth nor speaker desired)", isError: false)
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

    /// Force a fresh Bluetooth availability check by temporarily enabling Bluetooth options
    /// Use this when a new device connects to ensure we detect it
    private func checkBluetoothAvailableFresh() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // First: Check current route - if we're already on Bluetooth, it's available
        for output in audioSession.currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Found in current route", isError: false)
                return true
            }
        }
        
        // Second: Temporarily enable Bluetooth options to detect newly connected devices
        do {
            let currentCategory = audioSession.category
            let currentMode = audioSession.mode
            let currentOptions = audioSession.categoryOptions
            
            // Enable Bluetooth options temporarily
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            
            // Check available inputs
            var foundBluetooth = false
            if let availableInputs = audioSession.availableInputs {
                for input in availableInputs {
                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                        self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Found device: \(input.portName)", isError: false)
                        foundBluetooth = true
                        break
                    }
                }
            }
            
            // If Bluetooth found, keep the options enabled
            if !foundBluetooth {
                // Restore original settings if no Bluetooth found
                try audioSession.setCategory(currentCategory, mode: currentMode, options: currentOptions)
            }
            
            return foundBluetooth
        } catch {
            self.sendPhoneCallEvents(description: "LOG|checkBluetoothAvailableFresh: Error - \(error.localizedDescription)", isError: false)
            return false
        }
    }

    /// Check if a Bluetooth device is available/connected
    func isBluetoothAvailable() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        // First check: Are we currently using Bluetooth?
        for output in currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE {
                self.sendPhoneCallEvents(description: "LOG|Bluetooth found in current route: \(output.portType.rawValue)", isError: false)
                cachedBluetoothAvailable = true
                return true
            }
        }
        
        // Second check: Check all available inputs with current settings
        if let availableInputs = audioSession.availableInputs {
            for input in availableInputs {
                if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                    self.sendPhoneCallEvents(description: "LOG|Bluetooth found in available inputs: \(input.portType.rawValue)", isError: false)
                    cachedBluetoothAvailable = true
                    return true
                }
            }
        }
        
        // Third check: If we've cached Bluetooth as available but switched away from it,
        // trust the cached value (user might be on earpiece/speaker but BT is still connected)
        // This avoids doing temporary category changes that could disrupt audio
        if cachedBluetoothAvailable && hasCheckedBluetoothOnCallStart {
            self.sendPhoneCallEvents(description: "LOG|Using cached Bluetooth availability: true", isError: false)
            return true
        }
        
        // Fourth check: For initial check at call start (or if not cached), 
        // do a safe temporary check
        // Only do this if we haven't explicitly set earpiece mode
        if !hasCheckedBluetoothOnCallStart || !userExplicitlyChangedAudioRoute {
            do {
                let currentCategory = audioSession.category
                let currentMode = audioSession.mode
                let currentOptions = audioSession.categoryOptions
                
                // Temporarily set category with Bluetooth options to reveal Bluetooth devices
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
                
                // Now check available inputs - Bluetooth devices should appear
                var foundBluetooth = false
                if let availableInputs = audioSession.availableInputs {
                    for input in availableInputs {
                        if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
                            self.sendPhoneCallEvents(description: "LOG|Bluetooth device detected (temp check): \(input.portType.rawValue) - \(input.portName)", isError: false)
                            foundBluetooth = true
                            cachedBluetoothAvailable = true
                            break
                        }
                    }
                }
                
                // IMPORTANT: Restore original category settings immediately
                try audioSession.setCategory(currentCategory, mode: currentMode, options: currentOptions)
                
                // Re-apply current route preference to counter any auto-switch
                if desiredSpeakerState {
                    try audioSession.overrideOutputAudioPort(.speaker)
                } else if !desiredBluetoothState {
                    // Earpiece mode - set built-in mic as preferred
                    if let availableInputs = audioSession.availableInputs {
                        for input in availableInputs {
                            if input.portType == .builtInMic {
                                try audioSession.setPreferredInput(input)
                                break
                            }
                        }
                    }
                    try audioSession.overrideOutputAudioPort(.none)
                }
                
                if foundBluetooth {
                    return true
                }
            } catch {
                self.sendPhoneCallEvents(description: "LOG|Error in temporary Bluetooth check: \(error.localizedDescription)", isError: false)
            }
        }
        
        self.sendPhoneCallEvents(description: "LOG|No Bluetooth device found", isError: false)
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
        
        // Ensure we're on the main thread for audio session changes
        DispatchQueue.main.async {
            let audioSession = AVAudioSession.sharedInstance()
            
            if bluetoothOn {
                // Enable Bluetooth
                // Track that we're setting Bluetooth
                self.desiredBluetoothState = true
                self.desiredSpeakerState = false
                self.logAudioSessionState(label: "BEFORE Bluetooth Toggle ON")
                
                do {
                    // Step 1: FIRST set category with Bluetooth options to make BT available again
                    try audioSession.setCategory(
                        AVAudioSession.Category.playAndRecord,
                        options: [.allowBluetoothA2DP, .allowBluetooth]
                    )
                    self.sendPhoneCallEvents(description: "LOG|Category set with Bluetooth options", isError: false)
                    
                    // Step 2: Wait a tiny bit for iOS to recognize BT devices after category change
                    // then find and set the Bluetooth input
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        do {
                            // Re-fetch available inputs after category change
                            if let availableInputs = audioSession.availableInputs {
                                self.sendPhoneCallEvents(description: "LOG|Available inputs after category change: \(availableInputs.map { $0.portType.rawValue })", isError: false)
                                
                                var bluetoothFound = false
                                for input in availableInputs {
                                    if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
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
                self.desiredBluetoothState = false
                self.desiredSpeakerState = false
                self.userExplicitlyChangedAudioRoute = true
                
                self.sendPhoneCallEvents(description: "LOG|=== EARPIECE SWITCH START ===", isError: false)
                
                // Force earpiece by setting category and preferred input multiple times
                // This is a workaround for Twilio/iOS fighting over audio route
                self.forceEarpieceRoute()
                
                // Schedule multiple attempts to ensure earpiece sticks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.sendPhoneCallEvents(description: "LOG|Earpiece attempt 2 (0.3s delay)...", isError: false)
                    self.forceEarpieceRoute()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.sendPhoneCallEvents(description: "LOG|Earpiece attempt 3 (0.7s delay)...", isError: false)
                    self.forceEarpieceRoute()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let session = AVAudioSession.sharedInstance()
                    self.sendPhoneCallEvents(description: "LOG|=== FINAL CHECK (1.5s) ===", isError: false)
                    self.sendPhoneCallEvents(description: "LOG|Final outputs: \(session.currentRoute.outputs.map { "\($0.portType.rawValue)" })", isError: false)
                    self.sendPhoneCallEvents(description: "LOG|Final inputs: \(session.currentRoute.inputs.map { "\($0.portType.rawValue)" })", isError: false)
                    
                    // Now restore Bluetooth options so user can switch back to BT if they want
                    self.restoreBluetoothOptionsKeepingCurrentRoute()
                }
            }
        }
    }
    
    /// Force audio to earpiece by temporarily removing Bluetooth options
    private func forceEarpieceRoute() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Log current state
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: Current outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
            
            // Step 1: Set category WITHOUT Bluetooth options to force iOS to use built-in
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: []  // NO Bluetooth - forces built-in devices
            )
            
            // Step 2: Set built-in mic as preferred
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try session.setPreferredInput(input)
                        self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: Set preferredInput to builtInMic", isError: false)
                        break
                    }
                }
            }
            
            // Step 3: Override to earpiece (not speaker)
            try session.overrideOutputAudioPort(.none)
            
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute: After - outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|forceEarpieceRoute FAILED: \(error.localizedDescription)", isError: false)
        }
    }
    
    /// Restore Bluetooth options in category while keeping current route (earpiece or speaker)
    /// NOTE: We no longer restore Bluetooth options automatically because iOS auto-switches
    /// to Bluetooth when .allowBluetooth is in category options, even with preferredInput set.
    /// Instead, Bluetooth options are only added when user explicitly selects Bluetooth.
    private func restoreBluetoothOptionsKeepingCurrentRoute() {
        // DO NOTHING - Don't restore Bluetooth options!
        // This was causing iOS to auto-switch back to Bluetooth.
        // Bluetooth will be enabled only when user explicitly taps Bluetooth option.
        let session = AVAudioSession.sharedInstance()
        let currentOutputs = session.currentRoute.outputs.map { $0.portType.rawValue }
        self.sendPhoneCallEvents(description: "LOG|restoreBluetoothOptions: SKIPPED (would cause auto-switch). Current outputs = \(currentOutputs)", isError: false)
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
        // Ensure we're on the main thread for audio session changes
        DispatchQueue.main.async {
            // Track the desired audio state
            self.desiredSpeakerState = toSpeaker
            self.desiredBluetoothState = false
            self.userExplicitlyChangedAudioRoute = true
            
            self.logAudioSessionState(label: "BEFORE applySpeakerSetting toSpeaker=\(toSpeaker)")
            
            if toSpeaker {
                // For speaker: Use forceSpeakerRoute with multiple attempts
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER START ===", isError: false)
                
                self.forceSpeakerRoute()
                
                // Multiple attempts to ensure it sticks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.forceSpeakerRoute()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.forceSpeakerRoute()
                }
                
                // Final check and restore BT options
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let session = AVAudioSession.sharedInstance()
                    self.sendPhoneCallEvents(description: "LOG|=== SPEAKER FINAL CHECK ===", isError: false)
                    self.sendPhoneCallEvents(description: "LOG|Final outputs: \(session.currentRoute.outputs.map { "\($0.portType.rawValue)" })", isError: false)
                    
                    // Restore Bluetooth options
                    self.restoreBluetoothOptionsKeepingCurrentRoute()
                }
                
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting SPEAKER COMPLETE ===", isError: false)
            } else {
                // For earpiece: Use forceEarpieceRoute with multiple attempts
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE START ===", isError: false)
                
                self.forceEarpieceRoute()
                
                // Multiple attempts to ensure it sticks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.forceEarpieceRoute()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.forceEarpieceRoute()
                }
                
                // Final check and restore BT options
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let session = AVAudioSession.sharedInstance()
                    self.sendPhoneCallEvents(description: "LOG|=== EARPIECE FINAL CHECK ===", isError: false)
                    self.sendPhoneCallEvents(description: "LOG|Final outputs: \(session.currentRoute.outputs.map { "\($0.portType.rawValue)" })", isError: false)
                    
                    // Restore Bluetooth options
                    self.restoreBluetoothOptionsKeepingCurrentRoute()
                }
                
                self.sendPhoneCallEvents(description: "LOG|=== applySpeakerSetting EARPIECE COMPLETE ===", isError: false)
            }
            
            self.logAudioSessionState(label: "AFTER applySpeakerSetting toSpeaker=\(toSpeaker)")
        }
    }
    
    /// Force audio to speaker by setting appropriate category options
    private func forceSpeakerRoute() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Log current state
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute: Current outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
            
            // Set category with defaultToSpeaker but NO Bluetooth
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker]  // Speaker but NO Bluetooth
            )
            
            // Set built-in mic as preferred
            if let availableInputs = session.availableInputs {
                for input in availableInputs {
                    if input.portType == .builtInMic {
                        try session.setPreferredInput(input)
                        self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute: Set preferredInput to builtInMic", isError: false)
                        break
                    }
                }
            }
            
            // Override to speaker
            try session.overrideOutputAudioPort(.speaker)
            
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute: After - outputs = \(session.currentRoute.outputs.map { $0.portType.rawValue })", isError: false)
        } catch {
            self.sendPhoneCallEvents(description: "LOG|forceSpeakerRoute FAILED: \(error.localizedDescription)", isError: false)
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
            // Add a small delay to ensure audio session is fully initialized and Bluetooth device is detected
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.applyInitialAudioRoute()
            }
        }
    }
    
    /// Apply initial audio route based on available devices
    private func applyInitialAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        self.logAudioSessionState(label: "BEFORE applyInitialAudioRoute")
        
        // CRITICAL: If user explicitly changed audio route, don't override their choice
        if self.userExplicitlyChangedAudioRoute {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User explicitly changed route, respecting their choice", isError: false)
            return
        }
        
        // If user already explicitly set speaker or bluetooth, respect that
        if self.desiredSpeakerState {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User wants speaker, applying speaker", isError: false)
            self.applySpeakerRoute()
            return
        }
        
        if self.desiredBluetoothState {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: User wants bluetooth, applying bluetooth", isError: false)
            self.applyBluetoothRoute()
            return
        }
        
        // Check if Bluetooth is available
        let bluetoothAvailable = self.isBluetoothAvailable()
        
        if bluetoothAvailable {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: Bluetooth available, applying Bluetooth route", isError: false)
            self.desiredBluetoothState = true
            self.applyBluetoothRoute()
        } else {
            self.sendPhoneCallEvents(description: "LOG|applyInitialAudioRoute: No Bluetooth, using earpiece", isError: false)
            // Default to earpiece - no action needed, it's the default
        }
        
        self.logAudioSessionState(label: "AFTER applyInitialAudioRoute")
        
        // Notify Dart about the current audio route
        let currentRoute = self.getAudioRoute()
        self.sendPhoneCallEvents(
            description: "AudioRoute|\(currentRoute)|bluetoothAvailable=\(bluetoothAvailable)",
            isError: false
        )
    }
    
    /// Apply Bluetooth audio route
    private func applyBluetoothRoute() {
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
            return
        }
        
        // Step 2: Wait a tiny bit for iOS to recognize BT devices, then set preferred input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                // Find the Bluetooth input and set it as preferred
                if let availableInputs = audioSession.availableInputs {
                    self.sendPhoneCallEvents(description: "LOG|applyBluetoothRoute: Available inputs: \(availableInputs.map { "\($0.portType.rawValue):\($0.portName)" })", isError: false)
                    
                    var bluetoothFound = false
                    for input in availableInputs {
                        if input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP || input.portType == .bluetoothLE {
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
            
            // Step 4: Restore Bluetooth options after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                do {
                    try audioSession.setCategory(
                        AVAudioSession.Category.playAndRecord,
                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth]
                    )
                    if let availableInputs = audioSession.availableInputs {
                        for input in availableInputs {
                            if input.portType == .builtInMic {
                                try audioSession.setPreferredInput(input)
                                break
                            }
                        }
                    }
                    try audioSession.overrideOutputAudioPort(.speaker)
                    self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: BT options restored", isError: false)
                } catch {
                    self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: Failed to restore BT - \(error.localizedDescription)", isError: false)
                }
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applySpeakerRoute: FAILED - \(error.localizedDescription)", isError: false)
        }
    }
    
    /// Apply Earpiece audio route
    private func applyEarpieceRoute() {
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
            
            // Step 4: Restore Bluetooth options after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                do {
                    try audioSession.setCategory(
                        AVAudioSession.Category.playAndRecord,
                        options: [.allowBluetoothA2DP, .allowBluetooth]
                    )
                    if let availableInputs = audioSession.availableInputs {
                        for input in availableInputs {
                            if input.portType == .builtInMic {
                                try audioSession.setPreferredInput(input)
                                break
                            }
                        }
                    }
                    try audioSession.overrideOutputAudioPort(.none)
                    self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: BT options restored", isError: false)
                } catch {
                    self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: Failed to restore BT - \(error.localizedDescription)", isError: false)
                }
            }
        } catch {
            self.sendPhoneCallEvents(description: "LOG|applyEarpieceRoute: FAILED - \(error.localizedDescription)", isError: false)
        }
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
            self.sendPhoneCallEvents(description: "LOG|Holding current call \(currentActiveUUID) before answering new call", isError: false)
            
            // 1. Set hold on Twilio SDK immediately
            currentCall.isOnHold = true
            
            // 2. Send Hold event to Flutter IMMEDIATELY so BLoC saves caller data before Connected arrives
            self.sendPhoneCallEvents(description: "Hold", isError: false)
            
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
                self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription).", isError: true)
            } else {
                // Don't send "Call Ended" here - let callDidDisconnect handle it
                // It will check if other calls remain before sending
                self.sendPhoneCallEvents(description: "LOG|EndCallAction transaction successful for uuid=\(uuid)", isError: false)
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
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
        // Look up the call invite by UUID
        if let ci = self.callInvites[uuid] {
            let acceptOptions: AcceptOptions = AcceptOptions(callInvite: ci) { (builder) in
                builder.uuid = ci.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call uuid=\(uuid)", isError: false)
            let theCall = ci.accept(options: acceptOptions, delegate: self)
            self.sendPhoneCallEvents(description: "Answer|\(String(describing: extractUserNumber(from: theCall.from!)))|\(theCall.to!)|Incoming\(formatCustomParams(params: ci.customParameters))", isError:false)
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

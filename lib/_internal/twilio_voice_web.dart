import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// TODO(cybex-dev) implement package:web
// import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:twilio_voice/_internal/js/call/call_status.dart';
import 'package:web/web.dart' as web;
import 'package:web_callkit/web_callkit_web.dart';

import '../twilio_voice.dart';
import './js/js.dart' as twilio_js;
import 'js/core/enums/device_sound_name.dart';
import 'js/device/device_status.dart';
import 'js/utils/js_object_utils.dart';
import 'local_storage_web/local_storage_web.dart';
import 'method_channel/twilio_call_method_channel.dart';
import 'method_channel/twilio_voice_method_channel.dart';
import 'utils.dart';

/// The web implementation of [TwilioVoicePlatform].
class TwilioVoiceWeb extends MethodChannelTwilioVoice {
  
  static const _codecs = ["opus", "pcmu"];
  static const _closeProtection = true;
  final Map<String, String> _soundMap = {};
  late WebCallkitPlatform webCallkit;
  late CKConfiguration _ckConfiguration;

  TwilioVoiceWeb() {
    webCallkit = WebCallkitWeb.instance;
    _ckConfiguration = const CKConfiguration(
      capabilities: {
        CKCapability.supportHold,
        CKCapability.hold,
        CKCapability.mute,
        CKCapability.silence,
      },
      timer: CKTimer(),
      icons: {
        CKCallAction.answer: "icons/answer/128.png",
        CKCallAction.decline: "icons/hangup/128.png",
        CKCallAction.hangUp: "icons/hangup/128.png",
      },
      strictMode: false,
    );
    webCallkit.setConfiguration(_ckConfiguration);
    webCallkit.setOnCallActionHandler(_onCallkitCallActionListener);
  }

  void _onCallkitCallActionListener(String uuid, CKCallAction action, CKActionSource source) {
    printDebug("CallKit action: $action");
    switch (action) {
      case CKCallAction.answer:
        call.answer();
        break;
      case CKCallAction.decline:
        call.hangUp();
        break;
      case CKCallAction.mute:
        call.toggleMute(true);
        break;
      case CKCallAction.unmute:
        call.toggleMute(false);
        break;
      case CKCallAction.hold:
        call.holdCall(holdCall: true);
        break;
      case CKCallAction.unhold:
        call.holdCall(holdCall: false);
        break;
      case CKCallAction.hangUp:
        call.hangUp();
        break;
      // case CKCallAction.callback:
      //   _onRequestCallback(uuid);
      //   break;
      case CKCallAction.silence:
        // repost silent notification
        break;
      default:
        printDebug("Unhandled CallKit action: $action");
    }
  }

  // void _onRequestCallback(String uuid) {
  //   final map = <String, dynamic>{
  //     "uuid": uuid,
  //   };
  //   onRequestCallback?.call(map);
  // }

  final LocalStorageWeb _localStorage = LocalStorageWeb();

  twilio_js.Device? device;

  web.Navigator get _webNavigatorDelegate => web.window.navigator;

  web.Permissions get _webPermissionsDelegate => _webNavigatorDelegate.permissions;

  web.MediaDevices get _webMediaDevicesDelegate => _webNavigatorDelegate.mediaDevices;

  late final Call _call = Call();

  /// Whether the Twilio Device raises `incoming` while already on a call.
  /// Mirrors the SDK's `allowIncomingWhileBusy` device option. See [setAllowIncomingWhileBusy].
  bool get _allowIncomingWhileBusy => _localStorage.getAllowIncomingWhileBusy(true);

  set _allowIncomingWhileBusy(bool value) => _localStorage.saveAllowIncomingWhileBusy(value);

  @override
  Call get call => _call;

  static final TwilioVoicePlatform _instance = TwilioVoiceWeb();

  static void registerWith(Registrar registrar) {
    TwilioVoicePlatform.instance = _instance;
  }

  Stream<CallEvent>? _callEventsListener;

  @override
  Stream<CallEvent> get callEventsListener {
    _callEventsListener ??= callEventsStream.map(parseCallEvent);
    return _callEventsListener!;
  }

  //region Twilio Voice JS SDK loading

  /// Path the bundled Twilio Voice JS SDK is served from in a Flutter web build. Declared as an
  /// asset in this package's `pubspec.yaml`.
  static const String _bundledSdkAssetPath = 'assets/packages/twilio_voice/assets/twilio.min.js';

  /// In-flight/completed SDK load, so concurrent and repeat calls await the same operation.
  Future<void>? _sdkLoadFuture;

  /// Whether the Twilio Voice JS SDK global (`window.Twilio`) is available.
  bool get isSdkLoaded => web.window.hasProperty("Twilio".toJS).toDart;

  /// Ensures the Twilio Voice JS SDK is loaded and `window.Twilio` is available.
  ///
  /// The SDK is bundled with this package, so apps do not need to add a `<script>` tag to their
  /// `web/index.html`. If the SDK is already present - because the app loads it itself (e.g. a
  /// CDN `<script>` tag, as previous versions of this plugin required) - the bundled copy is not
  /// injected and the existing global is used, so existing integrations keep working.
  ///
  /// Called automatically by [setTokens]; exposed so apps can pre-load the SDK earlier (e.g.
  /// during splash) if desired. Completes with an error if the SDK could not be loaded; the
  /// failure is not cached, so a later call will retry.
  Future<void> ensureSdkLoaded() => _sdkLoadFuture ??= _loadSdk();

  Future<void> _loadSdk() async {
    // Already provided by the host app - use it rather than loading a second copy.
    if (isSdkLoaded) {
      return;
    }

    // Resolve against the document base URI so deployments under a non-root `<base href>` work.
    final url = Uri.parse(web.document.baseURI).resolve(_bundledSdkAssetPath).toString();
    logLocalEvent("Loading bundled Twilio Voice JS SDK from '$url'");

    final script = web.HTMLScriptElement()
      ..type = "text/javascript"
      ..async = false
      ..src = url;

    final completer = Completer<void>();
    JSFunction? onLoad;
    JSFunction? onError;

    void finish([Object? error]) {
      if (onLoad != null) script.removeEventListener("load", onLoad);
      if (onError != null) script.removeEventListener("error", onError);
      if (completer.isCompleted) return;
      if (error != null) {
        // Don't cache a failed load - allow a retry on the next call.
        _sdkLoadFuture = null;
        completer.completeError(error);
      } else {
        completer.complete();
      }
    }

    onLoad = ((web.Event _) {
      if (isSdkLoaded) {
        finish();
      } else {
        finish(StateError("Twilio Voice JS SDK loaded from '$url' but 'window.Twilio' is not defined."));
      }
    }).toJS;
    onError = ((web.Event _) {
      finish(StateError("Failed to load the Twilio Voice JS SDK from '$url'. Ensure the twilio_voice package assets are included in your web build."));
    }).toJS;

    script.addEventListener("load", onLoad);
    script.addEventListener("error", onError);
    web.document.head!.appendChild(script);

    return completer.future;
  }

  //endregion

  /// This feature is not available for web
  @override
  Future<bool?> showBackgroundCallUI() {
    return Future.value(false);
  }
  
  @override
  Future<bool?> updateCallKitIcon({String? icon}) async {
    return true;
  }

  /// Whether the Twilio Device raises `incoming` while already on a call, via the SDK's
  /// `allowIncomingWhileBusy` device option. Applied to the active device immediately.
  @override
  Future<bool> setAllowIncomingWhileBusy({bool allow = true}) async {
    _allowIncomingWhileBusy = allow;
    device?.updateOptions(_deviceOptions);
    return true;
  }

  /// Whether the Twilio Device raises `incoming` while already on a call. Defaults to true.
  @override
  Future<bool> getAllowIncomingWhileBusy() async => _allowIncomingWhileBusy;

  /// Set default caller name for incoming calls if no caller name is provided / registered.
  /// See [LocalStorageWeb.saveDefaultCallerName]
  @override
  Future<bool?> setDefaultCallerName(String callerName) async {
    logLocalEvent("defaultCaller is $callerName");
    _localStorage.saveDefaultCallerName(callerName);
    return true;
  }

  /// Remove registered client by id, if the client is not registered, do nothing.
  /// See [LocalStorageWeb.removeRegisteredClient]
  @override
  Future<bool?> unregisterClient(String clientId) async {
    logLocalEvent("Unregistering$clientId");
    _localStorage.removeRegisteredClient(clientId);
    return true;
  }

  /// Add registered client by [id, name] pair in local storage. If an existing client with the same id is already registered, it will be replaced.
  /// See [LocalStorageWeb.addRegisteredClient]
  @override
  Future<bool?> registerClient(String clientId, String clientName) async {
    logLocalEvent("Registering client $clientId:$clientName");
    _localStorage.addRegisteredClient(clientId, clientName);
    return true;
  }

  /// Request microphone permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia
  /// This is a 'hack' to acquire media permissions. The permissions API is not supported in all browsers.
  @override
  Future<bool?> requestMicAccess() async {
    logLocalEvent("requesting mic permission");
    try {
      final isSafariOrFirefox = RegExp(r'^((?!chrome|android).)*safari|firefox', caseSensitive: false).hasMatch(_webNavigatorDelegate.userAgent);

      if (isSafariOrFirefox) {
        try {
          // `Permissions.request` is a non-standard (Firefox) API not exposed by
          // package:web, so invoke it dynamically to preserve prior behavior.
          final descriptor = {"name": "microphone"}.jsify() as JSObject;
          final result = await _webPermissionsDelegate.callMethod<JSPromise<web.PermissionStatus>>("request".toJS, descriptor).toDart;
          if (result.state == "granted") return true;
        } catch (e) {
          printDebug("Failed to request microphone permission");
          printDebug(e);
        }
      }

      // Default approach for all browsers (and fallback for Safari & Firefox)
      /// This dirty hack to get media stream. Request (to show permissions popup on Chrome
      /// and other browsers, then stop the stream to release the permission)
      /// TODO(cybex-dev) - check supported media streams
      final web.MediaStream mediaStream = await _webMediaDevicesDelegate.getUserMedia(web.MediaStreamConstraints(audio: true.toJS)).toDart;
      mediaStream.getTracks().toDart.forEach((track) => track.stop());
      return hasMicAccess();
    } catch (e) {
      printDebug("Failed to request microphone permission");
      printDebug(e);
      return false;
    }
  }

  /// Queries current window for microphone permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> hasMicAccess() async {
    logLocalEvent("checkPermissionForMicrophone");
    try {
      final descriptor = {"name": "microphone"}.jsify() as JSObject;
      final perm = await _webPermissionsDelegate.query(descriptor).toDart;
      if (perm.state == "granted") {
        return true;
      } else if (perm.state == "prompt") {
        return false;
      } else {
        return false;
      }
    } catch (e) {
      printDebug("Failed to query microphone permission");
      printDebug(e);
      return false;
    }
  }

  /// Request bluetooth permissions.
  /// Not supported on web.
  @override
  Future<bool?> requestBluetoothPermissions() async {
    return true;
  }

  /// Queries browser for bluetooth permissions.
  /// Not supported on web.
  @override
  Future<bool> hasBluetoothPermissions() async {
    return true;
  }

  /// Request notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  @override
  Future<bool?> requestBackgroundPermissions() async {
    return webCallkit.requestPermissions();
  }

  /// Queries current window for notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> requiresBackgroundPermissions() async {
    return webCallkit.hasPermissions();
  }

  /// Unregister device from Twilio. Returns true if successful, false otherwise.
  /// [accessToken] is ignored for web
  /// See [twilio_js.Device.unregister]
  @override
  Future<bool?> unregister({String? accessToken}) async {
    if (device == null) {
      return true;
    }
    final state = getDeviceState(device!);
    if(state != DeviceState.registered) {
      printDebug("Device is not registered, cannot unregister");
      return true;
    }
    try {
      final promise = device!.unregister();
      await promise.toDart;
      _detachDeviceListeners(device!);
      _clearCalls();
      return true;
    } catch (e) {
      printDebug("Failed to unregister device: $e");
      return false;
    }
  }

  /// Not currently implemented for web
  /// TODO implement this or use web notifications from existing package
  /// https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/user_interface/Notifications
  @override
  set showMissedCallNotifications(bool value) {
    return;
  }

  void _clearCalls() {
    webCallkit.getCalls().toList().forEach((element) {
      webCallkit.reportCallDisconnected(element.uuid, response: CKDisconnectResponse.local);
    });
  }

  /// Creates and registered the Twilio Device. Returns true if successful, false otherwise.
  /// See [twilio_js.Device.new]
  /// Note: [deviceToken] is ignored for web
  @override
  Future<bool?> setTokens({required String accessToken, String? deviceToken}) async {
    // TODO use updateOptions for Twilio device
    assert(accessToken.isNotEmpty, "Access token cannot be empty");
    // The Twilio JS SDK is bundled with this package and injected on demand - `twilio_js.Device`
    // resolves the `window.Twilio` global, so the SDK must be present before we construct it.
    try {
      await ensureSdkLoaded();
    } catch (e) {
      printDebug("Failed to load Twilio Voice JS SDK: $e");
      // Keep the default "LOG" prefix - a prefix-less string is not a valid event and would
      // throw in [parseCallEvent].
      logLocalEvent("Failed to load Twilio Voice JS SDK: $e");
      return false;
    }
    // assert(deviceToken != null && deviceToken.isNotEmpty, "Device token cannot be null or empty");
    // if (device != null) {
    //   // check active calls?
    //   printDebug("Twilio device already active, unregistering...");
    //   try {
    //     await device!.unregister();
    //
    //   } catch (e) {
    //     printDebug("Failed to unregister device: $e");
    //     return false;
    //   }
    // }
    try {
      final shouldUpdate = device != null && getDeviceState(device!) == DeviceState.registered;
      if (shouldUpdate) {
        if(device?.token == accessToken) {
          printDebug("Device token is the same, no need to update");
          return true;
        }
        device!.updateToken(accessToken);
      } else {
        final existing = device;
        if (existing != null) {
          try {
            _detachDeviceListeners(existing);
            existing.destroy();
          } catch (e) {
            printDebug("Failed to tear down previous Twilio Device: $e");
          }
        }

        /// opus set as primary code
        /// https://www.twilio.com/blog/client-javascript-sdk-1-7-ga
        List<String> codecs = ["opus", "pcmu"];
        twilio_js.DeviceOptions options = twilio_js.DeviceOptions(
          logLevel: 1,
          codecPreferences: codecs.map((e) => e.toJS).toList().toJS,
          closeProtection: true,
          enableImprovedSignalingErrorPrecision: true,
          allowIncomingWhileBusy: _allowIncomingWhileBusy,
        );

        /// create new Twilio device
        device = twilio_js.Device(accessToken, options);
        _call.device = device;
        _attachDeviceListeners(device!);

        // Register device to accept notifications
        final promise = device!.register();
        await promise.toDart;
      }

      return true;
    } catch (e) {
      printDebug("Failed to set Twilio Device token: $e");
      return false;
    }
  }

  // Cached JS function references for device listeners. `.toJS` returns a NEW
  // JSFunction on every call, so add/removeListener must use the SAME cached
  // JSFunction or removeListener silently fails to detach.
  late final JSFunction _onDeviceRegisteredJs = _onDeviceRegistered.toJS;
  late final JSFunction _onDeviceUnregisteredJs = _onDeviceUnregistered.toJS;
  late final JSFunction _onDeviceErrorJs = _onDeviceError.toJS;
  late final JSFunction _onDeviceIncomingJs = _onDeviceIncoming.toJS;
  late final JSFunction _onTokenWillExpireJs = _onTokenWillExpire.toJS;

  /// Attach event listeners to [twilio_js.Device]
  /// See [twilio_js.Device.addListener](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceaddlistenereventname-listener)
  void _attachDeviceListeners(twilio_js.Device device) {
    // ignore: unnecessary_null_comparison
    assert(device != null, "Device cannot be null");
    device.addListener("registered", _onDeviceRegisteredJs);
    device.addListener("unregistered", _onDeviceUnregisteredJs);
    device.addListener("error", _onDeviceErrorJs);
    device.addListener("incoming", _onDeviceIncomingJs);
    device.addListener("tokenWillExpire", _onTokenWillExpireJs);
  }

  /// Detach event listeners to [twilio_js.Device]
  /// See [twilio_js.Device.removeListener](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceremovelistenereventname-listener)
  void _detachDeviceListeners(twilio_js.Device device) {
    // ignore: unnecessary_null_comparison
    assert(device != null, "Device cannot be null");
    device.removeListener("registered", _onDeviceRegisteredJs);
    device.removeListener("unregistered", _onDeviceUnregisteredJs);
    device.removeListener("error", _onDeviceErrorJs);
    device.removeListener("incoming", _onDeviceIncomingJs);
    device.removeListener("tokenWillExpire", _onTokenWillExpireJs);
  }

  /// On device registered and ready to make/receive calls via [twilio_js.Device.addListener] and [twilio_js.TwilioDeviceEvents.registered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  void _onDeviceRegistered() {
    printDebug("_onDeviceRegistered");
    printDebug("Device registered for callInvites");
  }

  /// On device unregistered, access token disabled and won't receive any more call invites [twilio_js.Device.removeListener] and [twilio_js.TwilioDeviceEvents.unregistered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event
  void _onDeviceUnregistered() {
    printDebug("_onDeviceUnregistered");
    printDebug("Device unregistered, won't receive no more callInvites");
  }

  /// On device error
  /// See [twilio_js.Device.addListener] and [twilio_js.TwilioDeviceEvents.error]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#error-event
  void _onDeviceError(twilio_js.TwilioError twilioError, twilio_js.Call? call) {
    logLocalEvent(twilioError.message);
  }

  /// On incoming call received via [twilio_js.Device.addListener] and [twilio_js.TwilioDeviceEvents.incoming]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#incoming-event
  void _onDeviceIncoming(twilio_js.Call call) {
    requestMicAccess();
    this.call.nativeCall = call;
    this.call._attachCallEventListeners(call);
    final params = getCallParams(call);
    final from = params["From"] ?? "";
    final to = params["To"] ?? "";
    logLocalEventEntries(
      ["Incoming", from, to, "Incoming", jsonEncode(params)],
      prefix: "",
    );
    logLocalEventEntries(
      ["Ringing", from, to, "Incoming", jsonEncode(params)],
      prefix: "",
    );

    _showIncomingCallNotification(call);
  }

  /// Shown when no name resolves and no default caller name has been configured.
  static const String _kUnknownCaller = "Unknown Caller";

  /// Resolves the name shown for a call, per the Interpreting Parameters contract:
  /// `__TWI_CALLER_NAME` -> resolve(`__TWI_CALLER_ID`) -> phone number -> registered client ->
  /// default caller name. Android is the reference implementation (see TVParametersImpl).
  String _resolveCallerName(Map<String, String> params) {
    final name = params["__TWI_CALLER_NAME"];
    if (name != null && name.isNotEmpty) {
      return name;
    }
    final id = params["__TWI_CALLER_ID"];
    if (id != null && id.isNotEmpty) {
      return _resolveRegisteredClient(id);
    }

    final from = params["From"] ?? "";
    if (from.isEmpty) {
      return _localStorage.getDefaultCallerName(_kUnknownCaller);
    }
    // A number is shown as-is; only client identities are looked up.
    if (!from.startsWith("client:")) {
      return from;
    }
    return _resolveRegisteredClient(from);
  }

  /// Registered client name for an id, or the default caller name if it is not registered.
  String _resolveRegisteredClient(String id) {
    final clientId = id.startsWith("client:") ? id.substring(7) : id;
    return _localStorage.getRegisteredClient(clientId) ?? _localStorage.getDefaultCallerName(_kUnknownCaller);
  }

  String? _resolveImageUrl(Map<String, String> params) {
    return params["__TWI_CALLER_URL"] ?? params["imageUrl"] ?? params["url"];
  }

  Future<void> _showIncomingCallNotification(twilio_js.Call call) async {
    // request permission to show notification
    await webCallkit.requestPermissions();

    final params = getCallParams(call);
    final callSid = params["CallSid"];
    if (callSid == null) {
      return;
    }
    final title = _resolveCallerName(params);
    // todo(cybex-dev): add support for custom image in web callkit.
    final imageUrl = _resolveImageUrl(params);

    final data = {
      ...params,
      "uuid": callSid,
      "to": title,
      "image": imageUrl,
    };
    await webCallkit.reportIncomingCall(
      uuid: callSid,
      handle: title,
      metadata: data,
      data: data,
    );
  }

  /// On device token about to expire (default is 10s prior to expiry), via [twilio_js.Device.addListener] and [twilio_js.TwilioDeviceEvents.tokenWillExpire]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#tokenwillexpire-event
  void _onTokenWillExpire(twilio_js.Device device) {
    logLocalEventEntries(["DEVICETOKEN", device.token], prefix: "");
  }

  /// Update Twilio Device sound defined by [SoundName], this will override the default Twilio Javascript sound.
  /// If url is null, the default will be used.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptionssounds-properties-and-default-sounds
  @override
  Future<void> updateSound(SoundName soundName, String? url) async {
    if (device == null) {
      printDebug("Device is not initialized, cannot update sound");
      return;
    }

    final name = soundName.jsName;

    if(url == null || url.isEmpty) {
      _soundMap.remove(name);
    } else {
      // Use provided url
      _soundMap[name] = url;
    }

    // Update Twilio Device sound
    device!.updateOptions(_deviceOptions);
  }

  /// Update Twilio Device sounds defined by [SoundName], this will override the default Twilio Javascript sounds.
  /// If a corresponding null value is provided, the default will be used.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptionssounds-properties-and-default-sounds
  @override
  Future<void> updateSounds({Map<SoundName, String>? sounds}) async {
    if(device == null) {
      printDebug("Device is not initialized, cannot update sounds");
      return;
    }
    if (sounds == null || sounds.isEmpty) {
      return;
    }

    _soundMap.clear();
    _soundMap.addAll(sounds.map((k, v) => MapEntry(k.jsName, v)));

    device!.updateOptions(_deviceOptions);
  }

  twilio_js.DeviceOptions get _deviceOptions {
    return twilio_js.DeviceOptions(
      logLevel: 1,
      codecPreferences: _codecs.map((e) => e.toJS).toList().toJS,
      closeProtection: _closeProtection,
      enableImprovedSignalingErrorPrecision: true,
      allowIncomingWhileBusy: _allowIncomingWhileBusy,
      sounds: _soundMap.jsify(),
    );
  }

  DeviceState getDeviceState(twilio_js.Device device) {
    return parseDeviceState(device.state);
  }
}

class Call extends MethodChannelTwilioCall {
  /// Twilio Call JS interface object
  twilio_js.Call? _jsCall;
  twilio_js.Device? _device;

  // ignore: unnecessary_getters_setters
  twilio_js.Device? get device => _device;

  set device(twilio_js.Device? value) {
    _device = value;
  }

  late WebCallkitPlatform webCallkit;

  Call({twilio_js.Call? call})
      : _jsCall = call,
        webCallkit = WebCallkitWeb.instance;

  twilio_js.Call? get nativeCall {
    return _jsCall;
  }

  set nativeCall(twilio_js.Call? value) {
    _jsCall = value;
    if (value != null) {
      activeCall = activeCallFromNativeJsCall(value);
      // _attachCallEventListeners(_jsCall!);
    }
  }

  /// Send digits to the call. Returns true if successful, false otherwise.
  /// See [twilio_js.Call.sendDigits]
  @override
  Future<bool?> sendDigits(String digits) async {
    if (_jsCall != null) {
      _jsCall!.sendDigits(digits);
      return true;
    }
    return false;
  }

  /// Not available for web
  @override
  Future<bool> toggleBluetooth({bool bluetoothOn = true}) {
    return Future.value(bluetoothOn);
  }

  /// Not available for web
  @override
  Future<bool> isBluetoothOn() {
    return Future.value(false);
  }

  /// Not currently implemented for web
  @override
  Future<bool?> toggleSpeaker(bool speakerIsOn) async {
    return Future.value(false);
  }

  /// Toggle mute on/off. Returns true if successful, false otherwise.
  @override
  Future<bool?> toggleMute(bool isMuted) async {
    final jsCall = _jsCall;
    if (jsCall == null) {
      return false;
    }
    jsCall.mute(isMuted);
    logLocalEvent(isMuted ? "Mute" : "Unmute", prefix: "");

    final sid = _getSid();
    if(sid != null) {
      await _toggleAttribute(isMuted, sid, CKCallAttributes.mute);
    }
    return isMuted;
  }

  /// Is call muted. Returns true if muted, false otherwise.
  @override
  Future<bool> isMuted() async {
    if (_jsCall != null) {
      return _jsCall!.isMuted();
    } else {
      return false;
    }
  }

  /// Not currently implemented for web
  /// https://github.com/twilio/twilio-voice.js/issues/32
  /// Call holding should be done server-side as suggested by @ryan-rowland here(https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1016872545)
  /// See this to get started: https://stackoverflow.com/questions/22643800/twilio-how-to-move-an-existing-call-to-a-conference
  /// See this for more info on how to use cold holding, and its requirements: https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1331081241
  /// TODO(cybex-dev) - implement call holding feature in [twilio-voice.js](https://github.com/twilio/twilio-voice.js) for use in twilio_voice_web
  @override
  Future<bool?> holdCall({bool holdCall = true}) async {
    return Future.value(false);
  }

  /// Not currently implemented for web
  @override
  Future<bool> isHolding() {
    return Future.value(false);
  }

  /// Not currently implemented for web
  @override
  Future<bool> isOnSpeaker() {
    return Future.value(false);
  }

  /// Answers an inbound call. Returns true if successful, false otherwise.
  /// See [twilio_js.Call.accept]
  @override
  Future<bool?> answer() async {
    if (_jsCall != null) {
      // Accept incoming call
      _jsCall!.accept();
      activeCall = activeCallFromNativeJsCall(_jsCall!);

      // attach event listeners
      // _attachCallEventListeners(_jsCall!);

      // log event
      final params = getCallParams(_jsCall!);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      logLocalEventEntries(
        ["Answer", from, to, "Incoming", jsonEncode(params)],
        prefix: "",
      );

      // notify SW to cancel notification
      final callSid = _getSid();
      if (callSid != null) {
        webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
      }

      return true;
    }
    return false;
  }

  /// Not currently implemented for web
  @override
  Future<String?> getSid() async {
    return _getSid();
  }

  /// Get Sid from parameters, helper method for not required futures for web calls
  String? _getSid() {
    if (_jsCall == null) {
      return null;
    }
    final params = getCallParams(_jsCall!);
    return params["CallSid"];
  }

  /// Returns true if there is an active call, a convenience function for [activeCall != null], false otherwise.
  /// See [MethodChannelTwilioCall.activeCall]
  @override
  Future<bool> isOnCall() async {
    return device?.isBusy ?? _jsCall != null;
  }

  /// Returns true if the call was disconnected, false otherwise.
  /// See [twilio_js.Call.disconnect]
  @override
  Future<bool?> hangUp() async {
    if (_jsCall != null) {
      // notify SW to cancel notification
      final _ = _getSid();

      CallStatus callStatus = getCallStatus(_jsCall!);
      // reject incoming call that is both outbound ringing or inbound pending
      if (callStatus == CallStatus.ringing || callStatus == CallStatus.pending) {
        _jsCall!.reject();
      } else {
        _jsCall!.disconnect();
      }

      return true;
    }
    return false;
  }

  /// Place outgoing call [from] to [to]. Returns true if successful, false otherwise.
  /// Generally accepted format is e164 (e.g. US number +15555555555)
  /// alternatively, use 'client:${clientId}' to call a Twilio Client connection
  /// Parameters send to Twilio's REST API endpoint 'makeCall' can be passed in [extraOptions];
  /// Parameters are reduced to this format
  /// <code>
  /// {
  ///  "From": from,
  ///  "To": to,
  ///  ...extraOptions
  /// }
  /// </code>
  /// See [twilio_js.Device.connect]
  @override
  Future<bool?> place({required String from, required String to, Map<String, dynamic>? extraOptions}) async {
    assert(device != null, "Twilio device is null, make sure you have initialized the device first by calling [ setTokens({required String accessToken, String? deviceToken}) ] ");
    assert(from.isNotEmpty, "'from' cannot be empty");
    assert(to.isNotEmpty, "'to' cannot be empty");
    final options = (extraOptions ?? {});
    assert(!options.keys.contains("From"), "'from' cannot be passed in 'extraOptions'");
    assert(!options.keys.contains("To"), "'to' cannot be passed in 'extraOptions'");

    logLocalEvent("Making new call");
    // handle parameters
    final params = <String, String>{
      "From": from,
      "To": to,
    };
    extraOptions?.forEach((key, value) {
      params[key] = value.toString();
    });

    // this.callOutgoing = true;
    // Log.d(TAG, "calling to " + call.argument("To").toString());
    // final options = twilioJs.DeviceConnectOptions(params);
    try {
      final callParams = params.jsify();
      final options = twilio_js.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      nativeCall = await promise.toDart;

      _attachCallEventListeners(_jsCall!);
      logLocalEvent("Call placed");
    } catch (e) {
      printDebug("Failed to place call: $e");
      return false;
    }
    return true;
  }

  /// Places new call using raw parameters passed directly to Twilio's REST API endpoint 'makeCall'. Returns true if successful, false otherwise.
  ///
  /// [extraOptions] will be added to the callPayload sent to your server
  /// See [twilio_js.Device.connect]
  @override
  Future<bool?> connect({Map<String, dynamic>? extraOptions}) async {
    assert(device != null, "Twilio device is null, make sure you have initialized the device first by calling [ setTokens({required String accessToken, String? deviceToken}) ] ");

    logLocalEvent("Making new call with Connect");
    // handle parameters
    final params = <String, String>{};
    extraOptions?.forEach((key, value) {
      params[key] = value.toString();
    });

    try {
      final callParams = params.jsify();
      final options = twilio_js.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      nativeCall = await promise.toDart;

      _attachCallEventListeners(_jsCall!);
    } catch (e) {
      printDebug("Failed to place call: $e");
      return false;
    }
    return true;
  }

  // Cached JS function references for call listeners. `.toJS` returns a NEW
  // JSFunction on every call, so add/removeListener must use the SAME cached
  // JSFunction or removeListener silently fails to detach.
  late final JSFunction _onCallRingingJs = _onCallRinging.toJS;
  late final JSFunction _onCallAcceptJs = _onCallAccept.toJS;
  late final JSFunction _onCallDisconnectJs = _onCallDisconnect.toJS;
  late final JSFunction _onCallCancelJs = _onCallCancel.toJS;
  late final JSFunction _onCallRejectJs = _onCallReject.toJS;
  late final JSFunction _onCallErrorJs = _onCallError.toJS;
  late final JSFunction _onCallReconnectingJs = _onCallReconnecting.toJS;
  late final JSFunction _onCallReconnectedJs = _onCallReconnected.toJS;
  late final JSFunction _onLogEventJs = _onLogEvent.toJS;
  late final JSFunction _onCallWarningJs = _onCallWarning.toJS;
  late final JSFunction _onCallWarningClearedJs = _onCallWarningCleared.toJS;

  /// Map of last call quality warnings emitted by JS call object per call SID.
  final Map<String, Set<CallQualityWarning>> _activeQualityWarnings = <String, Set<CallQualityWarning>>{};

  /// Attach event listeners to the active call
  /// See [twilio_js.Call.addListener]
  void _attachCallEventListeners(twilio_js.Call call) {
    // ignore: unnecessary_null_comparison
    assert(call != null, "Call cannot be null");
    call.addListener("ringing", _onCallRingingJs);
    call.addListener("accept", _onCallAcceptJs);
    call.addListener("disconnect", _onCallDisconnectJs);
    call.addListener("cancel", _onCallCancelJs);
    call.addListener("reject", _onCallRejectJs);
    call.addListener("error", _onCallErrorJs);
    call.addListener("reconnecting", _onCallReconnectingJs);
    call.addListener("reconnected", _onCallReconnectedJs);
    call.addListener("log", _onLogEventJs);
    call.addListener("warning", _onCallWarningJs);
    call.addListener("warning-cleared", _onCallWarningClearedJs);
  }

  /// On a call quality warning being raised, via [twilio_js.Call.addListener] and
  /// [twilio_js.TwilioCallEvents.warning].
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#warning-event
  void _onCallWarning(String name) {
    _updateQualityWarnings((set) => set.add(CallQualityWarning.fromName(name)));
  }

  /// On a call quality warning being cleared, via [twilio_js.Call.addListener] and
  /// [twilio_js.TwilioCallEvents.warningCleared].
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#warning-cleared-event
  void _onCallWarningCleared(String name) {
    _updateQualityWarnings((set) => set.remove(CallQualityWarning.fromName(name)));
  }

  /// Applies [mutate] to the active call's warning set and emits the change as
  /// "Quality|<current csv>|<previous csv>", matching the native platforms. The SID is used only
  /// to key the tracked set per call; it is not emitted.
  void _updateQualityWarnings(void Function(Set<CallQualityWarning>) mutate) {
    final sid = _getSid() ?? "";
    final previous = Set<CallQualityWarning>.of(_activeQualityWarnings[sid] ?? const {});
    final current = Set<CallQualityWarning>.of(previous);
    mutate(current);
    _activeQualityWarnings[sid] = current;

    String csv(Set<CallQualityWarning> s) => s.map((e) => e.wireName).join(",");
    logLocalEventEntries(["Quality", csv(current), csv(previous)], prefix: "");
  }

  /// Detach event listeners to the active call
  /// See [twilio_js.Call.removeListener]
  /// 'off' event listener isn't implemented in twilio-voice.js
  void _detachCallEventListeners(twilio_js.Call call) {
    // ignore: unnecessary_null_comparison
    assert(call != null, "Call cannot be null");
    call.removeListener("ringing", _onCallRingingJs);
    call.removeListener("accept", _onCallAcceptJs);
    call.removeListener("disconnect", _onCallDisconnectJs);
    call.removeListener("cancel", _onCallCancelJs);
    call.removeListener("reject", _onCallRejectJs);
    call.removeListener("error", _onCallErrorJs);
    call.removeListener("reconnecting", _onCallReconnectingJs);
    call.removeListener("reconnected", _onCallReconnectedJs);
    call.removeListener("log", _onLogEventJs);
    call.removeListener("warning", _onCallWarningJs);
    call.removeListener("warning-cleared", _onCallWarningClearedJs);
    _activeQualityWarnings.remove(_getSid());
  }

  void _onLogEvent(String status) {
    log("Log Event: $status");
  }

  /// On accept/answering (inbound) call
  /// Undocumented event: Ringing found in twilio-voice.js implementation: https://github.com/twilio/twilio-voice.js/blob/94ea6b6d8d1128ac5091f3a3bec4eae745e4d12f/lib/twilio/call.ts#L1355
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  // ignore: unused_element_parameter
  void _onCallRinging(bool hasEarlyMedia) {
    if (_jsCall != null) {
      final params = getCallParams(_jsCall!);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      final direction = _jsCall!.direction == "INCOMING" ? "Incoming" : "Outgoing";
      logLocalEventEntries(
        ["Ringing", from, to, direction],
        prefix: "",
      );
      final sid = _getSid();
      if (sid != null) {
        webCallkit.reportOutgoingCall(uuid: sid, handle: to, metadata: params, data: params);
      }
    }
  }

  /// On accept/answering (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallAccept(twilio_js.Call call) async {
    if (call.direction == "INCOMING") {
      final params = getCallParams(call);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      logLocalEventEntries([
        "Answer",
        from,
        to,
        "Incoming",
        jsonEncode(params),
      ], prefix: "");

      await webCallkit.requestPermissions();
    }
    _onCallConnected(call);
  }

  /// On disconnect active (outbound/inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#disconnect-event
  void _onCallDisconnect(twilio_js.Call call) async {
    final status = getCallStatus(call);
    _detachCallEventListeners(call);
    if (status == CallStatus.closed && _jsCall != null) {
      logLocalEvent("Call Ended", prefix: "");
    }
    nativeCall = null;

    await webCallkit.requestPermissions();
    final params = getCallParams(call);
    final callSid = params["CallSid"];
    if(callSid != null) {
      webCallkit.reportCallDisconnected(callSid, response: CKDisconnectResponse.remote);
    }
  }

  /// On cancels active (outbound/inbound) call
  /// This runs when:
  /// - ignoring an incoming call
  /// - calling [disconnect] on an active call before recipient has answered
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#cancel-event
  void _onCallCancel() {
    final jsCall = _jsCall;
    if (jsCall == null) {
      return;
    }

    // get call SID before reset
    final callSid = _getSid();
    final isIncoming = jsCall.direction == "INCOMING";

    _detachCallEventListeners(jsCall);
    nativeCall = null;
    logLocalEvent("Call Ended", prefix: "");

    if (callSid == null) {
      return;
    }

    if (isIncoming) {
      logLocalEvent("Missed Call", prefix: "");
      webCallkit.reportCallDisconnected(callSid, response: CKDisconnectResponse.missed);
    } else {
      webCallkit.reportCallDisconnected(callSid, response: CKDisconnectResponse.local);
    }
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event
  void _onCallReject() {
    final callSid = _getSid();
    if (_jsCall != null) {
      _detachCallEventListeners(_jsCall!);
      nativeCall = null;
    }
    logLocalEvent("Call Rejected");
    if (callSid != null) {
      webCallkit.reportCallDisconnected(callSid, response: CKDisconnectResponse.rejected);
    }
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#error-event
  void _onCallError(twilio_js.TwilioError error) {
    logLocalEvent("Call Error: ${error.code}, ${error.message}");
  }

  /// On active call connected to remote client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
  void _onCallConnected(twilio_js.Call call) {
    nativeCall = call;
    final direction = call.direction == "INCOMING" ? "Incoming" : "Outgoing";
    final params = getCallParams(call);
    final from = params["From"] ?? "";
    final to = params["To"] ?? "";
    final callSid = params["CallSid"];
    logLocalEventEntries(["Connected", from, to, direction], prefix: "");
    if (callSid != null) {
      webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
    }
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnecting(JSAny? twilioError) {
    logLocalEvent("Reconnecting");
    final callSid = _getSid();
    if (callSid != null) {
      webCallkit.updateCallStatus(callSid, callStatus: CKCallState.reconnecting);
    }
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnected() {
    logLocalEvent("Reconnected");
    final callSid = _getSid();
    if (callSid != null) {
      webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
    }
  }

  CallStatus getCallStatus(twilio_js.Call call) {
    final status = call.status();
    return parseCallStatus(status);
  }

  Future<void> _toggleAttribute(bool value, String uuid, CKCallAttributes attribute) {
    if (value) {
      return _addAttribute(uuid, attribute);
    } else {
      return _removeAttribute(uuid, attribute);
    }
  }

  Future<void> _addAttribute(String uuid, CKCallAttributes attribute) async {
    // web_callkit may not be tracking this call (e.g. notification was never shown).
    final call = webCallkit.getCall(uuid);
    if (call == null) {
      return;
    }
    final attrs = call.attributes..add(attribute);
    await webCallkit.updateCallAttributes(uuid, attributes: attrs);
  }

  Future<void> _removeAttribute(String uuid, CKCallAttributes attribute) async {
    final call = webCallkit.getCall(uuid);
    if (call == null) {
      return;
    }
    final attrs = call.attributes..remove(attribute);
    await webCallkit.updateCallAttributes(uuid, attributes: attrs);
  }
}

/// Since Call.customParameters is of type Map (but specifically implements a LegacyJavaScriptObject), we cannot access the Map directly.
/// Instead, we convert it to an array using [toArray] and then convert it to a Map
Map<String, String> _getCustomCallParameters(JSAny? callParameters) {
  final list = toArray(callParameters!).toDart;
  final entries = list.map((e) {
    final entry = (e as JSArray).toDart;
    return MapEntry<String, String>(
      entry.first.dartify().toString(),
      entry.last.dartify().toString(),
    );
  });
  return Map<String, String>.fromEntries(entries);
}

Map<String, String> getCallParams(twilio_js.Call call) {
  final customParams = _getCustomCallParameters(call.customParameters);
  final params = jsToStringMap(call.parameters);
  params.remove("Params");

  return Map<String, String>.from(customParams)..addAll(params);
}

ActiveCall activeCallFromNativeJsCall(twilio_js.Call call, {DateTime? initiated}) {
  final params = getCallParams(call);
  final from = params["From"] ?? params["from"] ?? "";
  final to = params["To"] ?? params["to"] ?? "";

  /// Do not remove To and From params as they are used to build call state using [createCallFromState(String)]
  // params.removeWhere((key, value) => key == "To" || key == "From");

  final direction = call.direction;
  final date = initiated ?? DateTime.now();
  return ActiveCall(
    from: from,
    // call.customParameters["From"] ?? "",
    to: to,
    // call.customParameters["To"] ?? "",
    customParams: params,
    //call.customParameters as Map<String, dynamic>?,
    callDirection: direction == "INCOMING" ? CallDirection.incoming : CallDirection.outgoing,
    initiated: date,
  );
}

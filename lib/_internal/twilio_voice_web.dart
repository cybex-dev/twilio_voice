import 'dart:async';
import 'dart:convert';
import 'dart:developer';

// TODO(cybex-dev) implement package:web
// ignore: deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

// Added as temporary measure till sky_engine includes js_util (allowInterop())
// TODO(cybex-dev) implement js_interop for allowInterop function
// ignore: deprecated_member_use
import 'package:js/js.dart' as js;

// TODO(cybex-dev) implement js_interop for js_util package
// ignore: deprecated_member_use
import 'package:js/js_util.dart' as js_util;
import 'package:twilio_voice/_internal/js/call/call_status.dart';

// This is required for JS interop, do not remove even though linter complains
// TODO(cybex-dev) implement js_interop for js_util package
// ignore: unused_import,deprecated_member_use
import 'package:js/js_util.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_voice_platform_interface.dart';
import 'package:web_callkit/web_callkit_web.dart';

import '../twilio_voice.dart';
import './js/js.dart' as twilio_js;
import 'js/core/enums/device_sound_name.dart';
import 'js/utils/js_object_utils.dart';
import 'local_storage_web/local_storage_web.dart';
import 'method_channel/twilio_call_method_channel.dart';
import 'method_channel/twilio_voice_method_channel.dart';
import 'utils.dart';

class Logger {
  // ignore: close_sinks
  static StreamController<String>? _callEventsController;

  static StreamController<String> get callEventsController {
    _callEventsController ??= StreamController<String>.broadcast();
    return _callEventsController!;
  }

  static Stream<String> get callEventsStream => callEventsController.stream;

  /// Logs event to EventChannel, but uses [List.join] with [separator] to join [prefix] and [description].
  /// This is used to send events to the EventChannel for integration into existing communication flow.
  /// The event will be sent as a String with the following format:
  /// - (if prefix is not empty): "prefix|description", where '|' is separator
  /// - (if prefix is empty): "description"
  static void logLocalEventEntries(List<String> entries, {String prefix = "LOG", String separator = "|"}) {
    logLocalEvent(entries.join(separator), prefix: prefix, separator: separator);
  }

  /// Logs event to EventChannel.
  /// This is used to send events to the EventChannel for integration into existing communication flow.
  /// The event will be sent as a String with the following format:
  /// - (if prefix is not empty): "prefix|description", where '|' is separator
  /// - (if prefix is empty): "description"
  static void logLocalEvent(String description, {String prefix = "LOG", String separator = "|"}) async {
    if (!kIsWeb) {
      throw UnimplementedError("Use eventChannel() via sendPhoneEvents on platform implementation");
    }
    // eventChannel.binaryMessenger.handlePlatformMessage(
    //   _kEventChannelName,
    //   const StandardMethodCodec().encodeSuccessEnvelope(description),
    //   (ByteData? data) {},
    // );
    String message = "";
    if (prefix.isEmpty) {
      message = description;
    } else {
      message = "$prefix$separator$description";
    }

    // Send events to EventChannel for integration into existing communication flow
    callEventsController.add(message);
  }
}

/// The web implementation of [TwilioVoicePlatform].
class TwilioVoiceWeb extends MethodChannelTwilioVoice {

  static const _codecs = ["opus", "pcmu"];
  static const _closeProtection = true;
  final Map<String, String> _soundMap = {};
  late WebCallkitPlatform webCallkit;
  late CKConfiguration _ckConfiguration;

  TwilioVoiceWeb() {
    // TODO(cybex-dev) - load twilio.min.js via [TwilioLoader] in future
    // loadTwilio();
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

  html.Navigator get _webNavigatorDelegate => html.window.navigator;

  html.Permissions? get _webPermissionsDelegate => _webNavigatorDelegate.permissions;

  html.MediaDevices? get _webMediaDevicesDelegate => _webNavigatorDelegate.mediaDevices;

  late final Call _call = Call();

  @override
  Call get call => _call;

  static void registerWith(Registrar registrar) {
    TwilioVoicePlatform.instance = TwilioVoiceWeb();
  }

  Stream<CallEvent>? _callEventsListener;

  @override
  Stream<CallEvent> get callEventsListener {
    _callEventsListener ??= Logger.callEventsStream.map(parseCallEvent);
    return _callEventsListener!;
  }

  /// This feature is not available for web
  @override
  Future<bool?> showBackgroundCallUI() {
    return Future.value(false);
  }

  /// Set default caller name for incoming calls if no caller name is provided / registered.
  /// See [LocalStorageWeb.saveDefaultCallerName]
  @override
  Future<bool?> setDefaultCallerName(String callerName) async {
    Logger.logLocalEvent("defaultCaller is $callerName");
    _localStorage.saveDefaultCallerName(callerName);
    return true;
  }

  /// Remove registered client by id, if the client is not registered, do nothing.
  /// See [LocalStorageWeb.removeRegisteredClient]
  @override
  Future<bool?> unregisterClient(String clientId) async {
    Logger.logLocalEvent("Unregistering$clientId");
    _localStorage.removeRegisteredClient(clientId);
    return true;
  }

  /// Add registered client by [id, name] pair in local storage. If an existing client with the same id is already registered, it will be replaced.
  /// See [LocalStorageWeb.addRegisteredClient]
  @override
  Future<bool?> registerClient(String clientId, String clientName) async {
    Logger.logLocalEvent("Registering client $clientId:$clientName");
    _localStorage.addRegisteredClient(clientId, clientName);
    return true;
  }

  /// Request microphone permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia
  /// This is a 'hack' to acquire media permissions. The permissions API is not supported in all browsers.
  @override
  Future<bool?> requestMicAccess() async {
    Logger.logLocalEvent("requesting mic permission");
    try {
      final isSafariOrFirefox = RegExp(r'^((?!chrome|android).)*safari|firefox', caseSensitive: false).hasMatch(_webNavigatorDelegate.userAgent);

      if (isSafariOrFirefox && _webPermissionsDelegate != null) {
        try {
          final result = await _webPermissionsDelegate!.request({"name": "microphone"});
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
      html.MediaStream mediaStream = await _webMediaDevicesDelegate?.getUserMedia({"audio": true}) ?? await _webNavigatorDelegate.getUserMedia(audio: true);
      mediaStream.getTracks().forEach((track) => track.stop());
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
    Logger.logLocalEvent("checkPermissionForMicrophone");
    try {
      final perm = await _webPermissionsDelegate?.query({"name": "microphone"});
      if (perm == null) {
        printDebug("Failed to query microphone permission");
        return false;
      }
      if (perm.state == "granted") {
        return true;
      } else if (perm.state == "prompt") {
        Logger.logLocalEvent("RequestMicrophoneAccess");
        return false;
      } else {
        Logger.logLocalEvent("Microphone permission denied", prefix: "");
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
      return false;
    }
    try {
      device?.unregister();
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
      /// opus set as primary code
      /// https://www.twilio.com/blog/client-javascript-sdk-1-7-ga
      List<String> codecs = ["opus", "pcmu"];
      twilio_js.DeviceOptions options = twilio_js.DeviceOptions(
        codecPreferences: codecs,
        closeProtection: true,
      );

      /// create new Twilio device
      device = twilio_js.Device(accessToken, options);
      _call.device = device;
      _attachDeviceListeners(device!);

      // Register device to accept notifications
      device!.register();

      return true;
    } catch (e) {
      printDebug("Failed to set Twilio Device token: $e");
      return false;
    }
  }

  /// Attach event listeners to [twilio_js.Device]
  /// See [twilio_js.Device.on]
  void _attachDeviceListeners(twilio_js.Device device) {
    // ignore: unnecessary_null_comparison
    assert(device != null, "Device cannot be null");
    device.on("registered", js.allowInterop(_onDeviceRegistered));
    device.on("unregistered", js.allowInterop(_onDeviceUnregistered));
    device.on("error", js.allowInterop(_onDeviceError));
    device.on("incoming", js.allowInterop(_onDeviceIncoming));
    device.on("tokenWillExpire", js.allowInterop(_onTokenWillExpire));
  }

  /// Detach event listeners to [twilio_js.Device]
  /// See [twilio_js.Device.off]
  void _detachDeviceListeners(twilio_js.Device device) {
    // ignore: unnecessary_null_comparison
    assert(device != null, "Device cannot be null");
    device.off("registered", js.allowInterop(_onDeviceRegistered));
    device.off("unregistered", js.allowInterop(_onDeviceUnregistered));
    device.off("error", js.allowInterop(_onDeviceError));
    device.off("incoming", js.allowInterop(_onDeviceIncoming));
    device.off("tokenWillExpire", js.allowInterop(_onTokenWillExpire));
  }

  /// On device registered and ready to make/receive calls via [twilio_js.Device.on] and [twilio_js.TwilioDeviceEvents.registered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  void _onDeviceRegistered() {
    printDebug("_onDeviceRegistered");
    printDebug("Device registered for callInvites");
  }

  // /// On device registered and ready to make/receive calls via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.registered]
  // /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  // Function _onDeviceRegistered() {
  //   // final _f = (twilioJs.Device device) {
  //   //   Logger.logLocalEvent("Device registered for callInvites", prefix: "");
  //   // };
  //   // return allowInterop(_f);
  //   return allowInterop((twilioJs.Device device) {
  //     Logger.logLocalEvent("Device registered for callInvites", prefix: "");
  //   });
  // }

  /// On device unregistered, access token disabled and won't receive any more call invites [twilio_js.Device.off] and [twilio_js.TwilioDeviceEvents.unregistered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event
  void _onDeviceUnregistered() {
    printDebug("_onDeviceUnregistered");
    printDebug("Device unregistered, won't receive no more callInvites");
  }

  /// On device error
  /// See [twilio_js.Device.on] and [twilio_js.TwilioDeviceEvents.error]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#error-event
  void _onDeviceError(twilio_js.TwilioError twilioError, twilio_js.Call? call) {
    logLocalEvent(twilioError.message);
  }

  /// On incoming call received via [twilio_js.Device.on] and [twilio_js.TwilioDeviceEvents.incoming]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#incoming-event
  void _onDeviceIncoming(twilio_js.Call call) {
    requestMicAccess();
    this.call.nativeCall = call;
    this.call._attachCallEventListeners(call);
    final params = getCallParams(call);
    final from = params["From"] ?? "";
    final to = params["To"] ?? "";
    Logger.logLocalEventEntries(
      ["Incoming", from, to, "Incoming", jsonEncode(params)],
      prefix: "",
    );
    Logger.logLocalEventEntries(
      ["Ringing", from, to, "Incoming", jsonEncode(params)],
      prefix: "",
    );

    _showIncomingCallNotification(call);
  }

  String _resolveCallerName(Map<String, String> params) {
    final from = params["From"] ?? "";
    if (from.startsWith("client:")) {
      final clientName = from.substring(7);
      return _localStorage.getRegisteredClient(clientName) ?? _localStorage.getRegisteredClient("defaultCaller") ?? clientName;
    } else {
      return from;
    }
  }

  String? _resolveImageUrl(Map<String, String> params) {
    return params["__TWI_CALLER_URL"] ?? params["imageUrl"] ?? params["url"];
  }

  Future<void> _showIncomingCallNotification(twilio_js.Call call) async {
    // request permission to show notification
    await webCallkit.requestPermissions();

    final params = getCallParams(call);
    final callSid = params["CallSid"] as String;
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

  /// On device token about to expire (default is 10s prior to expiry), via [twilio_js.Device.on] and [twilio_js.TwilioDeviceEvents.tokenWillExpire]
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
      codecPreferences: _codecs,
      closeProtection: _closeProtection,
      sounds: js_util.jsify(_soundMap),
    );
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
    Logger.logLocalEvent(speakerIsOn ? "Speaker On" : "Speaker Off", prefix: "");
    return Future.value(false);
  }

  /// Toggle mute on/off. Returns true if successful, false otherwise.
  @override
  Future<bool?> toggleMute(bool isMuted) async {
    Logger.logLocalEvent(isMuted ? "Mute" : "Unmute", prefix: "");
    if (_jsCall != null) {
      _jsCall!.mute(isMuted);
    }
    final sid = await getSid();
    await _toggleAttribute(isMuted, sid!, CKCallAttributes.mute);
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
    // Logger.logLocalEvent(holdCall ? "Unhold" : "Hold", prefix: "");
    // return Future.value(false);
    Logger.logLocalEvent("Unhold");
    final sid = await getSid();
    await _toggleAttribute(false, sid!, CKCallAttributes.hold);
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
      Logger.logLocalEventEntries(
        ["Answer", from, to, jsonEncode(params)],
        prefix: "",
      );

      // notify SW to cancel notification
      final callSid = await getSid();
      webCallkit.updateCallStatus(callSid!, callStatus: CKCallState.active);

      return true;
    }
    return false;
  }

  /// Not currently implemented for web
  @override
  Future<String?> getSid() async {
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
      final callSid = await getSid();

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

    Logger.logLocalEvent("Making new call");
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
      final callParams = js_util.jsify(params);
      final options = twilio_js.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      nativeCall = await js_util.promiseToFuture(promise);

      _attachCallEventListeners(_jsCall!);
      Logger.logLocalEvent("Call placed");
    } catch (e) {
      printDebug("Failed to place call: $e");
      return false;
    }
    return true;
  }

  /// Place outgoing call with raw parameters. Returns true if successful, false otherwise.
  /// Parameters send to Twilio's REST API endpoint 'makeCall' can be passed in [extraOptions];
  /// Parameters are reduced to this format
  /// <code>
  /// {
  ///  ...extraOptions
  /// }
  /// </code>
  /// See [twilio_js.Device.connect]
  @override
  Future<bool?> connect({Map<String, dynamic>? extraOptions}) async {
    assert(device != null, "Twilio device is null, make sure you have initialized the device first by calling [ setTokens({required String accessToken, String? deviceToken}) ] ");

    Logger.logLocalEvent("Making new call with Connect");
    // handle parameters
    final params = <String, String>{};
    extraOptions?.forEach((key, value) {
      params[key] = value.toString();
    });

    try {
      final callParams = js_util.jsify(params);
      final options = twilio_js.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      nativeCall = await js_util.promiseToFuture(promise);

      _attachCallEventListeners(_jsCall!);
    } catch (e) {
      printDebug("Failed to place call: $e");
      return false;
    }
    return true;
  }

  /// Attach event listeners to the active call
  /// See [twilio_js.Call.on]
  void _attachCallEventListeners(twilio_js.Call call) {
    // ignore: unnecessary_null_comparison
    assert(call != null, "Call cannot be null");
    // call.on("ringing", js.allowInterop(_onCallRinging));
    call.on("accept", js.allowInterop(_onCallAccept));
    call.on("disconnect", js.allowInterop(_onCallDisconnect));
    call.on("cancel", js.allowInterop(_onCallCancel));
    call.on("reject", js.allowInterop(_onCallReject));
    call.on("error", js.allowInterop(_onCallError));
    // call.on("connected", js.allowInterop(_onCallConnected));
    call.on("reconnecting", js.allowInterop(_onCallReconnecting));
    call.on("reconnected", js.allowInterop(_onCallReconnected));
    call.on("status", js.allowInterop(_onCallStatusChanged));
    call.on("log", js.allowInterop(_onLogEvent));
  }

  /// Detach event listeners to the active call
  /// See [twilio_js.Call.off]
  /// 'off' event listener isn't implemented in twilio-voice.js
  void _detachCallEventListeners(twilio_js.Call call) {
    // ignore: unnecessary_null_comparison
    assert(call != null, "Call cannot be null");
    // call.removeListener("ringing", js.allowInterop(_onCallRinging));
    call.removeListener("accept", js.allowInterop(_onCallAccept));
    call.removeListener("disconnect", js.allowInterop(_onCallDisconnect));
    call.removeListener("cancel", js.allowInterop(_onCallCancel));
    call.removeListener("reject", js.allowInterop(_onCallReject));
    call.removeListener("error", js.allowInterop(_onCallError));
    // call.removeListener("connected", js.allowInterop(_onCallConnected));
    call.removeListener("reconnecting", js.allowInterop(_onCallReconnecting));
    call.removeListener("reconnected", js.allowInterop(_onCallReconnected));
    call.removeListener("status", js.allowInterop(_onCallStatusChanged));
    call.removeListener("log", js.allowInterop(_onLogEvent));
  }

  void _onLogEvent(String status) {
    log("Log Event: $status");
  }

  /// On accept/answering (inbound) call
  /// Undocumented event: Ringing found in twilio-voice.js implementation: https://github.com/twilio/twilio-voice.js/blob/94ea6b6d8d1128ac5091f3a3bec4eae745e4d12f/lib/twilio/call.ts#L1355
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallStatusChanged(String status) {
    CallStatus callStatus = parseCallStatus(status);

    if (callStatus == CallStatus.pending) {
      /// jsCall should not be null here since `CallStatus.incoming` (incoming) or
      /// `CallStatus.connecting` (outgoing) via `place()` has already been fired and set
      _onCallRinging();
    } else if (callStatus == CallStatus.connected) {
      if (_jsCall != null) {
        _onCallConnected(_jsCall!);
      }
    }

    print("Twilio Call Status: ${status}");
    final params = getCallParams(_jsCall!);
    final callSid = params["CallSid"] as String;
    switch (callStatus) {
      case CallStatus.open:
      case CallStatus.pending:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.initiated);
        break;
      case CallStatus.ringing:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.ringing);
        break;
      case CallStatus.connected:
      case CallStatus.reconnected:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.active);
        break;
      case CallStatus.reconnecting:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.reconnecting);
        break;
      case CallStatus.answer:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.active);
        break;
      case CallStatus.rejected:
      case CallStatus.closed:
        // webCallkit.updateCallStatus(callSid, callStatus: CallState.disconnected);
        break;
      default:
        break;
    }
  }

  /// On accept/answering (inbound) call
  /// Undocumented event: Ringing found in twilio-voice.js implementation: https://github.com/twilio/twilio-voice.js/blob/94ea6b6d8d1128ac5091f3a3bec4eae745e4d12f/lib/twilio/call.ts#L1355
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  // ignore: unused_element_parameter
  void _onCallRinging({bool hasEarlyMedia = false}) {
    if (_jsCall != null) {
      final params = getCallParams(_jsCall!);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      final direction = _jsCall!.direction == "INCOMING" ? "Incoming" : "Outgoing";
      Logger.logLocalEventEntries(
        ["Ringing", from, to, direction],
        prefix: "",
      );
      final callSid = params["CallSid"] as String;
      webCallkit.updateCallStatus(callSid, callStatus: CKCallState.ringing);
    }
  }

  /// On accept/answering (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallAccept(twilio_js.Call call) async {
    if (call.direction == "INCOMING") {
      final params = getCallParams(call);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      Logger.logLocalEventEntries([
        "Answer",
        from,
        to,
        jsonEncode(params),
      ], prefix: "");

      await webCallkit.requestPermissions();
      final callSid = params["CallSid"] as String;
      webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
    }
  }

  /// On disconnect active (outbound/inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#disconnect-event
  void _onCallDisconnect(twilio_js.Call call) async {
    final status = getCallStatus(call);
    _detachCallEventListeners(call);
    if (status == CallStatus.closed && _jsCall != null) {
      Logger.logLocalEvent("Call Ended", prefix: "");
    }
    nativeCall = null;

    await webCallkit.requestPermissions();
    final params = getCallParams(call);
    final callSid = params["CallSid"] as String;
    webCallkit.reportCallDisconnected(callSid, response: CKDisconnectResponse.remote);
  }

  /// On cancels active (outbound/inbound) call
  /// This runs when:
  /// - ignoring an incoming call
  /// - calling [disconnect] on an active call before recipient has answered
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#cancel-event
  void _onCallCancel() async {
    // notify SW to cancel notification
    final callSid = await getSid();
    final callStatus = getCallStatus(_jsCall!);
    if (_jsCall != null) {
      _detachCallEventListeners(_jsCall!);
      nativeCall = null;
    }
    Logger.logLocalEvent("Call Ended", prefix: "");

    // reject incoming call that is both outbound ringing or inbound pending
    // TODO(cybex-dev): check call status for call disconnects
    if (callStatus == CallStatus.ringing || callStatus == CallStatus.pending || callStatus == CallStatus.closed) {
      Logger.logLocalEvent("Missed Call", prefix: "");
      webCallkit.reportCallDisconnected(callSid!, response: CKDisconnectResponse.missed);
    } else {
      webCallkit.reportCallDisconnected(callSid!, response: CKDisconnectResponse.local);
    }
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event
  void _onCallReject() async {
    final callSid = await getSid();
    if (_jsCall != null) {
      _detachCallEventListeners(_jsCall!);
      nativeCall = null;
    }
    Logger.logLocalEvent("Call Rejected");
    webCallkit.reportCallDisconnected(callSid!, response: CKDisconnectResponse.rejected);
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#error-event
  void _onCallError(twilio_js.TwilioError error) {
    Logger.logLocalEvent("Call Error: ${error.code}, ${error.message}");
  }

  /// On active call connected to remote client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
  void _onCallConnected(twilio_js.Call call) {
    nativeCall = call;
    final direction = call.direction == "INCOMING" ? "Incoming" : "Outgoing";
    final params = getCallParams(call);
    final from = params["From"] ?? "";
    final to = params["To"] ?? "";
    final callSid = params["CallSid"] as String;
    Logger.logLocalEventEntries(["Connected", from, to, direction], prefix: "");
    webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnecting(dynamic twilioError) {
    Logger.logLocalEvent("Reconnecting");
    final params = getCallParams(_jsCall!);
    final callSid = params["CallSid"] as String;
    webCallkit.updateCallStatus(callSid, callStatus: CKCallState.reconnecting);
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnected() {
    Logger.logLocalEvent("Reconnected");
    final params = getCallParams(_jsCall!);
    final callSid = params["CallSid"] as String;
    webCallkit.updateCallStatus(callSid, callStatus: CKCallState.active);
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

  Future<void> _addAttribute(String uuid, CKCallAttributes attribute) {
    final call = webCallkit.getCall(uuid)!;
    final attrs = call.attributes..add(attribute);
    return webCallkit.updateCallAttributes(uuid, attributes: attrs);
  }

  Future<void> _removeAttribute(String uuid, CKCallAttributes attribute) {
    final call = webCallkit.getCall(uuid)!;
    final attrs = call.attributes..remove(attribute);
    return webCallkit.updateCallAttributes(uuid, attributes: attrs);
  }
}

/// Since Call.customParameters is of type Map (but specifically implements a LegacyJavaScriptObject), we cannot access the Map directly.
/// Instead, we convert it to an array using [toArray] and then convert it to a Map
Map<String, String> _getCustomCallParameters(dynamic callParameters) {
  final list = toArray(callParameters) as List<dynamic>;
  final entries = list.map((e) {
    final entry = e as List;
    return MapEntry<String, String>(entry.first.toString(), entry.last.toString());
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

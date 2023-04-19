import 'dart:html' as html;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:js/js_util.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_voice_platform_interface.dart';

import '../twilio_voice.dart';
import './js/js.dart' as twilioJs;
import 'local_storage_web/local_storage_web.dart';
import 'method_channel/twilio_call_method_channel.dart';
import 'method_channel/twilio_voice_method_channel.dart';

// TODO - Future work
// - select output devices
// - select input devices
// - hold call
// - mute call
// - toggle speaker
// - get call SID
// - bind volume events
// - call notifications
// - return call (call back)

// TODO now
// get audio devices, bind to device

/// The web implementation of [TwilioVoicePlatform].
class TwilioVoiceWeb extends MethodChannelTwilioVoice {
  TwilioVoiceWeb() {
    // TODO(cybex-dev) - load twilio.min.js via [TwilioLoader] in future
    // loadTwilio();
  }

  final LocalStorageWeb _localStorage = LocalStorageWeb();

  twilioJs.Device? device;

  html.Navigator get _webNavigatorDelegate => html.window.navigator;

  html.Permissions? get _webPermissionsDelegate => _webNavigatorDelegate.permissions;

  late final Call _call = Call();

  @override
  Call get call => _call;

  static void registerWith(Registrar registrar) {
    TwilioVoicePlatform.instance = TwilioVoiceWeb();
  }

  Stream<CallEvent>? _callEventsListener;

  Stream<CallEvent> get callEventsListener {
    _callEventsListener ??= callEventsStream.map(parseCallEvent);
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
    logLocalEvent("defaultCaller is " + callerName);
    _localStorage.saveDefaultCallerName(callerName);
    return true;
  }

  /// Remove registered client by id, if the client is not registered, do nothing.
  /// See [LocalStorageWeb.removeRegisteredClient]
  @override
  Future<bool?> unregisterClient(String clientId) async {
    logLocalEvent("Unregistering" + clientId);
    _localStorage.removeRegisteredClient(clientId);
    return true;
  }

  /// Add registered client by [id, name] pair in local storage. If an existing client with the same id is already registered, it will be replaced.
  /// See [LocalStorageWeb.addRegisteredClient]
  @override
  Future<bool?> registerClient(String clientId, String clientName) async {
    logLocalEvent("Registering client " + clientId + ":" + clientName);
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
      /// TODO(cybex-dev) - Check browser type, if it is Firefox (or Safari), use the permissions API else use the getUserMedia API
      // final perm = await _webPermissionsDelegate?.request({"name": "microphone"});
      // return (perm == "granted");

      /// This dirty hack to get media stream. Request (to show permissions popup on Chrome and other browsers, then stop the stream to release the permission)
      /// TODO(cybex-dev) - check supported media streams
      html.MediaStream mediaStream = await _webNavigatorDelegate.getUserMedia(audio: true);
      mediaStream.getTracks().forEach((track) => track.stop());
      return hasMicAccess();
    } catch (e) {
      print("Failed to request microphone permission");
      print(e);
      return false;
    }
  }

  /// Queries current window for microphone permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> hasMicAccess() async {
    logLocalEvent("checkPermissionForMicrophone");
    try {
      final perm = await _webPermissionsDelegate?.query({"name": "microphone"});
      if (perm == null) {
        print("Failed to query microphone permission");
        return false;
      }
      if (perm.state == "granted") {
        return true;
      } else if (perm.state == "prompt") {
        logLocalEvent("RequestMicrophoneAccess");
        return false;
      } else {
        logLocalEvent("Microphone permission denied", prefix: "");
        return false;
      }
    } catch (e) {
      print("Failed to query microphone permission");
      print(e);
      return false;
    }
  }

  /// Request notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  @override
  Future<bool?> requestBackgroundPermissions() async {
    try {
      // final perm = await _webPermissionsDelegate?.request({"name": "notifications"});
      // if (perm == null) {
      //   print("Failed to request notifications permission");
      //   return false;
      // }
      // return (perm.state == "granted");
      final perm = await html.Notification.requestPermission();
      return (perm == "granted");
    } catch (e) {
      print("Failed to request notifications permission");
      print(e);
      return false;
    }
  }

  /// Queries current window for notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> requiresBackgroundPermissions() async {
    try {
      // final perm = await _webPermissionsDelegate?.query({"name": "notifications"});
      // if (perm == null) {
      //   print("Failed to query notifications permission");
      //   return false;
      // }
      // return (perm.state == "granted");
      final perm = html.Notification.permission;
      return (perm == "granted");
    } catch (e) {
      print("Failed to query notifications permission");
      print(e);
      return false;
    }
  }

  /// Unregister device from Twilio. Returns true if successful, false otherwise.
  /// [accessToken] is ignored for web
  /// See [twilioJs.Device.unregister]
  @override
  Future<bool?> unregister({String? accessToken}) async {
    if (device == null) {
      return false;
    }
    try {
      device?.unregister();
      _detachDeviceListeners(device!);
      return true;
    } catch (e) {
      print("Failed to unregister device: $e");
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

  /// Creates and registered the Twilio Device. Returns true if successful, false otherwise.
  /// See [twilioJs.Device.new]
  /// Note: [deviceToken] is ignored for web
  @override
  Future<bool?> setTokens({required String accessToken, String? deviceToken}) async {
    assert(accessToken.isNotEmpty, "Access token cannot be empty");
    // assert(deviceToken != null && deviceToken.isNotEmpty, "Device token cannot be null or empty");
    // if (device != null) {
    //   // check active calls?
    //   print("Twilio device already active, unregistering...");
    //   try {
    //     await device!.unregister();
    //
    //   } catch (e) {
    //     print("Failed to unregister device: $e");
    //     return false;
    //   }
    // }
    try {
      /// opus set as primary code
      /// https://www.twilio.com/blog/client-javascript-sdk-1-7-ga
      List<String> codecs = ["opus", "pcmu"];
      twilioJs.DeviceInitOptions options = twilioJs.DeviceInitOptions(codecPreferences: codecs);

      /// create new Twilio device
      device = twilioJs.Device(accessToken, options);
      _call.device = device;
      _attachDeviceListeners(device!);

      // Register device to accept notifications
      device!.register();

      return true;
    } catch (e) {
      print("Failed to set Twilio Device token: $e");
      return false;
    }
  }

  /// Attach event listeners to [twilioJs.Device]
  /// See [twilioJs.Device.on]
  void _attachDeviceListeners(twilioJs.Device device) {
    assert(device != null, "Device cannot be null");
    device.on("registered", allowInterop(_onDeviceRegistered));
    device.on("unregistered", allowInterop(_onDeviceUnregistered));
    device.on("error", allowInterop(_onDeviceError));
    device.on("incoming", allowInterop(_onDeviceIncoming));
    device.on("tokenWillExpire", allowInterop(_onTokenWillExpire));
  }

  /// Detach event listeners to [twilioJs.Device]
  /// See [twilioJs.Device.off]
  void _detachDeviceListeners(twilioJs.Device device) {
    assert(device != null, "Device cannot be null");
    device.off("registered", allowInterop(_onDeviceRegistered));
    device.off("unregistered", allowInterop(_onDeviceUnregistered));
    device.off("error", allowInterop(_onDeviceError));
    device.off("incoming", allowInterop(_onDeviceIncoming));
    device.off("tokenWillExpire", allowInterop(_onTokenWillExpire));
  }

  /// On device registered and ready to make/receive calls via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.registered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  void _onDeviceRegistered() {
    print("Device registered for callInvites");
  }

  /// On device unregistered, access token disabled and won't receive any more call invites [twilioJs.Device.off] and [twilioJs.TwilioDeviceEvents.unregistered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event
  void _onDeviceUnregistered() {
    print("Device unregistered, won't receive no more callInvites");
  }

  /// On device error
  /// See [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.error]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#error-event
  void _onDeviceError(twilioJs.TwilioError twilioError, twilioJs.Call? call) {
    print("Device Error: ${twilioError.message}");
  }

  /// On incoming call received via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.incoming]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#incoming-event
  void _onDeviceIncoming(twilioJs.Call call) {
    print("Call incoming");
    this.call.nativeCall = call;
    print(this.call.activeCall.toString());
    final from = "caller"; // call.parameters["From"] ?? "";
    final to = "recipient"; // call.parameters["To"] ?? "";
    logLocalEventEntries(["Incoming", from, to, "Incoming", "{}" /*jsonEncode(call.parameters)*/], prefix: "");
  }

  /// On device token about to expire (default is 10s prior to expiry), via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.tokenWillExpire]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#tokenwillexpire-event
  void _onTokenWillExpire(dynamic obj) {
    print("Token will expire");
  }
}

class Call extends MethodChannelTwilioCall {
  /// Twilio Call JS interface object
  twilioJs.Call? _jsCall;
  twilioJs.Device? _device;

  twilioJs.Device? get device => _device;

  set device(twilioJs.Device? value) {
    _device = value;
  }

  Call({twilioJs.Call? call}) : _jsCall = call;

  twilioJs.Call? get nativeCall {
    return _jsCall;
  }

  set nativeCall(twilioJs.Call? value) {
    _jsCall = value;
    if(value != null) {
      activeCall = activeCallFromNativeJsCall(value);
    }
  }

  /// Send digits to the call. Returns true if successful, false otherwise.
  /// See [twilioJs.Call.sendDigits]
  @override
  Future<bool?> sendDigits(String digits) async {
    if (_jsCall != null) {
      _jsCall!.sendDigits(digits);
      return true;
    }
    return false;
  }

  /// Not currently implemented for web
  @override
  Future<bool?> toggleSpeaker(bool speakerIsOn) async {
    logLocalEvent(speakerIsOn ? "Speaker On" : "Speaker Off", prefix: "");
    return Future.value(false);
  }

  /// Not currently implemented for web
  @override
  Future<bool?> toggleMute(bool isMuted) async {
    logLocalEvent(isMuted ? "Mute" : "Unmute", prefix: "");
    return Future.value(false);
  }

  /// Not currently implemented for web
  /// https://github.com/twilio/twilio-voice.js/issues/32
  /// Call holding should be done server-side as suggested by @ryan-rowland here(https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1016872545)
  /// See this to get started: https://stackoverflow.com/questions/22643800/twilio-how-to-move-an-existing-call-to-a-conference
  /// See this for more info on how to use cold holding, and its requirements: https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1331081241
  /// TODO(cybex-dev) - implement call holding feature in [twilio-voice.js](https://github.com/twilio/twilio-voice.js) for use in twilio_voice_web
  @override
  Future<bool?> holdCall({bool holdCall = true}) {
    // logLocalEvent(holdCall ? "Unhold" : "Hold", prefix: "");
    // return Future.value(false);
    logLocalEvent("Unhold");
    return Future.value(false);
  }

  /// Answers an inbound call. Returns true if successful, false otherwise.
  /// See [twilioJs.Call.accept]
  @override
  Future<bool?> answer() async {
    if (_jsCall != null) {
      // Accept incoming call
      _jsCall!.accept();
      activeCall = activeCallFromNativeJsCall(_jsCall!);

      // attach event listeners
      _attachCallEventListeners(_jsCall!);

      // log event
      final customParameters = _jsCall!.parameters;
      final from = "caller"; // customParameters["From"] ?? "";
      final to = "recipient"; // customParameters["To"] ?? "";
      logLocalEventEntries(["Answer", from, to, "{}" /*jsonEncode(customParameters)*/]);

      return true;
    }
    return false;
  }

  /// Gets call Sid from call parameters or custom parameters.
  @override
  Future<String?> getSid() async {
    if (_jsCall == null) {
      return null;
    }
    return _jsCall?.parameters["CallSid"] ?? _jsCall?.customParameters["CallSid"] ?? null;
  }

  /// Returns true if there is an active call, a convenience function for [activeCall != null], false otherwise.
  /// See [MethodChannelTwilioCall.activeCall]
  @override
  Future<bool> isOnCall() async {
    return activeCall != null;
  }

  /// Returns true if the call was disconnected, false otherwise.
  /// See [twilioJs.Call.disconnect]
  @override
  Future<bool?> hangUp() async {
    if (_jsCall != null) {
      _jsCall!.disconnect();
      _detachCallEventListeners(_jsCall!);
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
  /// See [twilioJs.Device.connect]
  @override
  Future<bool?> place({required String from, required String to, Map<String, dynamic>? extraOptions}) async {
    assert(device != null,
        "Twilio device is null, make sure you have initialized the device first by calling [ setTokens({required String accessToken, String? deviceToken}) ] ");
    assert(from.isNotEmpty, "From cannot be empty");
    assert(to.isNotEmpty, "To cannot be empty");
    assert(extraOptions?.keys.contains("From") ?? true, "From cannot be passed in extraOptions");
    assert(extraOptions?.keys.contains("To") ?? true, "To cannot be passed in extraOptions");

    logLocalEvent("Making new call", prefix: "");
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
      final callParams = jsify(params);
      final options = twilioJs.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      final _call = await promiseToFuture(promise);
      nativeCall = _call;

      _attachCallEventListeners(_jsCall!);
    } catch (e) {
      print("Failed to place call: $e");
      return false;
    }
    return true;
  }

  /// Attach event listeners to the active call
  /// See [twilioJs.Call.on]
  void _attachCallEventListeners(twilioJs.Call call) {
    assert(call != null, "Call cannot be null");
    call.on("accept", allowInterop(_onCallAccept));
    call.on("disconnect", allowInterop(_onCallDisconnect));
    call.on("cancel", allowInterop(_onCallCancel));
    call.on("reject", allowInterop(_onCallReject));
    call.on("error", allowInterop(_onCallError));
    // call.on("connected", allowInterop(_onCallConnected));
    call.on("reconnecting", allowInterop(_onCallReconnecting));
    call.on("reconnected", allowInterop(_onCallReconnected));
  }

  /// Detach event listeners to the active call
  /// See [twilioJs.Call.off]
  /// 'off' event listener isn't implemented in twilio-voice.js
  void _detachCallEventListeners(twilioJs.Call call) {
    assert(call != null, "Call cannot be null");
    // call.off("accept", allowInterop(_onCallAccept));
    // call.off("disconnect", allowInterop(_onCallDisconnect));
    // call.off("cancel", allowInterop(_onCallCancel));
    // call.off("reject", allowInterop(_onCallReject));
    // call.off("error", allowInterop(_onCallError));
    // call.off("connected", allowInterop(_onCallConnected));
    // call.off("reconnecting", allowInterop(_onCallReconnecting));
    // call.off("reconnected", allowInterop(_onCallReconnected));
  }

  /// On accept/answering (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallAccept(twilioJs.Call call) {
    activeCall = activeCallFromNativeJsCall(call);
    print(activeCall.toString());
    final from = "caller"; // call.parameters["From"] ?? "";
    final to = "recipient"; // call.parameters["To"] ?? "";
    logLocalEventEntries(["Answer", from, to, "{}"/*jsonEncode(call.parameters)*/]);
  }

  /// On disconnect active (outbound/inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#disconnect-event
  void _onCallDisconnect(twilioJs.Call call) {
    print("call disconnected");
    logLocalEvent("Call Ended");
  }

  /// On cancels active (outbound/inbound) call
  /// This runs when:
  /// - ignoring an incoming call
  /// - calling [disconnect] on an active call before recipient has answered
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#cancel-event
  void _onCallCancel() {
    activeCall = null;
    print("call cancelled");
    logLocalEvent("Missed Call");
    logLocalEvent("Call Ended");
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event
  void _onCallReject() {
    activeCall = null;
    print("call rejected");
    logLocalEvent("Call Rejected", prefix: "");
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#error-event
  void _onCallError(twilioJs.TwilioError error) {
    print("Call Error: $error");
    logLocalEvent("Call Error: ${error.code}, ${error.message}");
  }

  /// On active call connected to remote client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
  // void _onCallConnected() {
  //   final _f = (twilioJs.Call call) {
  //     final direction = call.direction() == "INCOMING" ? "Incoming" : "Outgoing";
  //     final from = call.customParameters["From"] ?? "";
  //     final to = call.customParameters["To"] ?? "";
  //     logLocalEventEntries(["Connected", from, to, direction]);
  //   };
  //   return allowInterop(_f);
  // }

  /// On active call reconnecting to Twilio network
  void _onCallReconnecting(dynamic twilioError) {
    print("Reconnecting: $twilioError}");
    logLocalEvent("Reconnecting...", prefix: "");
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnected() {
    print("Reconnected");
    logLocalEvent("Reconnected", prefix: "");
  }
}

ActiveCall activeCallFromNativeJsCall(twilioJs.Call call, {DateTime? initiated}) {
  final direction = call.direction;
  final date = initiated ?? DateTime.now();
  final _activeCall = ActiveCall(
    from: "caller",// call.customParameters["From"] ?? "",
    to: "recipient", // call.customParameters["To"] ?? "",
    customParams: {}, //call.customParameters as Map<String, dynamic>?,
    callDirection: direction == "INCOMING" ? CallDirection.incoming : CallDirection.outgoing,
    initiated: date,
  );
  return _activeCall;
}

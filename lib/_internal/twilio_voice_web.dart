import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_call_platform_interface.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_voice_platform_interface.dart';
import 'package:twilio_voice/_internal/twilio_loader.dart';

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

  late final Call _call = Call();

  @override
  TwilioCallPlatform get call => _call;

  static void registerWith(Registrar registrar) {
    TwilioVoicePlatform.instance = TwilioVoiceWeb();
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
  @override
  Future<bool?> requestMicAccess() async {
    logLocalEvent("requesting mic permission");
    final perm = await html.window.navigator.permissions?.request({"name": "microphone"});
    if (perm == null) {
      print("Failed to request microphone permission");
      return false;
    }
    if (perm.state == "granted") {
      return true;
    } else {
      return false;
    }
  }

  /// Queries current window for microphone permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> hasMicAccess() async {
    logLocalEvent("checkPermissionForMicrophone");
    final perm = await html.window.navigator.permissions?.query({"name": "microphone"});
    if (perm == null) {
      print("Failed to query microphone permission");
      return false;
    }
    if (perm.state == "granted") {
      return true;
    } else {
      logLocalEvent("RequestMicrophoneAccess", prefix: "");
      return false;
    }
  }

  /// Request notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  @override
  Future<bool?> requestBackgroundPermissions() async {
    final perm = await html.window.navigator.permissions?.request({"name": "notifications"});
    if (perm == null) {
      print("Failed to request notifications permission");
      return false;
    }
    if (perm.state == "granted") {
      return true;
    } else {
      return false;
    }
  }

  /// Queries current window for notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> requiresBackgroundPermissions() async {
    final perm = await html.window.navigator.permissions?.query({"name": "notifications"});
    if (perm == null) {
      print("Failed to query notifications permission");
      return false;
    }
    if (perm.state == "granted") {
      return true;
    } else {
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
      await device?.unregister();
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
      // create new Twilio device
      device = twilioJs.Device(accessToken, twilioJs.DeviceInitOptions());
      _attachDeviceListeners(device!);

      // Register device to accept notifications
      await device!.register();

      _call.device = device;
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
    device.on("registered", _onDeviceRegistered);
    device.on("unregistered", _onDeviceUnregistered);
    device.on("error", _onDeviceError);
    device.on("incoming", _onDeviceIncoming);
    device.on("tokenWillExpire", _onTokenWillExpire);
  }

  /// Detach event listeners to [twilioJs.Device]
  /// See [twilioJs.Device.off]
  void _detachDeviceListeners(twilioJs.Device device) {
    assert(device != null, "Device cannot be null");
    device.off("registered", _onDeviceRegistered);
    device.off("unregistered", _onDeviceUnregistered);
    device.off("error", _onDeviceError);
    device.off("incoming", _onDeviceIncoming);
    device.off("tokenWillExpire", _onTokenWillExpire);
  }

  /// On device registered and ready to make/receive calls via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.registered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  void _onDeviceRegistered(twilioJs.Device device) {
    logLocalEvent("Device registered for callInvites", prefix: "");
  }

  /// On device unregistered, access token disabled and won't receive any more call invites [twilioJs.Device.off] and [twilioJs.TwilioDeviceEvents.unregistered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event
  void _onDeviceUnregistered(twilioJs.Device device) {
    logLocalEvent("Device unregistered, won't receive no more callInvites", prefix: "");
  }

  /// On device error
  /// See [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.error]
  /// Documentation: https://www.twilio.com/docs/voice/client/javascript/device#events
  void _onDeviceError(twilioJs.Device device, String error) {
    logLocalEvent("Error: " + error);
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
  void _onTokenWillExpire(twilioJs.Device device) {
    // TODO
  }
}

class Call extends MethodChannelTwilioCall {
  /// Twilio Call JS interface object
  twilioJs.Call? _call;
  twilioJs.Device? _device;

  twilioJs.Device? get device => _device;

  set device(twilioJs.Device? value) {
    _device = value;
  }

  Call({twilioJs.Call? call}) : _call = call;

  /// Send digits to the call. Returns true if successful, false otherwise.
  /// See [twilioJs.Call.sendDigits]
  @override
  Future<bool?> sendDigits(String digits) async {
    if (_call != null) {
      _call!.sendDigits(digits);
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
  @override
  Future<bool?> holdCall({bool holdCall = true}) {
    logLocalEvent(holdCall ? "Unhold" : "Hold", prefix: "");
    return Future.value(false);
  }

  /// Answers an inbound call. Returns true if successful, false otherwise.
  /// See [twilioJs.Call.accept]
  @override
  Future<bool?> answer() async {
    if (_call != null) {
      // Accept incoming call
      _call!.accept();

      // attach event listeners
      _attachCallEventListeners(_call!);

      // log event
      final customParameters = _call!.customParameters;
      final from = customParameters["From"] ?? "";
      final to = customParameters["To"] ?? "";
      logLocalEventEntries(["Answer", from, to, jsonEncode(customParameters)]);

      return true;
    }
    return false;
  }

  /// Not currently implemented for web
  @override
  Future<String?> getSid() {
    return Future.value(null);
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
    if (_call != null) {
      _call!.disconnect();
      _detachCallEventListeners(_call!);
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
    assert(device != null, "Twilio device is null");
    assert(from.isNotEmpty, "From cannot be empty");
    assert(to.isNotEmpty, "To cannot be empty");
    assert(extraOptions?.keys.contains("From") ?? false, "From cannot be passed in extraOptions");
    assert(extraOptions?.keys.contains("To") ?? false, "From cannot be passed in extraOptions");

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
    final options = twilioJs.DeviceConnectOptions(params: params);
    try {
      var promise = _device!.connect(options);
      await promise.then((result) {
        _call = result;
        _attachCallEventListeners(_call!);
      });
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
    call.on("accept", _onCallAccept);
    call.on("disconnect", _onCallDisconnect);
    call.on("cancel", _onCallCancel);
    call.on("reject", _onCallReject);
    call.on("error", _onCallError);
    call.on("connected", _onCallConnected);
    call.on("reconnecting", _onCallReconnecting);
    call.on("reconnected", _onCallReconnected);
  }

  /// Detach event listeners to the active call
  /// See [twilioJs.Call.off]
  void _detachCallEventListeners(twilioJs.Call call) {
    assert(call != null, "Call cannot be null");
    call.off("accept", _onCallAccept);
    call.off("disconnect", _onCallDisconnect);
    call.off("cancel", _onCallCancel);
    call.off("reject", _onCallReject);
    call.off("error", _onCallError);
    call.off("connected", _onCallConnected);
    call.off("reconnecting", _onCallReconnecting);
    call.off("reconnected", _onCallReconnected);
  }

  /// On accept/answering (inbound) call
  void _onCallAccept(twilioJs.Call call) {
    final from = call.customParameters["From"] ?? "";
    final to = call.customParameters["To"] ?? "";
    logLocalEventEntries(["Answer", from, to, jsonEncode(call.customParameters)]);
  }

  /// On disconnect active (outbound/inbound) call
  void _onCallDisconnect(twilioJs.Call call, dynamic error) {
    if (error != null) {
      logLocalEvent("Call Ended: ${error.getErrorCode()}, ${error.getMessage()}");
    } else {
      logLocalEvent("Call Ended", prefix: "");
    }
  }

  /// On cancels active (outbound/inbound) call
  void _onCallCancel(twilioJs.Call call, String error) {
    logLocalEvent("Missed Call");
    logLocalEvent("Call Ended");
  }

  /// On reject (inbound) call
  void _onCallReject(twilioJs.Call call) {
    logLocalEvent("Call Rejected", prefix: "");
  }

  /// On reject (inbound) call
  void _onCallError(twilioJs.Call call, dynamic exception) {
    logLocalEvent("Call Error: ${exception.getErrorCode()}, ${exception.getMessage()}");
  }

  /// On active call connected to remote client
  void _onCallConnected(twilioJs.Call call) {
    final direction = call.direction == "INCOMING" ? "Incoming" : "Outgoing";
    final from = call.customParameters["From"] ?? "";
    final to = call.customParameters["To"] ?? "";
    logLocalEventEntries(["Connected", from, to, direction]);
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnecting(twilioJs.Call call, dynamic error) {
    logLocalEvent("Reconnecting...", prefix: "");
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnected(twilioJs.Call call, dynamic error) {
    logLocalEvent("Reconnected", prefix: "");
  }
}

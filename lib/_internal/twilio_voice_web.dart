import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

// Added as temporary measure till sky_engine includes js_util (allowInterop())
import 'package:js/js.dart' as js;
import 'package:js/js_util.dart' as js_util;
import 'package:twilio_voice/_internal/js/call/call_status.dart';
import 'package:js/js_util.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_voice_platform_interface.dart';

import '../twilio_voice.dart';
import './js/js.dart' as twilioJs;
import 'js/utils/js_object_utils.dart';
import 'local_storage_web/local_storage_web.dart';
import 'method_channel/twilio_call_method_channel.dart';
import 'method_channel/twilio_voice_method_channel.dart';

class TwilioSW {
  TwilioSW._() {
    _setupServiceWorker();
  }

  static TwilioSW _instance = TwilioSW._();

  static TwilioSW get instance => _instance;

  html.ServiceWorkerContainer? _webServiceWorkerContainerDelegate;
  html.ServiceWorker? _webServiceWorkerDelegate;
  StreamSubscription<html.MessageEvent>? _webServiceWorkerMessageSubscription;

  ValueChanged<Map<dynamic, dynamic>>? _messageReceived;

  set onMessageReceived(ValueChanged<Map<dynamic, dynamic>> value) {
    _messageReceived = value;
  }

  /// If present, this allows app functionality in the background.
  /// Use-cases included, but aren't limited to:
  /// - showing incoming call notifications with responding actions (e.g. answer/hangup).
  /// - listening to incoming calls (via TwilioVoiceSDK Js websocket connection)
  void _setupServiceWorker() {
    _webServiceWorkerContainerDelegate = html.window.navigator.serviceWorker;
    if (_webServiceWorkerContainerDelegate == null) {
      print("No service worker found, check if you've registered the `twilio-sw.js` service worker and if the script is present.");
      return;
    }

    // attach SW event listeners to respond to incoming messages from SW
    _attachServiceWorkerListeners();

    _webServiceWorkerDelegate = _webServiceWorkerContainerDelegate?.controller;
    if (_webServiceWorkerDelegate == null) {
      print("No service worker registered and/or controlling the page. Try (soft) refreshing?");
      return;
    }
  }

  void _attachServiceWorkerListeners() {
    if (_webServiceWorkerContainerDelegate != null) {
      if (_webServiceWorkerMessageSubscription != null) {
        // already registered, we don't have to register again
        return;
      }
      _webServiceWorkerMessageSubscription = _webServiceWorkerContainerDelegate!.onMessage.listen((event) {
        _messageReceived?.call(event.data);
      });
    }
  }

  Future<void> destroy() {
    return _detachServiceWorkerListeners();
  }

  Future<void> _detachServiceWorkerListeners() async {
    await _webServiceWorkerMessageSubscription?.cancel();
  }

  void send(Map<String, dynamic> message) {
    if (_webServiceWorkerDelegate != null) {
      _webServiceWorkerDelegate!.postMessage(message);
    }
  }
}

class NotificationService {
  TwilioSW _twilioSW = TwilioSW.instance;

  NotificationService._();

  static NotificationService _instance = NotificationService._();

  static NotificationService get instance => _instance;

  Future<void> showNotification({
    required String action,
    required String title,
    required String tag,
    String? body,
    String? imageUrl,
    bool? requiresInteraction,
    List<Map<String, String>>? actions,
  }) async {
    // request background permissions
    if(!await hasPermission()) {
      bool result = await requestPermission();
      if(!result) {
        print("Cannot show notification with permission.");
        return;
      }
    }

    final notification = <String, dynamic>{
      'action': action,
      'payload': {
        'title': title,
        'options': {
          'tag': tag,
          'body': body,
          'image': imageUrl,
          // TODO(cybex-dev): Service worker events i.e. 'notificationclick' & 'notificationclose' are (on Windows) intercepted before reaching twilio-sw, thus do not respond to events.
          'actions': actions,
          // TODO(cybex-dev) Hide requires interaction until we can handle events in the service worker (see above)
          'requireInteraction': requiresInteraction,
        }
      }
    };
    // See above, actions are removed temporarily on Windows notifications since they aren't triggered/received by Service Worker.
    // if (kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    //   notification['payload']['options']['actions'] = [];
    // }

    _twilioSW.send(notification);
  }

  Future<bool> requestPermission() async {
    try {
      final perm = await html.Notification.requestPermission();
      return (perm == "granted");
    } catch (e) {
      print("Failed to request notifications permission");
      print(e);
      return false;
    }
  }

  Future<bool> hasPermission() async {
    try {
      final perm = html.Notification.permission;
      return (perm == "granted");
    } catch (e) {
      print("Failed to query notifications permission");
      print(e);
      return false;
    }
  }
}

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
  TwilioVoiceWeb() {
    // TODO(cybex-dev) - load twilio.min.js via [TwilioLoader] in future
    // loadTwilio();

    // setup SW listener
    final sw = TwilioSW.instance;
    sw._setupServiceWorker();
    sw.onMessageReceived = _handleServiceWorkerMessage;
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
    if (_callEventsListener == null) {
      _callEventsListener = Logger.callEventsStream.map(parseCallEvent);
    }
    return _callEventsListener!;
  }

  void _handleServiceWorkerMessage(dynamic data) {
    String? action;
    Map? payload;
    if (data is String) {
      action = data;
    } else if (data is Map) {
      action = data["action"];
      payload = data["payload"];
    } else {
      print("Invalid data received from service worker: $data");
    }

    if (action == null) {
      print("No action received from service worker");
      return;
    }

    switch (action) {
      case "answer":
        call.answer();
        break;
      case "reject":
        call.hangUp();
        break;
      default:
        print("Unhandled action from service worker: $action");
    }
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
    Logger.logLocalEvent("defaultCaller is " + callerName);
    _localStorage.saveDefaultCallerName(callerName);
    return true;
  }

  /// Remove registered client by id, if the client is not registered, do nothing.
  /// See [LocalStorageWeb.removeRegisteredClient]
  @override
  Future<bool?> unregisterClient(String clientId) async {
    Logger.logLocalEvent("Unregistering" + clientId);
    _localStorage.removeRegisteredClient(clientId);
    return true;
  }

  /// Add registered client by [id, name] pair in local storage. If an existing client with the same id is already registered, it will be replaced.
  /// See [LocalStorageWeb.addRegisteredClient]
  @override
  Future<bool?> registerClient(String clientId, String clientName) async {
    Logger.logLocalEvent("Registering client " + clientId + ":" + clientName);
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
    Logger.logLocalEvent("checkPermissionForMicrophone");
    try {
      final perm = await _webPermissionsDelegate?.query({"name": "microphone"});
      if (perm == null) {
        print("Failed to query microphone permission");
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
      print("Failed to query microphone permission");
      print(e);
      return false;
    }
  }

  /// Request notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/permissions/request
  @override
  Future<bool?> requestBackgroundPermissions() async {
    return NotificationService.instance.requestPermission();
  }

  /// Queries current window for notifications permission. Returns true if permission is granted, false otherwise.
  /// Documentation: https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query
  @override
  Future<bool> requiresBackgroundPermissions() async {
    return NotificationService.instance.hasPermission();
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
      TwilioSW.instance.destroy();
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
    // TODO use updateOptions for Twilio device
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
      twilioJs.DeviceInitOptions options = twilioJs.DeviceInitOptions(
        codecPreferences: codecs,
        closeProtection: true,
      );

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
    device.on("registered", js.allowInterop(_onDeviceRegistered));
    device.on("unregistered", js.allowInterop(_onDeviceUnregistered));
    device.on("error", js.allowInterop(_onDeviceError));
    device.on("incoming", js.allowInterop(_onDeviceIncoming));
    device.on("tokenWillExpire", js.allowInterop(_onTokenWillExpire));
  }

  /// Detach event listeners to [twilioJs.Device]
  /// See [twilioJs.Device.off]
  void _detachDeviceListeners(twilioJs.Device device) {
    assert(device != null, "Device cannot be null");
    device.off("registered", js.allowInterop(_onDeviceRegistered));
    device.off("unregistered", js.allowInterop(_onDeviceUnregistered));
    device.off("error", js.allowInterop(_onDeviceError));
    device.off("incoming", js.allowInterop(_onDeviceIncoming));
    device.off("tokenWillExpire", js.allowInterop(_onTokenWillExpire));
  }

  /// On device registered and ready to make/receive calls via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.registered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event
  void _onDeviceRegistered() {
    print("_onDeviceRegistered");
    print("Device registered for callInvites");
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

  /// On device unregistered, access token disabled and won't receive any more call invites [twilioJs.Device.off] and [twilioJs.TwilioDeviceEvents.unregistered]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event
  void _onDeviceUnregistered() {
    print("_onDeviceUnregistered");
    print("Device unregistered, won't receive no more callInvites");
  }

  /// On device error
  /// See [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.error]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#error-event
  void _onDeviceError(twilioJs.TwilioError twilioError, twilioJs.Call? call) {
    logLocalEvent(twilioError.message);
  }

  /// On incoming call received via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.incoming]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#incoming-event
  void _onDeviceIncoming(twilioJs.Call call) {
    requestMicAccess();
    this.call.nativeCall = call;
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

  void _showIncomingCallNotification(twilioJs.Call call) {
    // request permission to show notification
    NotificationService.instance.requestPermission();

    final action = 'incoming';
    final callParams = getCallParams(call);
    final title = _resolveCallerName(callParams);
    final body = 'Incoming Call';
    final callSid = callParams["CallSid"] as String;
    final imageUrl = _resolveImageUrl(callParams);
    final actions = <Map<String, String>>[
      {'action': 'answer', 'title': 'Accept', 'icon': 'icons/answer/128.png'},
      {'action': 'reject', 'title': 'Reject', 'icon': 'icons/hangup/128.png'},
    ];
    // final actions = <Map<String, String>>[
    //   {'action': 'cancel', 'title': 'Ok'},
    // ];

    // show JS notification using SW
    NotificationService.instance.showNotification(
      action: action,
      title: title,
      tag: callSid,
      body: body,
      imageUrl: imageUrl,
      actions: actions,
      requiresInteraction: true,
    );
  }

  /// On device token about to expire (default is 10s prior to expiry), via [twilioJs.Device.on] and [twilioJs.TwilioDeviceEvents.tokenWillExpire]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#tokenwillexpire-event
  void _onTokenWillExpire(twilioJs.Device device) {
    logLocalEventEntries(["DEVICETOKEN", device.token], prefix: "");
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
    if (value != null) {
      activeCall = activeCallFromNativeJsCall(value);
      _attachCallEventListeners(_jsCall!);
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
    Logger.logLocalEvent(speakerIsOn ? "Speaker On" : "Speaker Off", prefix: "");
    return Future.value(false);
  }

  /// Not currently implemented for web
  @override
  Future<bool?> toggleMute(bool isMuted) async {
    Logger.logLocalEvent(isMuted ? "Mute" : "Unmute", prefix: "");
    if (_jsCall != null) {
      _jsCall!.mute(isMuted);
    }
    return isMuted;
  }

  /// Not currently implemented for web
  /// https://github.com/twilio/twilio-voice.js/issues/32
  /// Call holding should be done server-side as suggested by @ryan-rowland here(https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1016872545)
  /// See this to get started: https://stackoverflow.com/questions/22643800/twilio-how-to-move-an-existing-call-to-a-conference
  /// See this for more info on how to use cold holding, and its requirements: https://github.com/twilio/twilio-voice.js/issues/32#issuecomment-1331081241
  /// TODO(cybex-dev) - implement call holding feature in [twilio-voice.js](https://github.com/twilio/twilio-voice.js) for use in twilio_voice_web
  @override
  Future<bool?> holdCall({bool holdCall = true}) {
    // Logger.logLocalEvent(holdCall ? "Unhold" : "Hold", prefix: "");
    // return Future.value(false);
    Logger.logLocalEvent("Unhold");
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
      final params = getCallParams(_jsCall!);
      final from = params["From"] ?? "";
      final to = params["To"] ?? "";
      Logger.logLocalEventEntries(
        ["Answer", from, to, jsonEncode(params)],
        prefix: "",
      );

      // notify SW to cancel notification
      final callSid = await getSid();
      _cancelNotification(callSid!);

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
    return params["CallSid"] ?? null;
  }

  /// Returns true if there is an active call, a convenience function for [activeCall != null], false otherwise.
  /// See [MethodChannelTwilioCall.activeCall]
  @override
  Future<bool> isOnCall() async {
    return this.device?.isBusy ?? _jsCall != null;
  }

  /// Returns true if the call was disconnected, false otherwise.
  /// See [twilioJs.Call.disconnect]
  @override
  Future<bool?> hangUp() async {
    if (_jsCall != null) {
      // notify SW to cancel notification
      final callSid = await getSid();
      _cancelNotification(callSid!);

      CallStatus callStatus = getCallStatus(_jsCall!);
      if (callStatus == CallStatus.ringing) {
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
  /// See [twilioJs.Device.connect]
  @override
  Future<bool?> place({required String from, required String to, Map<String, dynamic>? extraOptions}) async {
    assert(device != null,
        "Twilio device is null, make sure you have initialized the device first by calling [ setTokens({required String accessToken, String? deviceToken}) ] ");
    assert(from.isNotEmpty, "From cannot be empty");
    assert(to.isNotEmpty, "To cannot be empty");
    assert(extraOptions?.keys.contains("From") ?? true, "From cannot be passed in extraOptions");
    assert(extraOptions?.keys.contains("To") ?? true, "To cannot be passed in extraOptions");

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
      final options = twilioJs.DeviceConnectOptions(params: callParams);
      final promise = _device!.connect(options);
      final _call = await js_util.promiseToFuture(promise);
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
  /// See [twilioJs.Call.off]
  /// 'off' event listener isn't implemented in twilio-voice.js
  void _detachCallEventListeners(twilioJs.Call call) {
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
    log("Log Event: " + status);
  }

  /// On accept/answering (inbound) call
  /// Undocumented event: Ringing found in twilio-voice.js implementation: https://github.com/twilio/twilio-voice.js/blob/94ea6b6d8d1128ac5091f3a3bec4eae745e4d12f/lib/twilio/call.ts#L1355
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallStatusChanged(String status) {
    CallStatus callStatus = parseCallStatus(status);

    switch (callStatus) {
      case CallStatus.closed:
        // TODO: Handle this case.
        break;
      case CallStatus.connected:
        if (_jsCall != null) {
          _onCallConnected(_jsCall!);
        }
        break;
      case CallStatus.reconnecting:
        // TODO: Handle this case.
        break;
      case CallStatus.reconnected:
        // TODO: Handle this case.
        break;
      case CallStatus.connecting:
      // Added missing Ringing for outgoing calls
      case CallStatus.ringing:

        /// jsCall should not be null here since `CallStatus.incoming` (incoming) or
        /// `CallStatus.connecting` (outgoing) via `place()` has already been fired and set
        _onCallRinging();
        break;
      case CallStatus.rejected:
        // TODO: Handle this case.
        break;
      case CallStatus.answer:
        // TODO: Handle this case.
        break;
    }
  }

  /// On accept/answering (inbound) call
  /// Undocumented event: Ringing found in twilio-voice.js implementation: https://github.com/twilio/twilio-voice.js/blob/94ea6b6d8d1128ac5091f3a3bec4eae745e4d12f/lib/twilio/call.ts#L1355
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
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
    }
  }

  /// On accept/answering (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#accept-event
  void _onCallAccept(twilioJs.Call call) {
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
    }
  }

  /// On disconnect active (outbound/inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#disconnect-event
  void _onCallDisconnect(twilioJs.Call call) {
    final status = getCallStatus(call);
    _detachCallEventListeners(call);
    if (status == CallStatus.closed && _jsCall != null) {
      Logger.logLocalEvent("Call Ended", prefix: "");
    }
    nativeCall = null;
  }

  /// On cancels active (outbound/inbound) call
  /// This runs when:
  /// - ignoring an incoming call
  /// - calling [disconnect] on an active call before recipient has answered
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#cancel-event
  void _onCallCancel() async {
    // notify SW to cancel notification
    final callSid = await getSid();
    _cancelNotification(callSid!);

    _showMissedCallNotification(_jsCall!);
    if (_jsCall != null) {
      _detachCallEventListeners(_jsCall!);
      nativeCall = null;
    }
    Logger.logLocalEvent("Missed Call", prefix: "");
    Logger.logLocalEvent("Call Ended", prefix: "");
  }



  Future<void> _showMissedCallNotification(twilioJs.Call call) async {
    final action = 'missed';
    final callParams = getCallParams(call);
    // TODO(cybex-dev) resolve from local storage
    final title = callParams["From"] ?? "";
    final body = 'Missed Call';

    final actions = <Map<String, String>>[
      // TODO(cybex-dev) future actions
      // {'action': 'callback', 'title': 'Return Call'},
    ];

    // show JS notification using SW
    NotificationService.instance.showNotification(
      action: action,
      title: title,
      tag: "",
      body: body,
      actions: actions,
      requiresInteraction: true,
    );
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event
  void _onCallReject() {
    if (_jsCall != null) {
      _detachCallEventListeners(_jsCall!);
      nativeCall = null;
    }
    Logger.logLocalEvent("Call Rejected");
  }

  /// On reject (inbound) call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#error-event
  void _onCallError(twilioJs.TwilioError error) {
    Logger.logLocalEvent("Call Error: ${error.code}, ${error.message}");
  }

  /// On active call connected to remote client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
  void _onCallConnected(twilioJs.Call call) {
    nativeCall = call;
    final direction = call.direction == "INCOMING" ? "Incoming" : "Outgoing";
    final params = getCallParams(call);
    final from = params["From"] ?? "";
    final to = params["To"] ?? "";
    Logger.logLocalEventEntries(["Connected", from, to, direction], prefix: "");
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnecting(dynamic twilioError) {
    Logger.logLocalEvent("Reconnecting...");
  }

  /// On active call reconnecting to Twilio network
  void _onCallReconnected() {
    Logger.logLocalEvent("Reconnected");
  }

  CallStatus getCallStatus(twilioJs.Call call) {
    final status = call.status();
    return parseCallStatus(status);
  }

  void _cancelNotification(String callSid) {
    final message = {
      'action': 'cancel',
      'payload': {
        'tag': callSid,
      },
    };
    TwilioSW.instance.send(message);
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

Map<String, String> getCallParams(twilioJs.Call call) {
  final customParams = _getCustomCallParameters(call.customParameters);
  final params = jsToStringMap(call.parameters);
  params.remove("Params");

  return Map<String, String>.from(customParams)..addAll(params);
}

ActiveCall activeCallFromNativeJsCall(twilioJs.Call call, {DateTime? initiated}) {
  final params = getCallParams(call);
  final from = params["From"] ?? params["from"] ?? "";
  final to = params["To"] ?? params["to"] ?? "";

  /// Do not remove To and From params as they are used to build call state using [createCallFromState(String)]
  // params.removeWhere((key, value) => key == "To" || key == "From");

  final direction = call.direction;
  final date = initiated ?? DateTime.now();
  final _activeCall = ActiveCall(
    from: from,
    // call.customParameters["From"] ?? "",
    to: to,
    // call.customParameters["To"] ?? "",
    customParams: params,
    //call.customParameters as Map<String, dynamic>?,
    callDirection: direction == "INCOMING" ? CallDirection.incoming : CallDirection.outgoing,
    initiated: date,
  );
  return _activeCall;
}

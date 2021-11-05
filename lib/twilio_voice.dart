library twilio_voice;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

part 'models/active_call.dart';
part 'models/call_event.dart';

typedef OnDeviceTokenChanged = Function(String token);

class TwilioVoice {
  static const MethodChannel _channel =
      const MethodChannel('twilio_voice/messages');

  static const EventChannel _eventChannel = EventChannel('twilio_voice/events');

  TwilioVoice._() : call = Call(_channel);

  static final TwilioVoice _instance = TwilioVoice._();
  static TwilioVoice get instance => _instance;

  late final Call call;

  Stream<CallEvent>? _callEventsListener;

  /// Sends call events
  Stream<CallEvent> get callEventsListener {
    if (_callEventsListener == null) {
      _callEventsListener = _eventChannel
          .receiveBroadcastStream()
          .map((dynamic event) => _parseCallEvent(event));
    }
    return _callEventsListener!;
  }

  OnDeviceTokenChanged? deviceTokenChanged;
  void setOnDeviceTokenChanged(OnDeviceTokenChanged deviceTokenChanged) {
    deviceTokenChanged = deviceTokenChanged;
  }

  /// register fcm token, and device token for android
  ///
  /// ios device token is obtained internally
  Future<bool?> setTokens({required String accessToken, String? deviceToken}) {
    return _channel.invokeMethod('tokens', <String, dynamic>{
      "accessToken": accessToken,
      "deviceToken": deviceToken
    });
  }

  /// Wheter or not should the user receive a notification after a missed call, default to true.
  ///
  /// Setting is persisted across restarts until overriden
  set showMissedCallNotifications(bool value) {
    _channel
        .invokeMethod('show-notifications', <String, dynamic>{"show": value});
  }

  /// Unregisters from Twilio
  ///
  /// If no accesToken is provided, previously registered accesToken will be used
  Future<bool?> unregister({String? accessToken}) {
    return _channel.invokeMethod(
        'unregister', <String, dynamic>{"accessToken": accessToken});
  }

  /// Checks if device needs background permission
  ///
  /// Android only, xiamoi devices need special permission to show background call UI
  Future<bool> requiresBackgroundPermissions() {
    return _channel.invokeMethod<bool?>('requiresBackgroundPermissions',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  Future<bool?> requestBackgroundPermissions() {
    return _channel.invokeMethod('requestBackgroundPermissions', {});
  }

  /// Checks if device has microphone permission
  Future<bool> hasMicAccess() {
    return _channel.invokeMethod<bool?>(
        'hasMicPermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Request microphone permission
  Future<bool?> requestMicAccess() {
    return _channel.invokeMethod('requestMicPermission', {});
  }

  /// Register clientId for background calls
  ///
  /// Register the client name for incomming calls while calling using ids
  Future<bool?> registerClient(String clientId, String clientName) {
    return _channel.invokeMethod('registerClient',
        <String, dynamic>{"id": clientId, "name": clientName});
  }

  /// Unegister clientId for background calls
  Future<bool?> unregisterClient(String clientId) {
    return _channel
        .invokeMethod('unregisterClient', <String, dynamic>{"id": clientId});
  }

  /// Set default caller name for no registered clients
  ///
  /// This caller name will be shown for incomming calls
  Future<bool?> setDefaultCallerName(String callerName) {
    return _channel.invokeMethod(
        'defaultCaller', <String, dynamic>{"defaultCaller": callerName});
  }

  /// Android-only, shows background call UI
  Future<bool?> showBackgroundCallUI() {
    return _channel.invokeMethod("backgroundCallUI", {});
  }

  CallEvent _parseCallEvent(String state) {
    if (state.startsWith("DEVICETOKEN|")) {
      var token = state.split('|')[1];
      if (deviceTokenChanged != null) {
        deviceTokenChanged!(token);
      }
      return CallEvent.log;
    } else if (state.startsWith("LOG|")) {
      List<String> tokens = state.split('|');
      print(tokens[1]);

      // source: https://www.twilio.com/docs/api/errors/31603
      // The callee does not wish to participate in the call.
      if(tokens[1].contains("31603")) {
        return CallEvent.declined;
      } else if(tokens.toString().toLowerCase().contains("call rejected")) {
        // Android call reject from string: "LOG|Call Rejected"
        return CallEvent.declined;
      } else if(tokens.toString().toLowerCase().contains("rejecting call")) {
        // iOS call reject froms tring: "LOG|provider:performEndCallAction: rejecting call"
        return CallEvent.declined;
      }
      return CallEvent.log;
    } else if (state.startsWith("Connected|")) {
      call._activeCall = createCallFromState(state, initiated: true);
      print(
          'Connected - From: ${call._activeCall!.from}, To: ${call._activeCall!.to}, StartOn: ${call._activeCall!.initiated}, Direction: ${call._activeCall!.callDirection}');
      return CallEvent.connected;
    } else if (state.startsWith("Ringing|")) {
      call._activeCall =
          createCallFromState(state, callDirection: CallDirection.outgoing);

      print(
          'Ringing - From: ${call._activeCall!.from}, To: ${call._activeCall!.to}, Direction: ${call._activeCall!.callDirection}');

      return CallEvent.ringing;
    } else if (state.startsWith("Answer")) {
      call._activeCall =
          createCallFromState(state, callDirection: CallDirection.incoming);
      print(
          'Answer - From: ${call._activeCall!.from}, To: ${call._activeCall!.to}, Direction: ${call._activeCall!.callDirection}');

      return CallEvent.answer;
    } else if (state.startsWith("ReturningCall")) {
      call._activeCall =
          createCallFromState(state, callDirection: CallDirection.outgoing);

      print(
          'Returning Call - From: ${call._activeCall!.from}, To: ${call._activeCall!.to}, Direction: ${call._activeCall!.callDirection}');

      return CallEvent.returningCall;
    }
    switch (state) {
      case 'Ringing':
        return CallEvent.ringing;
      case 'Connected':
        return CallEvent.connected;
      case 'Call Ended':
        call._activeCall = null;
        return CallEvent.callEnded;
      case 'Missed Call':
        return CallEvent.missedCall;
      case 'Unhold':
        return CallEvent.unhold;
      case 'Hold':
        return CallEvent.hold;
      case 'Unmute':
        return CallEvent.unmute;
      case 'Mute':
        return CallEvent.mute;
      case 'Speaker On':
        return CallEvent.speakerOn;
      case 'Speaker Off':
        return CallEvent.speakerOff;
      default:
        print('$state is not a valid CallState.');
        throw ArgumentError('$state is not a valid CallState.');
    }
  }
}

ActiveCall createCallFromState(String state,
    {CallDirection? callDirection, bool initiated = false}) {
  List<String> tokens = state.split('|');
  return ActiveCall(
      from: tokens[1],
      to: tokens[2],
      initiated: initiated ? DateTime.now() : null,
      callDirection: callDirection ??
          ("Incoming" == tokens[3]
              ? CallDirection.incoming
              : CallDirection.outgoing),
      customParams: parseCustomParams(tokens));
}

Map<String, dynamic>? parseCustomParams(List<String> tokens) {
  if (tokens.length != 5) return null;
  try {
    Map<String, dynamic> customValue = jsonDecode(tokens[4]);
    return customValue;
  } catch (error) {
    return null;
  }
}

class Call {
  ActiveCall? _activeCall;
  ActiveCall? get activeCall => _activeCall;

  final MethodChannel _channel;
  Call(this._channel);

  /// Places new call
  ///
  /// [extraOptions] will be added to the callPayload sent to your server
  Future<bool?> place(
      {required String from,
      required String to,
      Map<String, dynamic>? extraOptions}) {
    _activeCall =
        ActiveCall(from: from, to: to, callDirection: CallDirection.outgoing);

    var options = extraOptions ?? Map<String, dynamic>();
    options['From'] = from;
    options['To'] = to;
    return _channel.invokeMethod('makeCall', options);
  }

  /// Hangs active call
  Future<bool?> hangUp() {
    return _channel.invokeMethod('hangUp', <String, dynamic>{});
  }

  /// Checks if there is an ongoing call
  Future<bool> isOnCall() {
    return _channel.invokeMethod<bool?>('isOnCall',
        <String, dynamic>{}).then<bool>((bool? value) => value ?? false);
  }

  /// Gets the active call's SID. This will be null until the first Ringing event occurs
  Future<String?> getSid() {
    return _channel.invokeMethod<String?>('call-sid', <String, dynamic>{}).then<String?>((String? value) => value);
  }

  /// Answers incoming call
  Future<bool?> answer() {
    return _channel.invokeMethod('answer', <String, dynamic>{});
  }

  /// Holds active call
  Future<bool?> holdCall() {
    return _channel.invokeMethod('holdCall', <String, dynamic>{});
  }

  /// Toogles mute state to provided value
  Future<bool?> toggleMute(bool isMuted) {
    return _channel
        .invokeMethod('toggleMute', <String, dynamic>{"muted": isMuted});
  }

  /// Toogles speaker state to provided value
  Future<bool?> toggleSpeaker(bool speakerIsOn) {
    return _channel.invokeMethod(
        'toggleSpeaker', <String, dynamic>{"speakerIsOn": speakerIsOn});
  }

  Future<bool?> sendDigits(String digits) {
    return _channel
        .invokeMethod('sendDigits', <String, dynamic>{"digits": digits});
  }
}

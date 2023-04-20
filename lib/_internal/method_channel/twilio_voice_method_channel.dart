import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:twilio_voice/_internal/platform_interface/twilio_call_platform_interface.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../platform_interface/twilio_voice_platform_interface.dart';
import 'twilio_call_method_channel.dart';

typedef OnDeviceTokenChanged = Function(String token);

/// Implementation of [TwilioVoicePlatform] that uses method channels.
class MethodChannelTwilioVoice extends TwilioVoicePlatform {
  static TwilioVoicePlatform get instance => TwilioVoicePlatform.instance;

  late final TwilioCallPlatform _call = MethodChannelTwilioCall();

  @override
  TwilioCallPlatform get call => _call;

  Stream<CallEvent>? _callEventsListener;

  EventChannel get _eventChannel => eventChannel;

  MethodChannel get _channel => sharedChannel;

  /// Sends call events
  @override
  Stream<CallEvent> get callEventsListener {
    if (_callEventsListener == null) {
      _callEventsListener = _eventChannel.receiveBroadcastStream().map((dynamic event) => parseCallEvent(event));
    }
    return _callEventsListener!;
  }

  OnDeviceTokenChanged? deviceTokenChanged;

  @override
  void setOnDeviceTokenChanged(OnDeviceTokenChanged deviceTokenChanged) {
    deviceTokenChanged = deviceTokenChanged;
  }

  /// register fcm token, and device token for android
  ///
  /// ios device token is obtained internally
  @override
  Future<bool?> setTokens({required String accessToken, String? deviceToken}) {
    return _channel.invokeMethod('tokens', <String, dynamic>{"accessToken": accessToken, "deviceToken": deviceToken});
  }

  /// Whether or not should the user receive a notification after a missed call, default to true.
  ///
  /// Setting is persisted across restarts until overridden
  @override
  set showMissedCallNotifications(bool value) {
    _channel.invokeMethod('show-notifications', <String, dynamic>{"show": value});
  }

  /// Unregisters from Twilio
  ///
  /// If no accessToken is provided, previously registered accessToken will be used
  @override
  Future<bool?> unregister({String? accessToken}) {
    return _channel.invokeMethod('unregister', <String, dynamic>{"accessToken": accessToken});
  }

  /// Checks if device needs background permission
  ///
  /// Android only, xiamoi devices need special permission to show background call UI
  @override
  Future<bool> requiresBackgroundPermissions() {
    return _channel.invokeMethod<bool?>('requiresBackgroundPermissions', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  @override
  Future<bool?> requestBackgroundPermissions() {
    return _channel.invokeMethod('requestBackgroundPermissions', {});
  }

  /// Checks if device has microphone permission
  @override
  Future<bool> hasMicAccess() {
    return _channel.invokeMethod<bool?>('hasMicPermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Request microphone permission
  @override
  Future<bool?> requestMicAccess() {
    return _channel.invokeMethod('requestMicPermission', {});
  }

  /// Register clientId for background calls
  ///
  /// Register the client name for incoming calls while calling using ids
  @override
  Future<bool?> registerClient(String clientId, String clientName) {
    return _channel.invokeMethod('registerClient', <String, dynamic>{"id": clientId, "name": clientName});
  }

  /// Unregister clientId for background calls
  @override
  Future<bool?> unregisterClient(String clientId) {
    return _channel.invokeMethod('unregisterClient', <String, dynamic>{"id": clientId});
  }

  /// Set default caller name for no registered clients
  ///
  /// This caller name will be shown for incoming calls
  @override
  Future<bool?> setDefaultCallerName(String callerName) {
    return _channel.invokeMethod('defaultCaller', <String, dynamic>{"defaultCaller": callerName});
  }

  /// Android-only, shows background call UI
  @override
  Future<bool?> showBackgroundCallUI() {
    return _channel.invokeMethod("backgroundCallUI", {});
  }

  @override
  CallEvent parseCallEvent(String state) {
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
      if (tokens[1].contains("31603")) {
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("call rejected")) {
        // Android call reject from string: "LOG|Call Rejected"
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("rejecting call")) {
        // iOS call reject froms tring: "LOG|provider:performEndCallAction: rejecting call"
        return CallEvent.declined;
      } else if (tokens[1].contains("Call Rejected")) {
        // web call reject from string: "Call Rejected"
        return CallEvent.declined;
      }
      return CallEvent.log;
    } else if (state.startsWith("Connected|")) {
      call.activeCall = createCallFromState(state, initiated: true);
      print(
          'Connected - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, StartOn: ${call.activeCall!.initiated}, Direction: ${call.activeCall!.callDirection}');
      return CallEvent.connected;
    } else if (state.startsWith("Incoming|")) {
      // Added as temporary override for incoming calls, not breaking current (expected) Ringing behaviour
      call.activeCall = createCallFromState(state, callDirection: CallDirection.incoming);

      print('Incoming - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');

      return CallEvent.incoming;
    } else if (state.startsWith("Ringing|")) {
      call.activeCall = createCallFromState(state, callDirection: CallDirection.outgoing);

      print('Ringing - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');

      return CallEvent.ringing;
    } else if (state.startsWith("Answer")) {
      call.activeCall = createCallFromState(state, callDirection: CallDirection.incoming);
      print('Answer - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');

      return CallEvent.answer;
    } else if (state.startsWith("ReturningCall")) {
      call.activeCall = createCallFromState(state, callDirection: CallDirection.outgoing);

      print('Returning Call - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');

      return CallEvent.returningCall;
    }
    switch (state) {
      case 'Ringing':
        return CallEvent.ringing;
      case 'Connected':
        return CallEvent.connected;
      case 'Call Ended':
        call.activeCall = null;
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

ActiveCall createCallFromState(String state, {CallDirection? callDirection, bool initiated = false}) {
  List<String> tokens = state.split('|');
  return ActiveCall(
    from: tokens[1],
    to: tokens[2],
    initiated: initiated ? DateTime.now() : null,
    callDirection: callDirection ?? ("Incoming" == tokens[3] ? CallDirection.incoming : CallDirection.outgoing),
    customParams: parseCustomParams(tokens),
  );
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

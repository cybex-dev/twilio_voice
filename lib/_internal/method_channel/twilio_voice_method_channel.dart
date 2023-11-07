import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../twilio_voice.dart';
import '../platform_interface/twilio_call_platform_interface.dart';
import '../platform_interface/twilio_voice_platform_interface.dart';
import '../utils.dart';
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
    _callEventsListener ??= _eventChannel.receiveBroadcastStream().map((dynamic event) => parseCallEvent(event));
    return _callEventsListener!;
  }

  @override
  void setOnDeviceTokenChanged(OnDeviceTokenChanged deviceTokenChanged) {
    this.deviceTokenChanged = deviceTokenChanged;
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
  @Deprecated('custom call UI not used anymore, has no effect')
  @override
  Future<bool> requiresBackgroundPermissions() {
    return _channel.invokeMethod<bool?>('requiresBackgroundPermissions', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  @Deprecated('custom call UI not used anymore, has no effect')
  @override
  Future<bool?> requestBackgroundPermissions() {
    return _channel.invokeMethod('requestBackgroundPermissions', {});
  }

  /// Checks if device has a registered phone account
  ///
  /// Android only
  @override
  Future<bool> hasRegisteredPhoneAccount() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasRegisteredPhoneAccount', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Register phone account with TelecomManager
  ///
  /// Android only
  @override
  Future<bool> registerPhoneAccount() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('registerPhoneAccount', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if App's phone account is enabled
  ///
  /// Android only
  @override
  Future<bool> isPhoneAccountEnabled() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('isPhoneAccountEnabled', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Open phone account settings
  ///
  /// Android only
  @override
  Future<bool> openPhoneAccountSettings() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('openPhoneAccountSettings', {}).then<bool>((bool? value) => value ?? false);
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

  /// Checks if device has read phone state permission
  ///
  /// Android only
  @override
  Future<bool> hasReadPhoneStatePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasReadPhoneStatePermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Request read phone state permission
  ///
  /// Android only
  @override
  Future<bool?> requestReadPhoneStatePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestReadPhoneStatePermission', {});
  }

  /// Checks if device has 'android.permission.CALL_PHONE' permission
  ///
  /// Android only
  @override
  Future<bool> hasCallPhonePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasCallPhonePermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// request 'android.permission.CALL_PHONE' permission
  ///
  /// Android only
  @override
  Future<bool?> requestCallPhonePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestCallPhonePermission', {});
  }

  /// Checks if device has read phone numbers permission
  ///
  /// Android only
  @override
  Future<bool> hasReadPhoneNumbersPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasReadPhoneNumbersPermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Request read phone numbers permission
  ///
  /// Android only
  @override
  Future<bool?> requestReadPhoneNumbersPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestReadPhoneNumbersPermission', {});
  }

  /// Checks if device has bluetooth permissions
  /// Only available on Android
  /// Defaults to false
  @override
  Future<bool> hasBluetoothPermissions() {
    return Future.value(false);
  }

  /// Request bluetooth permissions
  /// Only available on Android
  @override
  Future<bool?> requestBluetoothPermissions() {
    return Future.value(false);
  }

  /// Reject call when no `CALL_PHONE` permissions are granted nor Phone Account (via `isPhoneAccountEnabled`) is registered.
  /// If set to true, the call is rejected immediately upon received. If set to false, the call is left until the timeout is reached / call is canceled.
  /// Defaults to false.
  ///
  /// Only available on Android
  @override
  Future<bool> rejectCallOnNoPermissions({bool shouldReject = false}) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('rejectCallOnNoPermissions', {"shouldReject": shouldReject}).then<bool>((bool? value) => value ?? false);
  }

  /// Returns true if call is rejected when no `CALL_PHONE` permissions are granted nor Phone Account (via `isPhoneAccountEnabled`) is registered. Defaults to false.
  ///
  /// Only available on Android
  @override
  Future<bool> isRejectingCallOnNoPermissions() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(false);
    }
    return _channel.invokeMethod<bool?>('isRejectingCallOnNoPermissions', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Set iOS call kit icon
  ///
  /// This allows for CallKit customization: setting the last button (bottom right) of the callkit.
  ///
  /// Ensure you have an icon registered in your XCode project (Runner > Assets)
  ///
  /// To do this:
  /// - open XCode
  /// - Create/Add your transparency / white mask image into Assets.xcassets (i.e. image uses Alpha channel only  (https://developer.apple.com/documentation/callkit/cxproviderconfiguration/2274376-icontemplateimagedata)
  /// - Name of icon e.g. "TransparentIcon"
  ///
  /// Use `TwilioVoice.instance.updateCallKitIcon(icon: "TransparentIcon")`
  @override
  Future<bool?> updateCallKitIcon({String? icon}) {
    return _channel.invokeMethod('updateCallKitIcon', <String, dynamic>{"icon": icon});
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
  /// Deprecated, has no effect
  @override
  Future<bool?> showBackgroundCallUI() {
    return Future.value(true);
  }

  @override
  CallEvent parseCallEvent(String state) {
    if (state.startsWith("DEVICETOKEN|")) {
      var token = state.split('|')[1];
      if (deviceTokenChanged != null) {
        deviceTokenChanged!(token);
      }
      return CallEvent.log;
    } else if (state.startsWith("LOG|PERMISSION|")) {
      List<String> tokens = state.split('|');
      if (kDebugMode) {
        if (tokens.length == 4) {
          printDebug("Name: ${tokens[2]}, granted state: ${tokens[3]}");
        }
      }
      return CallEvent.permission;
    } else if (state.startsWith("LOG|")) {
      List<String> tokens = state.split('|');
      if (kDebugMode) {
        printDebug(tokens[1]);
      }

      // source: https://www.twilio.com/docs/api/errors/31603
      // The callee does not wish to participate in the call.
      //
      // https://www.twilio.com/docs/api/errors/31486
      // The callee is busy.
      if (tokens[1].contains("31603") || tokens[1].contains("31486")) {
        call.activeCall = null;
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("call rejected")) {
        // Android call reject from string: "LOG|Call Rejected"
        call.activeCall = null;
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("rejecting call")) {
        // iOS call reject from string: "LOG|provider:performEndCallAction: rejecting call"
        call.activeCall = null;
        return CallEvent.declined;
      } else if (tokens[1].contains("Call Rejected")) {
        // macOS / web call reject from string: "Call Rejected"
        call.activeCall = null;
        return CallEvent.declined;
      }
      return CallEvent.log;
    } else if (state.startsWith("Connected|")) {
      call.activeCall = createCallFromState(state, initiated: true);
      if (kDebugMode) {
        printDebug(
            'Connected - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, StartOn: ${call.activeCall!.initiated}, Direction: ${call.activeCall!.callDirection}');
      }
      return CallEvent.connected;
    } else if (state.startsWith("Incoming|")) {
      // Added as temporary override for incoming calls, not breaking current (expected) Ringing behaviour
      call.activeCall = createCallFromState(state, callDirection: CallDirection.incoming);

      if (kDebugMode) {
        printDebug('Incoming - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.incoming;
    } else if (state.startsWith("Ringing|")) {
      call.activeCall = createCallFromState(state);

      if (kDebugMode) {
        printDebug('Ringing - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.ringing;
    } else if (state.startsWith("Answer")) {
      call.activeCall = createCallFromState(state, callDirection: CallDirection.incoming);
      if (kDebugMode) {
        printDebug('Answer - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.answer;
    } else if (state.startsWith("ReturningCall")) {
      call.activeCall = createCallFromState(state, callDirection: CallDirection.outgoing);

      if (kDebugMode) {
        printDebug('Returning Call - From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.returningCall;
    } else if (state.startsWith("Reconnecting")) {
      return CallEvent.reconnecting;
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
      case 'Bluetooth On':
        return CallEvent.bluetoothOn;
      case 'Bluetooth Off':
        return CallEvent.bluetoothOff;
      case 'Reconnected':
        return CallEvent.reconnected;
      default:
        if (kDebugMode) {
          printDebug('$state is not a valid CallState.');
        }
        throw ArgumentError('$state is not a valid CallState.');
    }
  }
}

ActiveCall createCallFromState(String state, {CallDirection? callDirection, bool initiated = false}) {
  List<String> tokens = state.split('|');
  final direction = callDirection ?? ("incoming" == tokens[3].toLowerCase() ? CallDirection.incoming : CallDirection.outgoing);
  return ActiveCall(
    from: tokens[1],
    to: tokens[2],
    initiated: initiated ? DateTime.now() : null,
    callDirection: direction,
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

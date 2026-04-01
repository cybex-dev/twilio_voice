import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../twilio_voice.dart';
import '../js/core/enums/device_sound_name.dart';
import '../platform_interface/twilio_call_platform_interface.dart';
import '../platform_interface/twilio_voice_platform_interface.dart';
import '../utils.dart';
import 'twilio_call_method_channel.dart';

/// Implementation of [TwilioVoicePlatform] that uses method channels.
class MethodChannelTwilioVoice extends TwilioVoicePlatform {
  late final TwilioCallPlatform _call = MethodChannelTwilioCall();
  Stream<CallEvent>? _callEventsListener;

  /// Cached audio route data from the latest native AudioRoute event.
  AudioRouteData? _lastAudioRouteData;

  /// The call SID extracted from the most recent native event.
  String? _lastEventCallSid;

  @override
  AudioRouteData? get lastAudioRouteData => _lastAudioRouteData;

  @override
  String? get lastEventCallSid => _lastEventCallSid;

  @override
  TwilioCallPlatform get call => _call;

  /// Sends call events
  @override
  Stream<CallEvent> get callEventsListener {
    _callEventsListener ??= _eventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => parseCallEvent(event))
        .handleError((error, stackTrace) {
      // Gracefully handle FlutterError events from native (e.g., "Call Failed: ...")
      // Without this, the error would kill the stream listener and crash the app.
      if (kDebugMode) {
        printDebug('Event stream error (handled gracefully): $error');
      }
    });
    return _callEventsListener!;
  }

  /// Checks if device has bluetooth permissions
  /// Only available on Android
  /// Defaults to false
  @override
  Future<bool> hasBluetoothPermissions() {
    return Future.value(false);
  }

  /// Checks if device has 'android.permission.CALL_PHONE' permission
  ///
  /// Android only
  @override
  Future<bool> hasCallPhonePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasCallPhonePermission',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if device has permission to manage system calls
  ///
  /// Android only
  @override
  Future<bool> hasManageOwnCallsPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasManageOwnCallsPermission',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if device has microphone permission
  @override
  Future<bool> hasMicAccess() {
    return _channel.invokeMethod<bool?>(
        'hasMicPermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if device has read phone numbers permission
  ///
  /// Android only
  @override
  Future<bool> hasReadPhoneNumbersPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasReadPhoneNumbersPermission',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if device has read phone state permission
  ///
  /// Android only
  @override
  Future<bool> hasReadPhoneStatePermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasReadPhoneStatePermission',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if device has a registered phone account
  ///
  /// Android only
  @override
  Future<bool> hasRegisteredPhoneAccount() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('hasRegisteredPhoneAccount',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if the app is being battery optimized (which can prevent background FCM delivery)
  /// Returns true if the app is being battery optimized
  ///
  /// Android only
  @override
  Future<bool> isBatteryOptimized() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(false);
    }
    return _channel.invokeMethod<bool?>(
        'isBatteryOptimized', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Checks if App's phone account is enabled
  ///
  /// Android only
  @override
  Future<bool> isPhoneAccountEnabled() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('isPhoneAccountEnabled', {}).then<bool>(
        (bool? value) => value ?? false);
  }

  /// Returns true if call is rejected when no `CALL_PHONE` permissions are granted nor Phone Account (via `isPhoneAccountEnabled`) is registered. Defaults to false.
  ///
  /// Only available on Android
  @override
  Future<bool> isRejectingCallOnNoPermissions() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(false);
    }
    return _channel.invokeMethod<bool?>('isRejectingCallOnNoPermissions',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Opens the app's battery settings page so user can manually disable battery optimization
  /// This is needed for Samsung and other OEMs with aggressive battery optimization
  ///
  /// Android only
  @override
  Future<bool?> openBatterySettings() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('openBatterySettings', {});
  }

  /// Check if the app has overlay/draw-over-apps permission
  /// This is needed for showing incoming call UI over lock screen on some devices
  ///
  /// Android only
  @override
  Future<bool> hasOverlayPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>(
        'hasOverlayPermission', {}).then<bool>((bool? value) => value ?? false);
  }

  /// Request overlay/draw-over-apps permission
  /// Opens the system settings to allow user to grant the permission
  /// This is needed for showing incoming call UI over lock screen on some devices
  ///
  /// Android only
  @override
  Future<bool?> requestOverlayPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestOverlayPermission', {});
  }

  /// Open MIUI/Xiaomi permission settings
  /// This opens the MIUI-specific permission page where users can enable
  /// "Display pop-up windows while running in the background" permission
  /// Falls back to general app settings if MIUI settings not available
  ///
  /// Android only
  @override
  Future<bool?> openMiuiPermissionSettings() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('openMiuiPermissionSettings', {});
  }

  /// Open phone account settings
  ///
  /// Android only
  @override
  Future<bool> openPhoneAccountSettings() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>('openPhoneAccountSettings',
        {}).then<bool>((bool? value) => value ?? false);
  }

  @override
  CallEvent parseCallEvent(String state) {
    if (state.startsWith("DEVICETOKEN|")) {
      var token = state.split('|')[1];
      if (deviceTokenChanged != null) {
        deviceTokenChanged!(token);
      }
      return CallEvent.log;
    } else if (state.startsWith("AudioRoute|")) {
      // Audio route change message from iOS: "AudioRoute|<route>|bluetoothAvailable=<bool>"
      // Parse the message to emit proper Bluetooth events
      try {
        var parts = state.split('|');
        if (parts.length >= 3) {
          var route = parts[1]; // 'bluetooth', 'receiver', or 'speaker'
          var bluetoothAvailableStr = parts[
              2]; // 'bluetoothAvailable=true' or 'bluetoothAvailable=false'
          var isBluetoothAvailable = bluetoothAvailableStr.contains('true');

          // Cache the parsed audio route data so callers can read it
          // without an extra method channel round-trip.
          _lastAudioRouteData = AudioRouteData(
            route: route,
            isBluetoothAvailable: isBluetoothAvailable,
          );

          if (kDebugMode) {
            printDebug(
                'Audio route updated: route=$route, bluetoothAvailable=$isBluetoothAvailable');
          }

          // Emit appropriate event based on current route and availability
          if (route == 'bluetooth' && isBluetoothAvailable) {
            return CallEvent.bluetoothOn;
          } else if (route == 'speaker') {
            return CallEvent.speakerOn;
          } else if (route == 'receiver' || route == 'earpiece') {
            // Bluetooth was disconnected or user switched to earpiece
            // This includes the case when BT disconnects mid-call
            if (!isBluetoothAvailable) {
              // Bluetooth is no longer available - emit bluetoothOff to update UI
              return CallEvent.bluetoothOff;
            } else {
              // Bluetooth still available but we're on earpiece (user switched)
              // Emit audioRouteChanged to trigger UI refresh
              return CallEvent.audioRouteChanged;
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          printDebug('Error parsing AudioRoute event: $e');
        }
      }
      // Always return audioRouteChanged for any AudioRoute message not handled above
      // This ensures the UI gets a chance to refresh its state
      return CallEvent.audioRouteChanged;
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

      // https://www.twilio.com/docs/api/errors/31600
      // Busy Everywhere. All possible destinations are busy.
      //
      // source: https://www.twilio.com/docs/api/errors/31603
      // The callee does not wish to participate in the call.
      //
      // https://www.twilio.com/docs/api/errors/31486
      // The callee is busy.
      if (tokens[1].contains("31600") ||
          tokens[1].contains("31603") ||
          tokens[1].contains("31486")) {
        // Note: call.activeCall is NOT cleared here — the BLoC owns call
        // lifecycle via CallSessionManager and clears it when processing
        // the event. Clearing here would race with the BLoC's held-call check.
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("call rejected")) {
        // Android call reject from string: "LOG|Call Rejected"
        return CallEvent.declined;
      } else if (tokens.toString().toLowerCase().contains("rejecting call")) {
        // iOS call reject from string: "LOG|provider:performEndCallAction: rejecting call"
        return CallEvent.declined;
      } else if (tokens[1].contains("Call Rejected")) {
        // macOS / web call reject from string: "Call Rejected"
        return CallEvent.declined;
      }
      return CallEvent.log;
    } else if (state.startsWith("Connecting|")) {
      call.activeCall = createCallFromState(state);
      _lastEventCallSid = call.activeCall?.callSid;
      if (kDebugMode) {
        printDebug(
            'Connecting - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }
      call.activeCall = createCallFromState(state, initiated: true);
      _lastEventCallSid = call.activeCall?.callSid;
      return CallEvent.connecting;
    } else if (state.startsWith("Connected|")) {
      call.activeCall = createCallFromState(state, initiated: true);
      _lastEventCallSid = call.activeCall?.callSid;
      if (kDebugMode) {
        printDebug(
            'Connected - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, StartOn: ${call.activeCall!.initiated}, Direction: ${call.activeCall!.callDirection}');
      }
      return CallEvent.connected;
    } else if (state.startsWith("IncomingWhileActive|")) {
      // Incoming call while another call is active
      // Do NOT overwrite activeCall - store as waitingCall instead
      final waitingCallData =
          createCallFromState(state, callDirection: CallDirection.incoming);
      _lastEventCallSid = waitingCallData.callSid;
      if (call is MethodChannelTwilioCall) {
        (call as MethodChannelTwilioCall).waitingCall = waitingCallData;
      }

      if (kDebugMode) {
        printDebug(
            'IncomingWhileActive - SID: ${waitingCallData.callSid}, From: ${waitingCallData.from}, To: ${waitingCallData.to}, Direction: ${waitingCallData.callDirection}');
      }

      return CallEvent.incomingWhileActive;
    } else if (state.startsWith("Incoming|")) {
      // Added as temporary override for incoming calls, not breaking current (expected) Ringing behaviour
      call.activeCall =
          createCallFromState(state, callDirection: CallDirection.incoming);
      _lastEventCallSid = call.activeCall?.callSid;

      if (kDebugMode) {
        printDebug(
            'Incoming - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.incoming;
    } else if (state.startsWith("Ringing|")) {
      call.activeCall = createCallFromState(state);
      _lastEventCallSid = call.activeCall?.callSid;

      if (kDebugMode) {
        printDebug(
            'Ringing - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.ringing;
    } else if (state.startsWith("Answer")) {
      call.activeCall =
          createCallFromState(state, callDirection: CallDirection.incoming);
      _lastEventCallSid = call.activeCall?.callSid;
      if (kDebugMode) {
        printDebug(
            'Answer - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.answer;
    } else if (state.startsWith("ReturningCall")) {
      call.activeCall =
          createCallFromState(state, callDirection: CallDirection.outgoing);
      _lastEventCallSid = call.activeCall?.callSid;

      if (kDebugMode) {
        printDebug(
            'Returning Call - SID: ${call.activeCall!.callSid}, From: ${call.activeCall!.from}, To: ${call.activeCall!.to}, Direction: ${call.activeCall!.callDirection}');
      }

      return CallEvent.returningCall;
    } else if (state.startsWith("Reconnecting")) {
      return CallEvent.reconnecting;
    } else if (state.startsWith("HeldCallData|")) {
      // Held call data emitted during resume from terminated state
      // Store as waitingCall so the BLoC can recover multi-call state
      final heldCallData = createCallFromState(state);
      _lastEventCallSid = heldCallData.callSid;
      if (call is MethodChannelTwilioCall) {
        (call as MethodChannelTwilioCall).waitingCall = heldCallData;
      }

      if (kDebugMode) {
        printDebug(
            'HeldCallData - SID: ${heldCallData.callSid}, From: ${heldCallData.from}, To: ${heldCallData.to}, Direction: ${heldCallData.callDirection}');
      }

      // Return log so the BLoC event stream doesn't react to this directly.
      // The BLoC's _onManuallyFetchCallDetailsOnStartup will read waitingCall.
      return CallEvent.log;
    } else if (state.startsWith("Swap|")) {
      // Native swap event: "Swap|sid|from|to"
      // iOS: from CallKit native swap button.
      // Android: from notification swap button (ACTION_SWAP broadcast).
      // The sid is the now-active call's SID, from/to are its info
      List<String> tokens = state.split('|');
      if (tokens.length >= 4) {
        _lastEventCallSid = tokens[1].isNotEmpty ? tokens[1] : null;
        if (kDebugMode) {
          printDebug(
              'Swap - SID: ${tokens[1]}, NowActive From: ${tokens[2]}, To: ${tokens[3]}');
        }
      }
      return CallEvent.swap;
    }

    // --- Simple events (may contain SID after pipe separator) ---
    // Helper to extract SID from "Event|sid" format
    String? extractSidFromSimpleEvent(String event) {
      final pipeIndex = event.indexOf('|');
      if (pipeIndex == -1) return null;
      final sid = event.substring(pipeIndex + 1);
      return sid.isNotEmpty ? sid : null;
    }

    if (state.startsWith('Call Ended')) {
      // Format: "Call Ended" or "Call Ended|sid"
      _lastEventCallSid = extractSidFromSimpleEvent(state);
      // Note: call.activeCall is NOT cleared here — the BLoC owns call
      // lifecycle via CallSessionManager. Clearing here races with the
      // BLoC's held-session stale-data check.
      return CallEvent.callEnded;
    } else if (state.startsWith('Held Call Ended')) {
      // Format: "Held Call Ended" or "Held Call Ended|sid"
      _lastEventCallSid = extractSidFromSimpleEvent(state);
      return CallEvent.heldCallEnded;
    } else if (state.startsWith('Hold')) {
      // Format: "Hold" or "Hold|sid"
      _lastEventCallSid = extractSidFromSimpleEvent(state);
      return CallEvent.hold;
    } else if (state.startsWith('Unhold')) {
      // Format: "Unhold" or "Unhold|sid"
      _lastEventCallSid = extractSidFromSimpleEvent(state);
      return CallEvent.unhold;
    } else if (state == 'Missed Call') {
      _lastEventCallSid = null;
      return CallEvent.missedCall;
    }

    // Events that don't carry SIDs
    switch (state) {
      case 'Ringing':
        return CallEvent.ringing;
      case 'Connected':
        return CallEvent.connected;
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
          printDebug('$state is not a valid CallState, treating as log.');
        }
        return CallEvent.log;
    }
  }

  /// Register clientId for background calls
  ///
  /// Register the client name for incoming calls while calling using ids
  @override
  Future<bool?> registerClient(String clientId, String clientName) {
    return _channel.invokeMethod('registerClient',
        <String, dynamic>{"id": clientId, "name": clientName});
  }

  /// Register phone account with TelecomManager
  ///
  /// Android only
  @override
  Future<bool> registerPhoneAccount() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod<bool?>(
        'registerPhoneAccount', {}).then<bool>((bool? value) => value ?? false);
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
    return _channel.invokeMethod<bool?>('rejectCallOnNoPermissions', {
      "shouldReject": shouldReject
    }).then<bool>((bool? value) => value ?? false);
  }

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  @Deprecated('custom call UI not used anymore, has no effect')
  @override
  Future<bool?> requestBackgroundPermissions() {
    return _channel.invokeMethod('requestBackgroundPermissions', {});
  }

  /// Request bluetooth permissions
  /// Only available on Android
  @override
  Future<bool?> requestBluetoothPermissions() {
    return Future.value(false);
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

  /// Request to be excluded from battery optimization
  /// Shows the system dialog asking user to allow ignoring battery optimizations
  ///
  /// Android only
  @override
  Future<bool?> requestIgnoreBatteryOptimizations() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestIgnoreBatteryOptimizations', {});
  }

  /// Requests system permission to manage calls
  ///
  /// Android only
  @override
  Future<bool?> requestManageOwnCallsPermission() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _channel.invokeMethod('requestManageOwnCallsPermission', {});
  }

  /// Request microphone permission
  @override
  Future<bool?> requestMicAccess() {
    return _channel.invokeMethod('requestMicPermission', {});
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

  /// Checks if device needs background permission
  ///
  /// Android only, xiamoi devices need special permission to show background call UI
  @Deprecated('custom call UI not used anymore, has no effect')
  @override
  Future<bool> requiresBackgroundPermissions() {
    return _channel.invokeMethod<bool?>('requiresBackgroundPermissions',
        {}).then<bool>((bool? value) => value ?? false);
  }

  /// Set default caller name for no registered clients
  ///
  /// This caller name will be shown for incoming calls
  @override
  Future<bool?> setDefaultCallerName(String callerName) {
    return _channel.invokeMethod(
        'defaultCaller', <String, dynamic>{"defaultCaller": callerName});
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
    return _channel.invokeMethod('tokens', <String, dynamic>{
      "accessToken": accessToken,
      "deviceToken": deviceToken
    });
  }

  /// Android-only, shows background call UI
  /// Deprecated, has no effect
  @override
  Future<bool?> showBackgroundCallUI() {
    return Future.value(true);
  }

  @override
  Future<bool?> setConferenceMode(bool isConference) {
    return _channel.invokeMethod(
        'setConferenceMode', <String, dynamic>{"isConference": isConference});
  }

  /// Whether or not should the user receive a notification after a missed call, default to true.
  ///
  /// Setting is persisted across restarts until overridden
  @override
  set showMissedCallNotifications(bool value) {
    _channel
        .invokeMethod('show-notifications', <String, dynamic>{"show": value});
  }

  /// Unregisters from Twilio
  ///
  /// If no accessToken is provided, previously registered accessToken will be used
  @override
  Future<bool?> unregister({String? accessToken}) {
    return _channel.invokeMethod(
        'unregister', <String, dynamic>{"accessToken": accessToken});
  }

  /// Unregister clientId for background calls
  @override
  Future<bool?> unregisterClient(String clientId) {
    return _channel
        .invokeMethod('unregisterClient', <String, dynamic>{"id": clientId});
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
    return _channel
        .invokeMethod('updateCallKitIcon', <String, dynamic>{"icon": icon});
  }

  @override
  Future<void> updateSound(SoundName soundName, String? url) {
    // TODO: implement updateSound
    throw UnimplementedError();
  }

  @override
  Future<void> updateSounds({Map<SoundName, String>? sounds}) {
    // TODO: implement updateSounds
    throw UnimplementedError();
  }

  static TwilioVoicePlatform get instance => TwilioVoicePlatform.instance;

  EventChannel get _eventChannel => eventChannel;

  MethodChannel get _channel => sharedChannel;
}

ActiveCall createCallFromState(String state,
    {CallDirection? callDirection, bool initiated = false}) {
  List<String> tokens = state.split('|');
  // New event format: Event|callSid|from|to|direction[|customParams]
  // tokens[0] = event name, tokens[1] = callSid, tokens[2] = from,
  // tokens[3] = to, tokens[4] = direction, tokens[5] = customParams (optional)
  final direction = callDirection ??
      ("incoming" == tokens[4].toLowerCase()
          ? CallDirection.incoming
          : CallDirection.outgoing);
  return ActiveCall(
    callSid: tokens[1].isNotEmpty ? tokens[1] : null,
    from: tokens[2],
    to: tokens[3],
    initiated: initiated ? DateTime.now() : null,
    callDirection: direction,
    customParams: parseCustomParams(tokens),
  );
}

Map<String, dynamic>? parseCustomParams(List<String> tokens) {
  if (tokens.length != 6) return null;
  try {
    Map<String, dynamic> customValue = jsonDecode(tokens[5]);
    return customValue;
  } catch (error) {
    return null;
  }
}

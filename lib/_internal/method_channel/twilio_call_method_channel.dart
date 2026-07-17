import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../platform_interface/twilio_call_platform_interface.dart';
import '../utils.dart';

// abstract class MethodChannelTwilioCall extends TwilioVoiceSharedPlatform {
class MethodChannelTwilioCall extends TwilioCallPlatform {
  ActiveCall? _activeCall;

  @override
  ActiveCall? get activeCall => _activeCall;

  @override
  set activeCall(ActiveCall? activeCall) {
    _activeCall = activeCall;
  }

  MethodChannel get _channel => sharedChannel;

  MethodChannelTwilioCall();

  /// Places new call
  ///
  /// [extraOptions] will be added to the callPayload sent to your server
  @override
  Future<bool?> place({required String from, required String to, Map<String, dynamic>? extraOptions}) {
    _activeCall = ActiveCall(from: from, to: to, callDirection: CallDirection.outgoing);

    var options = extraOptions ?? <String, dynamic>{};
    options['From'] = from;
    options['To'] = to;
    return _channel.invokeMethod('makeCall', options);
  }

  /// Hangs up active call
  @override
  Future<bool?> hangUp() {
    return _channel.invokeMethod('hangUp', <String, dynamic>{});
  }

  /// Checks if there is an ongoing call
  @override
  Future<bool> isOnCall() {
    return _channel.invokeMethod<bool?>('isOnCall', <String, dynamic>{}).then<bool>((bool? value) => value ?? false);
  }

  /// Gets the active call's SID. This will be null until the first Ringing event occurs
  @override
  Future<String?> getSid() {
    return _channel.invokeMethod<String?>('call-sid', <String, dynamic>{}).then<String?>((String? value) => value);
  }

  /// Answers incoming call
  @override
  Future<bool?> answer() {
    return _channel.invokeMethod('answer', <String, dynamic>{});
  }

  /// True if hold behaviour is configurable on the current platform, i.e. web & macOS
  /// (platforms backed by the Twilio Voice JS SDK which has no native hold mechanism).
  /// Android & iOS use the native Twilio Voice SDK hold.
  static bool get _canConfigureHold => kIsWeb || defaultTargetPlatform == TargetPlatform.macOS;

  HoldStrategy _holdStrategy = HoldStrategy.local;
  String? _holdAudioUrl;
  HoldActionCallback? _onHoldAction;

  @override
  HoldStrategy get holdStrategy => _holdStrategy;

  @override
  set holdStrategy(HoldStrategy strategy) {
    if (!_canConfigureHold) {
      throw UnimplementedError("holdStrategy is not implemented on this platform, the native Twilio Voice SDK hold is used instead");
    }
    _holdStrategy = strategy;
  }

  @override
  String? get holdAudioUrl => _holdAudioUrl;

  @override
  set holdAudioUrl(String? url) {
    if (!_canConfigureHold) {
      throw UnimplementedError("holdAudioUrl is not implemented on this platform, the native Twilio Voice SDK hold is used instead");
    }
    _holdAudioUrl = url;
  }

  @override
  HoldActionCallback? get onHoldAction => _onHoldAction;

  @override
  set onHoldAction(HoldActionCallback? callback) {
    if (!_canConfigureHold) {
      throw UnimplementedError("onHoldAction is not implemented on this platform, the native Twilio Voice SDK hold is used instead");
    }
    _onHoldAction = callback;
  }

  /// Holds active call
  /// [holdCall] is respected in web & macOS only, in native mobile it will always toggle the hold state.
  /// In future, native mobile will also respect the [holdCall] value.
  ///
  /// On macOS, the configured [holdStrategy] is applied:
  /// - [HoldStrategy.local]: hold is performed in the underlying webview (hold audio/silence
  ///   replaces the outbound stream, inbound audio is silenced locally).
  /// - [HoldStrategy.remote]: [onHoldAction] is invoked to perform a server-side hold, native
  ///   state is updated afterwards.
  @override
  Future<bool?> holdCall({bool holdCall = true}) async {
    if (_canConfigureHold && _holdStrategy == HoldStrategy.remote) {
      final callback = _onHoldAction;
      if (callback == null) {
        printDebug("holdCall: HoldStrategy.remote requires an onHoldAction callback, ignoring hold request");
        return false;
      }
      final sid = await getSid();
      final success = await callback(sid, holdCall);
      if (!success) {
        return false;
      }
      return _channel.invokeMethod('holdCall', <String, dynamic>{"shouldHold": holdCall, "strategy": "remote"});
    }
    return _channel.invokeMethod('holdCall', <String, dynamic>{
      "shouldHold": holdCall,
      "strategy": "local",
      if (_holdAudioUrl != null) "holdAudioUrl": _holdAudioUrl,
    });
  }

  /// Query's active call holding state
  @override
  Future<bool?> isHolding() {
    return _channel.invokeMethod('isHolding', <String, dynamic>{});
  }

  /// Toggles mute state to provided value
  @override
  Future<bool?> toggleMute(bool isMuted) {
    return _channel.invokeMethod('toggleMute', <String, dynamic>{"muted": isMuted});
  }

  /// Query's mute status of call, true if call is muted
  @override
  Future<bool?> isMuted() {
    return _channel.invokeMethod('isMuted', <String, dynamic>{});
  }

  /// Toggles speaker state to provided value
  @override
  Future<bool?> toggleSpeaker(bool speakerIsOn) {
    return _channel.invokeMethod('toggleSpeaker', <String, dynamic>{"speakerIsOn": speakerIsOn});
  }

  /// Switches Audio Device
  /*Future<String?> switchAudio({String audioDevice = "auto}) {
    return _channel.invokeMethod('switchAudio', <String, dynamic>{"audioDevice": audioDevice});
  }*/

  /// Query's speaker output status, true if on loud speaker.
  @override
  Future<bool?> isOnSpeaker() {
    return _channel.invokeMethod('isOnSpeaker', <String, dynamic>{});
  }

  @override
  Future<bool?> sendDigits(String digits) {
    return _channel.invokeMethod('sendDigits', <String, dynamic>{"digits": digits});
  }

  @override
  Future<bool?> toggleBluetooth({bool bluetoothOn = true}) {
    return _channel.invokeMethod('toggleBluetooth', <String, dynamic>{"bluetoothOn": bluetoothOn});
  }

  @override
  Future<bool?> isBluetoothOn() {
    return _channel.invokeMethod('isBluetoothOn', <String, dynamic>{});
  }

  @override
  Future<bool?> connect({Map<String, dynamic>? extraOptions}) {
    _activeCall = ActiveCall(from: "", to: "", callDirection: CallDirection.outgoing);
    final options = {
      ...?extraOptions,
    };
    return _channel.invokeMethod('connect', options);
  }
}

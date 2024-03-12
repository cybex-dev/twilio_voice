import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../platform_interface/twilio_call_platform_interface.dart';

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

  /// Holds active call
  /// [holdCall] is respected in web only, in native it will always toggle the hold state.
  /// In future, native mobile will also respect the [holdCall] value.
  @override
  Future<bool?> holdCall({bool holdCall = true}) {
    return _channel.invokeMethod('holdCall', <String, dynamic>{"shouldHold": holdCall});
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
}

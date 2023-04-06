import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../twilio_voice.dart';
import '../method_channel/twilio_call_method_channel.dart';
import 'shared_platform_interface.dart';

abstract class TwilioCallPlatform extends SharedPlatformInterface {
  TwilioCallPlatform() : super(token: _token);

  static final Object _token = Object();

  static TwilioCallPlatform _instance = MethodChannelTwilioCall();

  static TwilioCallPlatform get instance => _instance;

  static set instance(TwilioCallPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Gets active call
  ActiveCall? get activeCall;

  /// Sets active call
  set activeCall(ActiveCall? activeCall);

  /// Places new call
  ///
  /// [extraOptions] will be added to the callPayload sent to your server
  Future<bool?> place({required String from, required String to, Map<String, dynamic>? extraOptions});

  /// Hangs up active call
  Future<bool?> hangUp();

  /// Checks if there is an ongoing call
  Future<bool> isOnCall();

  /// Gets the active call's SID. This will be null until the first Ringing event occurs
  Future<String?> getSid();

  /// Answers incoming call
  Future<bool?> answer();

  /// Puts active call on hold
  Future<bool?> holdCall({bool holdCall = true});

  /// Toggles mute state to provided value
  Future<bool?> toggleMute(bool isMuted);

  /// Toggles speaker state to provided value
  Future<bool?> toggleSpeaker(bool speakerIsOn);

  Future<bool?> sendDigits(String digits);
}

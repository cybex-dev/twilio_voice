import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../twilio_voice.dart';
import '../method_channel/twilio_voice_method_channel.dart';
import 'shared_platform_interface.dart';
import 'twilio_call_platform_interface.dart';

typedef OnDeviceTokenChanged = Function(String token);

abstract class TwilioVoicePlatform extends SharedPlatformInterface {
  TwilioVoicePlatform() : super(token: _token);

  static final Object _token = Object();

  static TwilioVoicePlatform _instance = MethodChannelTwilioVoice();

  static TwilioVoicePlatform get instance => _instance;

  static set instance(TwilioVoicePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  TwilioCallPlatform get call;

  /// Sends call events
  Stream<CallEvent> get callEventsListener;

  OnDeviceTokenChanged? deviceTokenChanged;
  void setOnDeviceTokenChanged(OnDeviceTokenChanged deviceTokenChanged) {
    deviceTokenChanged = deviceTokenChanged;
  }

  /// register fcm token, and device token for android
  ///
  /// ios device token is obtained internally
  Future<bool?> setTokens({required String accessToken, String? deviceToken});

  /// Whether or not should the user receive a notification after a missed call, default to true.
  ///
  /// Setting is persisted across restarts until overridden
  set showMissedCallNotifications(bool value);

  /// Unregisters from Twilio
  ///
  /// If no accessToken is provided, previously registered accessToken will be used
  Future<bool?> unregister({String? accessToken});

  /// Checks if device needs background permission
  ///
  /// Android only, xiamoi devices need special permission to show background call UI
  Future<bool> requiresBackgroundPermissions();

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  Future<bool?> requestBackgroundPermissions();

  /// Checks if device has microphone permission
  Future<bool> hasMicAccess();

  /// Request microphone permission
  Future<bool?> requestMicAccess();

  /// Register clientId for background calls
  ///
  /// Register the client name for incoming calls while calling using ids
  Future<bool?> registerClient(String clientId, String clientName);

  /// Unregister clientId for background calls
  Future<bool?> unregisterClient(String clientId);

  /// Set default caller name for no registered clients
  ///
  /// This caller name will be shown for incoming calls
  Future<bool?> setDefaultCallerName(String callerName);

  /// Android-only, shows background call UI
  Future<bool?> showBackgroundCallUI();

  /// Sends call events
  CallEvent parseCallEvent(String state);
}

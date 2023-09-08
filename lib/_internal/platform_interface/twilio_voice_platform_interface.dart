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
  @Deprecated('custom call UI not used anymore, has no effect')
  Future<bool> requiresBackgroundPermissions();

  /// Requests background permission
  ///
  /// Android only, takes user to android settings to accept background permissions
  @Deprecated('custom call UI not used anymore, has no effect')
  Future<bool?> requestBackgroundPermissions();

  /// Checks if device has a registered phone account
  ///
  /// Android only
  Future<bool> hasRegisteredPhoneAccount();

  /// Register phone account with TelecomManager
  ///
  /// Android only
  Future<bool?> registerPhoneAccount();

  /// Checks if App's phone account is enabled
  ///
  /// Android only
  Future<bool> isPhoneAccountEnabled();

  /// Open phone account settings
  ///
  /// Android only
  Future<bool?> openPhoneAccountSettings();

  /// Checks if device has microphone permission
  Future<bool> hasMicAccess();

  /// Request microphone permission
  Future<bool?> requestMicAccess();

  /// Checks if device has read phone state permission
  ///
  /// Android only
  Future<bool> hasReadPhoneStatePermission();

  /// Request read phone state permission
  ///
  /// Android only
  Future<bool?> requestReadPhoneStatePermission();

  /// Checks if device has read phone state permission
  ///
  /// Android only
  Future<bool> hasCallPhonePermission();

  /// Request read phone state permission
  ///
  /// Android only
  Future<bool?> requestCallPhonePermission();

  /// Checks if device has read phone numbers permission
  ///
  /// Android only
  Future<bool> hasReadPhoneNumbersPermission();

  /// Request read phone numbers permission
  ///
  /// Android only
  Future<bool?> requestReadPhoneNumbersPermission();

  /// Checks if device has bluetooth permissions
  /// Only available on Android
  /// Defaults to false
  @Deprecated('custom call UI not used anymore, has no effect')
  Future<bool> hasBluetoothPermissions();

  /// Request bluetooth permissions
  /// To use bluetooth, you need to add the following to your `AndroidManifest.xml`
  ///
  /// `<uses-permission android:name="android.permission.BLUETOOTH" />`
  ///
  /// Only available on Android
  @Deprecated('custom call UI not used anymore, has no effect')
  Future<bool?> requestBluetoothPermissions();

  /// Reject call when no `CALL_PHONE` permissions are granted nor Phone Account (via `isPhoneAccountEnabled`) is registered.
  /// If set to true, the call is rejected immediately upon received. If set to false, the call is left until the timeout is reached / call is canceled.
  /// Defaults to false.
  ///
  /// Only available on Android
  Future<bool> rejectCallOnNoPermissions({bool shouldReject = false});

  /// Returns true if call is rejected when no `CALL_PHONE` permissions are granted nor Phone Account (via `isPhoneAccountEnabled`) is registered. Defaults to false.
  ///
  /// Only available on Android
  Future<bool> isRejectingCallOnNoPermissions();

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
  Future<bool?> updateCallKitIcon({String? icon});

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
  @Deprecated('custom call UI not used anymore, has no effect')
  Future<bool?> showBackgroundCallUI();

  /// Sends call events
  CallEvent parseCallEvent(String state);
}

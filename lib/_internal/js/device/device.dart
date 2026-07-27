import 'dart:js_interop';

import 'package:twilio_voice/_internal/js/call/call.dart';

/// Pre-major version update including breaking changes.
/// Flutter/Dart version update required.
enum TwilioDeviceEvents {
  // "error"
  error,
  // "incoming"
  incoming,
  // "registered"
  registered,
  // "registering"
  // registering,
  // "tokenWillExpire"
  tokenWillExpire,
  // "unregistered"
  unregistered,
}

@JS("Twilio.Device")
extension type Device._(JSObject _) implements JSObject {
  // factory used by js lib
  external factory Device(
    String token, [
    DeviceOptions? options,
  ]);

  // /// Returns array of active calls
  // /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicecalls
  // external JSAny? get calls;

  /// Returns true if the device is on an active call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceisbusy
  external bool get isBusy;

  /// Get current device token
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicetoken
  external String get token;

  /// Connect to Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connect
  external JSPromise<Call> connect([DeviceConnectOptions? options]);

  /// Register device token with Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceregister
  external JSPromise<JSAny?> register();

  /// Unregister device token with Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceunregister
  external JSPromise<JSAny?> unregister();

  /// Destroy the device, unregistering it, disconnecting any active calls and releasing
  /// its references so it can be garbage collected.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicedestroy
  external void destroy();

  /// Attach event listener for Twilio Device object. See [TwilioDeviceEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
  external void addListener(String event, JSFunction callback);

  /// Detach event listener for Twilio Device object. See [TwilioDeviceEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
  external void removeListener(String event, JSFunction callback);

  /// Update device options
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceupdateoptionsoptions
  external void updateOptions(DeviceOptions options);

  /// Get current call status, see [DeviceState]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicestate
  external String get state;

  /// Update the device's access token.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceupdatetokentoken
  external void updateToken(String token);
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
///
/// A bare `external factory` with only named parameters creates a JS object
/// literal. Note: object-literal factories cannot declare default values, so any
/// defaults previously baked in here are now supplied explicitly at the call sites.
extension type DeviceOptions._(JSObject _) implements JSObject {
  external factory DeviceOptions({
    int logLevel,
    JSArray<JSString> codecPreferences,
    bool closeProtection,
    JSAny? sounds,
    bool enableImprovedSignalingErrorPrecision,
    bool allowIncomingWhileBusy,
    int? tokenRefreshMs,
  });

  /// The Voice JavaScript SDK exposes a loglevel-based logger to allow for runtime logging configuration.
  ///
  /// You can set this property to a number which corresponds to the log levels shown below.
  /// 0 = "trace"
  /// 1 = "debug"
  /// 2 = "info"
  /// 3 = "warn"
  /// 4 = "error"
  /// 5 = "silent"
  ///
  /// Default is 1 "trace"
  external int logLevel;

  /// An array of codec names ordered from most-preferred to least-preferred.
  /// Opus and PCMU are the two codecs currently supported by Twilio Voice JS SDK. Opus can provide better quality for lower bandwidth, particularly noticeable in poor network conditions.
  /// Default: ["pcmu", "opus"]
  external JSArray<JSString> codecPreferences;

  /// Setting this property to true will enable a dialog prompt with the text "A call is currently in progress. Leaving or reloading the page will end the call." when closing a page which has an active connection.
  /// Setting the property to a string will create a custom message prompt with that string. If custom text is not supported by the browser, Twilio will display the browser's default dialog.
  external bool closeProtection;

  /// Not implemented yet
  /// Whether the Device instance should raise the 'incoming' event when a new call invite is received while already on an active call.
  /// set to false by default
  external bool allowIncomingWhileBusy;

  /// Whether to enable improved precision for signaling errors. Instead of catch-all 31005 type error codes, more specific error codes will be returned.
  external bool enableImprovedSignalingErrorPrecision;

  /// The sound files to use for the Device's ringtone and other sounds. This should be a map of sound names to URLs but the Map type is not supported in JS interop yet so we use a JS object (via jsify).
  external JSAny? sounds;

  /// The time in milliseconds after which the Device will attempt to refresh its access token.
  external int? tokenRefreshMs;
}

/// Device Connect options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connectoptions
extension type DeviceConnectOptions._(JSObject _) implements JSObject {
  external factory DeviceConnectOptions({JSAny? params});

  external JSAny? params;
}

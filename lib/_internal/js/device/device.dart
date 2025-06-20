// import 'dart:js_interop';
// TODO(cybex-dev) implement js_interop for js package
// ignore: deprecated_member_use
import 'package:js/js.dart';
import 'package:twilio_voice/_internal/js/call/call.dart';
import 'package:twilio_voice/_internal/js/core/core.dart';
import 'package:twilio_voice/_internal/js/twilio.dart';

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
class Device extends Twilio {
  // private constructor
  // ignore: unused_element_parameter, unused_element
  external Device._(token, [DeviceOptions? options]);

  // factory used by js lib
  external factory Device(
    String token, [
    DeviceOptions? options,
  ]);

  // /// Returns array of active calls
  // /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicecalls
  // @JS("calls")
  // external dynamic get calls;

  /// Returns true if the device is on an active call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceisbusy
  @JS("isBusy")
  external bool get isBusy;

  /// Get current device token
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#devicetoken
  @JS("token")
  external String get token;

  /// Connect to Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connect
  @JS("connect")
  external Promise<Call> connect([DeviceConnectOptions? options]);


  /// Register device token with Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceregister
  @JS("register")
  external Promise<void> register();

  /// Unregister device token with Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceunregister
  @JS("unregister")
  external Promise<void> unregister();

  /// Attach event listener for Twilio Device object. See [TwilioDeviceEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
  /// possibly use js interop here
  @JS("on")
  external void on(String event, Function callback);

  /// Detach event listener for Twilio Device object. See [TwilioDeviceEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#events
  /// possibly use js interop here
  @JS("off")
  external void off(String event, Function callback);

  /// Update device options
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceupdateoptionsoptions
  @JS("updateOptions")
  external void updateOptions(DeviceOptions options);
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
@anonymous
@JS()
class DeviceOptions {
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
  external List<String> codecPreferences;

  /// Setting this property to true will enable a dialog prompt with the text "A call is currently in progress. Leaving or reloading the page will end the call." when closing a page which has an active connection.
  /// Setting the property to a string will create a custom message prompt with that string. If custom text is not supported by the browser, Twilio will display the browser's default dialog.
  external bool closeProtection;

  /// Not implemented yet
  /// Whether the Device instance should raise the 'incoming' event when a new call invite is received while already on an active call.
  /// set to false by default
  external bool allowIncomingWhileBusy;

  /// Whether to enable improved precision for signaling errors. Instead of catch-all 31005 type error codes, more specific error codes will be returned.
  external bool enableImprovedSignalingErrorPrecision;

  /// The sound files to use for the Device's ringtone and other sounds. This should be a map of sound names to URLs but the Map type is not supported in JS interop yet so we use dynamic with jsify.
  external dynamic sounds;

  /// The time in milliseconds after which the Device will attempt to refresh its access token.
  external int? tokenRefreshMs;

  external factory DeviceOptions({int logLevel = 1, List<String>? codecPreferences, bool closeProtection = false, dynamic sounds, bool enableImprovedSignalingErrorPrecision = true, bool allowIncomingWhileBusy = false, int? tokenRefreshMs});
}

/// Device Connect options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connectoptions
@anonymous
@JS()
class DeviceConnectOptions {
  external dynamic params;
  external factory DeviceConnectOptions({dynamic params});
}

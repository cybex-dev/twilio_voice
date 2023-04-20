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
  external Device._(token, [DeviceInitOptions? options]);

  // factory used by js lib
  external factory Device(
    String token, [
    DeviceInitOptions? options,
  ]);

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
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
@anonymous
@JS()
class DeviceInitOptions {
  external int logLevel;
  external List<String> codecPreferences;

  external factory DeviceInitOptions({int logLevel = 1, List<String>? codecPreferences});
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
@anonymous
@JS()
class DeviceConnectOptions {
  external Map<String, String> params;
  external factory DeviceConnectOptions({dynamic params});
}

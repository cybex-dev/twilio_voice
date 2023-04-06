import 'package:js/js.dart';
import 'package:twilio_voice/_internal/js/call/call.dart';
import 'package:twilio_voice/_internal/js/core/core.dart';

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
class Device {
  @JS("Device")
  external Device._(String token, [DeviceInitOptions? options]);

  factory Device(String token, {DeviceInitOptions? options}) => Device._(token, options);

  /// Connect to Twilio Voice Client
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connect
  @JS("connect")
  external Promise<Call> connect(DeviceConnectOptions options);

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
@JS()
@anonymous
class DeviceInitOptions {
  @JS()
  external DeviceInitOptions._(int logLevel, List<String> codecPreferences);

  factory DeviceInitOptions({int logLevel = 1, List<String> codecPreferences = const ["opus", "pcmu"]}) =>
      DeviceInitOptions._(logLevel, codecPreferences);

  @JS("logLevel")
  external int logLevel;

  @JS("logLevel")
  external List<String> codecPreferences;
}

/// Device options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#deviceoptions
@JS()
@anonymous
class DeviceConnectOptions {
  @JS()
  external DeviceConnectOptions._(Map<String, String> params);

  factory DeviceConnectOptions(Map<String, String> params) => DeviceConnectOptions._(params);

  @JS("params")
  external Map<String, String> params;
}

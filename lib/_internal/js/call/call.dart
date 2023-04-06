import 'package:js/js.dart';

/// Pre-major version update including breaking changes.
/// Flutter/Dart version update required.
enum TwilioCallEvents {
  // "accept"
  accept,
  // "cancel"
  cancel,
  // "disconnect"
  disconnect,
  // "error"
  error,
  // "messageReceived"
  // messageReceived,
  // "messageSent"
  // messageSent,
  // "mute"
  mute,
  // "reconnected"
  reconnected,
  // "reconnecting"
  reconnecting,
  // "reject"
  reject,
  // "sample"
  // sample,
  // "warning"
  // warning,
  // "warningCleared"
  // warningCleared,
  // "connected", undocumented?
  connected,
}

@JS("Twilio.Call")
class Call {
  @JS("Call")
  external Call._();

  factory Call() => Call._();

  /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callcustomparameters
  @JS("customParameters")
  external Map<String, String> get customParameters;

  /// Get the direction of call, either "INCOMING" or "OUTGOING"
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldirection
  @JS("direction")
  external String direction();

  /// Disconnect active Twilio Call.
  /// Documentation: https://www.twilio.com/docs/voice/client/javascript/call#disconnect
  @JS("disconnect")
  external void disconnect();

  /// Mute active Twilio Call, defaults to true
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callmuteshouldmute
  @JS("mute")
  external void mute(bool shouldMute);

  /// Is active Twilio Call muted
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callismuted
  @JS("isMuted")
  external bool isMuted();

  /// Attach event listener for Twilio Call object. See [TwilioCallEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events
  /// possibly use js interop here
  @JS("on")
  external void on(String event, Function callback);

  /// Deattach event listener for Twilio Call object. See [TwilioCallEvents]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events
  /// possibly use js interop here
  @JS("off")
  external void off(String event, Function callback);

  /// Send digits to active Twilio Call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callsenddigitsdigits
  @JS("sendDigits")
  external void sendDigits(String digits);

  /// Accepts a call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callacceptacceptoptions
  @JS("accept")
  external void accept();
}

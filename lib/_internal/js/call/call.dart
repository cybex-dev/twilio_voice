import 'dart:js_interop';

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
  warning,
  // "warning-cleared"
  warningCleared,
  // "connected", undocumented?
  connected,
}

@JS("Twilio.Call")
extension type Call._(JSObject _) implements JSObject {
  external factory Call();

  /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callparameters
  external JSAny? get parameters;

  /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callcustomparameters
  external JSAny? get customParameters;

  /// Get the direction of call, either "INCOMING" or "OUTGOING"
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldirection
  external String get direction;

  /// Get current call status, see [TwilioCallStatus]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callstatus
  external String status();

  /// Disconnect active Twilio Call.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldisconnect
  external void disconnect();

  /// Reject incoming call Twilio Call.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callreject
  external void reject();

  /// Ignore placed call, does not alert dialing party.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callignore
  external void ignore();

  /// Mute active Twilio Call, defaults to true
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callmuteshouldmute
  external void mute(bool shouldMute);

  /// Is active Twilio Call muted
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callismuted
  external bool isMuted();

  /// Send digits to active Twilio Call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callsenddigitsdigits
  external void sendDigits(String digits);

  /// Accepts a call
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callacceptacceptoptions
  external void accept();

  /// Register a listener against Twilio Call object
  /// Documentation: https://nodejs.org/api/events.html#events_emitter_addlistener_eventname_listener
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#eventemitter-methods-and-properties
  external void addListener(String event, JSFunction callback);

  /// Deregister a listener against Twilio Call object
  /// Documentation: https://nodejs.org/api/events.html#events_emitter_removelistener_eventname_listener
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#eventemitter-methods-and-properties
  external void removeListener(String event, JSFunction callback);
}

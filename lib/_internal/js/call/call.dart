import 'package:js/js.dart';

import '../twilio.dart';

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
class Call extends Twilio {
  // ignore: unused_element
  external Call._();

  external factory Call();

  /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callparameters
  @JS("parameters")
  external dynamic get parameters;

  /// Get customParameters from Twilio Call, send via outgoing call or received from incoming call (via TwiML app)
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callcustomparameters
  @JS("customParameters")
  external dynamic get customParameters;

  /// Get the direction of call, either "INCOMING" or "OUTGOING"
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldirection
  @JS("direction")
  external String get direction;

  /// Get current call status, see [TwilioCallStatus]
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callstatus
  @JS("status")
  external String status();

  /// Disconnect active Twilio Call.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#calldisconnect
  @JS("disconnect")
  external void disconnect();

  /// Reject incoming call Twilio Call.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callreject
  @JS("reject")
  external void reject();

  /// Ignore placed call, does not alert dialing party.
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callignore
  @JS("ignore")
  external void ignore();

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

  /// Register a listener against Twilio Call object
  /// Documentation: https://nodejs.org/api/events.html#events_emitter_addlistener_eventname_listener
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#eventemitter-methods-and-properties
  @JS("addListener")
  external void addListener(String event, Function callback);

  /// Deregister a listener against Twilio Call object
  /// Documentation: https://nodejs.org/api/events.html#events_emitter_removelistener_eventname_listener
  /// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#eventemitter-methods-and-properties
  @JS("removeListener")
  external void removeListener(String event, Function callback);
}

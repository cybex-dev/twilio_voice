/// Acts as interface for the Twilio Voice JS SDK
/// The 2 main components of Twilio Voice SDJ are:
/// 1. Twilio.Device - This is the main object that is used to interact with the Twilio Voice SDK.
/// Documentation:
/// - https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice
/// - https://www.twilio.com/docs/voice/client/javascript/device (deprecated)
///
/// 2. Twilio.Call - This is the object that represents a call. It is returned by the Twilio.Device.connect() method.
/// Documentation:
/// - https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
///
/// The Twilio Voice JS SDK is loaded in the webview using the [TwilioVoiceWeb] plugin.

/// Short description of file & functions (high-level)0
/// Load twilio.js or twilio.min.js by filename (see web/twilio.js), @JS annotates this is a JS operation/function. Alternatively,
/// to call a specific JS function, add this inside the @JS annotation's parentheses e.g. [@JS("JSON.stringify")].
/// Declare external functions that will be called from JS - keep JS and dart names synonymous - for readers, future devs, and debugging.
/// These external functions are called from the main `plugin_name_web.dart` file.
@JS()
library twilio.js;

import 'package:js/js.dart';

@JS("Twilio")
class Twilio {

}
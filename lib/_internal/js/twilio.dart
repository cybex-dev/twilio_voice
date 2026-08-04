/// Acts as interface for the Twilio Voice JS SDK
/// The 2 main components of Twilio Voice SDK are:
/// 1. Twilio.Device - This is the main object that is used to interact with the Twilio Voice SDK.
/// Documentation:
/// - https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice
/// - https://www.twilio.com/docs/voice/client/javascript/device (deprecated)
///
/// 2. Twilio.Call - This is the object that represents a call. It is returned by the Twilio.Device.connect() method.
/// Documentation:
/// - https://www.twilio.com/docs/voice/sdks/javascript/twiliocall
///
/// The Twilio Voice JS SDK is loaded by the plugin itself (it is bundled as an asset), so
/// `window.Twilio` is available before these bindings are used - see [TwilioVoiceWeb] on web and
/// `TVWebView` on macOS.
///
/// Interop notes: these types bind to existing JS globals via `dart:js_interop` extension types.
/// `@JS("<name>")` names the JS object/member being bound; keep the JS and Dart names synonymous
/// for readers, future devs and debugging. They are consumed from `twilio_voice_web.dart`.
library;

import 'dart:js_interop';

/// Base namespace for the Twilio Voice JS SDK. Both [Twilio.Device] and
/// [Twilio.Call] live under this global object.
@JS("Twilio")
extension type Twilio._(JSObject _) implements JSObject {}

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

@JS("Twilio.Device")
external dynamic setup(String token, [DeviceSetupOptions? options]);

@JS()
@anonymous
class DeviceSetupOptions {
  external factory DeviceSetupOptions({
    int logLevel = 1,
    List<String> codecPreferences = const ["opus", "pcmu"],
  });
}

// https://www.rudderstack.com/blog/how-to-extend-a-flutter-plugin-to-support-web/
// https://github.com/rudderlabs/rudder-sdk-flutter/blob/develop/packages/example/web/index.html
// https://github.com/rudderlabs/rudder-sdk-flutter/blob/develop/packages/plugins/rudder_plugin_web/lib/internal/web_js.dart
// https://pub.dev/packages/js
// https://medium.com/7span/flutter-web-javascript-everything-that-you-need-to-know-b07a32d7ad56
// https://docs.flutter.dev/development/packages-and-plugins/developing-packages
// https://medium.com/flutter/how-to-write-a-flutter-web-plugin-part-2-afdddb69ece6
// https://tbrgroup.software/writing-a-flutter-web-plugin-with-javascript/
// https://stackoverflow.com/questions/52276662/using-dart-js-interop-with-es6-classes

// https://www.google.com/search?q=flutter+web+plugin+create+%22new%22+javascript+object&
// https://gpalma.pt/blog/flutter-web-using-javascript/
// https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#instantiate-a-device
// https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#methods

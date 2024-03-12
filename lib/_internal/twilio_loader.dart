import 'dart:async';
import 'dart:html';
import 'dart:js';

import 'utils.dart';

/// Injects a `script` with a `src` dynamically into the head of the current
/// document.
void _injectSrcScript(String src) async {
  ScriptElement script = ScriptElement();
  script.type = 'text/javascript';
  script.crossOrigin = 'anonymous';

  assert(document.head != null);
  document.head!.append(script);
  return;
}

/// Ignored for web in current implementation, using bundled twilio.min.js instead
/// Initializes the Twilio JS SDKs by injecting them into the `head` of the document when Twilio is initialized.
Future<void> loadTwilio() async {
  // If Twilio is already available, Twilio has already been initialized
  // (or the user has added the scripts to their html file).
  if (context['Twilio'] != null) {
    printDebug("Already found Twilio in context, skipping loadTwilio()...");
    return;
  }

  return _injectSrcScript('https://raw.githubusercontent.com/TwilioDevEd/voice-javascript-sdk-quickstart-node/main/public/twilio.min.js');
}

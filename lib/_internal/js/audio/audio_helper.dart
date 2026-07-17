// import 'dart:js_interop';
// TODO(cybex-dev) implement js_interop for js package
// ignore: deprecated_member_use
import 'package:js/js.dart';

import '../core/core.dart';

/// Twilio Device audio helper, accessed via [Device.audio].
/// Provides audio device management and the AudioProcessor API.
/// Documentation: https://twilio.github.io/twilio-voice.js/classes/AudioHelper.html
@JS()
class AudioHelper {
  /// Register an [AudioProcessor], routing input (microphone) audio through
  /// [AudioProcessor.createProcessedStream] before sending it to Twilio.
  /// Only one processor can be added at a time. Can be added/removed mid-call.
  /// Documentation: https://twilio.github.io/twilio-voice.js/classes/AudioHelper.html#addProcessor
  @JS("addProcessor")
  external Promise<void> addProcessor(AudioProcessor processor);

  /// Remove a previously added [AudioProcessor], restoring the original input stream.
  /// Documentation: https://twilio.github.io/twilio-voice.js/classes/AudioHelper.html#removeProcessor
  @JS("removeProcessor")
  external Promise<void> removeProcessor(AudioProcessor processor);
}

/// Twilio AudioProcessor interface, used with [AudioHelper.addProcessor].
///
/// [createProcessedStream] receives the input MediaStream and must return a Promise resolving
/// to the MediaStream sent to Twilio in its place (e.g. hold music via the Web Audio API).
/// [destroyProcessedStream] receives the processed MediaStream for cleanup once the input
/// stream is stopped, and must return a Promise.
///
/// Note: both callbacks must be wrapped with [allowInterop] when constructed from Dart.
/// Documentation: https://twilio.github.io/twilio-voice.js/interfaces/AudioProcessor.html
@JS()
@anonymous
class AudioProcessor {
  external factory AudioProcessor({
    Function createProcessedStream,
    Function destroyProcessedStream,
  });
}

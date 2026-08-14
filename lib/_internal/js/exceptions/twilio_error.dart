import 'dart:js_interop';

/// Interop wrapper for a Twilio Voice JS `TwilioError` object.
/// Documentation: https://www.twilio.com/docs/voice/sdks/error-codes
extension type TwilioError._(JSObject _) implements JSObject {
  external JSArray get causes;
  external int get code;
  external String get description;
  external String get explanation;
  external String get message;
  external String get name;
  external JSAny? get originalError;
  external JSArray get solutions;
}

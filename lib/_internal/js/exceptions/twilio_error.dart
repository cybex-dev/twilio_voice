import 'package:js/js.dart';

// @JS()
// @anonymous
// class TwilioError {
//   external factory TwilioError({
//     List causes,
//     int code,
//     String description,
//     String explanation,
//     String message,
//     String name,
//     dynamic originalError,
//     List solutions,
//   });
//
//   external List get causes;
//   external int get code;
//   external String get description;
//   external String get explanation;
//   external String get message;
//   external String get name;
//   external dynamic get originalError;
//   external List get solutions;
// }

@JS()
@staticInterop
abstract class TwilioError {
  external factory TwilioError();
}

extension TwilioErrorExtension on TwilioError {
  external List get causes;
  external int get code;
  external String get description;
  external String get explanation;
  external String get message;
  external String get name;
  external dynamic get originalError;
  external List get solutions;
}

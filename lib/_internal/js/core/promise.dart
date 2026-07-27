import 'dart:js_interop';

/// Awaits a JS [JSPromise] and converts its resolved value into a Dart map.
Future<Map<String, dynamic>> parsePromise(JSPromise promise) async {
  final response = await promise.toDart;
  final value = (response as JSObject).dartify() as Map<dynamic, dynamic>;
  return value.cast<String, dynamic>();
}

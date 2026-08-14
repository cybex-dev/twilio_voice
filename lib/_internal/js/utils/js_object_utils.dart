import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Converts a plain JS object into a Dart `Map<String, String>` by iterating
/// over its own enumerable keys.
Map<String, String> jsToStringMap(JSAny? jsonObject) {
  final map = <String, String>{};
  final obj = jsonObject as JSObject;
  final keys = objectKeys(obj);
  for (final key in keys.toDart) {
    final value = obj.getProperty<JSAny?>(key);
    map[key.toDart] = value?.dartify()?.toString() ?? '';
  }
  return map;
}

@JS('JSON.stringify')
external String stringify(JSAny obj);

@JS('Object.keys')
external JSArray<JSString> objectKeys(JSAny obj);

@JS('Array.from')
external JSArray toArray(JSAny source);

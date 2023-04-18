import 'package:js/js.dart';
import 'package:js/js_util.dart';

/// A workaround to converting an object from JS to a Dart Map.
Map jsToMap(jsObject) {
  return new Map.fromIterable(
    _getKeysOfObject(jsObject),
    value: (key) => getProperty(jsObject, key),
  );
}

// Both of these interfaces exist to call `Object.keys` from Dart.
//
// But you don't use them directly. Just see `jsToMap`.
@JS('Object.keys')
external List<String> _getKeysOfObject(jsObject);
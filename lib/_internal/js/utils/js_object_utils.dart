import 'package:js/js.dart';
import 'package:js/js_util.dart';

Map<String, String> jsToStringMap(dynamic jsonObject) {
  final map = <String, String>{};
  final keys = objectKeys(jsonObject);
  for (dynamic key in keys) {
    final value = getProperty(jsonObject, key);
    map[key] = value;
  }
  return map;
}

@JS('JSON.stringify')
external String stringify(Object obj);

@JS('Object.keys')
external List<String> objectKeys(Object obj);

@JS('Array.from')
external Object toArray(dynamic source);
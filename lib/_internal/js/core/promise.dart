import 'dart:js_util';

import 'package:js/js.dart';

@JS()
abstract class Promise<T> {
  external factory Promise(void Function(Function(T result) resolve, Function reject) executor);
  external Promise then(void Function(T result) onFulfilled, [Function onRejected]);
}

Future<Map<String, dynamic>> parsePromise(Promise<dynamic> promise) async {
  final response = await promiseToFuture(promise);
  final value = dartify(response) as Map<dynamic, dynamic>;
  return value.cast<String, dynamic>();
}

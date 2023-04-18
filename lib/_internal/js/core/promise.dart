import 'dart:js_util';

import 'package:js/js.dart';

@JS()
abstract class Promise<T> {
  external factory Promise(
      void executor(void resolve(T result), Function reject));
  external Promise then(void onFulfilled(T result), [Function onRejected]);
}

Future<Map<String, dynamic>> parsePromise(Promise<dynamic> promise) async {
  final response = await promiseToFuture(promise);
  final value = dartify(response) as Map<dynamic, dynamic>;
  return value.cast<String, dynamic>();
}

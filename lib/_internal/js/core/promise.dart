// TODO(cybex-dev) implement js_interop for js_util package
// ignore: deprecated_member_use
import 'dart:js_util';

// import 'dart:js_interop';
// TODO(cybex-dev) implement js_interop for js package
// ignore: deprecated_member_use
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

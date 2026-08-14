import 'package:flutter/foundation.dart';

void printDebug(dynamic message) {
  if (kDebugMode) {
    print(message);
  }
}

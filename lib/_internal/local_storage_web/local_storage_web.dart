import 'dart:html';

import 'i_local_storage_web.dart';

class LocalStorageWeb extends ILocalStorageWeb {
  final Storage _localStorage = window.localStorage;

  @override
  Storage get localStorage => _localStorage;

  @override
  void clearStorage() => localStorage.clear();

  @override
  String getDefaultCallerName(String defaultValue) {
    return _localStorage[kDefaultCallerName] ?? defaultValue;
  }

  @override
  void saveDefaultCallerName(String value) {
    _localStorage[kDefaultCallerName] = value;
  }

  @override
  void addRegisteredClient(String id, String name) {
    _localStorage[id] = name;
  }

  @override
  String? getRegisteredClient(String id, {String? defaultValue}) {
    return _localStorage[id] ?? defaultValue;
  }

  @override
  void removeRegisteredClient(String id) {
    _localStorage.remove(id);
  }
}

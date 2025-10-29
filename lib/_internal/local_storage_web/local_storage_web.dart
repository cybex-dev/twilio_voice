import 'package:web/web.dart';

import 'i_local_storage_web.dart';

class LocalStorageWeb extends ILocalStorageWeb {
  final Storage _localStorage = window.localStorage;

  @override
  Storage get localStorage => _localStorage;

  @override
  void clearStorage() => localStorage.clear();

  @override
  String getDefaultCallerName(String defaultValue) {
    return _localStorage.getItem(kDefaultCallerName) ?? defaultValue;
  }

  @override
  void saveDefaultCallerName(String value) {
    _localStorage.setItem(kDefaultCallerName, value);
  }

  @override
  void addRegisteredClient(String id, String name) {
    _localStorage.setItem(id, name);
  }

  @override
  String? getRegisteredClient(String id, {String? defaultValue}) {
    return _localStorage.getItem(id) ?? defaultValue;
  }

  @override
  void removeRegisteredClient(String id) {
    _localStorage.removeItem(id);
  }
}

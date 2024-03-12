import 'dart:html';

abstract class ILocalStorageWeb {
  /// local storage mapping keys
  final String kDefaultCallerName = "kDefaultCallerName";

  Storage get localStorage;

  /// Set default caller name for incoming calls if no caller name is provided / registered.
  void saveDefaultCallerName(String value);

  /// Get default caller name for incoming calls if no caller name is provided / registered.
  String getDefaultCallerName(String defaultValue);

  /// Add registered client by [id, name] pair in local storage. If an existing client with the same id is already registered, it will be replaced.
  void addRegisteredClient(String id, String name);

  /// Remove registered client by id, if the client is not registered, do nothing.
  void removeRegisteredClient(String id);

  /// Get registered client by id, if the client is not registered, return [defaultValue].
  String? getRegisteredClient(String id, {String? defaultValue});

  /// Clear local storage data
  void clearStorage();
}

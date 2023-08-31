import 'dart:html' as html;

abstract class ConsoleLogger {
  /// Gets the console object.
  html.Console get console => html.window.console;

  /// Logs a message to the console.
  void log(String message, {String? tag}) {
    console.log("[$tag] $message");
  }

  /// Logs a message to the console.
  void warn(String message, {String? tag}) {
    console.warn("[$tag] $message");
  }

  /// Logs a message to the console.
  void error(String message, {String? tag}) {
    console.error("[$tag] $message");
  }

  /// Logs a message to the console.
  void debug(String message, {String? tag}) {
    console.debug("[$tag] $message");
  }
}
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../method_channel/shared_platform_method_channel.dart';

abstract class SharedPlatformInterface extends PlatformInterface {
  static const _kMethodChannelName = 'twilio_voice/messages';
  static const _kEventChannelName = 'twilio_voice/events';

  /// Communication with native code
  MethodChannel get sharedChannel => _sharedChannel;
  MethodChannel _sharedChannel = const MethodChannel(_kMethodChannelName);

  /// Communication to flutter code
  EventChannel get eventChannel => _eventChannel;
  EventChannel _eventChannel = EventChannel(_kEventChannelName);

  SharedPlatformInterface({required Object token}) : super(token: token);

  static final Object _token = Object();

  static SharedPlatformInterface _instance = MethodChannelSharedPlatform(token: _token);

  static SharedPlatformInterface get instance => _instance;

  static set instance(SharedPlatformInterface instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Logs event to EventChannel, but uses [List.join] with [separator] to join [prefix] and [description].
  /// This is used to send events to the EventChannel for integration into existing communication flow.
  /// The event will be sent as a String with the following format:
  /// - (if prefix is not empty): "prefix|description", where '|' is separator
  /// - (if prefix is empty): "description"
  void logLocalEventEntries(List<String> entries, {String prefix = "LOG", String separator = "|"}) {
    logLocalEvent(entries.join(separator), prefix: prefix, separator: separator);
  }

  /// Logs event to EventChannel.
  /// This is used to send events to the EventChannel for integration into existing communication flow.
  /// The event will be sent as a String with the following format:
  /// - (if prefix is not empty): "prefix|description", where '|' is separator
  /// - (if prefix is empty): "description"
  void logLocalEvent(String description, {String prefix = "LOG", String separator = "|"}) {
    // eventChannel.binaryMessenger.handlePlatformMessage(
    //   _kEventChannelName,
    //   const StandardMethodCodec().encodeSuccessEnvelope(description),
    //   (ByteData? data) {},
    // );
    String message = "";
    if (prefix.isEmpty) {
      message = description;
    } else {
      message = "${prefix}${separator}${description}";
    }

    // Send events to EventChannel for integration into existing communication flow
    final byteMessage = const StandardMethodCodec().encodeSuccessEnvelope(message);
    eventChannel.binaryMessenger.send(_kEventChannelName, byteMessage);
  }

  /// Sends call events
// void logLocalError({String description = "", String code = "", Object? details}) {
//   final message = const StandardMethodCodec().encodeErrorEnvelope(code: code, message: description, details: details);
//   eventChannel.binaryMessenger.send(_kEventChannelName, message);
// }
}

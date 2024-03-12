import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../method_channel/shared_platform_method_channel.dart';
import '../utils.dart';

abstract class SharedPlatformInterface extends PlatformInterface {
  static const _kMethodChannelName = 'twilio_voice/messages';
  static const kEventChannelName = 'twilio_voice/events';

  /// Communication with native code
  MethodChannel get sharedChannel => _sharedChannel;
  final MethodChannel _sharedChannel = const MethodChannel(_kMethodChannelName);

  /// Communication to flutter code
  EventChannel get eventChannel => _eventChannel;
  final EventChannel _eventChannel = const EventChannel(kEventChannelName);

  // ignore: close_sinks
  StreamController<String>? _callEventsController;
  StreamController<String> get callEventsController {
    _callEventsController ??= StreamController<String>.broadcast();
    return _callEventsController!;
  }
  Stream<String> get callEventsStream => callEventsController.stream;

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
  void logLocalEvent(String description, {String prefix = "LOG", String separator = "|"}) async {
    if(!kIsWeb) {
      throw UnimplementedError("Use eventChannel() via sendPhoneEvents on platform implementation");
    }
    // eventChannel.binaryMessenger.handlePlatformMessage(
    //   _kEventChannelName,
    //   const StandardMethodCodec().encodeSuccessEnvelope(description),
    //   (ByteData? data) {},
    // );
    String message = "";
    if (prefix.isEmpty) {
      message = description;
    } else {
      message = "$prefix$separator$description";
    }

    printDebug("Sending event: $message");
    // Send events to EventChannel for integration into existing communication flow
    callEventsController.add(message);
  }

  /// Sends call events
  // void logLocalError({String description = "", String code = "", Object? details}) {
  //   final message = const StandardMethodCodec().encodeErrorEnvelope(code: code, message: description, details: details);
  //   eventChannel.binaryMessenger.send(_kEventChannelName, message);
  // }
}

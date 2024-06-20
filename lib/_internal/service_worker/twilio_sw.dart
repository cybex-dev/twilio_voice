import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import '../utils.dart';

class TwilioSW {
  TwilioSW._() {
    _setupServiceWorker();
  }

  static final TwilioSW _instance = TwilioSW._();

  static TwilioSW get instance => _instance;

  html.ServiceWorkerContainer? _webServiceWorkerContainerDelegate;
  html.ServiceWorker? _webServiceWorkerDelegate;
  StreamSubscription<html.MessageEvent>? _webServiceWorkerMessageSubscription;

  ValueChanged<Map<dynamic, dynamic>>? _messageReceived;

  set onMessageReceived(ValueChanged<Map<dynamic, dynamic>> value) {
    _messageReceived = value;
  }

  /// If present, this allows app functionality in the background.
  /// Use-cases included, but aren't limited to:
  /// - showing incoming call notifications with responding actions (e.g. answer/hangup).
  /// - listening to incoming calls (via TwilioVoiceSDK Js websocket connection)
  void _setupServiceWorker() {
    _webServiceWorkerContainerDelegate = html.window.navigator.serviceWorker;
    if (_webServiceWorkerContainerDelegate == null) {
      printDebug("No service worker found, check if you've registered the `twilio-sw.js` service worker and if the script is present.");
      return;
    }

    // attach SW event listeners to respond to incoming messages from SW
    _attachServiceWorkerListeners();

    _webServiceWorkerDelegate = _webServiceWorkerContainerDelegate?.controller;
    if (_webServiceWorkerDelegate == null) {
      printDebug("No service worker registered and/or controlling the page. Try (soft) refreshing?");
      return;
    }
  }

  void _attachServiceWorkerListeners() {
    if (_webServiceWorkerContainerDelegate != null) {
      if (_webServiceWorkerMessageSubscription != null) {
        // already registered, we don't have to register again
        return;
      }
      _webServiceWorkerMessageSubscription = _webServiceWorkerContainerDelegate!.onMessage.listen((event) {
        _messageReceived?.call(event.data);
      });
    }
  }

  Future<void> destroy() {
    return _detachServiceWorkerListeners();
  }

  Future<void> _detachServiceWorkerListeners() async {
    await _webServiceWorkerMessageSubscription?.cancel();
  }

  void send(Map<String, dynamic> message) {
    if (_webServiceWorkerDelegate != null) {
      _webServiceWorkerDelegate!.postMessage(message);
    }
  }
}

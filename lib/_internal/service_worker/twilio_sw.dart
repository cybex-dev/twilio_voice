import 'dart:html' as html;

import 'logger.dart';
import 'event_message.dart';

/// Provides access to the browser's Service Worker implementation. Allows getting the current service worker, container and registration via [self]. Allows interacting with the [self] service worker.
/// https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API
abstract class ServiceWorkerJS extends ConsoleLogger {
  html.ServiceWorker? get serviceWorker => serviceWorkerContainer?.controller;

  html.ServiceWorkerContainer? get serviceWorkerContainer => html.window.navigator.serviceWorker;

  /// Gets the service worker registration object, emulates the JS function
  /// `navigator.serviceWorker.ready`
  Future<html.ServiceWorkerRegistration>? get registrationReady => html.window.navigator.serviceWorker?.ready;

  static html.ServiceWorkerRegistration? _registration;

  html.ServiceWorkerRegistration? get self => _registration;

  set registration(html.ServiceWorkerRegistration? value) {
    registration = value;
  }
}
import 'package:twilio_voice/_internal/service_worker/twilio_sw.dart';

/// Provides access to the browser's Service Worker implementation. Allows getting the current service worker, container and registration via [self]. Allows interacting with the [self] service worker.
/// https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API
class ServiceWorkerJSImpl extends ServiceWorkerJS {
  ServiceWorkerJSImpl() {
    registerSelf();
    _attachEventListeners();
  }

  void registerSelf() {
    // TODO
    serviceWorkerContainer?.register('twilio_service_worker.js').then((registration) {
      registration = registration;
      console.log('Twilio Voice Service worker registered successfully');
    }).catchError((error) {
      console.warn('Error registering Twilio Service Worker: $error. This prevents notifications from working natively');
    });
  }

  void _attachEventListeners() {
    serviceWorkerContainer?.addEventListener('message', (event) {
      console.log('Received message from service worker: $event');
      // final message = EventMessage.fromEvent(event);
      // if (message == null) {
      //   return;
      // }
      // console.log('Received message from service worker: $message');
      // if (message.type == 'registration') {
      //   _registration = message.data as html.ServiceWorkerRegistration?;
      // }
    });
  }
}

import 'dart:html' as html;

import '../service_worker/twilio_sw.dart';
import 'notification_options.dart';
import 'notifications_js.dart';

class NotificationsJSImpl extends ServiceWorkerJS implements NotificationsJS {

  @override
  void cancelNotification(String? tag) async {
    if (tag == null || tag.isEmpty) {
      console.error('Cannot cancel a notification with an null/empty tag');
      return;
    }

    console.log("Canceling notification: $tag");
    final notification = await getNotificationByTag(tag);
    if (notification != null) {
      notification.close();
      console.log("Notification cancelled: $tag");
    }
  }

  @override
  Future<html.Notification?> getNotificationByTag(String tag) async {
    assert(self != null, 'No service worker in control of page, did you forget register one?');

    if (tag.isEmpty) {
      console.error('Cannot get a notification with an null/empty tag');
      return null;
    }

    final filter = {'tag': tag};
    final notifications = await self!.getNotifications(filter);
    if (notifications.length > 1) {
      console.warn('Found more than one notification with tag: $tag');
    }
    return notifications.firstWhere((element) => element.tag == tag, orElse: () => null);
  }

  @override
  bool hasNotificationPermissions() {
    return html.Notification.permission == 'granted';
  }

  @override
  void showNotification(String title, NotificationOptions options) async {
    assert(self != null, 'No service worker in control of page, did you forget register one?');
    assert(title.isNotEmpty, 'Notification title cannot be empty');
    assert(options.tag.isNotEmpty, 'Notification options tag cannot be empty');

    if (!hasNotificationPermissions()) {
      console.warn('Cannot show notification without permissions');
      return;
    }

    // TODO(cybex-dev): Check for existing notification with the same tag and close it if it exists
    self!.showNotification(title, options.toMap()).catchError((error) {
      console.error('Failed to show notification: $title, $options, $error');
    });
  }
}
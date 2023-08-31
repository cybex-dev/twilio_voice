import 'dart:html' as html;
import 'notification_options.dart';

/// Provides access to the browser's Service Worker implementation for the notification API.
abstract class NotificationsJS {
  /// Checks if the browser has notification permissions. True if the browser has notification permissions.
  bool hasNotificationPermissions();

  /// Shows a notification with the provided title and options.
  void showNotification(String title, NotificationOptions options);

  /// Gets a notification by tag. Returns a notification if found, null otherwise.
  Future<html.Notification?> getNotificationByTag(String tag);

  /// Cancels a notification by tag.
  void cancelNotification(String tag);
}

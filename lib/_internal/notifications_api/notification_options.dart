/// Options for a notification.
class NotificationOptions {
  final String tag;
  final String body;

  NotificationOptions({required this.tag, required this.body});

  /// Converts this object to a map.
  Map<String, dynamic> toMap() {
    return {
      'tag': tag,
      'body': body,
    };
  }
}
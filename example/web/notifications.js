/// Has background Notification API permissions
function hasNotificationPermissions() {
    return Notification.permission === 'granted';
}

function showNotification(title, options) {
    if (!hasNotificationPermissions()) {
        _error('Cannot show notification without permissions');
        return;
    }
    self.registration.showNotification(title, options).catch((error) => {
        _error('Error showing notification', error);
    });
}

function getNotificationByTag(tag) {
    return self.registration.getNotifications().then((notifications) => {
        return notifications.find((notification) => {
            return notification.tag === tag;
        });
    });
}

function cancelNotification(payload) {
    if (!payload) {
        _error('Cannot cancel a notification with no data', payload);
        return;
    }
    if (!payload.tag) {
        _error('Cannot cancel a notification with no tag', payload);
        return;
    }
    const tag = payload.tag;
    _log("Canceling notification: ", tag)
    return getNotificationByTag(tag).then((notification) => {
        if (notification) {
            notification.close();
            _log("Notification cancelled: ", tag)
        }
    });
}


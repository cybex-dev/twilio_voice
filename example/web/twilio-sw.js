// Twilio Voice Service Worker

importScripts('notifications.js')

const tag = 'Service Worker';

const _log = (...message) => {
    console.log(`[ ${tag} ]`, ...message);
};
const _error = (...message) => {
    console.error(`[ ${tag} ]`, ...message);
};

_log('Twilio Voice service-worker started');

self.addEventListener('message', (event) => {
    _handleMessage(event);
});

self.addEventListener('messageerror', (event) => {
    _error('messageerror event', event);
});

self.addEventListener('notificationclick', (event) => {
    _log(`notificationclick event [${event.action}]`, event);
    event.notification.close();
    _handleNotificationEvent(event.action, event.notification, event.notification.tag);
});

self.addEventListener('notificationclose', (event) => {
    _log('notificationclose event', event);
    event.notification.close();
    _handleNotificationEvent(null, event.data, event.tag);
});

function _handleNotificationEvent(action, payload, tag) {
    const message = {
        tag: tag,
    }
    switch (action) {
        case 'answer': {
            _focusClientWindow();
            _sendToClient(action, message);
            break;
        }
        case 'hangup':
        case 'reject': {
            _sendToClient(action, message);
            break;
        }
        default: {
            _focusClientWindow();
            break;
        }
    }
}

function _sendToClient(action, payload) {
    const message = {
        action: action,
        payload: payload
    };
    self.clients.matchAll().then((clients) => {
        clients.forEach((client) => {
            client.postMessage(message);
        });
    });
}

function _focusClientWindow() {
    self.clients.matchAll({
        type: "window",
    }).then((clients) => {
        clients
            .filter(value => !value.focused)
            .filter(value => "focus" in value)
            .forEach((client) => {
                client.focus().catch((error) => _error('Error focusing client window', error));
            });
    });
}

function _handleMessage(event) {
    if (!event) {
        _error('No event');
        return;
    }

    if (!event.data) {
        _error('No event data');
        return;
    }

    const data = event.data;
    const action = data.action;
    const payload = data.payload;

    switch (action) {
        case 'incoming':
        case 'missed': {
            _showNotification(payload);
            break;
        }
        case 'cancel': {
            cancelNotification(payload);
            break;
        }
    }
}

/**
 * Show a notification with actions (if available)
 * @param payload {title: string, options: NotificationOptions}
 * @private
 */
function _showNotification(payload) {
    if (!payload) {
        _error('Cannot show an incoming call notification with no data', payload);
        return;
    }

    if (!payload.hasOwnProperty('title') || !payload.title) {
        _error('Cannot show an incoming call notification with no title', payload);
        return;
    }

    if (!payload.hasOwnProperty('options') || !payload.options) {
        _error('Cannot show an incoming call notification with no options', payload);
        return;
    }

    const title = payload.title;
    const options = payload.options;
    showNotification(title, options);
}

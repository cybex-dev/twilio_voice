const tag = "callkit_sw";

// const log = (...message) => {
//     console.log(`[ ${tag} ]`, ...message);
// };
const error = (...message) => {
    console.error(`[ ${tag} ]`, ...message);
};
const warn = (...message) => {
    console.warn(`[ ${tag} ]`, message);
};

const matchOptions = {
    type: "window",
    includeUncontrolled: true,
};

const notificationActions = ["cancel", "cancelAll", "notification", "action"]

const handleNotificationClick = (event) => {
    console.log("Notification click, handling in service worker.");
    _handleNotificationResponse(event, "click");
}

const handleNotificationClose = (event) => {
    console.log("Notification closed, handling in service worker.");
    _handleNotificationResponse(event, "close");
}

const handleMessage = (event) => {
    console.log("Message Received, handling in service worker.");
    handleMessagePayload(event.data);
}

const handleMessagePayload = (message) => {
    const id = message.id;
    const action = message.action;
    const notification = message.notification;
    // const data = message.data;

    if (!notificationActions.includes(action)) {
        // invalid/unhandled action
        return;
    }

    // handle notification actions here only
    if (action === "notification") {
        return showNotification(notification.title, notification.options);
    } else  {
        return _handleNotificationAction(action, id)
    }
}

const _handleNotificationAction = (action, id) => {
    switch (action) {
        case "cancel": {
            cancelNotification(id);
            break;
        }
        case "cancelAll": {
            cancelAllNotifications();
            break;
        }
        case "action": {
            // do nothing
            break;
        }
        default: {

        }
    }
}

const _handleNotificationResponse = (event, type) => {
    const action = event.action;
    const n = event.notification;
    const data = n.data;
    const tag = n.tag;
    postMessage(action, type, data, tag);
}

const getClients = () => self.clients.matchAll(matchOptions);

const hasPermissions = () => Notification.permission === 'granted';

// function showNotification(title, options, timer) {
const showNotification = async (title, options) => {
    if (!hasPermissions()) {
        return;
    }

    self.registration.showNotification(title, options).catch((error) => {
        error('Error showing notification', error);
    });
}

const getAllNotifications = () => self.registration.getNotifications();

const getNotificationByTag = (tag) => {
    return getAllNotifications()
        .then((notifications) => notifications.find((notification) => notification.tag === tag));
}

const cancelAllNotifications = () => {
    return getAllNotifications()
        .then((notifications) => notifications.forEach(e => e.close()));
}

const cancelNotification = (tag) => {
    if (!tag) {
        error('Cancel notification error, no tag provided', tag);
        return;
    }
    return getNotificationByTag(tag).then((notification) => {
        if (notification) {
            return notification.close();
        }
    });
}

const postMessage = (action, type, data, tag) => {
    const message = {
        action: action,
        type: type,
        data: data,
        tag: tag,
    };

    getClients().then(clients => {
        if (clients.length === 0) {
            warn(`No clients to send message with action ${action} to.`);
            return;
        }
        clients.forEach(c => {
            c.postMessage(message);
        });
    });

}

self.addEventListener('message', (event) => {
    handleMessage(event);
});

self.addEventListener('notificationclick', (event) => {
    console.log(`notificationclick event [${event.action}]`, event);
    handleNotificationClick(event);
});

self.addEventListener('notificationclose', (event) => {
    console.log('notificationclose event', event);
    handleNotificationClose(event);
});
if ('serviceWorker' in navigator) {
    window.addEventListener('load', async () => {
        await navigator.serviceWorker.register('./twilio-sw.js').then(value => {
            console.log('Twilio Voice Service worker registered successfully.');
        }).catch((error) => {
            console.warn('Error registering Twilio Service Worker: ' + error.message + '. This prevents notifications from working natively');
        });
    });
}
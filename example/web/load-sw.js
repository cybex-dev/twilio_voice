if ('serviceWorker' in navigator) {
    window.addEventListener('load', async () => {
        // https://github.com/mswjs/msw/issues/98
        if(!navigator.serviceWorker.controller) {
            console.warn('No service worker controller found. This page is not loaded in a service worker context. Will attempt to unregister all service workers and re-register.');
            const registrations = await navigator.serviceWorker.getRegistrations()
            if(registrations.length > 0) {
                console.warn('No service worker controller found, but multiple services worker registrations are present. Unregistering...');
                await Promise.all(registrations.map(r => r.unregister()))
            }
        }
        await navigator.serviceWorker.register('./twilio-sw.js').then(value => {
            console.log('Twilio Voice Service worker registered successfully.');
        }).catch((error) => {
            console.warn('Error registering Twilio Service Worker: ' + error.message + '. This prevents notifications from working natively');
        });
    });
}
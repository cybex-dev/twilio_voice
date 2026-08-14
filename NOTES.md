
# Notes

### Web

Web implementation relies on the [js_notifications](https://pub.dev/packages/js_notifications) package for browser notifications. These notifications including Call functionality is used by a middleware package [web_callkit](https://pub.dev/packages/web_callkit) which provides boilerplate for call management and browser notification integration.

- `js_notifications` (1.0.0+) bundles its service worker with the package and registers it automatically - the `js_notifications-sw.js` file no longer needs to be copied to your web directory. This service worker is used for handling notifications in the background.
- `web_callkit` provides the boilerplate for call management and browser notification integration; since 1.0.0 it relies on the service worker bundled by `js_notifications`, so no files need to be copied into your `web/` folder.

Further, and most importantly the `twilio_voice` package makes use of the [twilio-voice.js](https://github.com/twilio/twilio-voice.js/) SDK.

The Twilio Voice JS SDK (`twilio.min.js`) is **bundled with the plugin** (`assets/twilio.min.js`, served at `assets/packages/twilio_voice/assets/twilio.min.js`) and injected automatically the first time `setTokens(...)` is called - the Dart interop binds to the `window.Twilio` global, and the plugin ensures that global exists before constructing a `Device`. No `<script>` tag or copied file is required in your app's `web/` folder.

If your app already provides its own SDK `<script>` tag, the plugin detects the existing `window.Twilio` global and does not inject a second copy (the self-supplied SDK is not version-checked). Pre-load explicitly with `(TwilioVoicePlatform.instance as TwilioVoiceWeb).ensureSdkLoaded()` if needed. See [README - Web Setup](README.md#web-setup).

The bundled SDK is redistributed under the Apache License 2.0 - see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the version and required notices.

**WASM:** the web implementation uses `dart:js_interop` + `package:web`, so `flutter build web --wasm` is supported (requires Dart >=3.3.0, Flutter >=3.22.0).

### Android

**Package Information:**
> minSdkVersion: 26
> 
> compileSdkVersion: 36

**Gradle:**
> gradle-wrapper: 8.11.1-all
> 
> Android Gradle Plugin (AGP): 8.9.1
> 
> Kotlin: 2.1.0

**Permissions:**
* `android.permission.FOREGROUND_SERVICE`
Required for foreground services on Android 10+ including running foreground services in the background e.g. to capture microphone audio.

* `android.permission.RECORD_AUDIO`
Grants access to the microphone for audio recording, to be used for voice calls.

* `android.permission.READ_PHONE_STATE`
Required for reading the phone state, the phone state is the backbone permission for `ConnectionService` integration. It allows checking active calls, placing new calls, and receiving calls and call state updates. It also allows creating a `PhoneAccount` required for placing calls. If not accepted, any and all incoming calls are rejected immediately upon receiving `CallInvite`.

* `android.permission.READ_PHONE_NUMBERS`
Required for reading phone numbers (e.g. for Telecom App), this is required to create a `PhoneAccount`, see `READ_PHONE_STATE` above.

* `android.permission.CALL_PHONE`
Required for `ConnectionService` to interact with the `TelecomManager` to place outgoing calls.

* `android.permission.MANAGE_OWN_CALLS`
  * Required for `ConnectionService` to interact with the `TelecomManager` to receive incoming calls.
  * According to Android documentation, this permission is only required for self-managed `ConnectionService`'s, however it seems to be required for system-managed `ConnectionService`'s as well (atleast on Android 13 and lower).
  * Finally, this permission seems to be required to place outgoing calls on Android 13 and lower, if not will result `java.lang.SecurityException: Self-managed ConnectionServices require MANAGE_OWN_CALLS permission.`

#### ConnectionService integration
 There are a few (additional) permissions added to use the [system-managed `ConnectionService`](https://developer.android.com/reference/android/telecom/ConnectionService), several permissions are required to enable this functionality (see example app). These permissions  `android.permission.READ_PHONE_STATE`, `android.permission.READ_PHONE_NUMBERS`, `android.permission.RECORD_AUDIO` and `android.permission.CALL_PHONE` have already been added to the package, you do not have to add them. Finally, a [PhoneAccount] is required to interact with the `ConnectionService`, this is discussed in more detail below.


#### Phone Account
Registering of a [PhoneAccount](https://developer.android.com/reference/android/telecom/PhoneAccount)'s are essential to the functionality. This is integrated into the plugin - however it should be noted if the `PhoneAccount` is not registered nor the `Call Account` enabled, the plugin will not function as expected. See [here](https://developer.android.com/reference/android/telecom/PhoneAccount) for more information regarding `PhoneAccount`s.  Logging output will indicate whether any permissions are lacking, or missing.

To register a Phone Account, request access to `READ_PHONE_NUMBERS` permission first.
```dart
TwilioVoice.instance.requestReadPhoneNumbersPermission();
```
then, register the `PhoneAccount`

To open the `Call Account` settings, use the following code:
```dart
   TwilioVoice.instance.openPhoneAccountSettings();
```

alternatively, this could be found in Phone App settings -> Other/Advanced Call Settings -> Calling Accounts -> Twilio Voice (toggle switch)

(if there is a method to programmatically open this, please submit a PR)

#### Android FCM Setup

Android delivers the `com.google.firebase.MESSAGING_EVENT` intent to a **single** resolved service it does **not** "fan out" to every registered `FirebaseMessagingService` as one would expect coming from iOS and their delegates. 
An app can have multiple services listening for the same `MESSAGE_EVENT` intent, but that does not mean the app is configured to work correctly since **Service A** receiving this intent (this time) does not mean **Service B** will be configured to handle the message correctly. 

e.g Using both `awesome_notifications_fcm` and `twilio_voice` will cause this problem. 
 

##### The Fix

To resolve this, edit your class subclassing `FirebaseMessagingService` and forward both messages and token rotations to the plugin:
1. (if you are subclassing `FirebaseMessagingService`), you will need to make two changes: add the following to your `onMessageReceived` and `onNewToken` methods in your subclass of `FirebaseMessagingService`:
```kotlin
override fun onMessageReceived(remoteMessage: RemoteMessage) {
    // Call the TwilioVoiceFcm.handleMessage(...) method to handle the incoming FCM message
    if (TwilioVoiceFcm.handleMessage(this, remoteMessage.data)) {
        // The message was handled by Twilio Voice, no further processing is needed
        return
    }

    // Handle other messages here if needed
}

override fun onNewToken(token: String) {
    // `onNewToken` goes to the same single service as messages, so forward rotations too -
    // without this Twilio keeps the stale binding and incoming calls eventually stop.
    TwilioVoiceFcm.updateToken(this, token)

    // Handle the rotated token for your own services here if needed
}
```
2. If you are not subclassing `FirebaseMessagingService` proceed with standard setup instructions in [Android Setup](README.md#android-setup).
3. If you wish to have a completely custom implementation, you will need to use the `TwilioVoiceFcm.handleMessage(...)` method to handle incoming FCM messages as in option 1 above, but will need to add your own service implementation and register it in your `AndroidManifest.xml` as described in [Android Setup](README.md#android-setup).


#### Android Subclassing FCM

How do I know if my app is using a subclass of `FirebaseMessagingService`?

1. Look in your project's `android/app/src` folder all the way to a `MainActivity.java` or `MainActivity.kt` or similar file. If you see a class that extends `FirebaseMessagingService`, then your app has a subclass of `FirebaseMessagingService`. This means there is the presence of an service implementation which does not mean it **will** be used. To check if it will be used, see 2. 
2. Open your `AndroidManifest.xml` and check for any `<service>` that has an intent filter for `com.google.firebase.MESSAGING_EVENT`. If you find such an entry, associated with the class found above then your app is using a subclass of `FirebaseMessagingService` and it will be used to handle incoming FCM messages. e.g.

```xml
<manifest xmlns:tools="http://schemas.android.com/tools"
    xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:icon="@mipmap/ic_launcher"
        android:label="twilio_voice_example">
      ...
        <service
            android:name="com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService" <!-- <------ This subclasses FirebaseMessagingService-->
            android:exported="false"
            android:stopWithTask="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT" /> <!-- <------ This will receive FCM messages-->
            </intent-filter>
        </service>
      ...
    </application>
</manifest>

```

If the `VoiceFirebaseMessagingService` is not present but instead another service handles FCM messages which is not configured to call `TwilioVoiceFcm.handleMessage(...)`, there is a very high possibility you will not receive any calls. To see how to configure your own service to handle FCM messages, see [Android Setup](README.md#android-setup) and [here](#android-subclassing-fcm) for more insight regarding FCM configuration.

### iOS & macOS

**iOS Pod Information:**
> s.platform = :ios, '13.0'
> 
> s.ios.deployment_target = '13.0'

If you encounter this error
> warning: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to 10.XX, but the range of supported deployment target versions is 10.XY to 13.1.99. (in target 'ABCD' from project 'Pods')

To resolve this:
- open XCode
- browse to your Pods project (left `Project Navigator` drawer, select `Pods` project (there is `Pods` or `Runner`, expand and select `Pods` folder)
- for each pod with the above issue, select the `pod` > then select the `General` tab > and set `Minimum Deployments` to the value to e.g. `10.15` (or whatever the latest version is that you're using in your main project).

You may also add this to your `Podfile` to ensure you don't do this each time:
```
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)

    # Add from here
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.15' # or whatever version you're using
    end
    # to here

  end
end
```

## Limitations

### General

Twilio does not reliably provide a way to determine whether a call was answered elsewhere (e.g. on another device), which unfortunately means any call that is made to a receiving device and is either cancelled early or answered elsewhere will be logged as a missed call. This is a limitation of the Twilio API and not the plugin itself. See [here](https://github.com/twilio/twilio-voice.js/issues/435) for more information.

### Android

Android `ConnectionService` provides the fundamentals to managing calls, including but not limited to call logging. Using a Managed `ConnectionService` means that call logging is handled by the system's "Phone App", and so there is not access or control over call logging at this time.

#### Callback
Further, some native UIs provide a callback feature. This callback feature relies on the system telecom app to callback. However, Twilio being one that requires an access token will not be able to provide a callback feature as the system telecom app will not have access to the Twilio access token. Some work has gone into making this more user-friendly but is not yet available.

### macOS

Clearly, macOS isn't uppermost in mind when looking at a mobile first platform like Flutter. There are some functionality limitations for the platform/interop such as [UIImage](https://docs.flutter.dev/ui/assets-and-images#loading-ios-images-in-flutter) support and Twilio Voice library support as a whole. Hopefully we'll be seeing these implemented in future.

With respect to CallKit integration for macOS, there isn't any direct support for CallKit other than via MacCatalyst which at present is somewhat out of scope for the project at this time.


### Web

As Web uses a custom [WebCallkit](https://github.com/cybex-dev/web_callkit) integration, this facilitates basic call management and browser notification integration. Call logging is not supported at this time.
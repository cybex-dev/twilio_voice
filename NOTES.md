
# Notes

### Web

Web implementation relies on the [js_notifications](https://pub.dev/packages/js_notifications) package for browser notifications. These notifications including Call functionality is used by a middleware package [web_callkit](https://pub.dev/packages/web_callkit) which provides boilerplate for call management and browser notification integration.

- `js_notifications` requires the service worker file `js_notifications-sw.js` to be copied to your web directory. This file is used for handling notifications in the background.
- `web_callkit` provides the boilerplate for call management and browser notification integration, however this package requires both files used in `js_notifications` package.

Further, and most importantly the `twilio_voice` package makes use of custom [twilio_voice.js](https://github.com/twilio/twilio-voice.js/) implementation (these changes are purely to provided Flutter status outputs allowing Flutter to monitor the status of the Twilio Device).

The javascript files required by `twilio_voice` is `twilio.min.js`, which is found in the `example/web` folder. This may in future be loaded dynamically, but for now is required to be provided in the `web/` folder.

### Android

**Package Information:**
> minSdkVersion: 26
> compileSdkVersion: 34

**Gradle:**
> gradle-wrapper: 8.2.1-all

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

### iOS & macOS

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

### Android

Android `ConnectionService` provides the fundamentals to managing calls, including but not limited to call logging. Using a Managed `ConnectionService` means that call logging is handled by the system's "Phone App", and so there is not access or control over call logging at this time.

### macOS

Clearly, macOS isn't uppermost in mind when looking at a mobile first platform like Flutter. There are some functionality limitations for the platform/interop such as [UIImage](https://docs.flutter.dev/ui/assets-and-images#loading-ios-images-in-flutter) support and Twilio Voice library support as a whole. Hopefully we'll be seeing these implemented in future.

With respect to CallKit integration for macOS, there isn't any direct support for CallKit other than via MacCatalyst which at present is somewhat out of scope for the project at this time.


### Web

As Web uses a custom [WebCallkit](https://github.com/cybex-dev/web_callkit) integration, this facilitates basic call management and browser notification integration. Call logging is not supported at this time.
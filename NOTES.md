# Notes

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

* `android.permission.POST_NOTIFICATIONS`
Required for displaying incoming call notifications on Android 13+.

* `android.permission.READ_PHONE_STATE`
Required for reading the phone state, the phone state is the backbone permission for `ConnectionService` integration. It allows checking active calls, placing new calls, and receiving calls and call state updates. It also allows creating a `PhoneAccount` required for placing calls. If not accepted, any and all incoming calls are rejected immediately upon receiving `CallInvite`.

* `android.permission.READ_PHONE_NUMBERS`
Required for reading phone numbers (e.g. for Telecom App), this is required to create a `PhoneAccount`, see `READ_PHONE_STATE` above.

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

### macOS

Clearly, macOS isn't uppermost in mind when looking at a mobile first platform like Flutter. There are some functionality limitations for the platform/interop such as [UIImage](https://docs.flutter.dev/ui/assets-and-images#loading-ios-images-in-flutter) support and Twilio Voice library support as a whole. Hopefully we'll be seeing these implemented in future.
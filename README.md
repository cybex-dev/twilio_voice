# twilio_voice

Provides an interface to Twilio's Programmable Voice SDK to allow voice-over-IP (VoIP) calling into your Flutter applications.
This plugin was taken from the original flutter_twilio_voice, as it seems that plugin is no longer maitained, this one is.

## Features
- Receive and place calls from iOS devices, uses callkit to receive calls.
- Receive and place calls from Android devices, uses custom UI to receive calls.


### Android Limitations

As iOS has CallKit, an Apple provided UI for answering calls, there is no default UI for android to receive calls, for this reason a default UI was made. To increase customization, the UI will use a splash_icon.png registered on your res/drawable folder. I havent found a way to customize colors, if you find one, please submit a pull request.

### Setup
Please follow Twilio's quickstart setup for each platform, you dont need to write the native code but it will help you undestand the basic functionality of setting up your server, registering your iOS app for VOIP, etc.

### iOS Setup

To customize the icon displayed on a CallKit call, Open XCode and add a png icon named 'callkit_icon' to your assets.xassets folder

### Android Setup:
register in your `AndroidManifest.xml` the service in charge of displaying incomming call notifications:

``` xml
<Application>
  .....
  <service
      android:name="com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService"
      android:stopWithTask="false">
      <intent-filter>
          <action android:name="com.google.firebase.MESSAGING_EVENT" />
      </intent-filter>
  </service>
```


### Usage

The plugin was separated into two classes, the `TwilioVoice.instance` and `TwilioVoice.instance.call`, the first one is in charge of general configuration and the second one is in charge of managing calls.

Register iOS capabilities 
- Add Audio and Voice over IP in background modes

### TwilioVoice.instance


#### Setting the tokens

call `TwilioVoice.instance.setTokens` as soon as your app starts.
- `accessToken` provided from your server, you can see an example cloud function [here](https://github.com/diegogarciar/twilio_voice/blob/master/functions.js).
- `deviceToken` is automatically handled on iOS, for android you need to pass a FCM token.

call `TwilioVoice.instance.unregister` to unregister from Twilio, if no access token is passed, it will use the token provided in `setTokens` at the same session.



### Call Identifier
As incomming call UI is shown in background and the App can even be closed when receiving the calls, you can map call identifiers such as `firebaseAuth` userIds to real names, this operation must be done before actially receiving the call. So if you have a chat app, and know the members names, register them so when they call, the call UI can display their names and not their userIds.


#### Registering a client
```
TwilioVoice.instance.registerClient(String clientId, String clientName)
```

#### Unegistering a client
```
TwilioVoice.instance.unregisterClient(String clientId)
```

#### Default caller
You can also set a dafault caller, such as "unknown number" or "chat friend" in case a call comes in from an unregistered client.

```
TwilioVoice.instance.setDefaultCallerName(String callerName)
```

### Call Events
use stream `TwilioVoice.instance.callEventsListener` to receive events from the TwilioSDK such as call events and logs, it is a broadcast so you can listen to it on different parts of your app. Some events might be missed when the app has not launched, please check out the example project to find the workarounds.

The events sent are the following
- ringing
- connected
- callEnded
- unhold
- hold
- unmute
- mute
- speakerOn
- speakerOff
- log
- answer

## showMissedCallNotifications
By default a local notification will be shown to the user after missing a call, clicking on the notification will call back the user. To remove this feature, set `showMissedCallNotifications` to `false`.



### Calls


#### Make a Call
`from` your own identifier
`to` the id you want to call
use `extraOptions` to pass additional variables to your server callback function.
```
 await TwilioVoice.instance.call.place(from:myId, to: clientId, extraOptions)
                   ;

```

#### Mute a Call

```
 TwilioVoice.instance.call.toggleMute(isMuted: true);

```

#### Toggle Speaker

```
 TwilioVoice.instance.call.toggleSpeaker(speakerIsOn: true);

```

#### Hang Up

```
 TwilioVoice.instance.call.hangUp();

```

#### Send Digits

```
 TwilioVoice.instance.call.sendDigits(String digits);

```


### Permissions

#### Microphone
To receive and place calls you need Microphone permisisons, register the micropohone permission in your info.plist for iOS.

You can use `TwilioVoice.instance.hasMicAccess` and `TwilioVoice.instance.requestMicAccess` to check and request the permission. Permissions is also automatically requested when receiving a call.

#### Background calls (Android only on some devices)
Xiami devices, and maybe others, need a spetial permission to receive background calls. use `TwilioVoice.instance.requiresBackgroundPermissions` to check if your device requires a special permission, if it does, show a rationale explaining the user why you need the permisison. Finally call 
`TwilioVoice.instance.requestBackgroundPermissions` which will take the user to the App Settings page to enable the permission.


### Localization
Because some of the UI is in native code, you need to localize those strings natively in your project. You can find in the example project localization for spanish, PRs are welcome for other languages.

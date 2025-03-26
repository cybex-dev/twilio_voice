# twilio_voice

Provides an interface to Twilio's Programmable Voice SDK to allow voice-over-IP (VoIP) calling into
your Flutter applications.
~~This plugin was taken from the original `flutter_twilio_voice` as it seems that plugin is no longer maintained, this one is.~~  Project ownership & maintenance handed over by [diegogarcia](https://github.com/diegogarciar). For the foreseeable future, I'll be actively maintaining this project.

#### 🐞Bug? Issue? Something odd?

Report it [here](https://github.com/cybex-dev/twilio_voice/issues/new?assignees=&labels=type:Bug,status:Unconfirmed&projects=&template=BUG_REPORT.md&title=).

#### 🚀 Feature Requests?

Any and all [Feature Requests](https://github.com/cybex-dev/twilio_voice/issues/new?assignees=&labels=type:Enhancement&projects=&template=FEATURE_REQUEST.md&title=) or Pull Requests are gladly welcome!

#### Live Example/Samples:

- [Twilio Voice Web](https://twilio-voice-web.web.app/#/)

*Currently, only Web sample is provided. If demand arises for a Desktop or Mobile builds, I'll throw one up on the relevant store/app provider or make one available.*

## Features

- Receive and place calls from iOS devices, uses Callkit to receive calls (Twilio Voice SDK [v6.13.0](https://www.twilio.com/docs/voice/sdks/ios/changelog#6130)).
- Receive and place calls from Android devices, uses ~~custom UI~~ native call screen to receive calls (via a `ConnectionService` impl) (Twilio Voice SDK [v6.9.0](https://www.twilio.com/docs/voice/sdks/android/3x-changelog#690)).
- Receive and place calls from Web (FCM push notification integration not yet supported by Twilio Voice Web, see [here](https://github.com/twilio/twilio-voice.js/pull/159#issuecomment-1551553299) for discussion)
- Receive and place calls from MacOS devices, uses custom UI to receive calls (in future & macOS
  13.0+, we'll be using CallKit).
- Interpret TwiML parameters to populate UI, see below [Interpreting Parameters](#interpreting-parameters)

### Feature addition schedule:

- Audio device selection support (select input/output audio devices, on-hold)
- Update plugin to Flutter federated packages (step 1 of 2 with Web support merge)
- Desktop platform support (implementation as JS wrapper/native implementation, Windows/Linux to start development)

### Android Limitations

~~As iOS has CallKit, an Apple provided UI for answering calls, there is no default UI for android to
receive calls, for this reason a default UI was made. To increase customization, the UI will use a
splash_icon.png registered on your res/drawable folder. I haven't found a way to customize colors,
if you find one, please submit a pull request.~~

Android provides a native UI by way of the `ConnectionService`. Twilio has made an attempt a [ConnectionService](https://github.com/twilio/voice-quickstart-android/tree/master/app/src/connection_service) implementation however it is fully realized in this package.

### macOS Limitations

1. CallKit support is found in macOS 13.0+ which there is no support for yet. In future, this will
   be taken into consideration for feature development.
2. Twilio Voice does not offer a native SDK for macOS, so we're using the Twilio Voice Web SDK (
   twilio-voice.js, v2.4.1-dev) to provide the functionality. This is a temporary solution until (or
   even if) Twilio Voice SDK for macOS is released.

This limits macOS to not support remote push notifications `.voip` and `.apns` as the web SDK does
not support this. Instead, it uses a web socket connection to listen for incoming calls, arguably
more efficient vs time but forces the app to be open at all times to receive incoming calls.

## Getting Started

First, add the package to your `pubspec.yaml` file:

```yaml
dependencies:
  ...
  twilio_voice: ^0.2.0+1
```

Then run `flutter pub get` in your terminal.

Please follow Twilio's quickstart setup for each platform, you don't need to write the native code
but it will help you understand the basic functionality of setting up your server, registering your
iOS app for VOIP, etc.

### iOS Setup

To customize the icon displayed on a CallKit call, Open XCode and add a png icon named '
callkit_icon' to your assets.xassets folder

see [[Notes]](https://github.com/diegogarciar/twilio_voice/blob/master/NOTES.md#ios--macos) for more information

### macOS Setup

Drop in addition.

see [[Limitations]](https://github.com/diegogarciar/twilio_voice/blob/master/NOTES.md#macos) and [[Notes]](https://github.com/diegogarciar/twilio_voice/blob/master/NOTES.md#ios--macos) for more information.

### Android Setup:

Firstly, ensure you place this in your app's proguard-rules.pro file:
```proguard
# Twilio Programmable Voice
-keep class com.twilio.** { *; }
-keep class tvo.webrtc.** { *; }
-dontwarn tvo.webrtc.**
-keep class com.twilio.voice.** { *; }
-keepattributes InnerClasses
```

next, register in your `AndroidManifest.xml` the service in charge of displaying incoming call
notifications:

```xml
<Application>
 .....
 <service
 android:name="com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService"
 android:stopWithTask="false">
<intent-filter> <action android:name="com.google.firebase.MESSAGING_EVENT" />
</intent-filter> </service>
```

#### Phone Account

To register a Phone Account, request access to `READ_PHONE_NUMBERS` permission first:

```dart
TwilioVoice.instance.requestReadPhoneNumbersPermission();  // Gives Android permissions to read Phone Accounts
```

then, register the `PhoneAccount` with:

```dart
TwilioVoice.instance.registerPhoneAccount();
```

#### Enable calling account

To open the `Call Account` settings, use the following code:

```dart
TwilioVoice.instance.openPhoneAccountSettings();
```

Check if it's enabled with:

```dart
TwilioVoice.instance.isPhoneAccountEnabled();
```

#### Calling with ConnectionService

Placing a call with Telecom app via Connection Service requires a `PhoneAccount` to be registered. See [Phone Account](#phone-account) above for more information.

Finally, to grant access to place calls, run:

```dart
TwilioVoice.instance.requestCallPhonePermission();  // Gives Android permissions to place calls
```

See [Customizing the Calling Account](#customizing-the-calling-account) for more information.

#### Enabling the ConnectionService

To enable the `ConnectionService` and make/receive calls, run:

```dart
TwilioVoice.instance.requestReadPhoneStatePermission();  // Gives Android permissions to read Phone State
```

Highly recommended to review the notes for **Android**. See [[Notes]](https://github.com/diegogarciar/twilio_voice/blob/master/NOTES.md#android) for more information.

#### Customizing the Calling Account

To customize the `label` and `shortDescription` of the calling account, add the following in your `res/values/strings.xml`:

```xml
<string name="phone_account_name" translatable="false">Example App</string>
<string name="phone_account_desc" translatable="false">Example app voice calls calling account</string>
```

This can be found in alternatively the Phone App's settings, `Other/Advanced Call Settings -> Calling Accounts -> (Example App)` (then toggle the switch)

![enter image description here](https://camo.githubusercontent.com/f483d950b603c08d07f566849b06c489ef8331919b8b50b6cb5b94f92d2a29be/68747470733a2f2f692e696d6775722e636f6d2f366d686a46575a2e676966)

See [example](https://github.com/cybex-dev/twilio_voice/blob/master/example/android/app/src/main/res/values/strings.xml) for more details

#### Known Issues

##### Bluetooth, Telecom App Crash

- Upon accepting an inbound call, at times the Telecom app/ Bluetooth service will crash and restart. This is a known bug, caused by `Class not found when unmarshalling: com.twilio.voice.CallInvite`. This is due to the Telecom service not using the same Classloader as the main Flutter app. See [here](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/telecomm/java/android/telecom/Call.java#2466) for source of error.
- Callback action on post dialer screen may not work as expected - this is platform and manufacturer specific. PRs are welcome here.
- Complete integration with showing missed calls. This is a work in progress.

### Web Setup:

There are 4 important files for Twilio incoming/missed call notifications to work:

- `notifications.js` is the main file, it handles the notifications and the service worker.
- `twilio-sw.js` is the service worker _content_ used to work with the default `flutter_service_worker.js` (this can be found in `build/web/flutter_service_worker.js` after calling `flutter build web`). This file's contents are to be copied into the `flutter_service_worker.js` file after you've built your application.

Also, the twilio javascript SDK itself, `twilio.min.js` is needed.

### To ensure proper/as intended setup:

1. Copy files `example/web/notifications.js` and `example/web/twilio.min.js` into your application's `web` folder.
2. This step should be done AFTER you've built your application, every time the `flutter_service_worker.js` changes (this includes hot reloads on your local machine unfortunately)
   1. Copy the contents of `example/web/twilio-sw.js` into your `build/web/flutter_service_worker.js` file, **at the end of the file**. See [service-worker](#service-worker) for more information.

Note, these files can be changed to suite your needs - however the core functionality should remain the same: responding to `notificationclick`, `notificationclose`, `message` events and associated sub-functions.

Finally, add the following code to your `index.html` file, **at the end of body tag**:

```html
    <body>
        <!--Start Twilio Voice impl-->
        <!--twilio native js library-->
        <script type="text/javascript" src="./twilio.min.js"></script>
        <!--End Twilio Voice impl-->

        <script>
            window.addEventListener('load', function(ev) {
              // Download main.dart.js
              ...          
    </body>
```

#### Web Considerations

_If you need to debug the service worker, open up Chrome Devtools, go to Application tab, and select Service Workers from the left menu. There you can see the service workers and their status.
To review service worker `notificationclick`, `notificationclose`, `message`, etc events - do this using Chrome Devtools (Sources tab, left panel below 'site code' the service workers are listed)_

##### Service Worker

Unifying the service worker(s) is best done via post-compilation tools or a CI/CD pipeline (suggested).

A snippet of the suggested service worker integration is as follows:

```yaml
#...
- run: cd ./example; flutter build web --release --target=lib/main.dart --output=build/web

- name: Update service worker
  run: cat ./example/web/twilio-sw.js >> ./example/build/web/flutter_service_worker.js
#...
```

A complete example could be found in the github workflows `.github/workflows/flutter.yml` file, see [here](https://github.com/cybex-dev/twilio_voice/blob/master/.github/workflows/flutter.yml). 

##### Web Notifications

2 types of notifications are shown:
 - Incoming call notifications with 2 buttons: `Answer` and `Reject`,
 - Missed call notifications with 1 button: `Call back`.

Notifications are presented as **alerts**. These notifications may not always been shown, check:
 - if the browser supports notifications,
 - if the user has granted permissions to show notifications,
 - if the notifications display method / notifications is enabled by the system (e.g. macOS notifications are disabled, or Windows notifications are disabled, etc).
 - if there are already notifications shown (https://stackoverflow.com/a/36383155/4628115)
 - if system is in 'Do Not Disturb' or 'Focus' mode.

### MacOS Setup:

The plugin is essentially a [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
wrapper. This makes macOS integration a drop-in solution.

However, you'll need to:

1. add the following to your `Info.plist` file:

   ```xml
   <key>NSMicrophoneUsageDescription</key>
   <string>Allow microphone access to make calls</string>
   ```
2. include Hardened Runtime entitlements (this is required for App Store distributed MacOS apps):

   ```xml
   <key>com.apple.security.audio-input</key>
   <true/>

   <!--Optionally for bluetooth support/permissions-->
   <key>com.apple.security.device.bluetooth</key>
   <true/>
   ```
3. Lastly and most importantly, ensure the `index.html` and `twilio.min.js` is bundled inside of `twilio_voice` package (this
   shouldn't be a problem, but just in case). Found in `twilio_voice.../.../Classes/Resources/*`.

See [this](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution#3087727)
for more information on preparing for publishing your macOS app

### Usage

The plugin was separated into two classes, the `TwilioVoice.instance`
and `TwilioVoice.instance.call`, the first one is in charge of general configuration and the second
one is in charge of managing calls.

Register iOS capabilities

- Add Audio and Voice over IP in background modes

### TwilioVoice.instance

#### Setting the tokens

call `TwilioVoice.instance.setTokens` as soon as your app starts.

- `accessToken` provided from your server, you can see an example cloud
  function [here](https://github.com/diegogarciar/twilio_voice/blob/master/functions.js).
- `deviceToken` is automatically handled on iOS, for android you need to pass a FCM token.

call `TwilioVoice.instance.unregister` to unregister from Twilio, if no access token is passed, it
will use the token provided in `setTokens` at the same session.

### Call Identifier

As incoming call UI is shown in background and the App can even be closed when receiving the calls,
you can map call identifiers such as `firebaseAuth` userIds to real names, this operation must be
done before actually receiving the call. So if you have a chat app, and know the members names,
register them so when they call, the call UI can display their names and not their userIds.

#### Registering a client

```
TwilioVoice.instance.registerClient(String clientId, String clientName)
```

#### Unregistering a client

```
TwilioVoice.instance.unregisterClient(String clientId)
```

#### Default caller

You can also set a default caller, such as "unknown number" or "chat friend" in case a call comes in
from an unregistered client.

```
TwilioVoice.instance.setDefaultCallerName(String callerName)
```

### Call Events

use stream `TwilioVoice.instance.callEventsListener` to receive events from the TwilioSDK such as
call events and logs, it is a broadcast so you can listen to it on different parts of your app. Some
events might be missed when the app has not launched, please check out the example project to find
the workarounds.

The events sent are the following

- incoming // web, MacOS only
- ringing
- connected
- reconnected
- reconnecting
- callEnded
- unhold
- hold
- unmute
- mute
- speakerOn
- speakerOff
- log
- declined (based on Twilio Error codes, or remote abort)
- answer
- missedCall
- returningCall
- permission (Android only)

### Interpreting Parameters

As a convenience, the plugin will interpret the TwiML parameters and send them as a map in the `CallInvite` or provided via `extraOptions` when creating the call. This is useful for passing additional information to the call screen and are prefixed with `__TWI`.

- `__TWI_CALLER_ID` - caller id
- `__TWI_CALLER_NAME` - caller name
- `__TWI_CALLER_URL` - caller image/thumbnail url (not implemented/supported at the moment)
- `__TWI_RECIPIENT_ID` - recipient id
- `__TWI_RECIPIENT_NAME` - recipient name
- `__TWI_RECIPIENT_URL` - recipient image/thumbnail url (not implemented/supported at the moment)
- `__TWI_SUBJECT` - subject/additional info

These parameters above are interpreted as follows.

#### Name resolution

Caller is usually referred to as `call.from` or `callInvite.from`. This can either be a number of a string (with the format `client:clientName`) or null.

The following rules are applied to determine the caller/recipient name, which is shown in the call screen and heads-up notification:

##### Incoming Calls:

`__TWI_CALLER_NAME` -> `resolve(__TWI_CALLER_ID)` -> (phone number) -> `registered client (from)` -> `defaultCaller name` -> `"Unknown Caller"`


##### Outgoing Calls:

`__TWI_RECIPIENT_NAME` -> `resolve(__TWI_RECIPIENT_ID)` -> (phone number) -> `registered client (to)` -> `defaultCaller name` -> `"Unknown Caller"`

**Details explaination:**

- if the call is an CallInvite (incoming), the plugin will interpret the string as follows or if the call is outgoing, the twilio `To` parameter field is used to:
  - if the `__TWI_CALLER_NAME` (or `__TWI_RECIPIENT_NAME`) parameter is provided, the plugin will show the value of `__TWI_CALLER_NAME` (or `__TWI_RECIPIENT_NAME`) as is, else
  - if the `__TWI_CALLER_ID` (or `__TWI_RECIPIENT_ID`) parameter is provided, the plugin will search for a registered client with the same id and show the client name,
- if the caller (`from` or `to` fields) is empty/not provided, the default caller name is shown e.g. "Unknown Caller", else
- else if the caller (`from` or `to` fields) is a number, the plugin will show the number as is, else
- else the plugin will search for a registered client with the `callInvite.from` (or call.to) value and show the client name, as a last resort
  - the default caller name is shown e.g. "Unknown Caller"

*Please note: the same approach applies to both caller and recipient name resolution.*

#### Subject

Using the provided `__TWI_SUBJECT` parameter, the plugin will show the subject as is, else (depending on the platform and manufacturer), the plugin will show:

- the caller name as the subject, or
- the app name as the subject, or
- the default subject "Incoming Call"

## showMissedCallNotifications

By default a local notification will be shown to the user after missing a call, clicking on the
notification will call back the user. To remove this feature, set `showMissedCallNotifications`
to `false`.

### Calls

#### Make a Call

`from` your own identifier
`to` the id you want to call
use `extraOptions` to pass additional variables to your server callback function.

```
 await TwilioVoice.instance.call.place(from:myId, to: clientId, extraOptions);

```

These translate to the your TwiML `event` function/service as:

*javascript sample*

```javascript
exports.handler = function(context, event, callback) {
    const from = event.From;
    const to = event.To;
    // event contains extraOptions as a key/value map

    // your TwiML code...
}
```

See [Setting up the Application](#setting-up-the-application) for more information.

*Please note: the hardcoded `To`, `From` may change in future.*

#### Receiving Calls

##### iOS

Receives calls via [CallKit](https://developer.apple.com/documentation/callkit) integration. Make sure to review the [iOS Setup](#ios-setup) section for more information.

##### Android

Receives calls via [ConnectionService](https://developer.android.com/reference/android/telecom/ConnectionService) integration. Make sure to review the [Android Setup](#android-setup) section for more information.

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

To receive and place calls you need Microphone permissions, register the microphone permission in
your info.plist for iOS.

You can use `TwilioVoice.instance.hasMicAccess` and `TwilioVoice.instance.requestMicAccess` to check
and request the permission. Permissions is also automatically requested when receiving a call.

#### Background calls (Android only on some devices)

~~Xiaomi devices, and maybe others, need a special permission to receive background calls.
use `TwilioVoice.instance.requiresBackgroundPermissions` to check if your device requires a special
permission, if it does, show a rationale explaining the user why you need the permission. Finally
call
`TwilioVoice.instance.requestBackgroundPermissions` which will take the user to the App Settings
page to enable the permission.~~

Deprecated in 0.10.0, as it is no longer needed. Custom UI has been replaced with native UI.

#### ConnectionService & Native Phone Account (Android only)

Similar to CallKit on iOS, Android implements their own via a [ConnectionService](https://developer.android.com/reference/android/telecom/ConnectionService) integration. To make use of this, you'll need to request `CALL_PHONE` permissions via:

```dart
TwilioVoice.instance.requestCallPhonePermission();  // Gives Android permissions to place outgoing calls
TwilioVoice.instance.requestReadPhoneStatePermission();  // Gives Android permissions to read Phone State including receiving calls
TwilioVoice.instance.requestReadPhoneNumbersPermission();  // Gives Android permissions to read Phone Accounts
TwilioVoice.instance.requestManageOwnCallsPermission();  // Gives Android permissions to manage calls, this isn't necessary to request as the permission is simply required in the Manifest, but added nontheless.
```

Following this, to register a Phone Account (required by all applications implementing a system-managed `ConnectionService`, run:

```dart
TwilioVoice.instance.registerPhoneAccount();  // Registers the Phone Account
TwilioVoice.instance.openPhoneAccountSettings();  // Opens the Phone Account settings

// After the account is enabled, you can check if it's enabled with:
TwilioVoice.instance.isPhoneAccountEnabled();  // Checks if the Phone Account is enabled
```

This last step can be considered the 'final check' to make/receive calls on Android.

**Permissions not granted?**

Finally, a consideration for not all (`CALL_PHONE`) permissions granted on an Android device. The following feature is available on Android only:

```dart
TwilioVoice.instance.rejectCallOnNoPermissions({Bool = false}); // Rejects incoming calls if permissions are not granted
TwilioVoice.instance.isRejectingCallOnNoPermissions(); // Checks if the plugin is rejecting calls if permissions are not granted
```

If the `CALL_PHONE` permissions group i.e. `READ_PHONE_STATE`, `READ_PHONE_NUMBERS`, `CALL_PHONE` aren't granted nor a Phone Account is registered and enabled, the plugin will either reject the incoming call (true) or not show the incoming call UI (false).

_Note: If `MANAGE_OWN_CALLS` permission is not granted, outbound calls will not work._

See [Android Setup](#android-setup) and [Android Notes](https://github.com/diegogarciar/twilio_voice/blob/master/NOTES.md#android) for more information regarding configuring the `ConnectionService` and registering a Phone Account.

### Localization

Because some of the UI is in native code, you need to localize those strings natively in your
project. You can find in the example project localization for spanish, PRs are welcome for other
languages.

---

## Twilio Setup/Quickstart Help

Twilio makes use of cloud functions to generate access tokens and sends them to your app. Further,
Twilio makes use of their own apps called TwiML apps to handle calling functions, etc

There are 2 major components to get Twilio Setup.

1. Cloud functions (facility generating **access tokens** and then **handling call requests**)
2. Mobile app that receives/updates tokens and performs the actual calls (see above)

---

### 1) Cloud Functions

Cloud functions can be separated or grouped together. The main 2 components are:

- generate access tokens
- `make-call` endpoint to actually place the call

You can host both in firebase, in TwiML apps or a mixture. The setup below assumes a mixture, where
Firebase Functions hosts the `access-token` for easy integration into Flutter and TwiML hosting
the `make-call` function.

## Cloud-Functions-Step-1: Create your TwiML app

This will allow you to actually place the call

Prerequisites
-------------

* A Twilio Account. Don't have one? [Sign up](https://www.twilio.com/try-twilio) for free!

## Setting up the Application

Grab [this](https://github.com/twilio/voice-quickstart-server-node) project from github, the sample
TwiML app.

```bash
cp .env.example .env
```

Edit `.env` with the three configuration parameters we gathered from above.

**See configure environment below for details**

Next, we need to install our dependencies from npm:

```bash
npm install
```

To make things easier for you, go into the `src/` folder, rename the `server.js` file to `make-call`
. This assumes each function will have its own file which for a new project isn't a bad idea.

Then add the following code:

```javascript
const AccessToken = require('twilio').jwt.AccessToken;
const VoiceGrant = AccessToken.VoiceGrant;
const VoiceResponse = require('twilio').twiml.VoiceResponse;

/**
 * Creates an endpoint that can be used in your TwiML App as the Voice Request Url.
 * <br><br>
 * In order to make an outgoing call using Twilio Voice SDK, you need to provide a
 * TwiML App SID in the Access Token. You can run your server, make it publicly
 * accessible and use `/makeCall` endpoint as the Voice Request Url in your TwiML App.
 * <br><br>
 *
 * @returns {Object} - The Response Object with TwiMl, used to respond to an outgoing call
 * @param context
 * @param event
 * @param callback
 */
exports.handler = function(context, event, callback) {
    // The recipient of the call, a phone number or a client

    console.log(event);
    const from = event.From;
    let to = event.to;
    if(isEmptyOrNull(to)) {
        to = event.To;
        if(isEmptyOrNull(to)) {
            console.error("Could not find someone to call");
            to = undefined;
        }
    }


    const voiceResponse = new VoiceResponse();

    if (!to) {
        voiceResponse.say("Welcome, you made your first call.");
    } else if (isNumber(to)) {
      const dial = voiceResponse.dial({callerId : callerNumber});
      dial.number(to);
  } else {
        console.log(`Calling [${from}] -> [${to}]`)

        const dial = voiceResponse.dial({callerId: to, timeout: 30, record: "record-from-answer-dual", trim: "trim-silence"});
        dial.client(to);
    }

    callback(null, voiceResponse);
}

const isEmptyOrNull = (s) => {
    return !s || s === '';
}
```

### Setup Twilio CLI

Ensure you are logged into `twilio-cli`. First, install `twilio-cli` with

```javascript
npm i twilio-cli -g
```

Afterwards, login to twilio using: (b sure to provide Twilio account SID and auth token for login):

```javascript
twilio login
```

We need to generate an app, this will give us an App SID to use later in firebase functions, (
see [this](https://github.com/twilio/voice-quickstart-ios#3-create-a-twiml-application-for-the-access-token)
more info)

### Create TwiML app

We need to create a TwiML app that will allow us to host a `make-call` function:

```bash
twilio api:core:applications:create \
--friendly-name=my-twiml-app \
--voice-method=POST \
--voice-url="https://my-quickstart-dev.twil.io/make-call"
```

This will present you with a application SID in the format ```APxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx```,
we will use this later in firebase config and generating push credential keys.

**Very Important!** The URL given here `https://my-quickstart-dev.twil.io/make-call` won't work for
you. Once you deployed your TwiML application (later), a URL is given to you (on first deploy) which
you need to copy and paste as your **Request URL** call. If you don't do this, calling won't work!

### Configure environment

ensure you have a `.env` file in the root of your project in the same directory as `package.json`

next, edit the `.env` file in the format

```bash
ACCOUNT_SID=(insert account SID)
APP_SID=(insert App SID, found on TwiML app or the APxxxxx key above)
```

`API_KEY` and `API_KEY_SECRET` aren't necessary here since we won't be using them

#### Get Push Credential:

**We will generate them a bit later**

- Android
  FCM: [Android instructions](https://github.com/twilio/voice-quickstart-android#7-create-a-push-credential-using-your-fcm-server-key)
- Apple
  APNS: [Apple instructions](https://github.com/twilio/voice-quickstart-ios#6-create-a-push-credential-with-your-voip-service-certificate)

You will get a Push Credential SID in the format: `CRxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`, use this
in `PUSH_CREDENTIAL_SID`

### Deploying

Now lets deploy.

#### Please note:  Check you have configured your environment first

Navigate to root directory, and deploy using

```javascript
twilio serverless:deploy
```

**Very Important!**: once complete (if you haven't done so), make sure to add the `make-call`
endpoint your Twilio app's `Request URL` in the main Twilio page. This URL will be shown as part of
the deployment text. If this isn't done, calling won't work!

### Cloud-Functions-Step-2: Setup Firebase & Configuration

Twilio's configurations are stored in `.runtimeconfig.json` which contains:

"auth_token": "",
"account_sid": "",
"app_sid": "",
"phone": "",
"api_key": "",
"api_key_secret": "",
"android_push_credential": "",
"apple_push_credential_debug": "",
"apple_push_credential_release": ""
_**Note:** this is used for local emulator testing, but you need to deploy these to your firebase
function application once you are ready to go live. If you don't, this won't work!_

**Push Credentials** are created once (for iOS, Android) and used to generate `access-token`s, a
callback function for all Twilio apps to use for their communication.

---

Below are the 3 operations you need to run to generate push credentials that should be added into
the `.runtimeconfig.json` above

##### Android

To generate Android push credentials, get the Cloud Messaging server key from Firebase FCM, and add
it to the following:

```
twilio api:chat:v2:credentials:create \
--type=fcm \
--friendly-name="voice-push-credential-fcm" \
--secret=SERVER_KEY_VALUE
```
and then place into the field: `android_push_credential` above

This generated a push credential SID in the format `CRxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` which must
be used to generate access tokens for android devices.

see for more
info: https://github.com/twilio/voice-quickstart-android#7-create-a-push-credential-using-your-fcm-server-key

##### iOS

Similar to Android, but more steps including using .p12 certificates. To get these certificates,
login into [Apple's developer site](https://developer.apple.com/) and go to
the [certificates page](https://developer.apple.com/account/resources/certificates/list). You need
to generate a VoIP Services certificate as shown below.

![voip_services.png](images/voip_services.png)

**Please note:** there are 2 different modes: sandbox and production.

**- SandBox Mode**

Using sandbox VoIP certificate:

> Export your VoIP Service Certificate as a .p12 file from Keychain Access and extract the
> certificate and private key from the .p12 file using the openssl command.

```
$ openssl pkcs12 -in PATH_TO_YOUR_SANDBOX_P12 -nokeys -out sandbox_cert.pem -nodes
$ openssl pkcs12 -in PATH_TO_YOUR_SANDBOX_P12 -nocerts -out sandbox_key.pem -nodes
$ openssl rsa -in sandbox_key.pem -out sandbox_key.pem
```
Using sandbox certificates, generate credential:

```
twilio api:chat:v2:credentials:create \
--type=apn \
--sandbox \
--friendly-name="voice-push-credential (sandbox)" \
--certificate="$(cat PATH_TO_SANDBOX_CERT_PEM)" \
--private-key="$(cat PATH_TO_SANDBOX_KEY_PEM)"
```
then place it into the field `apple_push_credential_debug`

**- Production Mode**

Using production VoIP certificate:

> Export your VoIP Service Certificate as a .p12 file from Keychain Access and extract the
> certificate and private key from the .p12 file using the openssl command.

```
$ openssl pkcs12 -in PATH_TO_YOUR_P12 -nokeys -out prod_cert.pem -nodes
$ openssl pkcs12 -in PATH_TO_YOUR_P12 -nocerts -out prod_key.pem -nodes
$ openssl rsa -in prod_key.pem -out prod_key.pem
```
Using production certificates, generate credential:

```
twilio api:chat:v2:credentials:create \
--type=apn \
--friendly-name="voice-push-credential (production)" \
--certificate="$(cat PATH_TO_PROD_CERT_PEM)" \
--private-key="$(cat PATH_TO_PROD_KEY_PEM)"
```
then place it into the field `apple_push_credential_release`

see for more
info: https://github.com/twilio/voice-quickstart-ios#6-create-a-push-credential-with-your-voip-service-certificate

---

## Cloud-Functions-Step-3: Generate access tokens via cloud function

`HTTP/GET api-voice-accessToken`

To generate **access-tokens**, the following firebase function is used:

_**Please Note** the default time is 1 hour token validity._

See for more
info: https://github.com/twilio/voice-quickstart-android/blob/master/Docs/access-token.md

**Firebase Cloud Function: access-token**

```javascript
const { AccessToken } = require('twilio').jwt;
const functions = require('firebase-functions');

const { VoiceGrant } = AccessToken;

/**
 * Creates an access token with VoiceGrant using your Twilio credentials.
 *
 * @param {Object} request - POST or GET request that provides the recipient of the call, a phone number or a client
 * @param {Object} response - The Response Object for the http request
 * @returns {string} - The Access Token string and expiry date in milliseconds
 */
exports.accessToken = functions.https.onCall((payload, context) => {
    // Check user authenticated
    if (typeof (context.auth) === 'undefined') {
        throw new functions.https.HttpsError('unauthenticated', 'The function must be called while authenticated');
    }
    let userId = context.auth.uid;

    console.log('creating access token for ', userId);

    //configuration using firebase environment variables
    const twilioConfig = functions.config().twilio;
    const accountSid = twilioConfig.account_sid;
    const apiKey = twilioConfig.api_key;
    const apiSecret = twilioConfig.api_key_secret;
    const outgoingApplicationSid = twilioConfig.app_sid;

    // Used specifically for creating Voice tokens, we need to use seperate push credentials for each platform.
    // iOS has different APNs environments, so we need to distinguish between sandbox & production as the one won't work in the other.
    let pushCredSid;
    if (payload.isIOS === true) {
        console.log('creating access token for iOS');
        pushCredSid = payload.production ? twilioConfig.apple_push_credential_release
            : (twilioConfig.apple_push_credential_debug || twilioConfig.apple_push_credential_release);
    } else if (payload.isAndroid === true) {
        console.log('creating access token for Android');
        pushCredSid = twilioConfig.android_push_credential;
    } else {
        throw new functions.https.HttpsError('unknown_platform', 'No platform specified');
    }

    // generate token valid for 24 hours - minimum is 3min, max is 24 hours, default is 1 hour
    const dateTime = new Date();
    dateTime.setDate(dateTime.getDate()+1);
    // Create an access token which we will sign and return to the client,
    // containing the grant we just created
    const voiceGrant = new VoiceGrant({
        outgoingApplicationSid,
        pushCredentialSid: pushCredSid,
    });

    // Create an access token which we will sign and return to the client,
    // containing the grant we just created
    const token = new AccessToken(accountSid, apiKey, apiSecret);
    token.addGrant(voiceGrant);

    // use firebase ID for identity
    token.identity = userId;
    console.log(`Token:${token.toJwt()}`);

    // return json object
    return {
        "token": token.toJwt(),
        "identity": userId,
        "expiry_date": dateTime.getTime()
    };
});
```
Add the function above to your Firebase Functions application,
see [this](https://firebase.google.com/docs/functions/get-started) for more help on creating a
firebase functions project

After you are done, deploy your `.runtimeconfig.json`,
see [this](https://firebase.google.com/docs/functions/config-env) for more help.

Once done with everything above, deploy your firebase function with this:

```bash
firebase deploy --only functions
```
##### Done!

Calling should work naturally - just make sure to fetch the token from the endpoint and you can call

See [example](https://github.com/diegogarciar/twilio_voice/blob/master/example/lib/main.dart#L51)
code, make sure to change the `voice-accessToken` to your function name, given to you by firebase
when deploying (as part of the deploy text)

## Future Work

- Move package to `federated plugin` structure (see [here](https://flutter.dev/go/federated-plugins) for more info), see reduced overhead advantages covered as motivation (see [here](https://medium.com/flutter/how-to-write-a-flutter-web-plugin-part-2-afdddb69ece6) for more info))

## Updating Twilio Voice JS SDK

`twilio.js` is no longer hosted via CDNs (see [reference](https://github.com/twilio/twilio-voice.js/blob/master/README.md#cdn)), instead it is hosted via npm / github. See instructions found [here](https://github.com/twilio/twilio-voice.js/blob/master/README.md#github)
This is automatically added to your `web/index.html` file, as a `<script/>` tag during runtime. See [here](./lib/_internal/twilio_loader.dart) for more info.);

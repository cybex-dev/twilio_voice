## 0.2.1

* Fix: [iOS] Race condition ending call remotely and locally results in a "End Call Failed: The operation couldn’t be completed." error. [Issue #184](https://github.com/cybex-dev/twilio_voice/issues/184)
* Fix: [iOS] Plugin messages sent via Event Sink throwing an error due to sending from background thread. [Issue #256](https://github.com/cybex-dev/twilio_voice/issues/256)

## 0.2.0+1

* Fix: [Web] `window.localStorage` deprecated members
* Updated README.md

## 0.2.0
* [Android] Support (long-awaited) AGP 8 update
* [Android, iOS] Update Twilio SDKs to latest versions, see release notes for:
    * [Android 6.9.0](https://www.twilio.com/docs/voice/sdks/android/3x-changelog#690), and 
    * [iOS 6.13.0](https://www.twilio.com/docs/voice/sdks/ios/changelog#6130),
    * _web coming soon with callkit integration_
* Update: example
  * Added: [Web] environment registration support
  * Added `defines.config.json` file to example to support environment configuration used with ```flutter run --dart-defines-file=defines.config.json```
  * Added: [Web] `FIREBASE_ENABLE` defines to initialize Firebase only if set to true
  * Update: [Web] Update example with Firebase Analytics (Web, optional)
* Added: [Web] Added raw `Connect({Map<String, dynamic>?})` sent to TwiML webhook.
* Fix: [Android] `showMissedCallNotifications` not working due to incorrect method channel name

## 0.1.3
* Added: CallEvents: 
  * `Reconnected`
  * `Reconnecting`
* Fix: [Android] Fix `unregister()` from Twilio (assign internal device token)
* Update: [Android] Add `MANGE_OWN_CALLS` permission to manifest, method channel implementation & example update, see discussion [here](https://github.com/cybex-dev/twilio_voice/issues/194).
* Update: example with logout action, new `CallEvent`s

## 0.1.1

* Fix: [Web] Multiple missed call notifications
* Fix: [Android] `openPhoneAccountsSettings` not always opening on various Android (mainly Samsung) devices
* Fix: Showing `CallDirection.outgoing` instead of `CallDirection.incoming` when Incoming call is ringing in `CallEventsListeners`.
* Fix: `ActiveCall` is not null even after the Call is declined.
* Fix: Android foreground service not starting on Android +11, many thanks to [@mohsen-jalali](https://github.com/mohsen-jalali)
* Fix: Android foreground microphone permission not granted on Android +14.
* Revert: [Android] allow registering clients with an empty name (supporting current implementation).

## 0.1.0

* Feat: [Android] Turn off the screen when a call is active and the head is against the handset. @solid-software (https://solid.software)
* Feat: [macOS] Added support for macOS, based on iOS implementation backed by Twilio Voice Web  (twilio-voice.js [v2.4.1-dev-custom](https://github.com/cybex-dev/twilio-voice.js/tree/2.4.1-dev-custom)).
* Feat: [Web] Web support with notifications (via Service Worker) with live example at https://twilio-voice-web.web.app @cybex-dev
* Feat: [Android, iOS, web] Add handset call status: `isMuted()`, `isOnSpeaker()` and `isHolding()` @cybex-dev
* Refactor: Hold call signature changed to `holdCall({bool shouldHold = true})` @cybex-dev
* Feat: [iOS] Add support for changing callkit icon (future plans to extended this for Flutter assets) @cybex-dev
* [twilio_voice_mimp:0.2.5) fix 4 Null Pointer execption Android
* [twilio_voice_mimp:0.2.4) add Android DE Local
* [twilio_voice_mimp:0.2.4) add Android IT Local
* [twilio_voice_mimp:0.2.3) Upgrade to Twilio Android SDK 6.1.2 / iOS SDK 6.4.2
* [twilio_voice_mimp:0.2.3) small Bugfix for null pointer Exception
* [twilio_voice_mimp:0.2.2) more Magic is needed with FLAG_MUTABLE (Android 12)
* [twilio_voice_mimp:0.2.1) PendingIntent gets FLAG_UPDATE_CURRENT replaced by FLAG_IMMUTABLE (Android 12)
* [twilio_voice_mimp:0.1.2) Upgrade to Twilio Android SDK 6.1.0 / iOS SDK 6.4.0
* [twilio_voice_mimp:0.1.1) Fix case Constants.ACTION_ACCEPT null pointer
* [twilio_voice_mimp:0.0.18) remove example / Add AudioSwitch
* [twilio_voice_mimp:0.0.17) Make Android RingTone louder
* [twilio_voice_mimp:0.0.16) Unknown Caller ist auch in der App sichtbar
* [twilio_voice_mimp:0.0.15) Splash Icon missing
* [twilio_voice_mimp:0.0.14) Compiler anhancements
* [twilio_voice_mimp:0.0.13) Android CallsScreen now displays ClientID / CallerID
* [twilio_voice_mimp:0.0.12) iOS XCODE failed
* [twilio_voice_mimp:0.0.11) iOS Podspecs were failing
* [twilio_voice_mimp:0.0.10) **German Localization in Android
* ~~Feat: Add check and request Bluetooth permissions @cybex-dev~~
* Feat: [Android] Use Android Native callkit equivalent via [ConnectionService](https://developer.android.com/reference/android/telecom/ConnectionService). @cybex-dev
* Change: [Android] Removed (Deprecated) `requiresBackgroundPermissions` & `requestBackgroundPermissions` as they are no longer needed for background UI screens. @cybex-dev
* Change: [Android] Removed (Deprecated) `showBackgroundCallUi` as it is no longer needed for background UI screens. (this might be reinstated in future, depending on feature requests) @cybex-dev
* Change: [Android] Removed (Deprecated) `backgroundCallUi` as it is no longer needed for background UI screens. @cybex-dev
* Change: [Android] Removed (Deprecated) `requestBluetoothPermission`, `hasBluetoothPermission` as these are no longer needed and handled by the native Telecom App. @cybex-dev
* (on-hold) Feat: [Android] Added custom scheme `twi://` @cybex-dev
* Feat (early-access): [Android] Added customParams interpretation via `TVCallInviteParameters` and `TVCallParameters`, see readme for more details. @cybex-dev
* Feat: [Android] Add CallingAccount (Phone Account) label & description via `strings.xml`. @cybex-dev
* Feat: [Android] Add Calling Account (Phone Account) icon (using current app icon via `getApplicationInfo().getIcon()`). @cybex-dev
* Fix: request Permissions return result via Flutter future.
* Fix: [Android] Missing platform method channel for `getSid()`
* Fix: [Android] Inconsistent caller/recipient names for inbound calls between ringing & connected states.
* Fix: [Android] Incorrect call direction for incoming calls
* Fix: call ringing event always showing `CallDirection.outgoing`
* Fix: [Android] Updated CallKit incoming/outgoing name parameter resolution
* Fix: [Web] Notification actions working intermittently.
* Fix: [Web] Added suggested service worker integration with CI/CD unifying with `flutter_service_worker.js`, see [here](https://firebase.flutter.dev/docs/messaging/usage/#background-messages) for more info regarding service worker limitations.
* Update: [Web] Remove additional service-worker files

## 0.0.9

* Feat: forwarded callInvite custom parameters to flutter

## 0.0.8

* Renamed callkit logo
* Merge-Android: Fixed null pointer exception for eventSink occurs in mute call. @GKPK

## 0.0.7

* Fixed from param on android

## 0.0.6

* Added android extra call params

## 0.0.5

* Updated Twilio SDK versions
* Added example proguard-rules.pro for android

## 0.0.4

* Fixes deprecation error with Xcode 12.5
* removed "client" from ids

## 0.0.3

* Added missed call notifications
* Updated Android SDK
* Added localization files

## 0.0.1

* Initial release

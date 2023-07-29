## Next release
* Feat: [Android] Turn off the screen when a call is active and the head is against the handset. @solid-software (https://solid.software)
* Feat: [macOS] Added support for macOS, based on iOS implementation backed by Twilio Voice Web  (twilio-voice.js [v2.4.1-dev-custom](https://github.com/cybex-dev/twilio-voice.js/tree/2.4.1-dev-custom)).
* Feat: [Web] Web support with notifications (via Service Worker) with live example at https://twilio-voice-web.web.app @cybex-dev
* Feat: [Android, iOS] Add handset call status: `isMuted()`, `isOnSpeaker()` and `isHolding()` @cybex-dev
* Refactor: Hold call signature changed to `holdCall({bool shouldHold = true})` @cybex-dev
* Feat: [iOS] Add support for changing callkit icon (future plans to extended this for Flutter assets) @cybex-dev

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

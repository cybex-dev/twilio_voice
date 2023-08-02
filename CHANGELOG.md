## Next release
* Feat: [Android] Turn off the screen when a call is active and the head is against the handset. @solid-software (https://solid.software)
* Feat: [macOS] Added support for macOS, based on iOS implementation backed by Twilio Voice Web  (twilio-voice.js [v2.4.1-dev-custom](https://github.com/cybex-dev/twilio-voice.js/tree/2.4.1-dev-custom)).
* Feat: [Web] Web support with notifications (via Service Worker) with live example at https://twilio-voice-web.web.app @cybex-dev
* Feat: [Android, iOS] Add handset call status: `isMuted()`, `isOnSpeaker()` and `isHolding()` @cybex-dev
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
* Feat: Add check and request Bluetooth permissions @cybex-dev

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

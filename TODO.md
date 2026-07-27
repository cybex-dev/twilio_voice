# Project TODO

## Platform communication
 * Improve message handling between Flutter and native platforms for event channels

## Plugin Support
 * Add support for Windows and Linux platforms, including necessary native code and build configurations

## Android foreground-service notification visibility
 * The ongoing-call foreground-service notification uses an `IMPORTANCE_NONE` channel
   (`TVConnectionService.getOrCreateChannel`), so it shows no status-bar icon and is silent.
   This is intentional for now (Telecom/the default dialer provides the real call UI), but
   consider raising it to `IMPORTANCE_LOW` if a more visible/persistent in-call indicator is
   wanted. The content-intent (tap-to-open-app) was fixed separately; only the channel
   importance remains a design choice.

## Simultaneous / multiple calls
 * Properly support and test multiple concurrent calls across platforms (no platform fully
   incorporates this yet). Includes per-call audio/hold state rather than shared cached
   fields: on Android, `isMuted`/`isHolding`/`isSpeakerOn`/`isBluetoothOn` are cached
   plugin-wide, updated only by CallAudioState broadcasts during a call and never reset on
   Call Ended, so between/at the start of calls the queries can report the previous call's
   state (low likelihood; better solved as part of this rework than a spot-patch).
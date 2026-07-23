# Project TODO

## Platform communication
 * Improve message handling between Flutter and native platforms for event channels

## Plugin Support
 * Add support for Windows and Linux platforms, including necessary native code and build configurations

## Web: WASM (dart2wasm) support — future version
 * Migrate the web layer off `dart:html` + `package:js`/`package:js/js_util.dart` (both
   wasm-incompatible) to `dart:js_interop` + `package:web` so `flutter build web --wasm` works.
   Surface in this repo: `twilio_voice_web.dart` and the 6 `lib/_internal/js/**` interop files
   (twilio, device, call, core/promise, exceptions/twilio_error, utils/js_object_utils) — each
   already has a commented `// import 'dart:js_interop';`. Rewrite `@JS`/`@staticInterop` classes
   as `extension type` interop, replace `js_util` calls (callMethod/getProperty/promiseToFuture/
   jsify/dartify), replace `allowInterop`→`.toJS` (preserving the W2 listener-identity caching),
   drop `js: ^0.7.1`. GATING BLOCKER: the `web_callkit` and `js_notifications` deps are not
   wasm-ready either, so they must be migrated + released first (chain: js_notifications →
   web_callkit → twilio_voice). twilio.min.js `<script>` loading is already wasm-compatible.

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
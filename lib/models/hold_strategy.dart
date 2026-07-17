/// Strategy used when placing a call on hold via `holdCall`.
///
/// The Twilio Voice JS SDK (used on web & macOS) does not provide a native hold mechanism,
/// see [twilio-voice.js#32](https://github.com/twilio/twilio-voice.js/issues/32).
/// Instead, holding is performed either locally on-device ([HoldStrategy.local]) or delegated
/// to the application ([HoldStrategy.remote]) which typically performs a server-side hold via
/// an API call (e.g. moving the call into a conference/queue with TwiML).
///
/// Android & iOS use the native Twilio Voice SDK's hold and ignore this strategy.
enum HoldStrategy {
  /// Hold is performed locally on-device, no server interaction required.
  ///
  /// Outbound audio (microphone) is replaced with hold audio (see `holdAudioUrl`) using the
  /// Twilio [AudioProcessor API](https://twilio.github.io/twilio-voice.js/interfaces/AudioProcessor.html),
  /// or silence if no hold audio is configured. Inbound (remote party) audio is silenced locally.
  ///
  /// Note: the media session stays active while on local hold - if the browser tab or app is
  /// closed, the held call is disconnected.
  local,

  /// Hold is delegated to the application via a [HoldActionCallback] (see `onHoldAction`).
  ///
  /// Use this to perform a true server-side hold with your own API, e.g. redirecting the
  /// remote party into a conference or queue with hold music via TwiML.
  remote,
}

/// Callback invoked when using [HoldStrategy.remote] to (un)hold the active call, providing the
/// active [callSid] and desired hold state [shouldHold].
///
/// Return `true` if the (un)hold action succeeded, `false` otherwise.
typedef HoldActionCallback = Future<bool> Function(String? callSid, bool shouldHold);

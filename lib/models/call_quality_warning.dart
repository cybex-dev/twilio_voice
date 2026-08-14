/// Call quality warnings raised by the Twilio Voice SDK during an active call.
///
/// Warnings are raised when a metric crosses a threshold and cleared when it recovers, so they
/// describe *sustained* conditions rather than instantaneous samples. Thresholds are defined by the
/// Twilio SDKs, e.g. RTT > 400ms for 3 of the last 5 samples.
///
/// Availability differs by platform - see [CallQualityWarning.constantAudioOutputLevel].
enum CallQualityWarning {
  /// Round Trip Time is high (Twilio: RTT > 400ms for 3 of the last 5 samples).
  highRtt,

  /// Jitter is high (Twilio: jitter > 30ms for 3 of the last 5 samples).
  highJitter,

  /// A high fraction of packets is being lost (Twilio: average packet loss > 3% over 7 samples).
  highPacketLoss,

  /// Mean Opinion Score is low (Twilio: MOS < 3.5 for 3 of the last 5 samples).
  lowMos,

  /// The audio *input* level has been effectively constant, which usually means the microphone is
  /// not picking anything up.
  constantAudioInputLevel,

  /// The audio *output* level has been effectively constant.
  ///
  /// **Android only** - the iOS and JS (web/macOS) SDKs do not raise this warning.
  constantAudioOutputLevel,

  /// A warning reported by the SDK that this plugin version does not recognise.
  unknown;

  /// The wire name used by the plugin's event protocol. Matches the Twilio JS SDK's warning
  /// names, which the native platforms normalise onto.
  String get wireName {
    switch (this) {
      case CallQualityWarning.highRtt:
        return 'high-rtt';
      case CallQualityWarning.highJitter:
        return 'high-jitter';
      case CallQualityWarning.highPacketLoss:
        return 'high-packet-loss';
      case CallQualityWarning.lowMos:
        return 'low-mos';
      case CallQualityWarning.constantAudioInputLevel:
        return 'constant-audio-input-level';
      case CallQualityWarning.constantAudioOutputLevel:
        return 'constant-audio-output-level';
      case CallQualityWarning.unknown:
        return 'unknown';
    }
  }

  /// Parses the wire name used by the plugin's event protocol.
  static CallQualityWarning fromName(String name) {
    switch (name) {
      case 'high-rtt':
        return CallQualityWarning.highRtt;
      case 'high-jitter':
        return CallQualityWarning.highJitter;
      case 'high-packet-loss':
      // Alias emitted by some Twilio JS SDK versions / matching the iOS enum name.
      case 'high-packets-lost-fraction':
        return CallQualityWarning.highPacketLoss;
      case 'low-mos':
        return CallQualityWarning.lowMos;
      case 'constant-audio-input-level':
        return CallQualityWarning.constantAudioInputLevel;
      case 'constant-audio-output-level':
        return CallQualityWarning.constantAudioOutputLevel;
      default:
        return CallQualityWarning.unknown;
    }
  }

  /// Parses a comma-separated list of wire names, ignoring empty entries.
  static Set<CallQualityWarning> parseAll(String csv) {
    if (csv.isEmpty) return <CallQualityWarning>{};
    return csv.split(',').where((e) => e.isNotEmpty).map(CallQualityWarning.fromName).toSet();
  }
}

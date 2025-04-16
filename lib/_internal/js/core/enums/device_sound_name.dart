enum SoundName {
  Incoming,
  Outgoing,
  Disconnect,
  Dtmf0,
  Dtmf1,
  Dtmf2,
  Dtmf3,
  Dtmf4,
  Dtmf5,
  Dtmf6,
  Dtmf7,
  Dtmf8,
  Dtmf9,
  DtmfS,
  DtmfH;

  /// Converts the enum value to a string. If the enum value is not found, throws a [StateError].
  static SoundName parse(String name) {
    final lowerName = name.toLowerCase();
    return SoundName.values.firstWhere((e) => e.name.toLowerCase() == lowerName);
  }
}
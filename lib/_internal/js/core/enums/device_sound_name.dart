// ignore_for_file: constant_identifier_names
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

  String get jsName {
    switch (this) {
      case SoundName.Incoming:
        return 'incoming';
      case SoundName.Outgoing:
        return 'outgoing';
      case SoundName.Disconnect:
        return 'disconnect';
      case SoundName.Dtmf0:
        return 'dtmf0';
      case SoundName.Dtmf1:
        return 'dtmf1';
      case SoundName.Dtmf2:
        return 'dtmf2';
      case SoundName.Dtmf3:
        return 'dtmf3';
      case SoundName.Dtmf4:
        return 'dtmf4';
      case SoundName.Dtmf5:
        return 'dtmf5';
      case SoundName.Dtmf6:
        return 'dtmf6';
      case SoundName.Dtmf7:
        return 'dtmf7';
      case SoundName.Dtmf8:
        return 'dtmf8';
      case SoundName.Dtmf9:
        return 'dtmf9';
      case SoundName.DtmfS:
        return 'dtmfS';
      case SoundName.DtmfH:
        return 'dtmfH';
    }
  }

  /// Converts the enum value to a string. If the enum value is not found, throws a [StateError].
  static SoundName parse(String name) {
    final lowerName = name.toLowerCase();
    return SoundName.values.firstWhere((e) => e.name.toLowerCase() == lowerName);
  }
}

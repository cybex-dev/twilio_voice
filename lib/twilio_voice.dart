library twilio_voice;

import 'package:twilio_voice/_internal/method_channel/twilio_call_method_channel.dart';

import '_internal/method_channel/twilio_voice_method_channel.dart';
import '_internal/platform_interface/twilio_voice_platform_interface.dart';

part 'models/active_call.dart';
part 'models/call_event.dart';

class TwilioVoice extends MethodChannelTwilioVoice {
  static TwilioVoicePlatform get instance => MethodChannelTwilioVoice.instance;
}

class Call extends MethodChannelTwilioCall {}

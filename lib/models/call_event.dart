part of twilio_voice;

enum CallEvent {
  incoming,
  ringing,
  connected,
  callEnded,
  unhold,
  hold,
  unmute,
  mute,
  speakerOn,
  speakerOff,
  bluetoothOn,
  bluetoothOff,
  log,
  declined,
  answer,
  missedCall,
  returningCall,
  audioSwitch,
}

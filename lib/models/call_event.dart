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
  log,
  declined,
  answer,
  missedCall,
  returningCall,
  audioSwitch,
}

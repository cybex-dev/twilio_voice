part of twilio_voice;

enum CallEvent {
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
  answer,
  missedCall,
  returningCall,
}

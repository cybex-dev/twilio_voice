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
  iosDeviceToken,
  declined,
  answer,
  missedCall,
  returningCall,
}

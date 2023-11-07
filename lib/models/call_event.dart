part of twilio_voice;

enum CallEvent {
  incoming,
  ringing,
  connected,
  reconnected,
  reconnecting,
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
  permission,
  declined,
  answer,
  missedCall,
  returningCall,
}

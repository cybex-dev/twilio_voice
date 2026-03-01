enum CallEvent {
  incoming,
  incomingWhileActive, // Incoming call while another call is active - doesn't overwrite activeCall
  connecting,
  ringing,
  connected,
  reconnected,
  reconnecting,
  callEnded,
  heldCallEnded, // The held call ended remotely while another call is active
  unhold,
  hold,
  swap, // Native swap: atomically swaps active and held calls (iOS CallKit / Android notification)
  unmute,
  mute,
  speakerOn,
  speakerOff,
  bluetoothOn,
  bluetoothOff,
  audioRouteChanged, // New event for audio route changes (e.g., BT disconnected mid-call)
  log,
  permission,
  declined,
  answer,
  missedCall,
  returningCall,
}

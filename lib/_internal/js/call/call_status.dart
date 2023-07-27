enum CallStatus {
  // The media session associated with the call has been disconnected.
  closed,

  // The call was accepted by or initiated by the local Device instance and the media session is being set up.
  connecting,

  // The media session associated with the call has been established - this depends on 'answerOnBridge' being set to true.
  // If not set to true, the call will be considered 'open' (or connected) once the call is connected to to Twilio.
  connected,

  // The ICE connection was disconnected and a reconnection has been triggered.
  reconnecting,

  // The ICE connection was disconnected, and has successfully reconnected.
  reconnected,

  // The callee has been notified of the call but has not yet responded.
  ringing,

  // The recipient has rejected the incoming call.
  rejected,

  // The recipient has answered the incoming call.
  answer,
}

CallStatus parseCallStatus(String status) {
  switch (status) {
    case "closed":
      return CallStatus.closed;
    case "connecting":
      return CallStatus.connecting;
    case "open":
    case "connected":
      return CallStatus.connected;
    case "reconnecting":
      return CallStatus.reconnecting;
    case "reconnected":
      return CallStatus.reconnected;
    case "ringing":
    case "pending":
      return CallStatus.ringing;
    case "rejected":
      return CallStatus.rejected;
    case "answer":
      return CallStatus.answer;
    default:
      return CallStatus.closed;
  }
}

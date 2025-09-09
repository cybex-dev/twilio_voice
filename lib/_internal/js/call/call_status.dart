enum CallStatus {
  // The media session associated with the call has been disconnected.
  closed,

  // The call was accepted by or initiated by the local Device instance and the media session is being set up.
  connecting,

  // The media session associated with the call has been established - this depends on 'answerOnBridge' being set to true.
  // If not set to true, the call will be considered 'open' (or connected) once the call is connected to to Twilio.
  open,
  // (unofficial) synonymous with `open`
  connected,

  // The ICE connection was disconnected and a reconnection has been triggered.
  reconnecting,

  // (unofficial) The ICE connection was disconnected, and has successfully reconnected.
  reconnected,

  // The callee has been notified of the call but has not yet responded.
  ringing,

  // The call is incoming and hasn't yet been accepted.
  pending,

  //(unofficial) The recipient has rejected the incoming call.
  rejected,

  // (unofficial) The recipient has answered the incoming call.
  answer,
}

CallStatus parseCallStatus(String status) {
  final lower = status.toLowerCase();
  return CallStatus.values.firstWhere(
    (e) => e.name.toLowerCase() == lower,
    orElse: () => CallStatus.closed,
  );
}

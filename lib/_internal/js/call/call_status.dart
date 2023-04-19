enum CallStatus {
  // The media session associated with the call has been disconnected.
  closed,

  // The call was accepted by or initiated by the local Device instance and the media session is being set up.
  connecting,

  // The media session associated with the call has been established.
  open,

  // The call is incoming and hasn't yet been accepted.
  pending,

  // The ICE connection was disconnected and a reconnection has been triggered.
  reconnecting,

  // The callee has been notified of the call but has not yet responded.
  ringing,
}

CallStatus parseCallStatus(String status) {
  switch (status) {
    case "closed":
      return CallStatus.closed;
    case "connecting":
      return CallStatus.connecting;
    case "open":
      return CallStatus.open;
    case "pending":
      return CallStatus.pending;
    case "reconnecting":
      return CallStatus.reconnecting;
    case "ringing":
    default:
      return CallStatus.ringing;
  }
}

class EventMessage {
  final String action;
  final Map<String, dynamic> payload;

  EventMessage(this.action, this.payload);
}
part of twilio_voice;

enum CallDirection { incoming, outgoing }

class ActiveCall {
  final String to;
  final String toFormatted;
  final String from;
  final String fromFormatted;
  final DateTime? initiated;
  final CallDirection callDirection;
  // Only available after Ringing and Answer events
  final Map<String, dynamic>? customParams;

  ActiveCall({
    required String from,
    required String to,
    this.initiated,
    required this.callDirection,
    this.customParams
  })   : this.to = to.replaceAll("client:", ""),
        this.from = from.replaceAll("client:", ""),
        toFormatted = _prettyPrintNumber(to),
        fromFormatted = _prettyPrintNumber(from);

  static String _prettyPrintNumber(String phoneNumber) {
    if (phoneNumber.indexOf('client:') > -1) {
      return phoneNumber.split(':')[1];
    }
    if (phoneNumber.substring(0, 1) == '+') {
      phoneNumber = phoneNumber.substring(1);
    }
    if (phoneNumber.length == 7) {
      return phoneNumber.substring(0, 3) + "-" + phoneNumber.substring(3);
    }
    if (phoneNumber.length < 10) {
      return phoneNumber;
    }
    int start = 0;
    if (phoneNumber.length == 11) {
      start = 1;
    }
    return "(" +
        phoneNumber.substring(start, start + 3) +
        ") " +
        phoneNumber.substring(start + 3, start + 6) +
        "-" +
        phoneNumber.substring(start + 6);
  }
}

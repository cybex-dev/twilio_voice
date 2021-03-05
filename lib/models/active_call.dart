part of twilio_voice;

enum CallDirection { incoming, outgoing }

class ActiveCall {
  String to;
  late String toFormatted;
  String from;
  late String fromFormatted;
  DateTime? initiated;
  CallDirection callDirection;

  ActiveCall({
    required this.from,
    required this.to,
    this.initiated,
    required this.callDirection,
  })   : toFormatted = _prettyPrintNumber(to),
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

import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

class OnCallWidget extends StatefulWidget {
  const OnCallWidget({super.key});

  @override
  State<OnCallWidget> createState() => _OnCallWidgetState();
}

class _OnCallWidgetState extends State<OnCallWidget> {
  final List<CallEvent> _events = [];

  /// Store only call-related events
  void _addEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEvent.incoming:
      case CallEvent.ringing:
      case CallEvent.connected:
      case CallEvent.callEnded:
      case CallEvent.declined:
      case CallEvent.answer:
      case CallEvent.missedCall:
      case CallEvent.returningCall:
        _events.add(event);
        break;
      default:
        break;
    }
  }

  /// Build 'On Call' status indicator
  Widget _buildOnCallStatus({bool onCall = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StatusIcon(active: onCall),
        const SizedBox(width: 8),
        Text(onCall ? "On Call" : "Not on call", style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  /// Build 'table' containing call details: from, to, direction, sid, call state
  Widget _buildCallDetails(ActiveCall? activeCall) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        // Labels
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text("From:"), Text("To:"), Text("Direction:"), Text("SID:"), Text("State:")],
        ),

        // Spacer
        const SizedBox(width: 8),

        // Content/labels/stats
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(activeCall?.fromFormatted ?? "N/A"),
              Text(activeCall?.toFormatted ?? "N/A"),
              activeCall != null ? Text(activeCall.callDirection == CallDirection.incoming ? "Incoming" : "Outgoing") : const Text("N/A"),
              _CallSID(),
              _events.isEmpty ? const Text("N/A") : Text(_events.last.toString()),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CallEvent>(
      stream: TwilioVoice.instance.callEventsListener,
      builder: (context, snapshot) {
        _addEvent(snapshot.data);
        return FutureBuilder<bool>(
          future: TwilioVoice.instance.call.isOnCall(),
          builder: (context, snapshot) {
            final activeCall = TwilioVoice.instance.call.activeCall;
            return Column(
              children: [
                _buildOnCallStatus(onCall: snapshot.data == true),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
                  child: _buildCallDetails(activeCall),
                )
              ],
            );
          },
        );
      },
    );
  }
}

class _CallSID extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: TwilioVoice.instance.call.getSid(),
      builder: (context, snapshot) {
        final sid = snapshot.data ?? "N/A";
        return Text(sid);
      },
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final bool active;

  const _StatusIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active == true ? Colors.green : Colors.red,
      ),
      width: 16,
      height: 16,
    );
  }
}

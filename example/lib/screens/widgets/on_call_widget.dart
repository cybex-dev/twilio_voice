import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

class OnCallWidget extends StatelessWidget {
  const OnCallWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: TwilioVoice.instance.callEventsListener,
      builder: (context, snapshot) {
        return FutureBuilder<bool>(
          future: TwilioVoice.instance.call.isOnCall(),
          builder: (context, snapshot) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StatusIcon(active: snapshot.data ?? false),
                const SizedBox(width: 8),
                Text(snapshot.data == true ? "On Call" : "Not on call", style: Theme.of(context).textTheme.bodyMedium),
              ],
            );
          },
        );
      },
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final bool active;

  const _StatusIcon({super.key, required this.active});

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

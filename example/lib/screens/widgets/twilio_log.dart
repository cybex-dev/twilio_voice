import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

class TwilioLog extends StatefulWidget {
  const TwilioLog({super.key});

  @override
  State<TwilioLog> createState() => _TwilioLogState();
}

class _TwilioLogState extends State<TwilioLog> {
  late final StreamSubscription<CallEvent> _subscription;
  final _tv = TwilioVoice.instance;
  final _events = <CallEvent>[];

  @override
  void initState() {
    super.initState();
    _subscription = _tv.callEventsListener.listen((event) {
      setState(() {
        _events.insert(0, event);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: ListView.separated(
        shrinkWrap: true,
        reverse: true,
        itemBuilder: (context, index) => Text(_events[index].toString()),
        separatorBuilder: (context, index) => const Divider(height: 2, thickness: 0.5),
        itemCount: _events.length,
        physics: const NeverScrollableScrollPhysics(),
      ),
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

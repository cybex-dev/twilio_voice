import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice/_internal/js/core/enums/device_sound_name.dart';
import 'package:twilio_voice/twilio_voice.dart';

import 'ui_permissions_screen.dart';
import 'widgets/call_actions.dart';
import 'widgets/call_features.dart';
import 'widgets/call_status.dart';
import 'widgets/twilio_log.dart';

typedef PerformCall = Future<void> Function(String clientIdentifier);

class UICallScreen extends StatefulWidget {
  final String userId;
  final PerformCall onPerformCall;
  final PerformCall? onCallToQueue;

  const UICallScreen({Key? key, required this.userId, required this.onPerformCall, this.onCallToQueue}) : super(key: key);

  @override
  State<UICallScreen> createState() => _UICallScreenState();
}

class _UICallScreenState extends State<UICallScreen> {
  late TextEditingController _controller;
  late final GlobalKey<FormFieldState<String>> _identifierKey = GlobalKey<FormFieldState<String>>();
  bool _copied = false;

  String _getRecipientIdFromEnv() {
    return const String.fromEnvironment("RECIPIENT_ID");
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _getRecipientIdFromEnv());
  }

  void _copyToClipboard(String data) {
    Clipboard.setData(ClipboardData(text: data));
    setState(() {
      _copied = true;
    });
    Future.delayed(const Duration(seconds: 1), () {
      setState(() {
        _copied = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        TextFormField(
          key: _identifierKey,
          controller: _controller,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return "Please enter a client identifier";
            }
            return null;
          },
          decoration: const InputDecoration(labelText: 'Client Identifier or Phone Number'),
        ),
        const SizedBox(height: 10),
        Wrap(
          children: [
            Text("My Identity: ${widget.userId}"),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _copyToClipboard(widget.userId),
              child: _copied ? const Icon(Icons.check, color: Colors.green, size: 16) : const Icon(Icons.copy, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 10),
        CallActions(
          canCall: true,
          onPerformCall: () {
            final identifier = _identifierKey.currentState?.value;
            if (identifier != null && identifier.isNotEmpty) {
              widget.onPerformCall(identifier);
            }
          },
        ),
        const SizedBox(height: 10),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(8.0),
            child: CallStatus(),
          ),
        ),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(8.0),
            child: CallControls(),
          ),
        ),
        ListTile(
          title: const Text("Permissions"),
          subtitle: const Text("Please allow all permissions to use the app"),
          trailing: const Icon(Icons.arrow_forward_ios),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const UiPermissionsScreen(),
              ),
            );
          },
        ),
        const Divider(),
        const _RingSound(),
        const Divider(),
        Expanded(
          child: Column(
            children: [
              Text("Events (latest at top)", style: Theme.of(context).textTheme.titleLarge),
              const TwilioLog(),
            ],
          ),
        ),
      ],
    );
  }
}

class _RingSound extends StatefulWidget {
  const _RingSound({Key? key}) : super(key: key);

  @override
  State<_RingSound> createState() => _RingSoundState();
}

class _RingSoundState extends State<_RingSound> {
  final _tv = TwilioVoicePlatform.instance;
  final TextEditingController _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: "Enter custom url sound (mp3)",
                hintText: "https://sdk.twilio.com/js/client/sounds/releases/1.0.0/incoming.mp3",
                suffix: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _controller.clear();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () async {
              final url = _controller.text.isEmpty ? null : _controller.text;
              await _tv.updateSound(SoundName.Incoming, url);
              // ignore: use_build_context_synchronously
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Updated incoming sound to ${_controller.text}")),
              );
            },
            child: const Text("Update"),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: () async {
              await _tv.updateSound(SoundName.Incoming, null);
              // ignore: use_build_context_synchronously
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Reset incoming sound")),
              );
            },
            child: const Text("Reset"),
          ),
        ],
      ),
    );
  }
}

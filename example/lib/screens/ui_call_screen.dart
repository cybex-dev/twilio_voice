import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice_example/screens/widgets/on_call_widget.dart';

import 'widgets/permissions_block.dart';

typedef PerformCall = Future<void> Function(String clientIdentifier);

class UICallScreen extends StatefulWidget {
  final String userId;
  final PerformCall onPerformCall;

  const UICallScreen({Key? key, required this.userId, required this.onPerformCall}) : super(key: key);

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
        ElevatedButton(
          child: const Text("Make Call"),
          onPressed: () {
            if (!_identifierKey.currentState!.validate()) {
              return;
            }
            final identity = _controller.text;
            widget.onPerformCall(identity);
          },
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: OnCallWidget(),
        ),
        const Divider(),
        const Expanded(
          child: PermissionsBlock(),
        )
      ],
    );
  }
}
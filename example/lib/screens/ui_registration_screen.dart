import 'package:flutter/material.dart';

typedef OnRegister = Future<void> Function(String accessToken, [String? identity]);

class UIRegistrationScreen extends StatefulWidget {
  final OnRegister onRegister;

  const UIRegistrationScreen({super.key, required this.onRegister});

  @override
  State<UIRegistrationScreen> createState() => _UIRegistrationScreenState();
}

class _UIRegistrationScreenState extends State<UIRegistrationScreen> {
  late final TextEditingController _accessTokenController = TextEditingController();
  late final TextEditingController _identityController = TextEditingController();
  late final GlobalKey<FormFieldState<String>> _accessTokenKey = GlobalKey<FormFieldState<String>>();

  void _onRegisterForCalls() {
    if (!_accessTokenKey.currentState!.validate()) {
      return;
    }
    final identity = _identityController.text;
    final token = _accessTokenController.text;
    widget.onRegister(token, identity);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextFormField(
          controller: _identityController,
          decoration: const InputDecoration(labelText: 'My Identity'),
        ),
        const SizedBox(height: 10),
        TextFormField(
          key: _accessTokenKey,
          validator: (value) => value == null || value.isEmpty ? "Access Token is required" : null,
          controller: _accessTokenController,
          decoration: const InputDecoration(labelText: 'Access Token'),
        ),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: _onRegisterForCalls,
          child: const Text("Register for calls"),
        ),
      ],
    );
  }
}

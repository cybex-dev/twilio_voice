import 'package:flutter/material.dart';
import 'package:twilio_voice_example/screens/widgets/permissions_block.dart';

class UiPermissionsScreen extends StatelessWidget {
  const UiPermissionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Plugin example app: Permissions"),
      ),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: PermissionsBlock(),
          ),
        ),
      ),
    );
  }
}

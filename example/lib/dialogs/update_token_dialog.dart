import 'package:flutter/material.dart';

class UpdateTokenDialogContent extends StatelessWidget {
  const UpdateTokenDialogContent({super.key});

  @override
  Widget build(BuildContext context) {
    final textController = TextEditingController();
    return AlertDialog(
      title: const Text('Paste your new token'),
      content: SingleChildScrollView(
        child: ListBody(
          children: <Widget>[
            const Text('Paste your new token to continue making calls, you\'ll still receive calls to the current device.'),
            const SizedBox(height: 16),
            TextField(
              controller: textController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'New Token',
                alignLabelWithHint: true,
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null); // User chose not to update the token
          },
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop(textController.text); // User chose to update the token
          },
          child: const Text('Update Token'),
        ),
      ],
    );
  }
}

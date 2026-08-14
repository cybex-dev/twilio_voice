import 'package:flutter/material.dart';

class PermissionTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final VoidCallback? onRequestPermission;
  final bool granted;
  final String grantedText;
  final String notGrantedText;
  final String actionText;

  const PermissionTile({
    super.key,
    this.icon,
    required this.title,
    required this.onRequestPermission,
    this.granted = false,
    this.grantedText = "Granted",
    this.notGrantedText = "Not Granted",
    this.actionText = "Request",
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: icon == null ? null : Icon(icon),
      title: Text(title),
      subtitle: Text(granted ? grantedText : notGrantedText),
      trailing: ElevatedButton(
        onPressed: granted ? null : onRequestPermission,
        child: Text(actionText),
      ),
    );
  }
}

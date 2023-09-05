import 'package:flutter/material.dart';

class StateToggle extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final bool state;

  const StateToggle({
    super.key,
    this.icon,
    required this.title,
    this.onTap,
    this.backgroundColor,
    this.state = false,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2.0),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        color: backgroundColor ?? Theme.of(context).cardColor,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                if (icon != null) Icon(icon, color: state ? iconColor : iconColor?.withOpacity(0.2) ?? Colors.grey),
                if (icon != null) const SizedBox(height: 8),
                Text(title, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

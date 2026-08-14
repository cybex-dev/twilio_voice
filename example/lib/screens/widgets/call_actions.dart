import 'package:flutter/material.dart';

class CallActions extends StatelessWidget {
  final bool canCall;
  final VoidCallback? onPerformCall;

  const CallActions({
    super.key,
    this.canCall = true,
    this.onPerformCall,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if(canCall)
          _CallAction(onPressed: onPerformCall, text: "Make Call"),
      ],
    );
  }
}

class _CallAction extends StatelessWidget {
  final VoidCallback? onPressed;
  final String text;

  const _CallAction({required this.onPressed, required this.text});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      child: Text(text),
    );
  }
}

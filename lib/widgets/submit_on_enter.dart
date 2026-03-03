import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SubmitOnEnter extends StatelessWidget {
  const SubmitOnEnter({
    super.key,
    required this.child,
    required this.onSubmit,
    this.controller,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onSubmit;
  final TextEditingController? controller;
  final bool enabled;

  bool get _isComposing {
    final value = controller?.value;
    if (value == null) return false;
    final composing = value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _handleSubmit() {
    if (!enabled || _isComposing) return;
    onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _handleSubmit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _handleSubmit,
      },
      child: child,
    );
  }
}

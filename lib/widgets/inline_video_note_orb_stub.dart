import 'package:flutter/material.dart';

class InlineVideoNoteOrb extends StatelessWidget {
  const InlineVideoNoteOrb({
    super.key,
    required this.videoUrl,
    required this.durationMs,
    required this.accentColor,
  });

  final String videoUrl;
  final int durationMs;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

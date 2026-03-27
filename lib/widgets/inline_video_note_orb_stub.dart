import 'package:flutter/material.dart';

class InlineVideoNoteOrb extends StatelessWidget {
  const InlineVideoNoteOrb({
    super.key,
    required this.videoUrl,
    required this.durationMs,
    required this.accentColor,
    required this.footerText,
  });

  final String videoUrl;
  final int durationMs;
  final Color accentColor;
  final String footerText;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

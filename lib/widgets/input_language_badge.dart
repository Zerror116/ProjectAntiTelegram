import 'package:flutter/material.dart';

import '../services/input_language_service.dart';

class InputLanguageBadge extends StatefulWidget {
  const InputLanguageBadge({super.key, this.controller});

  final TextEditingController? controller;

  @override
  State<InputLanguageBadge> createState() => _InputLanguageBadgeState();
}

class _InputLanguageBadgeState extends State<InputLanguageBadge> {
  String _textSnapshot = '';

  @override
  void initState() {
    super.initState();
    _textSnapshot = widget.controller?.text ?? '';
    _attachController(widget.controller);
  }

  @override
  void didUpdateWidget(covariant InputLanguageBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _detachController(oldWidget.controller);
    _textSnapshot = widget.controller?.text ?? '';
    _attachController(widget.controller);
  }

  @override
  void dispose() {
    _detachController(widget.controller);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final next = widget.controller?.text ?? '';
    if (next == _textSnapshot) return;
    setState(() => _textSnapshot = next);
  }

  void _attachController(TextEditingController? controller) {
    if (controller == null) return;
    try {
      controller.addListener(_onControllerChanged);
    } catch (_) {
      // Controller may already be disposed during route transitions.
    }
  }

  void _detachController(TextEditingController? controller) {
    if (controller == null) return;
    try {
      controller.removeListener(_onControllerChanged);
    } catch (_) {
      // Ignore disposal race; listener is no longer needed.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: inputLanguageService.currentCode,
      builder: (context, currentCode, _) {
        final inferredCode = _inferCodeFromText(_textSnapshot);
        final code = inferredCode ?? currentCode;
        return IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Text(
              code,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.35,
              ),
            ),
          ),
        );
      },
    );
  }
}

String? _inferCodeFromText(String text) {
  for (final rune in text.runes.toList().reversed) {
    if (_isLatin(rune)) return 'EN';
    if (_isUkrainian(rune)) return 'UK';
    if (_isBelarusian(rune)) return 'BE';
    if (_isCyrillic(rune)) return 'RU';
    if (_isArmenian(rune)) return 'HY';
    if (_isGeorgian(rune)) return 'KA';
    if (_isHebrew(rune)) return 'HE';
    if (_isArabic(rune)) return 'AR';
    if (_isGreek(rune)) return 'EL';
    if (_isHiraganaOrKatakana(rune)) return 'JA';
    if (_isHangul(rune)) return 'KO';
    if (_isCjk(rune)) return 'ZH';
  }
  return null;
}

bool _isLatin(int rune) =>
    (rune >= 0x0041 && rune <= 0x007A) ||
    (rune >= 0x00C0 && rune <= 0x024F) ||
    (rune >= 0x1E00 && rune <= 0x1EFF);

bool _isCyrillic(int rune) =>
    (rune >= 0x0400 && rune <= 0x04FF) || (rune >= 0x0500 && rune <= 0x052F);

bool _isUkrainian(int rune) => const {
  0x0404,
  0x0454,
  0x0406,
  0x0456,
  0x0407,
  0x0457,
  0x0490,
  0x0491,
}.contains(rune);

bool _isBelarusian(int rune) => const {0x040E, 0x045E}.contains(rune);

bool _isArmenian(int rune) => rune >= 0x0530 && rune <= 0x058F;

bool _isGeorgian(int rune) =>
    (rune >= 0x10A0 && rune <= 0x10FF) || (rune >= 0x1C90 && rune <= 0x1CBF);

bool _isHebrew(int rune) => rune >= 0x0590 && rune <= 0x05FF;

bool _isArabic(int rune) =>
    (rune >= 0x0600 && rune <= 0x06FF) ||
    (rune >= 0x0750 && rune <= 0x077F) ||
    (rune >= 0x08A0 && rune <= 0x08FF);

bool _isGreek(int rune) => rune >= 0x0370 && rune <= 0x03FF;

bool _isHiraganaOrKatakana(int rune) =>
    (rune >= 0x3040 && rune <= 0x309F) || (rune >= 0x30A0 && rune <= 0x30FF);

bool _isHangul(int rune) =>
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x3130 && rune <= 0x318F) ||
    (rune >= 0xAC00 && rune <= 0xD7AF);

bool _isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) || (rune >= 0x4E00 && rune <= 0x9FFF);

InputDecoration withInputLanguageBadge(
  InputDecoration decoration, {
  TextEditingController? controller,
}) {
  var normalized = decoration;
  if (normalized.suffix != null && normalized.suffixText != null) {
    normalized = normalized.copyWith(suffix: null);
  }
  if (normalized.suffix != null ||
      normalized.suffixText != null ||
      normalized.suffixIcon != null) {
    return normalized;
  }
  return normalized.copyWith(
    suffixIcon: Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Align(
        alignment: Alignment.centerRight,
        widthFactor: 1,
        child: InputLanguageBadge(controller: controller),
      ),
    ),
    suffixIconConstraints: const BoxConstraints(minWidth: 58, minHeight: 40),
  );
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

class PhoenixAmbientBackground extends StatefulWidget {
  const PhoenixAmbientBackground({
    super.key,
    required this.mode,
    this.opacity = 1,
    this.chat = false,
    this.enabled = true,
  });

  final String mode;
  final double opacity;
  final bool chat;
  final bool enabled;

  @override
  State<PhoenixAmbientBackground> createState() =>
      _PhoenixAmbientBackgroundState();
}

class _PhoenixAmbientBackgroundState extends State<PhoenixAmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.chat
          ? const Duration(milliseconds: 18000)
          : const Duration(milliseconds: 22000),
    );
    if (widget.enabled && _isActiveMode(widget.mode)) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(PhoenixAmbientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = widget.enabled && _isActiveMode(widget.mode);
    if (active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disableAnimations && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    } else if (!disableAnimations &&
        widget.enabled &&
        _isActiveMode(widget.mode) &&
        !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isActiveMode(String mode) {
    return mode.trim().isNotEmpty && mode.trim().toLowerCase() != 'off';
  }

  @override
  Widget build(BuildContext context) {
    final normalized = widget.mode.trim().toLowerCase();
    if (!_isActiveMode(normalized)) return const SizedBox.expand();
    final theme = Theme.of(context);
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity.clamp(0, 1),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              isComplex: true,
              willChange: !disableAnimations,
              painter: _PhoenixAmbientPainter(
                theme: theme,
                mode: normalized,
                progress: disableAnimations ? 0 : _controller.value,
                chat: widget.chat,
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }
}

class _PhoenixAmbientPalette {
  const _PhoenixAmbientPalette({
    required this.fire,
    required this.gold,
    required this.blue,
    required this.cyan,
    required this.violet,
    required this.ink,
    required this.baseGlow,
    required this.lineAlpha,
    required this.nodeAlpha,
  });

  final Color fire;
  final Color gold;
  final Color blue;
  final Color cyan;
  final Color violet;
  final Color ink;
  final double baseGlow;
  final double lineAlpha;
  final double nodeAlpha;

  static _PhoenixAmbientPalette fromTheme(
    ThemeData theme, {
    required bool chat,
  }) {
    final dark = theme.brightness == Brightness.dark;
    if (dark) {
      return _PhoenixAmbientPalette(
        fire: const Color(0xFFFF6B1A),
        gold: const Color(0xFFFFD166),
        blue: const Color(0xFF4A7DFF),
        cyan: const Color(0xFF26E7F2),
        violet: const Color(0xFF8B5CFF),
        ink: const Color(0xFF070A1F),
        baseGlow: chat ? 0.19 : 0.15,
        lineAlpha: chat ? 0.40 : 0.30,
        nodeAlpha: chat ? 0.70 : 0.52,
      );
    }
    return _PhoenixAmbientPalette(
      fire: const Color(0xFFFF7A1A),
      gold: const Color(0xFFFFB833),
      blue: const Color(0xFF2F6BFF),
      cyan: const Color(0xFF16B7C9),
      violet: const Color(0xFF7655D9),
      ink: const Color(0xFF0B1B43),
      baseGlow: chat ? 0.25 : 0.20,
      lineAlpha: chat ? 0.40 : 0.30,
      nodeAlpha: chat ? 0.70 : 0.52,
    );
  }
}

double _unitNoise(int seed, [double salt = 0]) {
  final raw = math.sin(seed * 12.9898 + salt * 78.233) * 43758.5453123;
  return raw - raw.floorToDouble();
}

double _wrap01(double value) => value - value.floorToDouble();

Offset _orbitPoint({
  required Size size,
  required int seed,
  required double progress,
  required bool chat,
}) {
  final xBase = _unitNoise(seed, 0.17);
  final yBase = _unitNoise(seed, 0.73);
  final t = progress * math.pi * 2;
  final edgeBias = chat ? 0.07 : 0.03;
  final width = 1 - edgeBias * 2;
  final height = 1 - edgeBias * 2;
  final freqX = 1 + (seed % 3);
  final freqY = 1 + ((seed + 1) % 3);
  final driftX = math.sin(t * freqX + seed) * (chat ? 17 : 13);
  final driftY = math.cos(t * freqY + seed * 0.61) * (chat ? 15 : 11);
  return Offset(
    size.width * (edgeBias + xBase * width) + driftX,
    size.height * (edgeBias + yBase * height) + driftY,
  );
}

Paint _stroke(Color color, double alpha, double width) {
  return Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = width
    ..color = color.withValues(alpha: alpha.clamp(0, 1));
}

Paint _fill(Color color, double alpha) {
  return Paint()..color = color.withValues(alpha: alpha.clamp(0, 1));
}

class _PhoenixAmbientPainter extends CustomPainter {
  const _PhoenixAmbientPainter({
    required this.theme,
    required this.mode,
    required this.progress,
    required this.chat,
  });

  final ThemeData theme;
  final String mode;
  final double progress;
  final bool chat;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final palette = _PhoenixAmbientPalette.fromTheme(theme, chat: chat);
    _paintBaseGlow(canvas, size, palette);
    switch (mode) {
      case 'network':
      case 'constellation':
        _paintConstellation(canvas, size, palette, dense: mode == 'network');
        break;
      case 'feathers':
      case 'embers':
      default:
        _paintEmbers(
          canvas,
          size,
          palette,
          featherBias: chat || mode == 'feathers',
        );
        break;
    }
  }

  void _paintBaseGlow(
    Canvas canvas,
    Size size,
    _PhoenixAmbientPalette palette,
  ) {
    final t = progress * math.pi * 2;
    final rect = Offset.zero & size;
    final dark = theme.brightness == Brightness.dark;

    final centerA = Offset(
      size.width * (0.18 + math.sin(t) * 0.04),
      size.height * (0.18 + math.cos(t) * 0.04),
    );
    final centerB = Offset(
      size.width * (0.78 + math.sin(t + 1.5) * 0.05),
      size.height * (0.82 + math.cos(t + 0.9) * 0.05),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  palette.ink.withValues(alpha: 0.10),
                  palette.violet.withValues(alpha: 0.05),
                  palette.blue.withValues(alpha: 0.04),
                ]
              : [
                  Colors.white.withValues(alpha: 0.08),
                  palette.blue.withValues(alpha: 0.035),
                  palette.fire.withValues(alpha: 0.025),
                ],
        ).createShader(rect),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                palette.blue.withValues(alpha: palette.baseGlow),
                palette.cyan.withValues(alpha: palette.baseGlow * 0.70),
                Colors.transparent,
              ],
            ).createShader(
              Rect.fromCircle(
                center: centerA,
                radius: size.shortestSide * (chat ? 0.72 : 0.58),
              ),
            ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                palette.fire.withValues(alpha: palette.baseGlow * 1.10),
                palette.gold.withValues(alpha: palette.baseGlow * 0.62),
                Colors.transparent,
              ],
            ).createShader(
              Rect.fromCircle(
                center: centerB,
                radius: size.shortestSide * (chat ? 0.66 : 0.52),
              ),
            ),
    );
  }

  void _paintEmbers(
    Canvas canvas,
    Size size,
    _PhoenixAmbientPalette palette, {
    required bool featherBias,
  }) {
    final t = progress * math.pi * 2;
    final particleCount = chat ? 38 : 30;

    for (var i = 0; i < particleCount; i += 1) {
      final phase = _wrap01(_unitNoise(i, 3.8) + progress);
      final xBase = _unitNoise(i, 5.4);
      final xWave = (xBase + math.sin(t + i * 0.7) * 0.018)
          .clamp(0.02, 0.98)
          .toDouble();
      final x = size.width * xWave + math.sin(t + i) * (featherBias ? 18 : 12);
      final y = size.height * (1.08 - phase * 1.22);
      final edgeFade = math.sin(math.pi * phase).clamp(0.0, 1.0).toDouble();
      final twinkle = 0.45 + 0.55 * math.sin(t * 2 + i * 1.31).abs();
      final radius = (0.75 + _unitNoise(i, 9.0) * 2.2) * (chat ? 1.18 : 1);
      final color = i % 4 == 0
          ? palette.cyan
          : (i.isEven ? palette.fire : palette.gold);
      canvas.drawCircle(
        Offset(x, y),
        radius,
        _fill(color, (featherBias ? 0.38 : 0.28) * twinkle * edgeFade),
      );
    }

    final fireStroke = _stroke(
      palette.fire,
      featherBias ? 0.44 : 0.32,
      featherBias ? 1.9 : 1.45,
    );
    final blueStroke = _stroke(
      palette.blue,
      featherBias ? 0.34 : 0.25,
      featherBias ? 1.55 : 1.2,
    );
    final cyanStroke = _stroke(palette.cyan, featherBias ? 0.30 : 0.22, 1.1);

    for (var i = 0; i < (featherBias ? 7 : 5); i += 1) {
      final side = i.isEven ? -1.0 : 1.0;
      final baseX = side < 0 ? size.width * -0.04 : size.width * 1.04;
      final baseY = size.height * (0.14 + i * (featherBias ? 0.13 : 0.16));
      final drift = math.sin(t + i) * (featherBias ? 26 : 18);
      final forward = math.cos(t + i * 0.4) * 18;
      final path = Path()
        ..moveTo(baseX, baseY + drift)
        ..cubicTo(
          size.width * (side < 0 ? 0.18 : 0.82) + forward,
          baseY - 64 + drift,
          size.width * (side < 0 ? 0.30 : 0.70) - forward,
          baseY + 84 + drift,
          size.width * (side < 0 ? 0.55 : 0.45),
          baseY + 28 + drift,
        );
      canvas.drawPath(
        path,
        i % 3 == 0 ? cyanStroke : (i.isEven ? fireStroke : blueStroke),
      );
    }
  }

  void _paintConstellation(
    Canvas canvas,
    Size size,
    _PhoenixAmbientPalette palette, {
    required bool dense,
  }) {
    final t = progress * math.pi * 2;
    final count = dense ? (chat ? 28 : 34) : (chat ? 24 : 28);
    final nodes = <Offset>[];

    for (var i = 0; i < count; i += 1) {
      nodes.add(
        _orbitPoint(size: size, seed: i + 11, progress: progress, chat: chat),
      );
    }

    final threshold = size.shortestSide * (dense ? 0.24 : 0.28);
    for (var i = 0; i < nodes.length; i += 1) {
      for (var j = i + 1; j < nodes.length; j += 1) {
        final distance = (nodes[i] - nodes[j]).distance;
        if (distance > threshold) continue;
        final strength = (1 - distance / threshold).clamp(0, 1).toDouble();
        final pulse = 0.65 + 0.35 * math.sin(t + i * 0.4 + j).abs();
        canvas.drawLine(
          nodes[i],
          nodes[j],
          _stroke(
            i % 3 == 0 ? palette.cyan : palette.blue,
            palette.lineAlpha * strength * pulse,
            dense ? 0.9 : 1.05,
          ),
        );
      }
    }

    final streamPaint = _stroke(palette.fire, chat ? 0.36 : 0.26, 1.35);
    for (var i = 0; i < (chat ? 4 : 3); i += 1) {
      final y = size.height * (0.18 + i * 0.24 + math.sin(t + i) * 0.035);
      final drift = math.sin(t + i) * 24;
      final path = Path()
        ..moveTo(size.width * -0.06, y + drift)
        ..cubicTo(
          size.width * 0.24,
          y - 42 + drift,
          size.width * 0.56,
          y + 58 - drift,
          size.width * 1.06,
          y - drift,
        );
      canvas.drawPath(path, streamPaint);
    }

    for (var i = 0; i < nodes.length; i += 1) {
      final twinkle = 0.45 + 0.55 * math.sin(t * 2 + i * 0.93).abs();
      final color = i % 7 == 0
          ? palette.fire
          : (i % 3 == 0
                ? palette.cyan
                : (i.isEven ? palette.blue : palette.violet));
      final radius = (i % 7 == 0 ? 2.45 : 1.55) + twinkle * 1.2;
      canvas.drawCircle(
        nodes[i],
        radius,
        _fill(color, palette.nodeAlpha * twinkle),
      );
      if (i % 7 == 0) {
        canvas.drawCircle(
          nodes[i],
          radius * 4.2,
          _fill(color, 0.05 + 0.05 * twinkle),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PhoenixAmbientPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.mode != mode ||
        oldDelegate.chat != chat ||
        oldDelegate.theme.brightness != theme.brightness ||
        oldDelegate.theme.colorScheme != theme.colorScheme;
  }
}

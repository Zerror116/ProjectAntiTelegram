import 'dart:math' as math;

import 'package:flutter/material.dart';

class PhoenixMorphSwitcher extends StatelessWidget {
  const PhoenixMorphSwitcher({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
  });

  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations == true;
    return AnimatedSwitcher(
      duration: disabled ? Duration.zero : duration,
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final scale = Tween<double>(begin: 0.82, end: 1).animate(animation);
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      child: child,
    );
  }
}

class PhoenixProgressRingIcon extends StatelessWidget {
  const PhoenixProgressRingIcon({
    super.key,
    required this.icon,
    this.progress,
    this.size = 42,
    this.iconSize = 20,
    this.color,
    this.backgroundColor,
    this.showSpinner = false,
  });

  final IconData icon;
  final double? progress;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? backgroundColor;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    final fill = backgroundColor ?? scheme.surfaceContainerHigh;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size - 8,
            height: size - 8,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
          ),
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              value: showSpinner ? null : progress?.clamp(0.0, 1.0),
              backgroundColor: accent.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          Icon(icon, size: iconSize, color: accent),
        ],
      ),
    );
  }
}

class PhoenixPresenceHalo extends StatelessWidget {
  const PhoenixPresenceHalo({
    super.key,
    required this.child,
    this.active = false,
    this.color,
    this.size,
  });

  final Widget child;
  final bool active;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? (active ? const Color(0xFF22C55E) : scheme.outline);
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations == true;
    final halo = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: accent.withValues(alpha: active ? 0.42 : 0.24),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Padding(padding: const EdgeInsets.all(3), child: child),
    );
    final content = active && !disabled
        ? TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.96, end: 1),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutBack,
            builder: (context, value, animatedChild) =>
                Transform.scale(scale: value, child: animatedChild),
            child: halo,
          )
        : halo;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: content),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PhoenixLiveWaveform extends StatefulWidget {
  const PhoenixLiveWaveform({
    super.key,
    this.barCount = 18,
    this.height = 22,
    this.color = Colors.white,
    this.enabled = true,
  });

  final int barCount;
  final double height;
  final Color color;
  final bool enabled;

  @override
  State<PhoenixLiveWaveform> createState() => _PhoenixLiveWaveformState();
}

class _PhoenixLiveWaveformState extends State<PhoenixLiveWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    if (widget.enabled) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant PhoenixLiveWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled =
        !widget.enabled ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = disabled ? 0.48 : _controller.value;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(widget.barCount, (index) {
              final phase =
                  (index / math.max(1, widget.barCount - 1)) * math.pi;
              final wave = (math.sin((t * math.pi * 2) + phase) + 1) / 2;
              final h = 4 + wave * (widget.height - 6);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Align(
                    alignment: Alignment.center,
                    child: AnimatedContainer(
                      duration: disabled
                          ? Duration.zero
                          : const Duration(milliseconds: 120),
                      height: h,
                      decoration: BoxDecoration(
                        color: widget.color.withValues(
                          alpha: 0.32 + wave * 0.50,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class PhoenixMicroburst extends StatelessWidget {
  const PhoenixMicroburst({
    super.key,
    required this.child,
    this.enabled = true,
    this.color,
    this.duration = const Duration(milliseconds: 520),
  });

  final Widget child;
  final bool enabled;
  final Color? color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final disabled =
        !enabled || MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disabled) return child;
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, animatedChild) {
        final glow = (1 - value).clamp(0.0, 1.0);
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: 1 + 0.08 * glow,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.18 * glow),
                      blurRadius: 18 * glow,
                      spreadRadius: 2 * glow,
                    ),
                  ],
                ),
                child: animatedChild,
              ),
            ),
            ...List.generate(4, (index) {
              final angle = (index / 4) * math.pi * 2;
              final distance = 8 + value * 14;
              return Transform.translate(
                offset: Offset(
                  math.cos(angle) * distance,
                  math.sin(angle) * distance,
                ),
                child: Opacity(
                  opacity: glow,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
      child: child,
    );
  }
}

class PhoenixLiftOnHover extends StatefulWidget {
  const PhoenixLiftOnHover({super.key, required this.child});

  final Widget child;

  @override
  State<PhoenixLiftOnHover> createState() => _PhoenixLiftOnHoverState();
}

class _PhoenixLiftOnHoverState extends State<PhoenixLiftOnHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations == true;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        duration: disabled ? Duration.zero : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        scale: _hovered ? 1.018 : 1,
        child: AnimatedSlide(
          duration: disabled
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          offset: _hovered ? const Offset(0, -0.012) : Offset.zero,
          child: widget.child,
        ),
      ),
    );
  }
}

class PhoenixStepperStrip extends StatelessWidget {
  const PhoenixStepperStrip({
    super.key,
    required this.steps,
    this.activeIndex = 0,
  });

  final List<String> steps;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (steps.isEmpty) return const SizedBox.shrink();
    return Row(
      children: List.generate(steps.length, (index) {
        final active = index <= activeIndex;
        final dot = AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: active ? 30 : 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Text(
            '${index + 1}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: active
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
        return Expanded(
          child: Row(
            children: [
              dot,
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  steps[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: active
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              if (index != steps.length - 1)
                Container(
                  width: 18,
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: active
                        ? theme.colorScheme.primary.withValues(alpha: 0.62)
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

class PhoenixCountUpText extends StatelessWidget {
  const PhoenixCountUpText({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.duration = const Duration(milliseconds: 540),
    this.textAlign,
  });

  final double value;
  final String Function(double value) format;
  final TextStyle? style;
  final Duration duration;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations == true;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: disabled ? value : 0, end: value),
      duration: disabled ? Duration.zero : duration,
      curve: Curves.easeOutCubic,
      builder: (context, current, _) {
        return Text(
          format(current),
          maxLines: 1,
          textAlign: textAlign,
          style: style,
        );
      },
    );
  }
}

class PhoenixDashedDropZone extends StatelessWidget {
  const PhoenixDashedDropZone({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: theme.colorScheme.primary.withValues(alpha: 0.34),
        radius: 20,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            PhoenixProgressRingIcon(
              icon: icon,
              progress: 1,
              size: 42,
              color: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surface,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 8.0;
    const gap = 6.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

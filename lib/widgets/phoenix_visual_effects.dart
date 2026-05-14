import 'package:flutter/material.dart';

class PhoenixSlideFadeIn extends StatelessWidget {
  const PhoenixSlideFadeIn({
    super.key,
    required this.child,
    this.enabled = true,
    this.beginOffset = const Offset(0, 16),
    this.duration = const Duration(milliseconds: 360),
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final bool enabled;
  final Offset beginOffset;
  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final disabled =
        !enabled ||
        duration == Duration.zero ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disabled) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: curve,
      builder: (context, value, animatedChild) {
        return Opacity(
          opacity: value.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(
              beginOffset.dx * (1 - value),
              beginOffset.dy * (1 - value),
            ),
            child: animatedChild,
          ),
        );
      },
      child: child,
    );
  }
}

class PhoenixOneShotHighlight extends StatelessWidget {
  const PhoenixOneShotHighlight({
    super.key,
    required this.child,
    this.enabled = true,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.duration = const Duration(milliseconds: 850),
  });

  final Widget child;
  final bool enabled;
  final Color? color;
  final BorderRadius borderRadius;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final disabled =
        !enabled ||
        duration == Duration.zero ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, animatedChild) {
        final glow = value < 0.62 ? 1 - (value / 0.62) : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.20 * glow),
                        blurRadius: 28 * glow,
                        spreadRadius: 1.5 * glow,
                        offset: Offset(0, 10 * glow),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            animatedChild!,
            Positioned(
              left: 18,
              right: 18,
              bottom: 3,
              child: IgnorePointer(
                child: Opacity(
                  opacity: glow.clamp(0, 1),
                  child: Container(
                    height: 2.5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          accent.withValues(alpha: 0.62),
                          scheme.tertiary.withValues(alpha: 0.42),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: child,
    );
  }
}

class PhoenixReadyBlink extends StatelessWidget {
  const PhoenixReadyBlink({
    super.key,
    required this.child,
    this.enabled = true,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.duration = const Duration(milliseconds: 720),
  });

  final Widget child;
  final bool enabled;
  final Color? color;
  final BorderRadius borderRadius;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final disabled =
        !enabled ||
        duration == Duration.zero ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.tertiary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, animatedChild) {
        final pulse = (1 - value).clamp(0, 1).toDouble();
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.22 * pulse),
                blurRadius: 26 * pulse,
                spreadRadius: 2 * pulse,
              ),
            ],
          ),
          child: animatedChild,
        );
      },
      child: child,
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

class PhoenixLoader extends StatefulWidget {
  final double size;

  const PhoenixLoader({super.key, this.size = 54});

  @override
  State<PhoenixLoader> createState() => _PhoenixLoaderState();
}

class _PhoenixLoaderState extends State<PhoenixLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextReduced = MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (_reducedMotion == nextReduced) {
      if (!nextReduced && !_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }
    _reducedMotion = nextReduced;
    if (_reducedMotion) {
      _controller.stop();
      _controller.value = 0;
      return;
    }
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = widget.size;
    if (_reducedMotion) {
      return SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
              width: 2.2,
            ),
          ),
          child: Icon(
            Icons.local_fire_department_rounded,
            size: size * 0.42,
            color: theme.colorScheme.primary,
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final rotation = _controller.value * 2 * math.pi;
        final pulse = 0.9 + (math.sin(rotation) * 0.08);

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: pulse,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.24),
                        theme.colorScheme.tertiary.withValues(alpha: 0.14),
                      ],
                    ),
                  ),
                ),
              ),
              Transform.rotate(
                angle: rotation,
                child: Container(
                  width: size * 0.82,
                  height: size * 0.82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.72),
                      width: 3,
                    ),
                  ),
                ),
              ),
              Icon(
                Icons.local_fire_department_rounded,
                size: size * 0.42,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        );
      },
    );
  }
}

class PhoenixLoadingView extends StatelessWidget {
  final String title;
  final String? subtitle;
  final double size;

  const PhoenixLoadingView({
    super.key,
    this.title = 'Загрузка',
    this.subtitle,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhoenixLoader(size: size),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class PhoenixWingsLoader extends StatefulWidget {
  final double size;

  const PhoenixWingsLoader({super.key, this.size = 96});

  @override
  State<PhoenixWingsLoader> createState() => _PhoenixWingsLoaderState();
}

class _PhoenixWingsLoaderState extends State<PhoenixWingsLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1650),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextReduced = MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (_reducedMotion == nextReduced) {
      if (!nextReduced && !_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
      return;
    }
    _reducedMotion = nextReduced;
    if (_reducedMotion) {
      _controller.stop();
      _controller.value = 1;
      return;
    }
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildWing(ThemeData theme, {required bool left}) {
    final wingWidth = widget.size * 0.56;
    final wingHeight = widget.size * 0.28;
    final colors = <Color>[
      theme.colorScheme.primary.withValues(alpha: 0.95),
      theme.colorScheme.tertiary.withValues(alpha: 0.85),
    ];
    return Container(
      width: wingWidth,
      height: wingHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(left ? wingWidth * 0.85 : wingWidth * 0.35),
          right: Radius.circular(left ? wingWidth * 0.35 : wingWidth * 0.85),
        ),
        gradient: LinearGradient(
          begin: left ? Alignment.centerLeft : Alignment.centerRight,
          end: left ? Alignment.centerRight : Alignment.centerLeft,
          colors: left ? colors : colors.reversed.toList(),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.22),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_reducedMotion) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          Icons.local_fire_department_rounded,
          size: widget.size * 0.68,
          color: theme.colorScheme.primary,
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        final wingAngle = 0.18 + (0.88 * t);
        final pulse = 0.94 + (0.1 * t);
        final bodyScale = 0.92 + (0.14 * t);
        final size = widget.size;
        return SizedBox(
          width: size * 1.4,
          height: size * 1.2,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: pulse,
                child: Container(
                  width: size * 0.9,
                  height: size * 0.9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.22),
                        theme.colorScheme.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(-size * 0.28, -size * 0.05),
                child: Transform.rotate(
                  angle: -wingAngle,
                  alignment: Alignment.centerRight,
                  child: _buildWing(theme, left: true),
                ),
              ),
              Transform.translate(
                offset: Offset(size * 0.28, -size * 0.05),
                child: Transform.rotate(
                  angle: wingAngle,
                  alignment: Alignment.centerLeft,
                  child: _buildWing(theme, left: false),
                ),
              ),
              Transform.scale(
                scale: bodyScale,
                child: Icon(
                  Icons.local_fire_department_rounded,
                  size: size * 0.72,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PhoenixWingLoadingView extends StatelessWidget {
  final String title;
  final String? subtitle;
  final double size;

  const PhoenixWingLoadingView({
    super.key,
    this.title = 'Проект Феникс запускается',
    this.subtitle,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhoenixWingsLoader(size: size),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

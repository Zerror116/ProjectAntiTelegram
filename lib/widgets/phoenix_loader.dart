import 'dart:math' as math;

import 'package:flutter/material.dart';

const String _phoenixHeroAsset = 'assets/app_icon_source.png';

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
        final pulse = 0.9 + (math.sin(_controller.value * 2 * math.pi) * 0.08);
        final wave = (math.sin(_controller.value * 2 * math.pi) + 1) / 2;
        final barHeights = <double>[
          0.42 + (wave * 0.34),
          0.68 - (wave * 0.16),
          0.36 + ((1 - wave) * 0.28),
        ];

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: pulse,
                child: Container(
                  width: size * 0.88,
                  height: size * 0.88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      radius: 0.9,
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.18),
                        theme.colorScheme.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(barHeights.length, (index) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    width: size * 0.12,
                    height: size * barHeights[index],
                    margin: EdgeInsets.symmetric(horizontal: size * 0.03),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.96),
                          theme.colorScheme.tertiary.withValues(alpha: 0.82),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.22),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                  );
                }),
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
    final heroSize = math.max(size * 1.55, 86.0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhoenixEntryHero(size: heroSize),
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
            PhoenixEntryHero(size: size),
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

class PhoenixEntryHero extends StatefulWidget {
  final double size;

  const PhoenixEntryHero({super.key, this.size = 128});

  @override
  State<PhoenixEntryHero> createState() => _PhoenixEntryHeroState();
}

class _PhoenixEntryHeroState extends State<PhoenixEntryHero>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _pulseController;
  bool _reducedMotion = false;
  bool _pulseStarted = false;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _introController.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_pulseStarted && mounted) {
        _pulseStarted = true;
        _pulseController.repeat();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextReduced = MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (nextReduced == _reducedMotion) {
      if (!_reducedMotion && !_introController.isAnimating) {
        if (_introController.isCompleted) {
          if (!_pulseController.isAnimating) {
            _pulseController.repeat();
          }
        } else {
          _introController.forward();
        }
      }
      return;
    }
    _reducedMotion = nextReduced;
    if (_reducedMotion) {
      _introController.stop();
      _pulseController.stop();
      _introController.value = 1;
      _pulseController.value = 0;
      return;
    }
    _pulseStarted = false;
    _introController
      ..stop()
      ..value = 0;
    _pulseController
      ..stop()
      ..value = 0;
    _introController.forward();
  }

  @override
  void dispose() {
    _introController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  double _mix(double from, double to, double t) => from + ((to - from) * t);

  Widget _buildImageFrame(
    ThemeData theme, {
    required double reveal,
    required double scale,
    required double tilt,
    required double lift,
  }) {
    final size = widget.size;
    final radius = size * 0.26;
    return Transform.translate(
      offset: Offset(0, lift),
      child: Transform.rotate(
        angle: tilt,
        child: Transform.scale(
          scale: scale,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.42),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.28),
                  blurRadius: 34,
                  spreadRadius: 1,
                  offset: const Offset(0, 14),
                ),
                BoxShadow(
                  color: theme.colorScheme.tertiary.withValues(alpha: 0.24),
                  blurRadius: 18,
                  spreadRadius: 1,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.colorScheme.surfaceContainerHighest,
                          theme.colorScheme.surfaceContainer,
                        ],
                      ),
                    ),
                  ),
                  ClipRect(
                    child: Align(
                      alignment: Alignment.center,
                      widthFactor: reveal,
                      child: Image.asset(
                        _phoenixHeroAsset,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: const Alignment(-0.65, -1),
                            end: const Alignment(0.75, 1),
                            colors: [
                              Colors.white.withValues(alpha: 0.16),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.10),
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_reducedMotion) {
      return _buildImageFrame(theme, reveal: 1, scale: 1, tilt: 0, lift: 0);
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_introController, _pulseController]),
      builder: (context, _) {
        final intro = Curves.easeOutCubic.transform(
          _introController.value.clamp(0, 1),
        );
        final introBack = Curves.easeOutBack.transform(
          _introController.value.clamp(0, 1),
        );
        final pulseWave = math.sin(_pulseController.value * math.pi * 2);
        final pulse = (pulseWave + 1) / 2;

        final reveal = _mix(0.80, 1.0, introBack).clamp(0.75, 1.0);
        final scale = _mix(0.93, 1.0, intro) * _mix(0.992, 1.01, pulse);
        final tilt = _mix(0.07, 0.0, intro) + (pulseWave * 0.008);
        final lift = _mix(16, 0, intro) + (pulseWave * 1.8);
        final glowScale = _mix(0.86, 1.0, intro) + (pulse * 0.04);
        final glowOpacity = _mix(0.10, 0.20, pulse);
        final haloSize = widget.size * 1.22;

        return SizedBox(
          width: haloSize,
          height: haloSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: glowScale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withValues(
                          alpha: glowOpacity,
                        ),
                        theme.colorScheme.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                ),
              ),
              _buildImageFrame(
                theme,
                reveal: reveal,
                scale: scale,
                tilt: tilt,
                lift: lift,
              ),
            ],
          ),
        );
      },
    );
  }
}

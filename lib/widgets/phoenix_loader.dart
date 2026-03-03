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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat();
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

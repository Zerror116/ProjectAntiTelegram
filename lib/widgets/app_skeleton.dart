import 'dart:math' as math;

import 'package:flutter/material.dart';

class AppSkeleton extends StatefulWidget {
  const AppSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 12,
    this.margin,
  });

  final double? width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry? margin;

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _loops = 0;
  bool _motionDisabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1280),
    )..addStatusListener(_handleStatus);
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disabled != _motionDisabled) {
      _motionDisabled = disabled;
      if (disabled) {
        _controller.stop();
        _controller.value = 0.5;
      } else if (_loops < 2 && !_controller.isAnimating) {
        _controller.forward(from: 0);
      }
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _motionDisabled) return;
    _loops += 1;
    if (_loops < 2) {
      _controller.forward(from: 0);
    } else {
      _controller.value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.surfaceContainerHighest;
    final glow = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.10),
      theme.colorScheme.surfaceContainerHigh,
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final shift = (_controller.value * 2) - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1.8 + shift, -0.35),
              end: Alignment(1.8 + shift, 0.35),
              colors: [base, glow, base],
              stops: const [0.12, 0.5, 0.88],
            ),
          ),
        );
      },
    );
  }
}

class AppSkeletonCard extends StatelessWidget {
  const AppSkeletonCard({
    super.key,
    this.height = 152,
    this.margin,
    this.radius = 24,
    this.showImage = true,
  });

  final double height;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool showImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showImage) ...[
            const AppSkeleton(width: 92, height: 92, radius: 18),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                AppSkeleton(width: 140, height: 16, radius: 10),
                SizedBox(height: 10),
                AppSkeleton(height: 12, radius: 10),
                SizedBox(height: 8),
                AppSkeleton(width: 180, height: 12, radius: 10),
                Spacer(),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppSkeleton(width: 80, height: 28, radius: 14),
                    AppSkeleton(width: 92, height: 28, radius: 14),
                    AppSkeleton(width: 74, height: 28, radius: 14),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AppMessageSkeletonList extends StatelessWidget {
  const AppMessageSkeletonList({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: count,
      itemBuilder: (context, index) {
        final fromMe = index.isOdd;
        final widthFactor = 0.48 + (index % 3) * 0.12;
        final maxWidth = MediaQuery.sizeOf(context).width * 0.7;
        final width = maxWidth * math.min(widthFactor, 0.82);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Align(
            alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: width,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  AppSkeleton(width: 86, height: 10, radius: 10),
                  SizedBox(height: 10),
                  AppSkeleton(height: 12, radius: 10),
                  SizedBox(height: 8),
                  AppSkeleton(width: 140, height: 12, radius: 10),
                  SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppSkeleton(width: 56, height: 10, radius: 10),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

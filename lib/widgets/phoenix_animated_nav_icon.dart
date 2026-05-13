import 'package:flutter/material.dart';

class PhoenixAnimatedNavIcon extends StatefulWidget {
  const PhoenixAnimatedNavIcon({
    super.key,
    required this.icon,
    required this.selected,
    required this.mode,
    required this.pulse,
  });

  final IconData icon;
  final bool selected;
  final String mode;
  final int pulse;

  @override
  State<PhoenixAnimatedNavIcon> createState() => _PhoenixAnimatedNavIconState();
}

class _PhoenixAnimatedNavIconState extends State<PhoenixAnimatedNavIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 430),
    );
    if (widget.selected) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(PhoenixAnimatedNavIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse != oldWidget.pulse ||
        widget.selected != oldWidget.selected) {
      if (_isActiveMode(widget.mode) && widget.selected) {
        _controller.forward(from: 0);
      } else {
        _controller.value = widget.selected ? 1 : 0;
      }
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
    if (!_isActiveMode(normalized)) {
      return _buildIcon(context, scale: widget.selected ? 1.05 : 1);
    }
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (disableAnimations) {
      return _buildIcon(context, scale: widget.selected ? 1.05 : 1);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutBack.transform(_controller.value);
        final scale = normalized == 'glow'
            ? 1 + 0.10 * t
            : 1 + 0.20 * mathPulse(_controller.value);
        final tilt = normalized == 'glow'
            ? 0.05 * mathPulse(_controller.value)
            : 0.10 * (1 - _controller.value) * (widget.selected ? 1 : 0);
        return Transform.rotate(
          angle: tilt,
          child: _buildIcon(context, scale: scale, glow: normalized == 'glow'),
        );
      },
    );
  }

  double mathPulse(double value) {
    if (value <= 0 || value >= 1) return 0;
    return (1 - (2 * value - 1).abs()).clamp(0, 1);
  }

  Widget _buildIcon(
    BuildContext context, {
    required double scale,
    bool glow = false,
  }) {
    final theme = Theme.of(context);
    return Transform.scale(
      scale: scale,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glow && widget.selected)
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.20),
                    theme.colorScheme.tertiary.withValues(alpha: 0.06),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          Opacity(
            opacity: widget.selected ? 1 : 0.78,
            child: Icon(widget.icon, size: widget.selected ? 28 : 26),
          ),
        ],
      ),
    );
  }
}

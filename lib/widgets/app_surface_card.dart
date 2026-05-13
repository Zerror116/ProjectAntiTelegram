import 'package:flutter/material.dart';

class AppSurfaceCard extends StatelessWidget {
  const AppSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.radius = 24,
    this.compact = false,
    this.highlight = false,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool compact;
  final bool highlight;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final resolvedBorder =
        borderColor ??
        (highlight
            ? scheme.primary.withValues(alpha: 0.34)
            : scheme.outlineVariant.withValues(alpha: 0.9));
    final base = compact
        ? scheme.surfaceContainerLow
        : scheme.surfaceContainerLow.withValues(alpha: 0.98);
    final topGlow = highlight
        ? scheme.primary.withValues(alpha: 0.10)
        : scheme.primary.withValues(alpha: 0.04);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: resolvedBorder),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.alphaBlend(topGlow, base), base],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: compact ? 0.04 : 0.08),
            blurRadius: compact ? 14 : 26,
            offset: Offset(0, compact ? 6 : 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

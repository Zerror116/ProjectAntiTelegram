import 'package:flutter/material.dart';

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.alignLeft = false,
    this.compact = false,
    this.accentColor,
    this.badge,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? action;
  final bool alignLeft;
  final bool compact;
  final Color? accentColor;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = accentColor ?? scheme.primary;
    final subtitleText = (subtitle ?? '').trim();
    return Align(
      alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Container(
          margin: EdgeInsets.all(compact ? 8 : 16),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 18 : 24,
            vertical: compact ? 18 : 26,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(compact ? 22 : 28),
            border: Border.all(color: scheme.outlineVariant),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  accent.withValues(alpha: 0.08),
                  scheme.surfaceContainerLow,
                ),
                scheme.surfaceContainerLow,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: alignLeft
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (badge != null && badge!.trim().isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: accent.withValues(alpha: 0.22)),
                  ),
                  child: Text(
                    badge!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(height: compact ? 12 : 14),
              ],
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: compact ? 72 : 86,
                    height: compact ? 72 : 86,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          accent.withValues(alpha: 0.18),
                          accent.withValues(alpha: 0.03),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: compact ? 56 : 64,
                    height: compact ? 56 : 64,
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Icon(icon, size: compact ? 26 : 30, color: accent),
                  ),
                ],
              ),
              SizedBox(height: compact ? 12 : 16),
              Text(
                title,
                textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitleText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  subtitleText,
                  textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.38,
                  ),
                ),
              ],
              if (action != null) ...[
                SizedBox(height: compact ? 14 : 18),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

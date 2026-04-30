import 'package:flutter/material.dart';

class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color border;
  final bool compact;

  factory AppStatusBadge.preset(
    BuildContext context,
    String status, {
    bool compact = false,
  }) {
    final preset = AppStatusPreset.resolve(Theme.of(context), status);
    return AppStatusBadge(
      label: preset.label,
      icon: preset.icon,
      background: preset.background,
      foreground: preset.foreground,
      border: preset.border,
      compact: compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(compact ? 12 : 14),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 13 : 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class AppStatusPreset {
  const AppStatusPreset({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color border;

  static AppStatusPreset resolve(ThemeData theme, String rawStatus) {
    final scheme = theme.colorScheme;
    final status = rawStatus.trim().toLowerCase();
    switch (status) {
      case 'queued':
      case 'queue':
      case 'pending':
      case 'publishing':
        return AppStatusPreset(
          label: 'В очереди',
          icon: Icons.schedule_rounded,
          background: scheme.primaryContainer.withValues(alpha: 0.46),
          foreground: scheme.onPrimaryContainer,
          border: scheme.primary.withValues(alpha: 0.24),
        );
      case 'sending':
        return AppStatusPreset(
          label: 'Отправляется',
          icon: Icons.outbox_outlined,
          background: scheme.secondaryContainer.withValues(alpha: 0.52),
          foreground: scheme.onSecondaryContainer,
          border: scheme.secondary.withValues(alpha: 0.24),
        );
      case 'published':
      case 'sent':
        return AppStatusPreset(
          label: 'Опубликован',
          icon: Icons.campaign_outlined,
          background: const Color(0xFF0E8F6A).withValues(alpha: 0.16),
          foreground: const Color(0xFF67E0B6),
          border: const Color(0xFF0E8F6A).withValues(alpha: 0.34),
        );
      case 'reserved':
        return AppStatusPreset(
          label: 'Забронирован',
          icon: Icons.inventory_2_outlined,
          background: scheme.tertiaryContainer.withValues(alpha: 0.44),
          foreground: scheme.onTertiaryContainer,
          border: scheme.tertiary.withValues(alpha: 0.24),
        );
      case 'cancelled':
      case 'client_cancelled':
        return AppStatusPreset(
          label: 'Клиент отказался',
          icon: Icons.block_rounded,
          background: scheme.errorContainer.withValues(alpha: 0.34),
          foreground: scheme.onErrorContainer,
          border: scheme.error.withValues(alpha: 0.24),
        );
      case 'processed':
        final isDark = theme.brightness == Brightness.dark;
        return AppStatusPreset(
          label: 'Обработан',
          icon: Icons.check_circle_outline_rounded,
          background: isDark
              ? const Color(0xFF19A36B).withValues(alpha: 0.16)
              : const Color(0xFFD8F4E4),
          foreground: isDark
              ? const Color(0xFF7CE2B6)
              : const Color(0xFF0D6B42),
          border: isDark
              ? const Color(0xFF19A36B).withValues(alpha: 0.34)
              : const Color(0xFF16935F),
        );
      case 'oversized':
      case 'oversize':
        return AppStatusPreset(
          label: 'Габарит',
          icon: Icons.all_inbox_outlined,
          background: scheme.secondaryContainer.withValues(alpha: 0.4),
          foreground: scheme.onSecondaryContainer,
          border: scheme.secondary.withValues(alpha: 0.24),
        );
      case 'revision-needed':
      case 'revision_needed':
        return AppStatusPreset(
          label: 'Нужна ревизия',
          icon: Icons.tune_rounded,
          background: const Color(0xFFFFB648).withValues(alpha: 0.16),
          foreground: const Color(0xFFFFD18A),
          border: const Color(0xFFFFB648).withValues(alpha: 0.34),
        );
      case 'hidden-missing-photo':
      case 'missing_photo':
        return AppStatusPreset(
          label: 'Нет фото',
          icon: Icons.hide_image_outlined,
          background: scheme.errorContainer.withValues(alpha: 0.28),
          foreground: scheme.onErrorContainer,
          border: scheme.error.withValues(alpha: 0.2),
        );
      case 'support-open':
      case 'support_open':
        return AppStatusPreset(
          label: 'Поддержка: открыто',
          icon: Icons.support_agent_rounded,
          background: const Color(0xFFFF8A65).withValues(alpha: 0.14),
          foreground: const Color(0xFFFFC0B0),
          border: const Color(0xFFFF8A65).withValues(alpha: 0.34),
        );
      case 'support-in-progress':
      case 'support_in_progress':
        return AppStatusPreset(
          label: 'Поддержка: в работе',
          icon: Icons.handyman_outlined,
          background: const Color(0xFF3AA7A3).withValues(alpha: 0.16),
          foreground: const Color(0xFFA6F2EE),
          border: const Color(0xFF3AA7A3).withValues(alpha: 0.34),
        );
      case 'support-closed':
      case 'support_closed':
        return AppStatusPreset(
          label: 'Поддержка: закрыто',
          icon: Icons.task_alt_rounded,
          background: const Color(0xFF19A36B).withValues(alpha: 0.16),
          foreground: const Color(0xFF7CE2B6),
          border: const Color(0xFF19A36B).withValues(alpha: 0.34),
        );
      default:
        return AppStatusPreset(
          label: rawStatus.trim().isEmpty ? 'Статус' : rawStatus.trim(),
          icon: Icons.info_outline_rounded,
          background: scheme.surfaceContainerHigh,
          foreground: scheme.onSurface,
          border: scheme.outlineVariant,
        );
    }
  }
}

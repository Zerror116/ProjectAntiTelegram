import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/web_notification_service.dart';

String describeWebNotificationState({
  required WebNotificationPermissionState permissionState,
  required bool isIosWeb,
  required bool isAndroidWeb,
  required bool isStandalone,
}) {
  switch (permissionState) {
    case WebNotificationPermissionState.granted:
      return 'Системные уведомления браузера уже включены.';
    case WebNotificationPermissionState.denied:
      if (isIosWeb) {
        return 'Разрешение на уведомления заблокировано. Откройте настройки iPhone и включите уведомления для ярлыка сайта.';
      }
      if (isAndroidWeb) {
        return 'Разрешение на уведомления заблокировано. Откройте настройки сайта в браузере и разрешите уведомления.';
      }
      return 'Разрешение на уведомления заблокировано в браузере. Его можно включить в настройках сайта.';
    case WebNotificationPermissionState.defaultState:
      if (isIosWeb && !isStandalone) {
        return 'Чтобы получать уведомления на iPhone, добавьте сайт на экран «Домой», откройте ярлык и подтвердите доступ.';
      }
      return 'Включите системные уведомления, чтобы новые сообщения приходили со звуком и появлялись в системной шторке.';
    case WebNotificationPermissionState.unsupported:
      if (isIosWeb && !isStandalone) {
        return 'На iPhone уведомления для сайта доступны после добавления ярлыка на экран «Домой».';
      }
      return 'Этот режим браузера пока не даёт сайту показать системное окно уведомлений.';
  }
}

String webNotificationPrimaryActionLabel({
  required WebNotificationPermissionState permissionState,
  required bool isIosWeb,
  required bool isStandalone,
}) {
  if (permissionState == WebNotificationPermissionState.granted) {
    return 'Показать тест';
  }
  if (permissionState == WebNotificationPermissionState.defaultState &&
      !(isIosWeb && !isStandalone)) {
    return 'Включить уведомления';
  }
  return 'Как включить';
}

Future<void> showWebNotificationHelpSheet(
  BuildContext context, {
  required WebNotificationPermissionState permissionState,
  required bool isIosWeb,
  required bool isAndroidWeb,
  required bool isStandalone,
}) {
  final steps = <String>[
    if (isIosWeb && !isStandalone) ...[
      '1. Откройте сайт в Safari.',
      '2. Нажмите «Поделиться» -> «На экран Домой».',
      '3. Откройте ярлык с экрана «Домой».',
      '4. Нажмите «Включить уведомления» внутри приложения.',
      '5. Если доступ уже был запрещён: Настройки iPhone -> Уведомления -> Проект Феникс.',
    ] else if (isIosWeb) ...[
      '1. Откройте Настройки iPhone -> Уведомления.',
      '2. Найдите ярлык «Проект Феникс».',
      '3. Включите «Допуск уведомлений», звук и показ в системных уведомлениях.',
      '4. Вернитесь в приложение и проверьте тестовое уведомление.',
    ] else if (isAndroidWeb) ...[
      '1. Откройте сайт в Chrome или через установленный ярлык.',
      '2. Нажмите на иконку замка/настроек сайта рядом с адресом.',
      '3. Включите разрешение «Уведомления».',
      '4. В системных настройках Android включите звук и показ уведомлений для браузера или PWA.',
    ] else ...[
      '1. Откройте настройки сайта в браузере.',
      '2. Разрешите уведомления для garphoenix.com.',
      '3. Включите звук и показ уведомлений в браузере или системе.',
    ],
  ];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                permissionState == WebNotificationPermissionState.denied
                    ? 'Как снова включить уведомления'
                    : 'Как включить уведомления',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                describeWebNotificationState(
                  permissionState: permissionState,
                  isIosWeb: isIosWeb,
                  isAndroidWeb: isAndroidWeb,
                  isStandalone: isStandalone,
                ),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              ...steps.map(
                (step) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(step, style: theme.textTheme.bodyMedium),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class WebNotificationPromptCard extends StatelessWidget {
  const WebNotificationPromptCard({
    super.key,
    required this.permissionState,
    required this.isStandalone,
    required this.onPrimaryPressed,
    required this.onGuidePressed,
    this.onDismissed,
    this.loading = false,
  });

  final WebNotificationPermissionState permissionState;
  final bool isStandalone;
  final VoidCallback onPrimaryPressed;
  final VoidCallback onGuidePressed;
  final VoidCallback? onDismissed;
  final bool loading;

  bool get _isIosWeb => kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isAndroidWeb =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = permissionState == WebNotificationPermissionState.granted
        ? 'Уведомления браузера включены'
        : 'Включите системные уведомления';
    final subtitle = describeWebNotificationState(
      permissionState: permissionState,
      isIosWeb: _isIosWeb,
      isAndroidWeb: _isAndroidWeb,
      isStandalone: isStandalone,
    );
    final stepIndex = switch (permissionState) {
      WebNotificationPermissionState.granted => 2,
      WebNotificationPermissionState.defaultState => loading ? 1 : 0,
      WebNotificationPermissionState.denied => 0,
      WebNotificationPermissionState.unsupported => 0,
    };
    final tone = switch (permissionState) {
      WebNotificationPermissionState.granted => colorScheme.tertiary,
      WebNotificationPermissionState.denied => colorScheme.error,
      WebNotificationPermissionState.unsupported => colorScheme.outline,
      WebNotificationPermissionState.defaultState => colorScheme.primary,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.38),
            colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: tone.withValues(alpha: 0.10),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(color: tone.withValues(alpha: 0.22)),
                  ),
                  child: Icon(Icons.notifications_active_outlined, color: tone),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onDismissed != null)
                  IconButton(
                    tooltip: 'Скрыть',
                    onPressed: onDismissed,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _NotificationFlowStep(
                  label: 'Разрешение',
                  active: stepIndex >= 0,
                  done: stepIndex > 0,
                  color: tone,
                ),
                _NotificationFlowLine(active: stepIndex > 0, color: tone),
                _NotificationFlowStep(
                  label: 'Привязка',
                  active: stepIndex >= 1,
                  done: stepIndex > 1,
                  color: tone,
                ),
                _NotificationFlowLine(active: stepIndex > 1, color: tone),
                _NotificationFlowStep(
                  label: 'Готово',
                  active: stepIndex >= 2,
                  done:
                      permissionState == WebNotificationPermissionState.granted,
                  color: tone,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onPressed: loading ? null : onPrimaryPressed,
                  icon: loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          permissionState ==
                                  WebNotificationPermissionState.granted
                              ? Icons.notifications_rounded
                              : Icons.notifications_active_outlined,
                        ),
                  label: Text(
                    webNotificationPrimaryActionLabel(
                      permissionState: permissionState,
                      isIosWeb: _isIosWeb,
                      isStandalone: isStandalone,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onPressed: onGuidePressed,
                  icon: const Icon(Icons.tips_and_updates_outlined),
                  label: const Text('Инструкция'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationFlowLine extends StatelessWidget {
  const _NotificationFlowLine({required this.active, required this.color});

  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.70)
              : Theme.of(context).colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _NotificationFlowStep extends StatelessWidget {
  const _NotificationFlowStep({
    required this.label,
    required this.active,
    required this.done,
    required this.color,
  });

  final String label;
  final bool active;
  final bool done;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: active
                ? color.withValues(alpha: done ? 0.22 : 0.13)
                : theme.colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
            border: Border.all(
              color: active
                  ? color.withValues(alpha: 0.86)
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Icon(
            done ? Icons.check_rounded : Icons.circle,
            size: done ? 16 : 7,
            color: active ? color : theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: active
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outline,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

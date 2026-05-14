import 'package:flutter/material.dart';

import '../widgets/phoenix_micro_interactions.dart';

class PwaGuideScreen extends StatelessWidget {
  const PwaGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Как добавить сайт в быстрый доступ')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PhoenixStepperStrip(
              steps: ['Safari', 'Поделиться', 'Домой'],
              activeIndex: 2,
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Как добавить сайт в быстрый доступ',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _installStep(
                      context,
                      1,
                      Icons.public_rounded,
                      'Откройте ссылку приложения в Safari.',
                    ),
                    _installStep(
                      context,
                      2,
                      Icons.ios_share_rounded,
                      'Нажмите Поделиться → На экран «Домой».',
                    ),
                    _installStep(
                      context,
                      3,
                      Icons.add_to_home_screen_outlined,
                      'Подтвердите добавление ярлыка.',
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'После этого приложение открывается как отдельный экран без браузерных вкладок.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Что уже работает в PWA-режиме',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('• Кэш базовых файлов приложения.'),
                    const Text('• Автоподгрузка обновлений после релиза.'),
                    const Text('• Установка на главный экран iOS.'),
                    const Text(
                      '• Фоновая синхронизация после восстановления сети (через повторные запросы API).',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ограничения iOS',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '• Нет полноценного background service как в нативных iOS-приложениях.',
                    ),
                    const Text(
                      '• Push-уведомления зависят от политики Safari и версии iOS.',
                    ),
                    const Text(
                      '• Для App Store потребуется отдельная нативная упаковка и публикация.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _installStep(
    BuildContext context,
    int index,
    IconData icon,
    String text,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          PhoenixProgressRingIcon(
            icon: icon,
            progress: 1,
            size: 34,
            iconSize: 16,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.surfaceContainerLow,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$index. $text',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

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
                    const Text('1. Откройте ссылку приложения в Safari.'),
                    const Text('2. Нажмите Поделиться → На экран «Домой».'),
                    const Text('3. Подтвердите добавление ярлыка.'),
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
}

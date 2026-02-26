// lib/screens/admin_panel.dart
import 'package:flutter/material.dart';

class AdminPanel extends StatelessWidget {
  const AdminPanel({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Админ‑панель')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: () {
                // навигация в экран создания каналов/настроек
              },
              icon: const Icon(Icons.add),
              label: const Text('Создать канал'),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                // навигация в настройки каналов
              },
              icon: const Icon(Icons.settings),
              label: const Text('Настройки каналов'),
            ),
          ],
        ),
      ),
    );
  }
}

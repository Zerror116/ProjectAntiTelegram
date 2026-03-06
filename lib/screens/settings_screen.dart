// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';

import '../main.dart';
import 'bug_report_screen.dart';
import 'privacy_policy_screen.dart';
import 'support_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  bool _darkMode = false;
  late final VoidCallback _notificationsListener;
  late final VoidCallback _themeListener;

  @override
  void initState() {
    super.initState();
    _notifications = notificationsEnabledNotifier.value;
    _darkMode = themeModeNotifier.value == ThemeMode.dark;

    _notificationsListener = () {
      if (!mounted) return;
      setState(() => _notifications = notificationsEnabledNotifier.value);
    };
    _themeListener = () {
      if (!mounted) return;
      setState(() => _darkMode = themeModeNotifier.value == ThemeMode.dark);
    };

    notificationsEnabledNotifier.addListener(_notificationsListener);
    themeModeNotifier.addListener(_themeListener);
  }

  @override
  void dispose() {
    notificationsEnabledNotifier.removeListener(_notificationsListener);
    themeModeNotifier.removeListener(_themeListener);
    super.dispose();
  }

  Future<void> _toggleNotifications(bool v) async {
    await setNotificationsEnabled(v);
    if (!mounted) return;
    setState(() => _notifications = v);
    showAppNotice(
      context,
      v ? 'Уведомления включены' : 'Уведомления отключены',
      tone: v ? AppNoticeTone.success : AppNoticeTone.warning,
    );
    await playAppSound(v ? AppUiSound.success : AppUiSound.warning);
  }

  Future<void> _toggleDarkMode(bool v) async {
    await setDarkModeEnabled(v);
    if (!mounted) return;
    setState(() => _darkMode = v);
  }

  void _openSupport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SupportScreen()),
    );
  }

  void _openBugReport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BugReportScreen()),
    );
  }

  void _openPrivacyPolicy() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              value: _notifications,
              onChanged: _toggleNotifications,
              title: const Text('Уведомления'),
              subtitle: const Text(
                'Локальные уведомления и звуки внутри приложения',
              ),
            ),
            SwitchListTile(
              value: _darkMode,
              onChanged: _toggleDarkMode,
              title: const Text('Тёмная тема'),
              subtitle: const Text('Переключить тему приложения'),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('Поддержка'),
              subtitle: const Text('Открыть чат поддержки и задать вопрос'),
              onTap: _openSupport,
            ),
            ListTile(
              leading: const Icon(Icons.report_problem_outlined),
              title: const Text('Сообщить о проблеме'),
              subtitle: const Text(
                'Быстро отправить описание ошибки в отдельный служебный канал',
              ),
              onTap: _openBugReport,
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Политика конфиденциальности'),
              subtitle: const Text(
                'Как обрабатываются данные и ограничения ЛС',
              ),
              onTap: _openPrivacyPolicy,
            ),
          ],
        ),
      ),
    );
  }
}

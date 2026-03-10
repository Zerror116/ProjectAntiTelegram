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
  bool _performanceMode = false;
  String _density = 'standard';
  String _cardSize = 'standard';
  Color _lightSeed = const Color(0xFF2F6BFF);
  Color _darkSeed = const Color(0xFF7A4DFF);
  late final VoidCallback _notificationsListener;
  late final VoidCallback _themeListener;
  late final VoidCallback _densityListener;
  late final VoidCallback _cardSizeListener;
  late final VoidCallback _lightSeedListener;
  late final VoidCallback _darkSeedListener;
  late final VoidCallback _performanceModeListener;

  bool get _canOpenSupport {
    return authService.hasPermission('chat.write.support');
  }

  bool get _canReportProblem {
    return _canOpenSupport;
  }

  @override
  void initState() {
    super.initState();
    _notifications = notificationsEnabledNotifier.value;
    _darkMode = themeModeNotifier.value == ThemeMode.dark;
    _density = uiDensityNotifier.value;
    _cardSize = uiCardSizeNotifier.value;
    _lightSeed = lightThemeSeedNotifier.value;
    _darkSeed = darkThemeSeedNotifier.value;
    _performanceMode = performanceModeNotifier.value;

    _notificationsListener = () {
      if (!mounted) return;
      setState(() => _notifications = notificationsEnabledNotifier.value);
    };
    _themeListener = () {
      if (!mounted) return;
      setState(() => _darkMode = themeModeNotifier.value == ThemeMode.dark);
    };
    _densityListener = () {
      if (!mounted) return;
      setState(() => _density = uiDensityNotifier.value);
    };
    _cardSizeListener = () {
      if (!mounted) return;
      setState(() => _cardSize = uiCardSizeNotifier.value);
    };
    _lightSeedListener = () {
      if (!mounted) return;
      setState(() => _lightSeed = lightThemeSeedNotifier.value);
    };
    _darkSeedListener = () {
      if (!mounted) return;
      setState(() => _darkSeed = darkThemeSeedNotifier.value);
    };
    _performanceModeListener = () {
      if (!mounted) return;
      setState(() => _performanceMode = performanceModeNotifier.value);
    };

    notificationsEnabledNotifier.addListener(_notificationsListener);
    themeModeNotifier.addListener(_themeListener);
    uiDensityNotifier.addListener(_densityListener);
    uiCardSizeNotifier.addListener(_cardSizeListener);
    lightThemeSeedNotifier.addListener(_lightSeedListener);
    darkThemeSeedNotifier.addListener(_darkSeedListener);
    performanceModeNotifier.addListener(_performanceModeListener);
  }

  @override
  void dispose() {
    notificationsEnabledNotifier.removeListener(_notificationsListener);
    themeModeNotifier.removeListener(_themeListener);
    uiDensityNotifier.removeListener(_densityListener);
    uiCardSizeNotifier.removeListener(_cardSizeListener);
    lightThemeSeedNotifier.removeListener(_lightSeedListener);
    darkThemeSeedNotifier.removeListener(_darkSeedListener);
    performanceModeNotifier.removeListener(_performanceModeListener);
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

  Future<void> _togglePerformanceMode(bool v) async {
    await setPerformanceModeEnabled(v);
    if (!mounted) return;
    setState(() => _performanceMode = v);
    showAppNotice(
      context,
      v
          ? 'Включен режим для старых устройств'
          : 'Режим для старых устройств выключен',
      tone: AppNoticeTone.info,
    );
  }

  Future<void> _setDensity(String value) async {
    await setUiDensityPreset(value);
    if (!mounted) return;
    setState(() => _density = value);
  }

  Future<void> _setCardSize(String value) async {
    await setUiCardSizePreset(value);
    if (!mounted) return;
    setState(() => _cardSize = value);
  }

  Future<void> _setLightSeed(Color color) async {
    await setThemeSeedColors(lightSeed: color);
    if (!mounted) return;
    setState(() => _lightSeed = color);
  }

  Future<void> _setDarkSeed(Color color) async {
    await setThemeSeedColors(darkSeed: color);
    if (!mounted) return;
    setState(() => _darkSeed = color);
  }

  Widget _buildColorPresetRow({
    required String title,
    required Color current,
    required ValueChanged<Color> onTap,
    required List<Color> presets,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: presets.map((color) {
            final selected = color.toARGB32() == current.toARGB32();
            return InkWell(
              onTap: () => onTap(color),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.onSurface
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
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
            SwitchListTile(
              value: _performanceMode,
              onChanged: _togglePerformanceMode,
              title: const Text('Режим для старых устройств'),
              subtitle: const Text(
                'Снижает нагрузку: меньше анимаций и легче отрисовка',
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _density,
              items: const [
                DropdownMenuItem(
                  value: 'compact',
                  child: Text('Плотность: компакт'),
                ),
                DropdownMenuItem(
                  value: 'standard',
                  child: Text('Плотность: стандарт'),
                ),
                DropdownMenuItem(
                  value: 'comfortable',
                  child: Text('Плотность: комфорт'),
                ),
                DropdownMenuItem(
                  value: 'spacious',
                  child: Text('Плотность: свободно'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                _setDensity(v);
              },
              decoration: const InputDecoration(
                labelText: 'Плотность интерфейса',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _cardSize,
              items: const [
                DropdownMenuItem(
                  value: 'compact',
                  child: Text('Карточки: компакт'),
                ),
                DropdownMenuItem(
                  value: 'standard',
                  child: Text('Карточки: стандарт'),
                ),
                DropdownMenuItem(
                  value: 'large',
                  child: Text('Карточки: крупные'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                _setCardSize(v);
              },
              decoration: const InputDecoration(
                labelText: 'Размер карточек',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildColorPresetRow(
                      title: 'Цвет светлой темы',
                      current: _lightSeed,
                      onTap: _setLightSeed,
                      presets: const [
                        Color(0xFF2F6BFF),
                        Color(0xFF2E8BFF),
                        Color(0xFF0091EA),
                        Color(0xFF0077B6),
                        Color(0xFF4A90E2),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildColorPresetRow(
                      title: 'Цвет тёмной темы',
                      current: _darkSeed,
                      onTap: _setDarkSeed,
                      presets: const [
                        Color(0xFF7A4DFF),
                        Color(0xFF8B5CF6),
                        Color(0xFF6D4CFF),
                        Color(0xFF5E35B1),
                        Color(0xFF4C51BF),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_canOpenSupport)
              ListTile(
                leading: const Icon(Icons.support_agent),
                title: const Text('Поддержка'),
                subtitle: const Text('Открыть чат поддержки и задать вопрос'),
                onTap: _openSupport,
              ),
            if (_canReportProblem)
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

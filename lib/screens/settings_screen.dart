import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

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
  bool _twoFactorEligible = false;
  bool _twoFactorEnabled = false;
  bool _twoFactorLoading = false;
  String? _twoFactorEnabledAt;
  late final VoidCallback _notificationsListener;
  late final VoidCallback _themeListener;
  late final VoidCallback _performanceModeListener;

  bool get _canOpenSupport => true;

  bool get _canReportProblem => _canOpenSupport;

  @override
  void initState() {
    super.initState();
    _notifications = notificationsEnabledNotifier.value;
    _darkMode = themeModeNotifier.value == ThemeMode.dark;
    _performanceMode = performanceModeNotifier.value;
    _twoFactorEligible = _isTwoFactorEligibleRole();

    _notificationsListener = () {
      if (!mounted) return;
      setState(() => _notifications = notificationsEnabledNotifier.value);
    };
    _themeListener = () {
      if (!mounted) return;
      setState(() => _darkMode = themeModeNotifier.value == ThemeMode.dark);
    };
    _performanceModeListener = () {
      if (!mounted) return;
      setState(() => _performanceMode = performanceModeNotifier.value);
    };

    notificationsEnabledNotifier.addListener(_notificationsListener);
    themeModeNotifier.addListener(_themeListener);
    performanceModeNotifier.addListener(_performanceModeListener);
    if (_twoFactorEligible) {
      _loadTwoFactorStatus();
    }
  }

  @override
  void dispose() {
    notificationsEnabledNotifier.removeListener(_notificationsListener);
    themeModeNotifier.removeListener(_themeListener);
    performanceModeNotifier.removeListener(_performanceModeListener);
    super.dispose();
  }

  Future<void> _toggleNotifications(bool value) async {
    await setNotificationsEnabled(value);
    if (!mounted) return;
    setState(() => _notifications = value);
    showAppNotice(
      context,
      value ? 'Уведомления включены' : 'Уведомления отключены',
      tone: value ? AppNoticeTone.success : AppNoticeTone.warning,
    );
    await playAppSound(value ? AppUiSound.success : AppUiSound.warning);
  }

  Future<void> _toggleDarkMode(bool value) async {
    await setDarkModeEnabled(value);
    if (!mounted) return;
    setState(() => _darkMode = value);
  }

  Future<void> _togglePerformanceMode(bool value) async {
    await setPerformanceModeEnabled(value);
    if (!mounted) return;
    setState(() => _performanceMode = value);
    showAppNotice(
      context,
      value
          ? 'Включен режим для старых устройств'
          : 'Режим для старых устройств выключен',
      tone: AppNoticeTone.info,
    );
  }

  bool _isTwoFactorEligibleRole() {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return role == 'admin' || role == 'tenant' || role == 'creator';
  }

  String _extractDioMessage(
    Object error, {
    String fallback = 'Ошибка сервера',
  }) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && (data['error'] != null || data['message'] != null)) {
        return (data['error'] ?? data['message']).toString();
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }
    return fallback;
  }

  Future<void> _loadTwoFactorStatus({bool silent = true}) async {
    if (!_twoFactorEligible) return;
    if (mounted) {
      setState(() => _twoFactorLoading = true);
    }
    try {
      final data = await authService.getTwoFactorStatus();
      if (!mounted) return;
      setState(() {
        _twoFactorEnabled = data['enabled'] == true;
        _twoFactorEnabledAt = data['enabled_at']?.toString();
      });
    } catch (e) {
      if (!silent && mounted) {
        showAppNotice(
          context,
          _extractDioMessage(e),
          tone: AppNoticeTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _twoFactorLoading = false);
    }
  }

  Future<void> _openTwoFactorSheet() async {
    if (_twoFactorLoading || !_twoFactorEligible) return;
    if (_twoFactorEnabled) {
      await _showDisableTwoFactorDialog();
    } else {
      await _showEnableTwoFactorDialog();
    }
  }

  Future<void> _showEnableTwoFactorDialog() async {
    setState(() => _twoFactorLoading = true);
    try {
      final setup = await authService.startTwoFactorSetup();
      if (!mounted) return;

      final secret = (setup['secret'] ?? '').toString().trim();
      final otpauthUrl = (setup['otpauth_url'] ?? '').toString().trim();
      if (secret.isEmpty) {
        throw Exception('Сервер не вернул секрет 2FA');
      }

      final codeCtrl = TextEditingController();
      String localError = '';
      bool saving = false;
      final enabled = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> submit() async {
                final code = codeCtrl.text.replaceAll(RegExp(r'\s+'), '');
                if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                  setDialogState(() => localError = 'Введите 6-значный код');
                  return;
                }
                setDialogState(() {
                  saving = true;
                  localError = '';
                });
                try {
                  await authService.confirmTwoFactorSetup(
                    secret: secret,
                    code: code,
                  );
                  if (!dialogContext.mounted) return;
                  Navigator.of(dialogContext).pop(true);
                } catch (e) {
                  setDialogState(() {
                    localError = _extractDioMessage(
                      e,
                      fallback: 'Не удалось включить 2FA',
                    );
                    saving = false;
                  });
                }
              }

              return AlertDialog(
                title: const Text('Google Authenticator (2FA)'),
                content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Добавьте ключ в Google Authenticator и введите 6-значный код.',
                        ),
                        const SizedBox(height: 12),
                        SelectableText('Секрет: $secret'),
                        const SizedBox(height: 8),
                        if (otpauthUrl.isNotEmpty) ...[
                          const Text(
                            'Ссылка otpauth (если нужно добавить вручную):',
                          ),
                          const SizedBox(height: 4),
                          SelectableText(otpauthUrl),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: secret),
                                );
                                if (!dialogContext.mounted) return;
                                showAppNotice(
                                  dialogContext,
                                  'Секрет скопирован',
                                  tone: AppNoticeTone.info,
                                );
                              },
                              icon: const Icon(Icons.copy_rounded),
                              label: const Text('Копировать секрет'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: codeCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Код 2FA',
                            hintText: '6 цифр',
                          ),
                        ),
                        if (localError.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              localError,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Отмена'),
                  ),
                  ElevatedButton(
                    onPressed: saving ? null : submit,
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Включить'),
                  ),
                ],
              );
            },
          );
        },
      );
      codeCtrl.dispose();

      await _loadTwoFactorStatus();
      if (enabled == true && mounted) {
        showAppNotice(context, '2FA включена', tone: AppNoticeTone.success);
      }
    } catch (e) {
      if (mounted) {
        showAppNotice(
          context,
          _extractDioMessage(e),
          tone: AppNoticeTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _twoFactorLoading = false);
    }
  }

  Future<void> _showDisableTwoFactorDialog() async {
    final passCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    String localError = '';
    bool saving = false;

    final disabled = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final password = passCtrl.text;
              final code = codeCtrl.text.replaceAll(RegExp(r'\s+'), '');
              if (password.isEmpty) {
                setDialogState(() => localError = 'Введите пароль');
                return;
              }
              if (!RegExp(r'^\d{6}$').hasMatch(code)) {
                setDialogState(() => localError = 'Введите 6-значный код');
                return;
              }
              setDialogState(() {
                saving = true;
                localError = '';
              });
              try {
                await authService.disableTwoFactor(
                  password: password,
                  code: code,
                );
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(true);
              } catch (e) {
                setDialogState(() {
                  localError = _extractDioMessage(
                    e,
                    fallback: 'Не удалось отключить 2FA',
                  );
                  saving = false;
                });
              }
            }

            return AlertDialog(
              title: const Text('Отключить 2FA'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Пароль'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: codeCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Код 2FA',
                        hintText: '6 цифр',
                      ),
                    ),
                    if (localError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          localError,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: saving ? null : submit,
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Отключить'),
                ),
              ],
            );
          },
        );
      },
    );
    passCtrl.dispose();
    codeCtrl.dispose();

    await _loadTwoFactorStatus();
    if (disabled == true && mounted) {
      showAppNotice(context, '2FA отключена', tone: AppNoticeTone.info);
    }
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
            if (_twoFactorEligible)
              ListTile(
                leading: const Icon(Icons.shield_moon_outlined),
                title: const Text('Google Authenticator (2FA)'),
                subtitle: Text(
                  _twoFactorEnabled
                      ? (_twoFactorEnabledAt != null
                            ? 'Включено • $_twoFactorEnabledAt'
                            : 'Включено')
                      : 'Выключено',
                ),
                trailing: _twoFactorLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _twoFactorEnabled
                            ? Icons.lock_outline_rounded
                            : Icons.lock_open_rounded,
                      ),
                onTap: _openTwoFactorSheet,
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

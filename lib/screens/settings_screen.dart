import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../services/web_notification_service.dart';
import '../widgets/web_notification_prompt.dart';
import 'bug_report_screen.dart';
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
  int _twoFactorBackupCodesRemaining = 0;
  int _twoFactorTrustedDevicesCount = 0;
  bool _apkInfoLoading = false;
  String? _apkDownloadUrl;
  String _apkInfoMessage = '';
  WebNotificationPermissionState _webNotificationPermissionState =
      WebNotificationPermissionState.unsupported;
  late final VoidCallback _notificationsListener;
  late final VoidCallback _themeListener;
  late final VoidCallback _performanceModeListener;

  bool get _canOpenSupport => true;

  bool get _canReportProblem => _canOpenSupport;

  bool get _isAndroidWeb =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
    if (_isAndroidWeb) {
      _loadApkDownloadUrl();
    }
    if (kIsWeb) {
      unawaited(_loadWebNotificationPermissionState());
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

  Future<void> _openSystemNotificationSettings() async {
    if (kIsWeb) {
      await showWebNotificationHelpSheet(
        context,
        permissionState: _webNotificationPermissionState,
        isIosWeb: defaultTargetPlatform == TargetPlatform.iOS,
        isAndroidWeb: defaultTargetPlatform == TargetPlatform.android,
        isStandalone: WebNotificationService.isStandaloneDisplayMode,
      );
      return;
    }
    final opened = await launchUrl(
      Uri.parse('app-settings:'),
      mode: LaunchMode.externalApplication,
    );
    if (opened) return;
    if (!mounted) return;
    showAppNotice(
      context,
      'Не удалось открыть настройки устройства',
      tone: AppNoticeTone.warning,
    );
  }

  Future<void> _loadWebNotificationPermissionState() async {
    if (!kIsWeb) return;
    final state = await WebNotificationService.getPermissionState();
    if (!mounted) return;
    setState(() {
      _webNotificationPermissionState = state;
    });
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

  Future<void> _loadApkDownloadUrl() async {
    if (!kIsWeb) return;
    if (mounted) {
      setState(() {
        _apkInfoLoading = true;
        _apkInfoMessage = '';
      });
    }
    try {
      final resp = await dio.get(
        '/api/app/update',
        options: Options(
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
        ),
      );
      String? nextUrl;
      final root = resp.data;
      if (root is Map) {
        final data = root['data'];
        if (data is Map) {
          final android = data['android'];
          if (android is Map) {
            final raw = (android['download_url'] ?? '').toString().trim();
            if (raw.isNotEmpty) {
              nextUrl = raw;
            }
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _apkDownloadUrl = nextUrl;
        _apkInfoMessage = nextUrl == null
            ? 'APK пока не настроен на сервере'
            : 'Скачать Android APK';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _apkDownloadUrl = null;
        _apkInfoMessage = _extractDioMessage(
          e,
          fallback: 'Не удалось получить ссылку APK',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _apkInfoLoading = false;
        });
      }
    }
  }

  Future<void> _openApkDownload() async {
    if (!_isAndroidWeb) {
      showAppNotice(
        context,
        'Скачивание APK доступно только с Android-устройств',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final raw = (_apkDownloadUrl ?? '').trim();
    if (raw.isEmpty) {
      showAppNotice(
        context,
        'Ссылка APK пока не настроена на сервере',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      showAppNotice(
        context,
        'Некорректная ссылка APK',
        tone: AppNoticeTone.error,
      );
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!mounted) return;
    if (!opened) {
      showAppNotice(
        context,
        'Не удалось открыть ссылку APK',
        tone: AppNoticeTone.error,
      );
    }
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
        _twoFactorBackupCodesRemaining =
            int.tryParse('${data['backup_codes_remaining'] ?? 0}') ?? 0;
        _twoFactorTrustedDevicesCount =
            int.tryParse('${data['trusted_devices_count'] ?? 0}') ?? 0;
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
      List<String> backupCodesGenerated = const [];
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
                  final result = await authService.confirmTwoFactorSetup(
                    secret: secret,
                    code: code,
                  );
                  final rawCodes = result['backup_codes'];
                  if (rawCodes is List) {
                    backupCodesGenerated = rawCodes
                        .map((item) => item.toString().trim())
                        .where((item) => item.isNotEmpty)
                        .toList();
                  }
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
        if (backupCodesGenerated.isNotEmpty) {
          await _showBackupCodesDialog(backupCodesGenerated);
          if (mounted) {
            showAppNotice(
              context,
              'Сохраните резервные коды в безопасном месте',
              tone: AppNoticeTone.warning,
            );
          }
        }
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

  Future<void> _showBackupCodesDialog(List<String> codes) async {
    if (!mounted || codes.isEmpty) return;
    final printable = codes.join('\n');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Резервные коды 2FA'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Каждый код одноразовый. Сохраните их в безопасном месте.',
                  ),
                  const SizedBox(height: 12),
                  SelectableText(printable),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: printable));
                if (!dialogContext.mounted) return;
                showAppNotice(
                  dialogContext,
                  'Резервные коды скопированы',
                  tone: AppNoticeTone.info,
                );
              },
              child: const Text('Копировать'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  Future<List<String>?> _showRegenerateBackupCodesDialog() async {
    final passCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    String localError = '';
    bool saving = false;
    List<String>? generated;

    await showDialog<void>(
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
                setDialogState(() => localError = 'Введите 6-значный код 2FA');
                return;
              }
              setDialogState(() {
                saving = true;
                localError = '';
              });
              try {
                final result = await authService.regenerateTwoFactorBackupCodes(
                  password: password,
                  code: code,
                );
                final rawCodes = result['backup_codes'];
                generated = rawCodes is List
                    ? rawCodes
                          .map((item) => item.toString().trim())
                          .where((item) => item.isNotEmpty)
                          .toList()
                    : <String>[];
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
              } catch (e) {
                setDialogState(() {
                  localError = _extractDioMessage(
                    e,
                    fallback: 'Не удалось сгенерировать резервные коды',
                  );
                  saving = false;
                });
              }
            }

            return AlertDialog(
              title: const Text('Новые резервные коды'),
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
                      : () => Navigator.of(dialogContext).pop(),
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
                      : const Text('Сгенерировать'),
                ),
              ],
            );
          },
        );
      },
    );

    passCtrl.dispose();
    codeCtrl.dispose();
    return generated;
  }

  Future<void> _openTwoFactorRecoveryCenter() async {
    if (_twoFactorLoading || !_twoFactorEnabled) return;
    setState(() => _twoFactorLoading = true);
    List<Map<String, dynamic>> devices = const [];
    try {
      devices = await authService.listTrustedTwoFactorDevices();
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
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var localDevices = List<Map<String, dynamic>>.from(devices);
        var actionBusy = false;
        var localError = '';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> revokeOne(String id) async {
              if (actionBusy) return;
              setDialogState(() {
                actionBusy = true;
                localError = '';
              });
              try {
                await authService.revokeTrustedTwoFactorDevice(id);
                localDevices.removeWhere((row) => '${row['id']}' == id);
                await _loadTwoFactorStatus();
              } catch (e) {
                setDialogState(() {
                  localError = _extractDioMessage(e);
                });
              } finally {
                setDialogState(() => actionBusy = false);
              }
            }

            Future<void> revokeAll() async {
              if (actionBusy) return;
              setDialogState(() {
                actionBusy = true;
                localError = '';
              });
              try {
                await authService.revokeAllTrustedTwoFactorDevices();
                localDevices = [];
                await _loadTwoFactorStatus();
              } catch (e) {
                setDialogState(() {
                  localError = _extractDioMessage(e);
                });
              } finally {
                setDialogState(() => actionBusy = false);
              }
            }

            Future<void> regenerateCodes() async {
              if (actionBusy) return;
              final codes = await _showRegenerateBackupCodesDialog();
              if (codes == null || codes.isEmpty) return;
              if (!dialogContext.mounted) return;
              await _showBackupCodesDialog(codes);
              await _loadTwoFactorStatus();
            }

            return AlertDialog(
              title: const Text('2FA: коды и устройства'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Резервных кодов осталось: $_twoFactorBackupCodesRemaining',
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: actionBusy ? null : regenerateCodes,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Перегенерировать резервные коды'),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Доверенные устройства: ${localDevices.length}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          if (localDevices.isNotEmpty)
                            TextButton(
                              onPressed: actionBusy ? null : revokeAll,
                              child: const Text('Отозвать все'),
                            ),
                        ],
                      ),
                      if (localDevices.isEmpty)
                        const Text('Нет активных доверенных устройств')
                      else
                        ...localDevices.map((device) {
                          final id = '${device['id']}';
                          final mask = (device['fingerprint_mask'] ?? 'unknown')
                              .toString();
                          final trustedUntil = (device['trusted_until'] ?? '')
                              .toString();
                          final lastSeen = (device['last_seen'] ?? '')
                              .toString();
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.devices_outlined),
                            title: Text(mask),
                            subtitle: Text(
                              'До: ${trustedUntil.isEmpty ? '—' : trustedUntil}\nПоследняя активность: ${lastSeen.isEmpty ? '—' : lastSeen}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.link_off_rounded),
                              onPressed: actionBusy
                                  ? null
                                  : () => revokeOne(id),
                            ),
                          );
                        }),
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
                  onPressed: actionBusy
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Закрыть'),
                ),
              ],
            );
          },
        );
      },
    );
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
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Системные настройки уведомлений'),
              subtitle: const Text(
                'Открыть настройки уведомлений устройства/браузера',
              ),
              onTap: _openSystemNotificationSettings,
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
            if (_twoFactorEligible && _twoFactorEnabled)
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Резервные коды и устройства'),
                subtitle: Text(
                  'Кодов: $_twoFactorBackupCodesRemaining • Доверенных устройств: $_twoFactorTrustedDevicesCount',
                ),
                onTap: _openTwoFactorRecoveryCenter,
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
            if (_isAndroidWeb)
              ListTile(
                leading: _apkInfoLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_for_offline_outlined),
                title: const Text('Скачать APK для Android'),
                subtitle: Text(
                  _apkInfoMessage.isEmpty
                      ? 'Проверяем наличие APK'
                      : _apkInfoMessage,
                ),
                onTap: _apkInfoLoading ? null : _openApkDownload,
              ),
          ],
        ),
      ),
    );
  }
}

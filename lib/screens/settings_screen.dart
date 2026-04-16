import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../services/messenger_preferences_service.dart';
import '../services/web_notification_service.dart';
import '../utils/phone_utils.dart';
import '../widgets/web_notification_prompt.dart';
import 'bug_report_screen.dart';
import 'chat_storage_screen.dart';
import 'change_password_screen.dart';
import 'change_phone_screen.dart';
import 'notification_preferences_screen.dart';
import 'notifications_screen.dart';
import 'printer_test_screen.dart';
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
  bool _deletingAccount = false;
  bool _twoFactorEligible = false;
  bool _twoFactorEnabled = false;
  bool _twoFactorLoading = false;
  String? _twoFactorEnabledAt;
  int _twoFactorBackupCodesRemaining = 0;
  int _twoFactorTrustedDevicesCount = 0;
  bool _apkInfoLoading = false;
  String? _apkDownloadUrl;
  String _apkInfoMessage = '';
  String _appVersionLabel = '—';
  String _appPlatformLabel = '';
  bool _cacheBusy = false;
  bool _messengerPrefsLoading = false;
  bool _messengerPrefsSaving = false;
  MessengerPreferences _messengerPrefs = MessengerPreferences.defaults;
  WebNotificationPermissionState _webNotificationPermissionState =
      WebNotificationPermissionState.unsupported;
  late final VoidCallback _notificationsListener;
  late final VoidCallback _themeListener;
  late final VoidCallback _performanceModeListener;

  bool get _canOpenSupport => true;

  bool get _canReportProblem => _canOpenSupport;

  bool get _canOpenThermalPrinter {
    final role = authService.effectiveRole.toLowerCase().trim();
    final desktopWeb =
        kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
    return desktopWeb && (role == 'admin' || role == 'creator');
  }

  bool get _isAndroidWeb =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _canOpenNotificationCenter {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'creator';
  }

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
    unawaited(_loadMessengerPreferences());
    unawaited(_loadAppMeta());
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

  Future<void> _showNotificationGuide() async {
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

    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final isMacOs = defaultTargetPlatform == TargetPlatform.macOS;
    final steps = isAndroid
        ? const <String>[
            '1. Откройте системные настройки телефона.',
            '2. Найдите Феникс -> Уведомления.',
            '3. Для Android 13 и новее разрешите приложению уведомления, звук, показ на экране блокировки и всплывающие уведомления.',
            '4. Если телефон экономит батарею слишком агрессивно, разрешите Феникс работу в фоне, чтобы важные уведомления не задерживались.',
          ]
        : isMacOs
        ? const <String>[
            '1. Откройте System Settings -> Notifications.',
            '2. Найдите Феникс в списке приложений.',
            '3. Включите показ в Notification Center, баннеры и звук.',
            '4. Если уведомления были запрещены раньше, включите их вручную в системных настройках macOS.',
          ]
        : const <String>[
            '1. Откройте Настройки iPhone.',
            '2. Найдите Феникс -> Уведомления.',
            '3. Включите «Допуск уведомлений», баннеры, звук и показ в центре уведомлений.',
            '4. Если уведомления уже были запрещены раньше, включите их вручную в настройках системы.',
          ];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Как включить уведомления',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  isAndroid
                      ? 'Android показывает системные уведомления только после явного разрешения пользователя. Их нужно включить в системных настройках телефона.'
                      : isMacOs
                      ? 'На macOS уведомления включаются в системном разделе Notifications. Там же настраиваются баннеры, звук и показ в центре уведомлений.'
                      : 'На iPhone уведомления начинают работать только после системного разрешения. Баннеры, звук и центр уведомлений настраиваются отдельно.',
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

  Future<void> _loadWebNotificationPermissionState() async {
    if (!kIsWeb) return;
    final state = await WebNotificationService.getPermissionState();
    if (!mounted) return;
    setState(() {
      _webNotificationPermissionState = state;
    });
  }

  Future<void> _loadMessengerPreferences() async {
    setState(() => _messengerPrefsLoading = true);
    try {
      final prefs = await messengerPreferencesService.load();
      if (!mounted) return;
      setState(() {
        _messengerPrefs = prefs;
        _messengerPrefsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _messengerPrefsLoading = false);
    }
  }

  Future<void> _updateMessengerPreferences(
    MessengerPreferences nextPrefs,
  ) async {
    setState(() => _messengerPrefsSaving = true);
    try {
      final saved = await messengerPreferencesService.save(nextPrefs);
      if (!mounted) return;
      setState(() {
        _messengerPrefs = saved;
        _messengerPrefsSaving = false;
      });
      showAppNotice(
        context,
        'Настройки медиа сохранены',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _messengerPrefsSaving = false);
      showAppNotice(
        context,
        _extractDioMessage(
          e,
          fallback: 'Не удалось сохранить настройки медиа',
        ),
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _openPrinterTest() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PrinterTestScreen()),
    );
  }

  bool _isTwoFactorEligibleRole() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'tenant' || role == 'creator';
  }

  bool get _isClientBaseRole {
    return authService.effectiveRole.toLowerCase().trim() == 'client';
  }

  String get _displayName {
    final user = authService.currentUser;
    final name = (user?.name ?? '').trim();
    if (name.isNotEmpty) return name;
    final email = (user?.email ?? '').trim();
    if (email.isNotEmpty) return email;
    return 'Аккаунт Феникс';
  }

  String get _displayEmail {
    return (authService.currentUser?.email ?? '').trim();
  }

  String get _displayPhone {
    final raw = (authService.currentUser?.phone ?? '').toString().trim();
    if (raw.isEmpty) return '';
    return PhoneUtils.formatForDisplay(raw);
  }

  String get _currentRoleLabel {
    switch (authService.effectiveRole.toLowerCase().trim()) {
      case 'creator':
        return 'Создатель';
      case 'tenant':
        return 'Арендатор';
      case 'admin':
        return 'Администратор';
      case 'worker':
        return 'Работник';
      case 'client':
      default:
        return 'Клиент';
    }
  }

  String get _currentSavedSessionId {
    final user = authService.currentUser;
    if (user == null) return '';
    final email = user.email.trim().toLowerCase();
    final tenantCode = (user.tenantCode ?? '').trim().toLowerCase();
    return '$email::$tenantCode';
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

  Future<void> _loadAppMeta() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersionLabel = packageInfo.version.trim().isEmpty
            ? '—'
            : packageInfo.version.trim();
        _appPlatformLabel = _describePlatform();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _appPlatformLabel = _describePlatform();
      });
    }
  }

  String _describePlatform() {
    if (kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return 'Android (браузер)';
        case TargetPlatform.iOS:
          return 'iPhone / iPad (браузер)';
        case TargetPlatform.macOS:
          return 'macOS (сайт)';
        case TargetPlatform.windows:
          return 'Windows (сайт)';
        case TargetPlatform.linux:
          return 'Linux (сайт)';
        default:
          return 'Веб';
      }
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iPhone / iPad';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Устройство';
    }
  }

  String _formatDateTimeLabel(DateTime? value) {
    if (value == null) return 'Не указано';
    final local = value.toLocal();
    final dd = local.day.toString().padLeft(2, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final yyyy = local.year.toString();
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$dd.$mm.$yyyy $hh:$min';
  }

  Future<void> _clearVisualCache() async {
    if (_cacheBusy) return;
    setState(() => _cacheBusy = true);
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      if (!mounted) return;
      showAppNotice(
        context,
        'Кэш изображений очищен',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        _extractDioMessage(
          e,
          fallback: 'Не удалось очистить кэш изображений',
        ),
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  Future<void> _clearSavedSessionsOnDevice() async {
    final sessions = await authService.listSavedTenantSessions();
    if (sessions.isEmpty) {
      if (!mounted) return;
      showAppNotice(
        context,
        'На этом устройстве нет сохранённых входов',
        tone: AppNoticeTone.info,
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить сохранённые входы'),
        content: Text(
          'Удалить с этого устройства ${sessions.length} сохранённых входов и групп?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final row in sessions) {
      final id = (row['id'] ?? '').toString().trim();
      if (id.isEmpty || id == _currentSavedSessionId) continue;
      await authService.removeSavedTenantSession(id);
    }
    if (!mounted) return;
    showAppNotice(
      context,
      'Сохранённые входы на этом устройстве очищены',
      tone: AppNoticeTone.success,
    );
  }

  Future<void> _logout() async {
    await authService.logout();
  }

  Future<void> _deleteAccount() async {
    final identifierCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    var obscure = true;
    final confirmPayload = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Удалить аккаунт'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Для подтверждения введите email или номер телефона и ваш пароль.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: identifierCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email или номер телефона',
                  hintText: 'user@mail.com / 79991234567',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passwordCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'Пароль',
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () {
                      setDialogState(() => obscure = !obscure);
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(dialogContext, {
                  'identifier': identifierCtrl.text.trim(),
                  'password': passwordCtrl.text,
                });
              },
              child: const Text('Удалить аккаунт'),
            ),
          ],
        ),
      ),
    );
    identifierCtrl.dispose();
    passwordCtrl.dispose();

    final identifier = (confirmPayload?['identifier'] ?? '').trim();
    final password = confirmPayload?['password'] ?? '';
    if (identifier.isEmpty || password.isEmpty) return;

    setState(() => _deletingAccount = true);
    try {
      final resp = await authService.dio.post(
        '/api/auth/delete_account',
        data: {'identifier': identifier, 'password': password},
      );
      if (resp.statusCode == 200) {
        await authService.clearToken();
        return;
      }
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось удалить аккаунт',
        tone: AppNoticeTone.error,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        _extractDioMessage(e),
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  Future<void> _openPermissionsGuide() async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget item({
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
            children: [
              Text(
                'Разрешения приложения',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Здесь собраны только самые важные разрешения. Если что-то не работает, сначала проверьте именно их.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              item(
                icon: Icons.notifications_outlined,
                title: 'Уведомления',
                subtitle:
                    'Нужны для личных сообщений, поддержки, доставки, акций и обновлений.',
              ),
              item(
                icon: Icons.photo_camera_outlined,
                title: 'Камера',
                subtitle:
                    'Нужна для фото товаров, аватарок, чатов и быстрых снимков внутри приложения.',
              ),
              item(
                icon: Icons.photo_library_outlined,
                title: 'Фото и файлы',
                subtitle:
                    'Нужны, чтобы выбирать изображения, документы и медиа с устройства.',
              ),
              item(
                icon: Icons.mic_none_rounded,
                title: 'Микрофон',
                subtitle:
                    'Нужен для голосовых сообщений и записи звука в чате.',
              ),
              item(
                icon: Icons.place_outlined,
                title: 'Геолокация',
                subtitle:
                    'Нужна для выбора адреса, точки доставки и работы с картой.',
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  await _showNotificationGuide();
                },
                icon: const Icon(Icons.help_outline_rounded),
                label: const Text('Как включить уведомления'),
              ),
            ],
          ),
        );
      },
    );
  }

  String _sessionTitle(Map<String, dynamic> row) {
    final userAgent = (row['user_agent'] ?? '').toString().trim();
    final lower = userAgent.toLowerCase();

    if (lower.contains('iphone')) return 'iPhone';
    if (lower.contains('ipad')) return 'iPad';
    if (lower.contains('xiaomi') ||
        lower.contains(' redmi') ||
        lower.contains('redmi ') ||
        lower.contains(' poco') ||
        lower.contains('poco ')) {
      return 'Xiaomi';
    }
    if (lower.contains('samsung') || lower.contains('sm-')) {
      return 'Samsung';
    }
    if (lower.contains('pixel')) return 'Google Pixel';
    if (lower.contains('huawei')) return 'Huawei';
    if (lower.contains('honor')) return 'Honor';
    if (lower.contains('oneplus')) return 'OnePlus';
    if (lower.contains('realme')) return 'realme';
    if (lower.contains('oppo')) return 'OPPO';
    if (lower.contains('vivo')) return 'vivo';
    if (lower.contains('motorola') || lower.contains('moto')) {
      return 'Motorola';
    }
    if (lower.contains('nothing')) return 'Nothing Phone';
    if (lower.contains('android')) return 'Android-устройство';
    if (lower.contains('mac os') || lower.contains('macintosh')) {
      return lower.contains('safari') ? 'Mac (Safari)' : 'Mac';
    }
    if (lower.contains('windows')) {
      return lower.contains('chrome')
          ? 'Windows (Chrome)'
          : lower.contains('edg')
          ? 'Windows (Edge)'
          : 'Windows';
    }
    if (lower.contains('linux')) return 'Linux';
    if (lower.contains('safari')) return 'Safari';
    if (lower.contains('chrome')) return 'Chrome';
    if (lower.contains('firefox')) return 'Firefox';
    if (lower.contains('dart')) return 'Феникс';
    if (kIsWeb) return 'Браузер';
    return userAgent.isEmpty ? 'Устройство' : userAgent;
  }

  String _sessionSubtitle(Map<String, dynamic> row) {
    final fingerprint = (row['device_fingerprint'] ?? '').toString().trim();
    final lastSeen = DateTime.tryParse((row['last_seen_at'] ?? '').toString());
    final expires = DateTime.tryParse((row['expires_at'] ?? '').toString());
    final parts = <String>[];
    if (fingerprint.isNotEmpty) {
      final masked = fingerprint.length > 12
          ? '${fingerprint.substring(0, 6)}…${fingerprint.substring(fingerprint.length - 4)}'
          : fingerprint;
      parts.add('Устройство: $masked');
    }
    if (lastSeen != null) {
      parts.add('Последняя активность: ${_formatDateTimeLabel(lastSeen)}');
    }
    if (expires != null) {
      parts.add('Сессия до: ${_formatDateTimeLabel(expires)}');
    }
    return parts.isEmpty ? 'Детали сессии недоступны' : parts.join('\n');
  }

  Future<void> _openSessionsDialog() async {
    List<Map<String, dynamic>> serverSessions = const [];
    final savedSessions = await authService.listSavedTenantSessions();
    String errorMessage = '';
    var serverSupported = true;
    try {
      final resp = await authService.dio.get('/api/auth/sessions');
      final root = resp.data;
      if (root is Map && root['ok'] == true && root['data'] is List) {
        serverSessions = List<Map<String, dynamic>>.from(root['data']);
      } else {
        errorMessage = 'Не удалось загрузить активные входы';
      }
    } catch (e) {
      if (e is DioException &&
          (e.response?.statusCode == 403 || e.response?.statusCode == 404)) {
        serverSupported = false;
      } else {
        errorMessage = _extractDioMessage(
          e,
          fallback: 'Не удалось загрузить активные входы',
        );
      }
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var localServerSessions = List<Map<String, dynamic>>.from(serverSessions);
        var localSavedSessions = List<Map<String, dynamic>>.from(savedSessions);
        var busy = false;
        var localError = errorMessage;

        Future<void> revokeOthers(StateSetter setDialogState) async {
          if (busy || !serverSupported) return;
          setDialogState(() {
            busy = true;
            localError = '';
          });
          try {
            await authService.dio.post('/api/auth/sessions/revoke_others');
            localServerSessions = localServerSessions
                .where((row) => row['is_current'] == true)
                .toList();
          } catch (e) {
            localError = _extractDioMessage(
              e,
              fallback: 'Не удалось завершить другие входы',
            );
          } finally {
            setDialogState(() => busy = false);
          }
        }

        Future<void> revokeOne(
          StateSetter setDialogState,
          String sessionId,
        ) async {
          if (busy) return;
          setDialogState(() {
            busy = true;
            localError = '';
          });
          try {
            await authService.dio.delete('/api/auth/sessions/$sessionId');
            localServerSessions.removeWhere(
              (row) => '${row['id']}' == sessionId,
            );
          } catch (e) {
            localError = _extractDioMessage(
              e,
              fallback: 'Не удалось завершить этот вход',
            );
          } finally {
            setDialogState(() => busy = false);
          }
        }

        Future<void> removeSavedSession(
          StateSetter setDialogState,
          String sessionId,
        ) async {
          if (busy) return;
          setDialogState(() => busy = true);
          try {
            await authService.removeSavedTenantSession(sessionId);
            localSavedSessions.removeWhere(
              (row) => (row['id'] ?? '').toString().trim() == sessionId,
            );
          } finally {
            setDialogState(() => busy = false);
          }
        }

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Устройства и входы'),
              content: SizedBox(
                width: 620,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (serverSupported) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Активные входы',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            if (localServerSessions.length > 1)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => revokeOthers(setDialogState),
                                child: const Text('Завершить остальные'),
                              ),
                          ],
                        ),
                        if (localServerSessions.isEmpty)
                          const Text('Сейчас есть только текущий вход.')
                        else
                          ...localServerSessions.map((row) {
                            final isCurrent = row['is_current'] == true;
                            final id = (row['id'] ?? '').toString().trim();
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                isCurrent
                                    ? Icons.phone_android_rounded
                                    : Icons.devices_other_outlined,
                              ),
                              title: Text(
                                isCurrent
                                    ? '${_sessionTitle(row)} • Это устройство'
                                    : _sessionTitle(row),
                              ),
                              subtitle: Text(_sessionSubtitle(row)),
                              trailing: isCurrent || id.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Завершить вход',
                                      onPressed: busy
                                          ? null
                                          : () => revokeOne(
                                                setDialogState,
                                                id,
                                              ),
                                      icon: const Icon(
                                        Icons.logout_rounded,
                                      ),
                                    ),
                            );
                          }),
                      ] else
                        const Text(
                          'Полный список активных входов пока доступен не для всех ролей.',
                        ),
                      const SizedBox(height: 16),
                      Text(
                        'Сохранённые входы на этом устройстве',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (localSavedSessions.isEmpty)
                        const Text('На этом устройстве нет других сохранённых входов.')
                      else
                        ...localSavedSessions.map((row) {
                          final id = (row['id'] ?? '').toString().trim();
                          final title = ((row['tenant_name'] ?? row['tenant_code']) ?? '')
                              .toString()
                              .trim();
                          final subtitle =
                              '${(row['role'] ?? 'client').toString()} • ${(row['email'] ?? '').toString().trim()}';
                          final active = id == _currentSavedSessionId;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              active
                                  ? Icons.check_circle_rounded
                                  : Icons.account_circle_outlined,
                            ),
                            title: Text(
                              title.isEmpty ? 'Группа Феникс' : title,
                            ),
                            subtitle: Text(subtitle),
                            trailing: active || id.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Убрать с этого устройства',
                                    onPressed: busy
                                        ? null
                                        : () => removeSavedSession(
                                              setDialogState,
                                              id,
                                            ),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                          );
                        }),
                      if (localError.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          localError,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy
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
            final raw =
                ((android['landing_url'] ?? android['download_url']) ?? '')
                    .toString()
                    .trim();
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

  void _openNotificationCenter() {
    if (!_canOpenNotificationCenter) {
      showAppNotice(
        context,
        'Раздел событий доступен только создателю.',
        tone: AppNoticeTone.info,
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
  }

  void _openNotificationPreferences() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationPreferencesScreen()),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
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
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
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
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing:
            trailing ??
            const Icon(Icons.chevron_right_rounded, size: 20),
        onTap: onTap,
      ),
    );
  }

  Widget _buildValueCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _qualityLabel(String value) {
    switch (value.trim().toLowerCase()) {
      case 'file':
        return 'Как файл';
      case 'hd':
        return 'HD';
      case 'standard':
      default:
        return 'Стандарт';
    }
  }

  Widget _buildPolicyField({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      items: items,
      onChanged: (_messengerPrefsLoading || _messengerPrefsSaving)
          ? null
          : onChanged,
    );
  }

  Future<void> _openStorageManager() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatStorageScreen(
          onClearVisualCache: _clearVisualCache,
          onClearSavedSessions: _clearSavedSessionsOnDevice,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = _displayPhone;
    final email = _displayEmail;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.all(16),
          children: [
            _buildSectionCard(
              icon: Icons.security_rounded,
              title: 'Аккаунт и безопасность',
              subtitle:
                  'Почта, телефон, пароль, защита входа и управление устройствами.',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildValueCard(
                        icon: Icons.person_outline_rounded,
                        label: 'Ваш аккаунт',
                        value: _displayName,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildValueCard(
                        icon: Icons.verified_user_outlined,
                        label: 'Роль',
                        value: _currentRoleLabel,
                      ),
                    ),
                  ],
                ),
                if (email.isNotEmpty || phone.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (email.isNotEmpty)
                        Expanded(
                          child: _buildValueCard(
                            icon: Icons.mail_outline_rounded,
                            label: 'Email',
                            value: email,
                          ),
                        ),
                      if (email.isNotEmpty && phone.isNotEmpty)
                        const SizedBox(width: 10),
                      if (phone.isNotEmpty)
                        Expanded(
                          child: _buildValueCard(
                            icon: Icons.phone_outlined,
                            label: 'Телефон',
                            value: phone,
                          ),
                        ),
                    ],
                  ),
                ],
                _buildActionTile(
                  icon: Icons.password_rounded,
                  title: 'Сменить пароль',
                  subtitle: 'Обновить пароль входа в аккаунт.',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ChangePasswordScreen(),
                    ),
                  ),
                ),
                _buildActionTile(
                  icon: Icons.phone_android_outlined,
                  title: 'Сменить номер телефона',
                  subtitle: 'Обновить номер, привязанный к аккаунту.',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ChangePhoneScreen(),
                    ),
                  ),
                ),
                if (_twoFactorEligible)
                  _buildActionTile(
                    icon: Icons.shield_outlined,
                    title: 'Двухфакторная защита',
                    subtitle: _twoFactorEnabled
                        ? (_twoFactorEnabledAt != null
                              ? 'Включена • $_twoFactorEnabledAt'
                              : 'Включена')
                        : 'Выключена. Можно добавить одноразовый код для входа.',
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
                  _buildActionTile(
                    icon: Icons.key_outlined,
                    title: 'Резервные коды и доверенные устройства',
                    subtitle:
                        'Кодов: $_twoFactorBackupCodesRemaining • Доверенных устройств: $_twoFactorTrustedDevicesCount',
                    onTap: _openTwoFactorRecoveryCenter,
                  ),
                _buildActionTile(
                  icon: Icons.devices_other_outlined,
                  title: 'Устройства и входы',
                  subtitle:
                      'Посмотреть активные входы, завершить лишние и убрать сохранённые входы с устройства.',
                  onTap: _openSessionsDialog,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Выйти'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _deletingAccount ? null : _deleteAccount,
                      icon: _deletingAccount
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.delete_forever_outlined),
                      label: Text(
                        _deletingAccount
                            ? 'Удаление...'
                            : 'Удалить аккаунт',
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _buildSectionCard(
              icon: Icons.notifications_active_outlined,
              title: 'Уведомления',
              subtitle:
                  'Личные сообщения, поддержка, акции, системные разрешения и история событий.',
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SwitchListTile.adaptive(
                    value: _notifications,
                    onChanged: _toggleNotifications,
                    title: const Text('Уведомления на этом устройстве'),
                    subtitle: const Text(
                      'Отключает звуки, локальные подсказки и push именно на этом устройстве.',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _buildActionTile(
                  icon: Icons.tune_rounded,
                  title: _isClientBaseRole
                      ? 'Уведомления Феникс'
                      : 'Настройки уведомлений Феникс',
                  subtitle: _isClientBaseRole
                      ? 'Личные сообщения, поддержка, акции, обновления и другие категории.'
                      : 'Категории уведомлений, каналы доставки и более точные настройки.',
                  onTap: _openNotificationPreferences,
                ),
                _buildActionTile(
                  icon: Icons.help_outline_rounded,
                  title: 'Как включить системные уведомления',
                  subtitle:
                      'Короткая инструкция для телефона, браузера и системных настроек.',
                  onTap: _showNotificationGuide,
                ),
                if (_canOpenNotificationCenter)
                  _buildActionTile(
                    icon: Icons.notifications_none_rounded,
                    title: 'Центр уведомлений',
                    subtitle:
                        'История событий, счётчики и быстрые переходы по важным действиям.',
                    onTap: _openNotificationCenter,
                  ),
              ],
            ),
            _buildSectionCard(
              icon: Icons.palette_outlined,
              title: 'Внешний вид и работа',
              subtitle:
                  'Тема, производительность и инструменты, связанные с работой приложения.',
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SwitchListTile.adaptive(
                    value: _darkMode,
                    onChanged: _toggleDarkMode,
                    title: const Text('Тёмная тема'),
                    subtitle: const Text(
                      'Переключить внешний вид приложения между светлым и тёмным режимом.',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SwitchListTile.adaptive(
                    value: _performanceMode,
                    onChanged: _togglePerformanceMode,
                    title: const Text('Режим для старых устройств'),
                    subtitle: const Text(
                      'Меньше анимаций и более лёгкая отрисовка для слабых устройств.',
                    ),
                  ),
                ),
                if (_canOpenThermalPrinter) ...[
                  const SizedBox(height: 10),
                  _buildActionTile(
                    icon: Icons.print_outlined,
                    title: 'Термопринтер и печать',
                    subtitle:
                        'Проверка печати чеков и служебных макетов с десктоп-сайта.',
                    onTap: _openPrinterTest,
                  ),
                ],
              ],
            ),
            _buildSectionCard(
              icon: Icons.wifi_tethering_outlined,
              title: 'Медиа и сеть',
              subtitle:
                  'Автозагрузка медиа, поведение на Wi‑Fi/сотовой сети и базовая политика качества.',
              children: [
                if (_messengerPrefsLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _buildPolicyField(
                    label: 'Фото: автозагрузка',
                    value: _messengerPrefs.mediaAutoDownloadImages,
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('Никогда')),
                      DropdownMenuItem(value: 'wifi', child: Text('Только Wi‑Fi')),
                      DropdownMenuItem(
                        value: 'wifi_cellular',
                        child: Text('Wi‑Fi и сотовая сеть'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaAutoDownloadImages: value,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildPolicyField(
                    label: 'Голосовые: автозагрузка',
                    value: _messengerPrefs.mediaAutoDownloadAudio,
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('Никогда')),
                      DropdownMenuItem(value: 'wifi', child: Text('Только Wi‑Fi')),
                      DropdownMenuItem(
                        value: 'wifi_cellular',
                        child: Text('Wi‑Fi и сотовая сеть'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaAutoDownloadAudio: value,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildPolicyField(
                    label: 'Видео: автозагрузка',
                    value: _messengerPrefs.mediaAutoDownloadVideo,
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('Никогда')),
                      DropdownMenuItem(value: 'wifi', child: Text('Только Wi‑Fi')),
                      DropdownMenuItem(
                        value: 'wifi_cellular',
                        child: Text('Wi‑Fi и сотовая сеть'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaAutoDownloadVideo: value,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildPolicyField(
                    label: 'Документы: автозагрузка',
                    value: _messengerPrefs.mediaAutoDownloadDocuments,
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('Никогда')),
                      DropdownMenuItem(value: 'wifi', child: Text('Только Wi‑Fi')),
                      DropdownMenuItem(
                        value: 'wifi_cellular',
                        child: Text('Wi‑Fi и сотовая сеть'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaAutoDownloadDocuments: value,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildValueCard(
                          icon: Icons.wifi_rounded,
                          label: 'Отправка по Wi‑Fi',
                          value: _qualityLabel(
                            _messengerPrefs.mediaSendQualityWifi,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildValueCard(
                          icon: Icons.network_cell_rounded,
                          label: 'Отправка по сотовой сети',
                          value: _qualityLabel(
                            _messengerPrefs.mediaSendQualityCellular,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPolicyField(
                    label: 'Качество по Wi‑Fi',
                    value: _messengerPrefs.mediaSendQualityWifi,
                    items: const [
                      DropdownMenuItem(value: 'standard', child: Text('Стандарт')),
                      DropdownMenuItem(value: 'hd', child: Text('HD')),
                      DropdownMenuItem(value: 'file', child: Text('Как файл')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaSendQualityWifi: value,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildPolicyField(
                    label: 'Качество по сотовой сети',
                    value: _messengerPrefs.mediaSendQualityCellular,
                    items: const [
                      DropdownMenuItem(value: 'standard', child: Text('Стандарт')),
                      DropdownMenuItem(value: 'hd', child: Text('HD')),
                      DropdownMenuItem(value: 'file', child: Text('Как файл')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(
                        _updateMessengerPreferences(
                          _messengerPrefs.copyWith(
                            mediaSendQualityCellular: value,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
            _buildSectionCard(
              icon: Icons.privacy_tip_outlined,
              title: 'Конфиденциальность и данные',
              subtitle:
                  'Разрешения приложения, локальные данные и очистка кэша.',
              children: [
                _buildActionTile(
                  icon: Icons.storage_outlined,
                  title: 'Хранилище чатов и медиа',
                  subtitle:
                      'Размер локального outbox, кэш изображений и очистка хвостов загрузки.',
                  onTap: _openStorageManager,
                ),
                _buildActionTile(
                  icon: Icons.perm_device_information_outlined,
                  title: 'Разрешения приложения',
                  subtitle:
                      'Уведомления, камера, фото, микрофон и геолокация — где и зачем они нужны.',
                  onTap: _openPermissionsGuide,
                ),
                _buildActionTile(
                  icon: Icons.image_not_supported_outlined,
                  title: 'Очистить кэш изображений',
                  subtitle:
                      'Очистить локальный кэш фото и медиа, чтобы освободить память устройства.',
                  trailing: _cacheBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cleaning_services_outlined),
                  onTap: _cacheBusy ? null : _clearVisualCache,
                ),
                _buildActionTile(
                  icon: Icons.phonelink_erase_outlined,
                  title: 'Очистить сохранённые входы на устройстве',
                  subtitle:
                      'Удалить локально сохранённые группы и входы, которые больше не нужны.',
                  trailing: const Icon(Icons.delete_sweep_outlined),
                  onTap: _clearSavedSessionsOnDevice,
                ),
              ],
            ),
            _buildSectionCard(
              icon: Icons.support_agent_rounded,
              title: 'Поддержка и помощь',
              subtitle:
                  'Частые вопросы, обращение в поддержку и сообщение о проблеме.',
              children: [
                if (_canOpenSupport)
                  _buildActionTile(
                    icon: Icons.forum_outlined,
                    title: 'Поддержка',
                    subtitle:
                        'Открыть помощь, частые вопросы и написать в поддержку.',
                    onTap: _openSupport,
                  ),
                if (_canReportProblem)
                  _buildActionTile(
                    icon: Icons.report_problem_outlined,
                    title: 'Сообщить о проблеме',
                    subtitle:
                        'Быстро отправить описание ошибки в отдельный служебный канал.',
                    onTap: _openBugReport,
                  ),
                _buildActionTile(
                  icon: Icons.notifications_paused_outlined,
                  title: 'Если уведомления не приходят',
                  subtitle:
                      'Открыть короткую инструкцию по разрешениям и системным настройкам.',
                  onTap: _showNotificationGuide,
                ),
              ],
            ),
            _buildSectionCard(
              icon: Icons.info_outline_rounded,
              title: 'О приложении',
              subtitle:
                  'Версия, платформа, обновления и загрузка Android APK.',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildValueCard(
                        icon: Icons.tag_outlined,
                        label: 'Версия',
                        value: _appVersionLabel,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildValueCard(
                        icon: Icons.devices_outlined,
                        label: 'Платформа',
                        value: _appPlatformLabel.isEmpty
                            ? 'Феникс'
                            : _appPlatformLabel,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_isAndroidWeb)
                  _buildActionTile(
                    icon: _apkInfoLoading
                        ? Icons.downloading_rounded
                        : Icons.download_for_offline_outlined,
                    title: 'Скачать APK для Android',
                    subtitle: _apkInfoMessage.isEmpty
                        ? 'Проверяем, доступна ли загрузка APK'
                        : _apkInfoMessage,
                    trailing: _apkInfoLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded, size: 20),
                    onTap: _apkInfoLoading ? null : _openApkDownload,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

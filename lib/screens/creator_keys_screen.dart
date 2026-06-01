import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../utils/date_time_utils.dart';
import '../widgets/input_language_badge.dart';

class CreatorKeysScreen extends StatefulWidget {
  const CreatorKeysScreen({super.key});

  @override
  State<CreatorKeysScreen> createState() => _CreatorKeysScreenState();
}

class _CreatorKeysScreenState extends State<CreatorKeysScreen> {
  static const String _platformCreatorEmail = 'zerotwo02166@gmail.com';
  static final RegExp _tenantAccessKeyTemplateRegExp = RegExp(
    r'^[A-Z]{3}-[A-Z0-9]{1,32}-KEY$',
  );

  final _tenantNameCtrl = TextEditingController();
  final _tenantNotesCtrl = TextEditingController();
  final _tenantMonthsCtrl = TextEditingController(text: '1');
  final _tenantPublicationIntervalSecondsCtrl = TextEditingController(
    text: '2',
  );
  final _tenantAutoProcessingDelayCtrl = TextEditingController(text: '60');
  final _tenantDeliveryMinAmountCtrl = TextEditingController(text: '1500');
  final _tenantClientCitiesCtrl = TextEditingController();

  bool _loading = true;
  bool _tenantActionLoading = false;
  bool _tenantsLoading = false;
  bool _tenantAutoProcessingEnabled = false;
  bool _tenantManualShelfEnabled = false;
  bool _tenantPickupOnlyEnabled = false;
  bool _tenantCartDeliveryReadyEnabled = false;
  bool _tenantDeliverySnapshotOnAdminApprove = false;
  bool _tenantRevisionDeleteApprovalEnabled = false;
  bool _tenantDefectStatsEnabled = false;

  String _message = '';
  String _lastGeneratedTenantKey = '';
  String _selectedTenantId = '';
  String _selectedTenantCode = '';

  List<Map<String, dynamic>> _tenants = [];

  bool get _isPlatformCreator {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    final email = (authService.currentUser?.email ?? '').toLowerCase().trim();
    return role == 'creator' && email == _platformCreatorEmail;
  }

  Options _creatorRequestOptions() {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    if (role == 'creator') {
      return Options(headers: const {'X-View-Role': 'creator'});
    }
    return Options();
  }

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  @override
  void dispose() {
    _tenantNameCtrl.dispose();
    _tenantNotesCtrl.dispose();
    _tenantMonthsCtrl.dispose();
    _tenantPublicationIntervalSecondsCtrl.dispose();
    _tenantAutoProcessingDelayCtrl.dispose();
    _tenantDeliveryMinAmountCtrl.dispose();
    _tenantClientCitiesCtrl.dispose();
    super.dispose();
  }

  String _extractDioError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final text = (data['error'] ?? data['message'] ?? '').toString().trim();
        if (text.isNotEmpty) return text;
      }
      return e.message ?? 'Ошибка запроса';
    }
    return e.toString();
  }

  String _composeTenantAccessKey({
    required String prefix,
    required String middle,
  }) {
    final cleanPrefix = prefix.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    final cleanMiddle = middle.toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    final candidate = '$cleanPrefix-$cleanMiddle-KEY';
    if (_tenantAccessKeyTemplateRegExp.hasMatch(candidate)) return candidate;
    return '';
  }

  int _tenantMonthsOrDefault() {
    final parsed = int.tryParse(_tenantMonthsCtrl.text.trim());
    if (parsed == null) return 1;
    return parsed.clamp(1, 24).toInt();
  }

  bool _toBoolValue(dynamic value) {
    if (value is bool) return value;
    final normalized = (value ?? '').toString().trim().toLowerCase();
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'on' ||
        normalized == 'да';
  }

  int _parseIntValue(
    String raw, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return fallback;
    return parsed.clamp(min, max).toInt();
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<String> _stringListFromText(String raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final line in raw.split(RegExp(r'\r?\n|,'))) {
      final value = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isEmpty) continue;
      final key = value.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      result.add(value);
      if (result.length >= 80) break;
    }
    return result;
  }

  List<String> _stringListFromSettings(dynamic raw) {
    if (raw is List) {
      return raw
          .map((item) => item.toString().replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return _stringListFromText((raw ?? '').toString());
  }

  Map<String, dynamic> _tenantWorkflowPayload({
    required TextEditingController publicationSecondsCtrl,
    required TextEditingController autoDelayCtrl,
    required TextEditingController minAmountCtrl,
    required TextEditingController citiesCtrl,
    required bool autoProcessingEnabled,
    required bool manualShelfEnabled,
    required bool pickupOnlyEnabled,
    required bool deliveryReadyEnabled,
    required bool deliverySnapshotOnAdminApprove,
    required bool revisionDeleteApprovalEnabled,
    required bool defectStatsEnabled,
  }) {
    final publicationSeconds = _parseIntValue(
      publicationSecondsCtrl.text,
      fallback: 2,
      min: 1,
      max: 600,
    );
    final autoDelayMinutes = _parseIntValue(
      autoDelayCtrl.text,
      fallback: 60,
      min: 1,
      max: 1440,
    );
    final minAmount = _parseIntValue(
      minAmountCtrl.text,
      fallback: 1500,
      min: 0,
      max: 10000000,
    );
    final cities = _stringListFromText(citiesCtrl.text);
    final workflowSettings = <String, dynamic>{
      'version': 1,
      'product_processing': {
        'mode': autoProcessingEnabled ? 'auto_after_delay' : 'manual',
        'auto_delay_minutes': autoDelayMinutes,
      },
      'delivery': {
        'mode': deliverySnapshotOnAdminApprove
            ? 'snapshot_after_admin_approve'
            : 'classic',
        'client_ready_button': deliveryReadyEnabled,
        'min_amount': minAmount,
        'snapshot_on_admin_approve': deliverySnapshotOnAdminApprove,
      },
      'worker': {
        'manual_shelf_enabled': manualShelfEnabled,
        'pickup_only_enabled': pickupOnlyEnabled,
        'revision_delete_approval_enabled': revisionDeleteApprovalEnabled,
      },
      'channels': {'publication_interval_ms': publicationSeconds * 1000},
      'registration': {'client_city_options': cities},
      'analytics': {'defect_stats_enabled': defectStatsEnabled},
    };
    return {
      'workflow_settings': workflowSettings,
      'client_city_options': cities,
    };
  }

  Map<String, dynamic> _createTenantWorkflowPayload() {
    return _tenantWorkflowPayload(
      publicationSecondsCtrl: _tenantPublicationIntervalSecondsCtrl,
      autoDelayCtrl: _tenantAutoProcessingDelayCtrl,
      minAmountCtrl: _tenantDeliveryMinAmountCtrl,
      citiesCtrl: _tenantClientCitiesCtrl,
      autoProcessingEnabled: _tenantAutoProcessingEnabled,
      manualShelfEnabled: _tenantManualShelfEnabled,
      pickupOnlyEnabled: _tenantPickupOnlyEnabled,
      deliveryReadyEnabled: _tenantCartDeliveryReadyEnabled,
      deliverySnapshotOnAdminApprove: _tenantDeliverySnapshotOnAdminApprove,
      revisionDeleteApprovalEnabled: _tenantRevisionDeleteApprovalEnabled,
      defectStatsEnabled: _tenantDefectStatsEnabled,
    );
  }

  void _resetCreateTenantSettings() {
    _tenantPublicationIntervalSecondsCtrl.text = '2';
    _tenantAutoProcessingDelayCtrl.text = '60';
    _tenantDeliveryMinAmountCtrl.text = '1500';
    _tenantClientCitiesCtrl.clear();
    _tenantAutoProcessingEnabled = false;
    _tenantManualShelfEnabled = false;
    _tenantPickupOnlyEnabled = false;
    _tenantCartDeliveryReadyEnabled = false;
    _tenantDeliverySnapshotOnAdminApprove = false;
    _tenantRevisionDeleteApprovalEnabled = false;
    _tenantDefectStatsEnabled = false;
  }

  Future<void> _reloadAll() async {
    if (!_isPlatformCreator) {
      if (mounted) {
        setState(() {
          _loading = false;
          _tenants = [];
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _message = '';
      });
    }
    await _loadTenants(silent: true);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadTenants({bool silent = false}) async {
    if (!_isPlatformCreator) return;
    if (mounted && !silent) {
      setState(() => _tenantsLoading = true);
    } else {
      _tenantsLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/tenants',
        options: _creatorRequestOptions(),
      );
      final data = resp.data;
      if (data is Map &&
          data['ok'] == true &&
          data['data'] is List &&
          mounted) {
        final rows = List<Map<String, dynamic>>.from(
          data['data'],
        ).where((row) => row['is_deleted'] != true).toList();
        String selectedId = _selectedTenantId;
        String selectedCode = _selectedTenantCode;
        if (rows.isNotEmpty) {
          final hasSelected =
              selectedId.isNotEmpty &&
              rows.any((row) => (row['id'] ?? '').toString() == selectedId);
          if (!hasSelected) {
            selectedId = (rows.first['id'] ?? '').toString();
            selectedCode = (rows.first['code'] ?? '').toString();
          } else {
            final selected = rows.firstWhere(
              (row) => (row['id'] ?? '').toString() == selectedId,
              orElse: () => rows.first,
            );
            selectedCode = (selected['code'] ?? '').toString();
          }
        } else {
          selectedId = '';
          selectedCode = '';
        }
        setState(() {
          _tenants = rows;
          _selectedTenantId = selectedId;
          _selectedTenantCode = selectedCode;
        });
      }
    } catch (e) {
      if (mounted && !silent) {
        setState(
          () => _message = 'Ошибка загрузки ключей: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _tenantsLoading = false);
      } else {
        _tenantsLoading = false;
      }
    }
  }

  Future<void> _createTenantKey() async {
    final name = _tenantNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _message = 'Введите название арендатора');
      return;
    }

    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });

    try {
      final resp = await authService.dio.post(
        '/api/admin/tenants',
        data: {
          'name': name,
          'months': _tenantMonthsOrDefault(),
          if (_tenantNotesCtrl.text.trim().isNotEmpty)
            'notes': _tenantNotesCtrl.text.trim(),
          ..._createTenantWorkflowPayload(),
        },
        options: _creatorRequestOptions(),
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final row = Map<String, dynamic>.from(data['data']);
        final warning = (row['warning'] ?? '').toString().trim();
        if (mounted) {
          setState(() {
            _lastGeneratedTenantKey = (row['access_key'] ?? '').toString();
            _tenantNameCtrl.clear();
            _tenantNotesCtrl.clear();
            _tenantMonthsCtrl.text = '1';
            _resetCreateTenantSettings();
            _message = warning.isNotEmpty
                ? 'Ключ создан. $warning'
                : 'Ключ арендатора создан';
          });
        }
        await _loadTenants(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка создания ключа: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _confirmTenantPayment(String tenantId, {int months = 1}) async {
    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/tenants/$tenantId/confirm-payment',
        data: {'months': months.clamp(1, 24)},
        options: _creatorRequestOptions(),
      );
      if (mounted) setState(() => _message = 'Оплата подтверждена');
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка оплаты: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _setTenantStatus(String tenantId, String status) async {
    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/tenants/$tenantId/status',
        data: {'status': status},
        options: _creatorRequestOptions(),
      );
      if (mounted) {
        setState(() {
          _message = status == 'active'
              ? 'Ключ активирован'
              : 'Ключ заблокирован';
        });
      }
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка статуса: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _deleteTenant(String tenantId, String tenantName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить ключ арендатора'),
        content: Text(
          'Арендатор "$tenantName" будет отключен.\n'
          'Его подписка станет недействительной.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      await authService.dio.delete(
        '/api/admin/tenants/$tenantId',
        options: _creatorRequestOptions(),
      );
      if (!mounted) return;
      setState(() {
        _message = 'Ключ арендатора удален';
        _tenants.removeWhere((row) => (row['id'] ?? '').toString() == tenantId);
        if (_selectedTenantId == tenantId) {
          if (_tenants.isNotEmpty) {
            _selectedTenantId = (_tenants.first['id'] ?? '').toString();
            _selectedTenantCode = (_tenants.first['code'] ?? '').toString();
          } else {
            _selectedTenantId = '';
            _selectedTenantCode = '';
          }
        }
      });
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _changeTenantAccessKey(
    String tenantId,
    String tenantName,
    String currentKey,
  ) async {
    final detectedPrefix = RegExp(
      r'^([A-Z]{3})-',
    ).firstMatch(currentKey.toUpperCase().trim())?.group(1);
    final prefixCtrl = TextEditingController(text: detectedPrefix ?? 'PHX');
    final middleCtrl = TextEditingController();
    final nextKey = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String errorText = '';
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Изменить ключ арендатора'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Арендатор: ${tenantName.isEmpty ? 'Без названия' : tenantName}',
                ),
                const SizedBox(height: 4),
                Text('Текущий ключ: $currentKey'),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: prefixCtrl,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 3,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z]'),
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Код',
                          hintText: 'PHX',
                          counterText: '',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: middleCtrl,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 32,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z0-9]'),
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Шифр',
                          hintText: 'ABCDEF',
                          counterText: '',
                          border: const OutlineInputBorder(),
                          errorText: errorText.isEmpty ? null : errorText,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 92,
                      child: TextFormField(
                        initialValue: 'KEY',
                        enabled: false,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: 'Ключ',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Формат ключа: (PHX)(ВАШКОД)(KEY)\nСлева 3 буквы, справа всегда KEY, по центру буквы/цифры.',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Примеры кода: PHX, ARX, RTX, RSO, PFO.',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              FilledButton.tonal(
                onPressed: () {
                  final normalized = _composeTenantAccessKey(
                    prefix: prefixCtrl.text,
                    middle: middleCtrl.text,
                  );
                  if (normalized.isEmpty) {
                    setDialogState(
                      () => errorText = 'Формат: XXX-<буквы/цифры>-KEY',
                    );
                    return;
                  }
                  Navigator.pop(ctx, normalized);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
      },
    );
    prefixCtrl.dispose();
    middleCtrl.dispose();
    if (nextKey == null) return;

    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      final payload = <String, dynamic>{'access_key': nextKey};
      final resp = await authService.dio.patch(
        '/api/admin/tenants/$tenantId/access-key',
        data: payload,
        options: _creatorRequestOptions(),
      );
      final data = resp.data;
      final newKey = data is Map && data['data'] is Map
          ? (data['data']['access_key'] ?? '').toString()
          : '';
      if (!mounted) return;
      setState(() {
        _lastGeneratedTenantKey = newKey;
        _message = newKey.isNotEmpty
            ? 'Ключ арендатора обновлен'
            : 'Ключ обновлен, но значение не получено';
      });
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка смены ключа: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _openTenantSettings(String tenantId, String tenantName) async {
    if (tenantId.isEmpty) return;
    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    Map<String, dynamic> settings = <String, dynamic>{};
    try {
      final resp = await authService.dio.get(
        '/api/admin/tenants/$tenantId/feature-settings',
        options: _creatorRequestOptions(),
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        settings = Map<String, dynamic>.from(data['data'] as Map);
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка загрузки настроек: ${_extractDioError(e)}',
      );
      return;
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
    if (!mounted) return;

    final payload = await _showTenantSettingsEditor(
      title: tenantName.isEmpty ? 'Настройки группы' : 'Настройки: $tenantName',
      initialSettings: settings,
    );
    if (payload == null) return;

    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/tenants/$tenantId/feature-settings',
        data: payload,
        options: _creatorRequestOptions(),
      );
      if (!mounted) return;
      setState(() => _message = 'Настройки сохранены');
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка сохранения настроек: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<Map<String, dynamic>?> _showTenantSettingsEditor({
    required String title,
    required Map<String, dynamic> initialSettings,
  }) async {
    final productProcessing = _asMap(initialSettings['product_processing']);
    final delivery = _asMap(initialSettings['delivery']);
    final worker = _asMap(initialSettings['worker']);
    final channels = _asMap(initialSettings['channels']);
    final registration = _asMap(initialSettings['registration']);
    final analytics = _asMap(initialSettings['analytics']);

    final publicationMs = _parseIntValue(
      (channels['publication_interval_ms'] ??
              initialSettings['publication_interval_ms'] ??
              2000)
          .toString(),
      fallback: 2000,
      min: 500,
      max: 600000,
    );
    final publicationSecondsCtrl = TextEditingController(
      text: (publicationMs / 1000).round().clamp(1, 600).toString(),
    );
    final autoDelayCtrl = TextEditingController(
      text:
          (productProcessing['auto_delay_minutes'] ??
                  initialSettings['auto_product_processing_delay_minutes'] ??
                  60)
              .toString(),
    );
    final minAmountCtrl = TextEditingController(
      text:
          (delivery['min_amount'] ??
                  initialSettings['cart_delivery_ready_min_amount'] ??
                  1500)
              .toString(),
    );
    final citiesCtrl = TextEditingController(
      text: _stringListFromSettings(
        registration['client_city_options'] ??
            initialSettings['client_city_options'],
      ).join('\n'),
    );

    var autoProcessingEnabled =
        (productProcessing['mode'] ??
                    initialSettings['product_processing_mode'] ??
                    '')
                .toString() ==
            'auto_after_delay' ||
        _toBoolValue(initialSettings['auto_product_processing_enabled']);
    var manualShelfEnabled = _toBoolValue(
      worker['manual_shelf_enabled'] ?? initialSettings['manual_shelf_enabled'],
    );
    var pickupOnlyEnabled = _toBoolValue(
      worker['pickup_only_enabled'] ?? initialSettings['pickup_only_enabled'],
    );
    var deliveryReadyEnabled = _toBoolValue(
      delivery['client_ready_button'] ??
          initialSettings['cart_delivery_ready_enabled'],
    );
    var deliverySnapshotOnAdminApprove = _toBoolValue(
      delivery['snapshot_on_admin_approve'] ??
          initialSettings['delivery_snapshot_on_admin_approve'],
    );
    var revisionDeleteApprovalEnabled = _toBoolValue(
      worker['revision_delete_approval_enabled'] ??
          initialSettings['revision_delete_approval_enabled'],
    );
    var defectStatsEnabled = _toBoolValue(
      analytics['defect_stats_enabled'] ??
          initialSettings['defect_stats_enabled'],
    );

    try {
      return await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _settingsSectionTitle('Каналы'),
                    _settingsNumberField(
                      controller: publicationSecondsCtrl,
                      labelText: 'Интервал публикации постов',
                      suffixText: 'сек',
                      helperText: 'От 1 до 600 секунд.',
                    ),
                    _settingsSectionTitle('Обработка товара'),
                    _settingsSwitchTile(
                      title: 'Автообработка товара',
                      subtitle: 'Через заданное время после покупки.',
                      value: autoProcessingEnabled,
                      onChanged: (value) =>
                          setDialogState(() => autoProcessingEnabled = value),
                    ),
                    _settingsNumberField(
                      controller: autoDelayCtrl,
                      labelText: 'Через сколько минут автообработка',
                      suffixText: 'мин',
                      helperText: 'От 1 минуты до 24 часов.',
                    ),
                    _settingsSectionTitle('Доставка'),
                    _settingsSwitchTile(
                      title: 'Кнопка клиента "Готов на доставку"',
                      subtitle: 'Кнопка активируется от указанной суммы.',
                      value: deliveryReadyEnabled,
                      onChanged: (value) =>
                          setDialogState(() => deliveryReadyEnabled = value),
                    ),
                    _settingsNumberField(
                      controller: minAmountCtrl,
                      labelText: 'Готов на доставку от суммы',
                      suffixText: '₽',
                      helperText: 'Минимальная сумма обработанных товаров.',
                    ),
                    _settingsSwitchTile(
                      title: 'Сборка доставки после подтверждения админа',
                      subtitle: 'Черновой режим новой логики доставки.',
                      value: deliverySnapshotOnAdminApprove,
                      onChanged: (value) => setDialogState(
                        () => deliverySnapshotOnAdminApprove = value,
                      ),
                    ),
                    _settingsSectionTitle('Рабочий'),
                    _settingsSwitchTile(
                      title: 'Ручная полка у рабочего',
                      subtitle: 'Рабочий сможет вводить любую полку вручную.',
                      value: manualShelfEnabled,
                      onChanged: (value) =>
                          setDialogState(() => manualShelfEnabled = value),
                    ),
                    _settingsSwitchTile(
                      title: 'Самовывоз',
                      subtitle: 'Рабочий сможет отмечать товар как самовывоз.',
                      value: pickupOnlyEnabled,
                      onChanged: (value) =>
                          setDialogState(() => pickupOnlyEnabled = value),
                    ),
                    _settingsSwitchTile(
                      title: 'Удаление в ревизии через администратора',
                      subtitle: 'Рабочий отправляет запрос, админ решает.',
                      value: revisionDeleteApprovalEnabled,
                      onChanged: (value) => setDialogState(
                        () => revisionDeleteApprovalEnabled = value,
                      ),
                    ),
                    _settingsSectionTitle('Регистрация'),
                    TextField(
                      controller: citiesCtrl,
                      minLines: 3,
                      maxLines: 7,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Города клиентов',
                          helperText: 'Каждый город с новой строки.',
                          border: OutlineInputBorder(),
                        ),
                        controller: citiesCtrl,
                      ),
                    ),
                    _settingsSectionTitle('Статистика'),
                    _settingsSwitchTile(
                      title: 'Статистика брака',
                      subtitle: 'Включает будущий учёт брака и возвратов.',
                      value: defectStatsEnabled,
                      onChanged: (value) =>
                          setDialogState(() => defectStatsEnabled = value),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(
                    ctx,
                    _tenantWorkflowPayload(
                      publicationSecondsCtrl: publicationSecondsCtrl,
                      autoDelayCtrl: autoDelayCtrl,
                      minAmountCtrl: minAmountCtrl,
                      citiesCtrl: citiesCtrl,
                      autoProcessingEnabled: autoProcessingEnabled,
                      manualShelfEnabled: manualShelfEnabled,
                      pickupOnlyEnabled: pickupOnlyEnabled,
                      deliveryReadyEnabled: deliveryReadyEnabled,
                      deliverySnapshotOnAdminApprove:
                          deliverySnapshotOnAdminApprove,
                      revisionDeleteApprovalEnabled:
                          revisionDeleteApprovalEnabled,
                      defectStatsEnabled: defectStatsEnabled,
                    ),
                  );
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('Сохранить'),
              ),
            ],
          ),
        ),
      );
    } finally {
      publicationSecondsCtrl.dispose();
      autoDelayCtrl.dispose();
      minAmountCtrl.dispose();
      citiesCtrl.dispose();
    }
  }

  Widget _settingsSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }

  Widget _settingsNumberField({
    required TextEditingController controller,
    required String labelText,
    required String suffixText,
    String? helperText,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: withInputLanguageBadge(
          InputDecoration(
            labelText: labelText,
            suffixText: suffixText,
            helperText: helperText,
            border: const OutlineInputBorder(),
          ),
          controller: controller,
        ),
      ),
    );
  }

  Widget _settingsSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _tenantCreateSettingsBlock() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        title: const Text(
          'Настройки группы',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: const Text('Черновая настройка логики для арендатора'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _settingsSectionTitle('Каналы'),
          _settingsNumberField(
            controller: _tenantPublicationIntervalSecondsCtrl,
            labelText: 'Интервал публикации постов',
            suffixText: 'сек',
            helperText: 'По умолчанию 2 секунды.',
          ),
          _settingsSectionTitle('Обработка товара'),
          _settingsSwitchTile(
            title: 'Автообработка товара',
            subtitle: 'Через заданное время после покупки.',
            value: _tenantAutoProcessingEnabled,
            onChanged: (value) =>
                setState(() => _tenantAutoProcessingEnabled = value),
          ),
          _settingsNumberField(
            controller: _tenantAutoProcessingDelayCtrl,
            labelText: 'Через сколько минут автообработка',
            suffixText: 'мин',
            helperText: 'По умолчанию 60 минут.',
          ),
          _settingsSectionTitle('Доставка'),
          _settingsSwitchTile(
            title: 'Кнопка клиента "Готов на доставку"',
            subtitle: 'Кнопка активируется от указанной суммы.',
            value: _tenantCartDeliveryReadyEnabled,
            onChanged: (value) =>
                setState(() => _tenantCartDeliveryReadyEnabled = value),
          ),
          _settingsNumberField(
            controller: _tenantDeliveryMinAmountCtrl,
            labelText: 'Готов на доставку от суммы',
            suffixText: '₽',
            helperText: 'По умолчанию 1500 ₽.',
          ),
          _settingsSwitchTile(
            title: 'Сборка доставки после подтверждения админа',
            subtitle: 'Черновой режим новой доставки.',
            value: _tenantDeliverySnapshotOnAdminApprove,
            onChanged: (value) =>
                setState(() => _tenantDeliverySnapshotOnAdminApprove = value),
          ),
          _settingsSectionTitle('Рабочий'),
          _settingsSwitchTile(
            title: 'Ручная полка у рабочего',
            subtitle: 'Рабочий сможет вводить любую полку вручную.',
            value: _tenantManualShelfEnabled,
            onChanged: (value) =>
                setState(() => _tenantManualShelfEnabled = value),
          ),
          _settingsSwitchTile(
            title: 'Самовывоз',
            subtitle: 'Рабочий сможет отмечать товар как самовывоз.',
            value: _tenantPickupOnlyEnabled,
            onChanged: (value) =>
                setState(() => _tenantPickupOnlyEnabled = value),
          ),
          _settingsSwitchTile(
            title: 'Удаление в ревизии через администратора',
            subtitle: 'Рабочий отправляет запрос, админ решает.',
            value: _tenantRevisionDeleteApprovalEnabled,
            onChanged: (value) =>
                setState(() => _tenantRevisionDeleteApprovalEnabled = value),
          ),
          _settingsSectionTitle('Регистрация'),
          TextField(
            controller: _tenantClientCitiesCtrl,
            minLines: 3,
            maxLines: 7,
            decoration: withInputLanguageBadge(
              const InputDecoration(
                labelText: 'Города клиентов',
                helperText: 'Каждый город с новой строки.',
                border: OutlineInputBorder(),
              ),
              controller: _tenantClientCitiesCtrl,
            ),
          ),
          _settingsSectionTitle('Статистика'),
          _settingsSwitchTile(
            title: 'Статистика брака',
            subtitle: 'Включает будущий учёт брака и возвратов.',
            value: _tenantDefectStatsEnabled,
            onChanged: (value) =>
                setState(() => _tenantDefectStatsEnabled = value),
          ),
        ],
      ),
    );
  }

  Widget _tenantCreateCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Новый арендатор',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tenantNameCtrl,
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  labelText: 'Название арендатора',
                  border: OutlineInputBorder(),
                ),
                controller: _tenantNameCtrl,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tenantMonthsCtrl,
              keyboardType: TextInputType.number,
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  labelText: 'Срок подписки (месяцы)',
                  border: OutlineInputBorder(),
                ),
                controller: _tenantMonthsCtrl,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tenantNotesCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  labelText: 'Заметка (опционально)',
                  border: OutlineInputBorder(),
                ),
                controller: _tenantNotesCtrl,
              ),
            ),
            const SizedBox(height: 12),
            _tenantCreateSettingsBlock(),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _tenantActionLoading ? null : _createTenantKey,
              icon: const Icon(Icons.key_outlined),
              label: Text(
                _tenantActionLoading ? 'Сохранение...' : 'Создать ключ',
              ),
            ),
            if (_lastGeneratedTenantKey.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Выданный ключ (показывается один раз):',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _lastGeneratedTenantKey,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _lastGeneratedTenantKey),
                        );
                        if (!mounted) return;
                        setState(() => _message = 'Ключ скопирован');
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Скопировать ключ'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tenantList() {
    if (_tenantsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_tenants.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Арендаторы пока не созданы'),
        ),
      );
    }

    return Column(
      children: _tenants.map((tenant) {
        final id = (tenant['id'] ?? '').toString();
        final name = (tenant['name'] ?? '').toString();
        final code = (tenant['code'] ?? '').toString();
        final status = (tenant['status'] ?? '').toString();
        final keyValue = (tenant['access_key_value'] ?? '').toString().trim();
        final keyShown = keyValue.isNotEmpty
            ? keyValue
            : 'Полный ключ не сохранен. Нажмите "Изменить ключ".';
        final subscription = formatDateTimeValue(
          tenant['subscription_expires_at'],
          fallback: '',
        );
        final isActive = status == 'active';

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name.isEmpty ? 'Без названия' : name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isActive
                            ? Colors.green.withValues(alpha: 0.15)
                            : Colors.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isActive
                              ? Colors.green.withValues(alpha: 0.5)
                              : Colors.red.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        isActive ? 'Оплачено' : 'Не оплачено',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: isActive
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Код: $code'),
                Text('Ключ: $keyShown'),
                if (subscription.isNotEmpty) Text('Подписка до: $subscription'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _tenantActionLoading
                          ? null
                          : () => _confirmTenantPayment(id, months: 1),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('+1 месяц'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _tenantActionLoading
                          ? null
                          : () => _setTenantStatus(
                              id,
                              isActive ? 'blocked' : 'active',
                            ),
                      icon: Icon(
                        isActive
                            ? Icons.block_outlined
                            : Icons.check_circle_outline,
                      ),
                      label: Text(isActive ? 'Отключить' : 'Активировать'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _tenantActionLoading
                          ? null
                          : () => _changeTenantAccessKey(id, name, keyShown),
                      icon: const Icon(Icons.key_outlined),
                      label: const Text('Изменить ключ'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _tenantActionLoading
                          ? null
                          : () => _openTenantSettings(id, name),
                      icon: const Icon(Icons.tune_outlined),
                      label: const Text('Настройки'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _tenantActionLoading
                          ? null
                          : () => _deleteTenant(id, name),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Удалить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isPlatformCreator) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ключи')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text('Доступ к ключам есть только у создателя платформы.'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ключи арендаторов')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _reloadAll,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_message.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _message,
                          style: TextStyle(
                            color: _message.toLowerCase().contains('ошибка')
                                ? Colors.red
                                : Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    _tenantCreateCard(),
                    const SizedBox(height: 10),
                    _tenantList(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
      ),
    );
  }
}

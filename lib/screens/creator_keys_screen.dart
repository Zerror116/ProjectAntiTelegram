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

  bool _loading = true;
  bool _tenantActionLoading = false;
  bool _tenantsLoading = false;

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
    return parsed.clamp(1, 24);
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

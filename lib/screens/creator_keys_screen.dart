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

  final _tenantNameCtrl = TextEditingController();
  final _tenantNotesCtrl = TextEditingController();
  final _tenantMonthsCtrl = TextEditingController(text: '1');
  final _inviteMaxUsesCtrl = TextEditingController();
  final _inviteExpiresDaysCtrl = TextEditingController(text: '30');
  final _inviteNotesCtrl = TextEditingController();

  bool _loading = true;
  bool _tenantActionLoading = false;
  bool _inviteActionLoading = false;
  bool _tenantsLoading = false;
  bool _invitesLoading = false;

  String _message = '';
  String _inviteRole = 'client';
  String _lastGeneratedTenantKey = '';
  String _lastInviteCode = '';
  String _lastInviteLink = '';
  String _selectedTenantId = '';
  String _selectedTenantCode = '';

  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _invites = [];

  bool get _isPlatformCreator {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    final email = (authService.currentUser?.email ?? '').toLowerCase().trim();
    return role == 'creator' && email == _platformCreatorEmail;
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
    _inviteMaxUsesCtrl.dispose();
    _inviteExpiresDaysCtrl.dispose();
    _inviteNotesCtrl.dispose();
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

  int _tenantMonthsOrDefault() {
    final parsed = int.tryParse(_tenantMonthsCtrl.text.trim());
    if (parsed == null) return 1;
    return parsed.clamp(1, 24);
  }

  int? _toPositiveIntOrNull(String raw, {int min = 1, int max = 100000}) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return null;
    return parsed.clamp(min, max);
  }

  int _toInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  String _roleLabel(String role) {
    switch (role.toLowerCase().trim()) {
      case 'admin':
        return 'Администратор';
      case 'worker':
        return 'Работник';
      case 'client':
      default:
        return 'Клиент';
    }
  }

  Future<void> _reloadAll() async {
    if (!_isPlatformCreator) {
      if (mounted) {
        setState(() {
          _loading = false;
          _tenants = [];
          _invites = [];
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
    await _loadInvites(silent: true);
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
      final resp = await authService.dio.get('/api/admin/tenants');
      final data = resp.data;
      if (data is Map &&
          data['ok'] == true &&
          data['data'] is List &&
          mounted) {
        final rows = List<Map<String, dynamic>>.from(data['data']);
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

  Future<void> _loadInvites({bool silent = false}) async {
    if (!_isPlatformCreator) return;
    if (mounted && !silent) {
      setState(() => _invitesLoading = true);
    } else {
      _invitesLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/tenant/invites',
        queryParameters: {
          'include_inactive': 1,
          if (_selectedTenantId.trim().isNotEmpty)
            'tenant_id': _selectedTenantId.trim(),
          if (_selectedTenantCode.trim().isNotEmpty)
            'tenant_code': _selectedTenantCode.trim(),
        },
      );
      final data = resp.data;
      if (data is Map &&
          data['ok'] == true &&
          data['data'] is List &&
          mounted) {
        setState(() {
          _invites = List<Map<String, dynamic>>.from(data['data']);
        });
      }
    } catch (e) {
      if (mounted && !silent) {
        setState(
          () =>
              _message = 'Ошибка загрузки приглашений: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _invitesLoading = false);
      } else {
        _invitesLoading = false;
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
      await authService.dio.delete('/api/admin/tenants/$tenantId');
      if (mounted) setState(() => _message = 'Ключ арендатора удален');
      await _loadTenants(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _tenantActionLoading = false);
    }
  }

  Future<void> _createInvite() async {
    final maxUses = _toPositiveIntOrNull(
      _inviteMaxUsesCtrl.text,
      min: 1,
      max: 100000,
    );
    final expiresDays = _toPositiveIntOrNull(
      _inviteExpiresDaysCtrl.text,
      min: 1,
      max: 365,
    );
    setState(() {
      _inviteActionLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/tenant/invites',
        data: {
          if (_selectedTenantId.trim().isNotEmpty)
            'tenant_id': _selectedTenantId.trim(),
          if (_selectedTenantCode.trim().isNotEmpty)
            'tenant_code': _selectedTenantCode.trim(),
          'role': _inviteRole,
          if (maxUses != null) 'max_uses': maxUses,
          if (expiresDays != null) 'expires_days': expiresDays,
          if (_inviteNotesCtrl.text.trim().isNotEmpty)
            'notes': _inviteNotesCtrl.text.trim(),
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final row = Map<String, dynamic>.from(data['data']);
        final reused = data['reused'] == true;
        if (mounted) {
          setState(() {
            _lastInviteCode = (row['code'] ?? '').toString();
            _lastInviteLink = (row['invite_link'] ?? '').toString();
            _inviteNotesCtrl.clear();
            _message = reused
                ? 'Активный код уже существовал, возвращаю его'
                : 'Код приглашения создан';
          });
        }
        await _loadInvites(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка приглашения: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _inviteActionLoading = false);
    }
  }

  Future<void> _setInviteStatus(String inviteId, bool active) async {
    setState(() => _inviteActionLoading = true);
    try {
      await authService.dio.patch(
        '/api/admin/tenant/invites/$inviteId/status',
        data: {
          'is_active': active,
          if (_selectedTenantId.trim().isNotEmpty)
            'tenant_id': _selectedTenantId.trim(),
          if (_selectedTenantCode.trim().isNotEmpty)
            'tenant_code': _selectedTenantCode.trim(),
        },
      );
      await _loadInvites(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка кода: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _inviteActionLoading = false);
    }
  }

  Future<void> _deleteInvite(String inviteId) async {
    setState(() => _inviteActionLoading = true);
    try {
      await authService.dio.delete(
        '/api/admin/tenant/invites/$inviteId',
        data: {
          if (_selectedTenantId.trim().isNotEmpty)
            'tenant_id': _selectedTenantId.trim(),
          if (_selectedTenantCode.trim().isNotEmpty)
            'tenant_code': _selectedTenantCode.trim(),
        },
      );
      await _loadInvites(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления кода: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _inviteActionLoading = false);
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
        final keyMask = (tenant['access_key_mask'] ?? '—').toString();
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
                Text('Маска ключа: $keyMask'),
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

  Widget _inviteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Коды приглашения',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                if (_tenants.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    value: _selectedTenantId.isEmpty ? null : _selectedTenantId,
                    decoration: const InputDecoration(
                      labelText: 'Арендатор для приглашений',
                      border: OutlineInputBorder(),
                    ),
                    items: _tenants
                        .map(
                          (tenant) => DropdownMenuItem<String>(
                            value: (tenant['id'] ?? '').toString(),
                            child: Text(
                              '${(tenant['name'] ?? '').toString()} (${(tenant['code'] ?? '').toString()})',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      final selected = _tenants.firstWhere(
                        (tenant) => (tenant['id'] ?? '').toString() == value,
                        orElse: () => _tenants.first,
                      );
                      setState(() {
                        _selectedTenantId = value;
                        _selectedTenantCode = (selected['code'] ?? '')
                            .toString();
                      });
                      _loadInvites();
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                DropdownButtonFormField<String>(
                  value: _inviteRole,
                  decoration: const InputDecoration(
                    labelText: 'Роль по приглашению',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'client', child: Text('Клиент')),
                    DropdownMenuItem(value: 'worker', child: Text('Работник')),
                    DropdownMenuItem(
                      value: 'admin',
                      child: Text('Администратор'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _inviteRole = value);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _inviteMaxUsesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Лимит использований (пусто = без лимита)',
                      border: OutlineInputBorder(),
                    ),
                    controller: _inviteMaxUsesCtrl,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _inviteExpiresDaysCtrl,
                  keyboardType: TextInputType.number,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Срок действия (дней)',
                      border: OutlineInputBorder(),
                    ),
                    controller: _inviteExpiresDaysCtrl,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _inviteNotesCtrl,
                  minLines: 1,
                  maxLines: 3,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Заметка (опционально)',
                      border: OutlineInputBorder(),
                    ),
                    controller: _inviteNotesCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _inviteActionLoading ? null : _createInvite,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(
                    _inviteActionLoading
                        ? 'Создание...'
                        : 'Создать код приглашения',
                  ),
                ),
                if (_lastInviteCode.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    'Код: $_lastInviteCode',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
                if (_lastInviteLink.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SelectableText(_lastInviteLink),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _lastInviteLink),
                      );
                      if (!mounted) return;
                      setState(
                        () => _message = 'Ссылка приглашения скопирована',
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Копировать ссылку'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (_invitesLoading)
          const Center(child: CircularProgressIndicator())
        else
          ..._invites.take(10).map((invite) {
            final id = (invite['id'] ?? '').toString();
            final code = (invite['code'] ?? '').toString();
            final role = (invite['role'] ?? 'client').toString();
            final isActive = invite['is_active'] == true;
            final used = _toInt(invite['used_count']);
            final maxUses = invite['max_uses'];
            final maxUsesLabel = maxUses == null ? '∞' : '$maxUses';

            return Card(
              child: ListTile(
                title: Text('$code • ${_roleLabel(role)}'),
                subtitle: Text('Использовано: $used / $maxUsesLabel'),
                trailing: Wrap(
                  spacing: 6,
                  children: [
                    IconButton(
                      tooltip: isActive ? 'Отключить' : 'Включить',
                      icon: Icon(
                        isActive ? Icons.block_outlined : Icons.check_circle,
                      ),
                      onPressed: _inviteActionLoading
                          ? null
                          : () => _setInviteStatus(id, !isActive),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _inviteActionLoading
                          ? null
                          : () => _deleteInvite(id),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
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
                    const SizedBox(height: 8),
                    _inviteSection(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
      ),
    );
  }
}

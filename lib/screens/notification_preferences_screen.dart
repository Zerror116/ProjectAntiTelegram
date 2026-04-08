import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/native_push_service.dart';

class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key});

  @override
  State<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends State<NotificationPreferencesScreen> {
  static const Map<String, String> _categoryLabels = <String, String>{
    'chat': 'Личные сообщения',
    'support': 'Поддержка',
    'reserved': 'Забронированный товар',
    'delivery': 'Доставка',
    'promo': 'Акции и промо',
    'updates': 'Обновления приложения',
    'security': 'Безопасность',
  };

  static const Map<String, String> _channelLabels = <String, String>{
    'push': 'Push и системные уведомления',
    'in_app': 'Внутри приложения',
    'email': 'Email',
  };

  static const Map<String, String> _badgeLabels = <String, String>{
    'count_chat': 'Личные сообщения',
    'count_support': 'Поддержка',
    'count_reserved': 'Забронированный товар',
    'count_delivery': 'Доставка',
    'count_security': 'Безопасность',
    'count_promo': 'Акции и промо',
    'count_updates': 'Обновления приложения',
  };

  bool _loading = true;
  bool _saving = false;
  String _message = '';

  Map<String, bool> _categories = <String, bool>{};
  Map<String, bool> _channels = <String, bool>{};
  Map<String, bool> _badgePreferences = <String, bool>{};
  bool _promoOptIn = false;
  bool _updatesOptIn = true;
  bool _quietHoursEnabled = false;
  String _digestMode = 'daily_non_urgent';
  bool _loadedPushEnabled = false;

  bool _clientMasterEnabled = true;
  bool _clientChatEnabled = true;
  bool _clientSupportEnabled = true;
  bool _clientPromoEnabled = false;

  final TextEditingController _quietFromCtrl = TextEditingController();
  final TextEditingController _quietToCtrl = TextEditingController();
  final TextEditingController _promoCapCtrl = TextEditingController();
  final TextEditingController _updatesCapCtrl = TextEditingController();
  final TextEditingController _lowPriorityCapCtrl = TextEditingController();

  String get _baseRole {
    return authService.effectiveRole.toLowerCase().trim();
  }

  bool get _isClientBaseRole => _baseRole == 'client';
  bool get _isCreatorBaseRole => _baseRole == 'creator';
  bool get _isAdminBaseRole => _baseRole == 'admin';
  bool get _isWorkerBaseRole => _baseRole == 'worker';
  bool get _isTenantBaseRole => _baseRole == 'tenant';
  bool get _isStaffSimplifiedRole => !_isClientBaseRole && !_isCreatorBaseRole;

  bool get _showsReservedLocked => _isAdminBaseRole || _isWorkerBaseRole;
  bool get _showsDeliveryLocked =>
      _isAdminBaseRole || _isWorkerBaseRole || _isTenantBaseRole;

  bool _effectivePushEnabledFromState() {
    if (_isClientBaseRole) {
      return _clientMasterEnabled;
    }
    return _channels['push'] ?? false;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _quietFromCtrl.dispose();
    _quietToCtrl.dispose();
    _promoCapCtrl.dispose();
    _updatesCapCtrl.dispose();
    _lowPriorityCapCtrl.dispose();
    super.dispose();
  }

  String _extractDioMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        return (data['error'] ?? data['message'] ?? 'Ошибка сервера')
            .toString();
      }
      return error.message ?? 'Ошибка сервера';
    }
    return error.toString();
  }

  Map<String, bool> _boolMap(dynamic raw, Iterable<String> keys) {
    final source = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final next = <String, bool>{};
    for (final key in keys) {
      next[key] = source[key] == true;
    }
    return next;
  }

  bool _deriveClientMasterEnabled(Map<String, dynamic> data) {
    final categories = _boolMap(data['categories'], _categoryLabels.keys);
    final channels = _boolMap(data['channels'], _channelLabels.keys);
    return channels.values.any((value) => value) ||
        categories.values.any((value) => value) ||
        data['promo_opt_in'] == true ||
        data['updates_opt_in'] == true;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = '';
    });
    try {
      final response = await authService.dio.get(
        '/api/notifications/preferences',
      );
      final root = response.data;
      final data = root is Map && root['ok'] == true && root['data'] is Map
          ? Map<String, dynamic>.from(root['data'])
          : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _categories = _boolMap(data['categories'], _categoryLabels.keys);
        _channels = _boolMap(data['channels'], _channelLabels.keys);
        _badgePreferences = _boolMap(
          data['badge_preferences'],
          _badgeLabels.keys,
        );
        _promoOptIn = data['promo_opt_in'] == true;
        _updatesOptIn = data['updates_opt_in'] != false;
        _quietHoursEnabled = data['quiet_hours_enabled'] == true;
        _digestMode = (data['digest_mode'] ?? 'daily_non_urgent').toString();
        _quietFromCtrl.text = (data['quiet_from'] ?? '').toString();
        _quietToCtrl.text = (data['quiet_to'] ?? '').toString();
        final caps = data['frequency_caps'] is Map
            ? Map<String, dynamic>.from(data['frequency_caps'])
            : const <String, dynamic>{};
        _promoCapCtrl.text = (caps['promo_per_day'] ?? 2).toString();
        _updatesCapCtrl.text = (caps['updates_per_day'] ?? 3).toString();
        _lowPriorityCapCtrl.text = (caps['low_priority_per_day'] ?? 5)
            .toString();

        _clientMasterEnabled = _deriveClientMasterEnabled(data);
        _clientChatEnabled = _categories['chat'] ?? true;
        _clientSupportEnabled = _categories['support'] ?? true;
        _clientPromoEnabled =
            (_categories['promo'] ?? false) || data['promo_opt_in'] == true;
        _loadedPushEnabled = _effectivePushEnabledFromState();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _extractDioMessage(error);
      });
    } finally {
      if (!mounted) {
        _loading = false;
      } else {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final shouldPromptNativePermissionAfterSave =
        !_loadedPushEnabled && _effectivePushEnabledFromState();
    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      late final Map<String, dynamic> payload;
      if (_isClientBaseRole) {
        payload = <String, dynamic>{
          'categories': <String, bool>{
            'chat': _clientMasterEnabled ? _clientChatEnabled : false,
            'support': _clientMasterEnabled ? _clientSupportEnabled : false,
            'reserved': false,
            'delivery': _clientMasterEnabled,
            'promo': _clientMasterEnabled ? _clientPromoEnabled : false,
            'updates': _clientMasterEnabled,
            'security': _clientMasterEnabled,
          },
          'channels': <String, bool>{
            'push': _clientMasterEnabled,
            'in_app': _clientMasterEnabled,
            'email': false,
          },
          'promo_opt_in': _clientMasterEnabled && _clientPromoEnabled,
          'updates_opt_in': _clientMasterEnabled,
        };
      } else if (_isCreatorBaseRole) {
        payload = <String, dynamic>{
          'categories': _categories,
          'channels': _channels,
          'promo_opt_in': _promoOptIn,
          'updates_opt_in': _updatesOptIn,
          'quiet_hours_enabled': _quietHoursEnabled,
          'quiet_from': _quietFromCtrl.text.trim(),
          'quiet_to': _quietToCtrl.text.trim(),
          'digest_mode': _digestMode,
          'frequency_caps': <String, dynamic>{
            'promo_per_day': int.tryParse(_promoCapCtrl.text.trim()) ?? 2,
            'updates_per_day': int.tryParse(_updatesCapCtrl.text.trim()) ?? 3,
            'low_priority_per_day':
                int.tryParse(_lowPriorityCapCtrl.text.trim()) ?? 5,
          },
          'badge_preferences': _badgePreferences,
        };
      } else {
        payload = <String, dynamic>{
          'categories': _categories,
          'channels': _channels,
        };
      }

      await authService.dio.patch(
        '/api/notifications/preferences',
        data: payload,
      );
      await refreshNotificationBadgeCount();
      if (!mounted) return;
      showAppNotice(
        context,
        'Настройки уведомлений сохранены',
        tone: AppNoticeTone.success,
      );
      if (shouldPromptNativePermissionAfterSave && mounted) {
        final granted = await NativePushService.ensurePermissionInContext(
          context,
        );
        if (!granted && mounted) {
          showAppNotice(
            context,
            'Системное разрешение на уведомления пока не выдано. Вы сможете включить его позже.',
            tone: AppNoticeTone.info,
          );
        }
      }
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _extractDioMessage(error);
      });
    } finally {
      if (!mounted) {
        _saving = false;
      } else {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    final theme = Theme.of(context);
    return Column(
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
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildSwitchCard({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
    bool enabled = true,
    Widget? trailing,
  }) {
    return Card(
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: enabled ? onChanged : null,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        secondary: trailing,
      ),
    );
  }

  Widget _buildLockedCard({required String title, required String subtitle}) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.lock_outline_rounded),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Text(
          'Всегда включено',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(String text) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBox() {
    if (_message.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        _message,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }

  Widget _buildClientView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(
          'Уведомления Феникс',
          'Здесь только простые пользовательские уведомления без служебных настроек.',
        ),
        const SizedBox(height: 12),
        _buildMessageBox(),
        if (_message.isNotEmpty) const SizedBox(height: 12),
        _buildSwitchCard(
          title: 'Получение уведомлений',
          subtitle:
              'Главный переключатель всех уведомлений Феникс на этом устройстве.',
          value: _clientMasterEnabled,
          onChanged: (value) {
            setState(() {
              _clientMasterEnabled = value;
            });
          },
        ),
        _buildSwitchCard(
          title: 'Личные сообщения',
          subtitle: 'Новые сообщения и ответы в личных чатах.',
          value: _clientChatEnabled,
          enabled: _clientMasterEnabled,
          onChanged: (value) {
            setState(() {
              _clientChatEnabled = value;
            });
          },
        ),
        _buildSwitchCard(
          title: 'Поддержка',
          subtitle: 'Ответы поддержки и изменения по вашим обращениям.',
          value: _clientSupportEnabled,
          enabled: _clientMasterEnabled,
          onChanged: (value) {
            setState(() {
              _clientSupportEnabled = value;
            });
          },
        ),
        _buildSwitchCard(
          title: 'Акции и промо',
          subtitle: 'Полноэкранные предложения и промо-уведомления от Феникс.',
          value: _clientPromoEnabled,
          enabled: _clientMasterEnabled,
          onChanged: (value) {
            setState(() {
              _clientPromoEnabled = value;
            });
          },
        ),
        _buildInfoCard(
          'Обновления приложения, безопасность и доставка управляются системой автоматически и отдельно здесь не показываются.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('Сохранить уведомления'),
        ),
      ],
    );
  }

  Widget _buildChannelsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              'Каналы доставки',
              'Какими путями уведомления могут приходить вам.',
            ),
            const SizedBox(height: 12),
            ..._channelLabels.entries.map((entry) {
              return SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                value: _channels[entry.key] ?? false,
                onChanged: (value) {
                  setState(() {
                    _channels[entry.key] = value;
                  });
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildStaffView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(
          'Рабочие уведомления Феникс',
          'Здесь только нужные вам уведомления без служебных настроек создателя.',
        ),
        const SizedBox(height: 12),
        _buildMessageBox(),
        if (_message.isNotEmpty) const SizedBox(height: 12),
        _buildSwitchCard(
          title: 'Личные сообщения',
          subtitle: 'Сообщения в чатах и ответы по работе.',
          value: _categories['chat'] ?? true,
          onChanged: (value) {
            setState(() {
              _categories['chat'] = value;
            });
          },
        ),
        _buildSwitchCard(
          title: 'Поддержка',
          subtitle: 'Рабочие обращения и ответы службы поддержки.',
          value: _categories['support'] ?? true,
          onChanged: (value) {
            setState(() {
              _categories['support'] = value;
            });
          },
        ),
        if (_showsReservedLocked)
          _buildLockedCard(
            title: 'Забронированный товар',
            subtitle:
                'Это рабочее уведомление включено автоматически и недоступно для отключения.',
          ),
        if (_showsDeliveryLocked)
          _buildLockedCard(
            title: 'Доставка',
            subtitle:
                'Это рабочее уведомление включено автоматически и недоступно для отключения.',
          ),
        _buildChannelsSection(),
        _buildInfoCard(
          'Обновления приложения и безопасность включены всегда. Тихие часы, ограничение частоты и состав счётчика доступны только создателю.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('Сохранить настройки'),
        ),
      ],
    );
  }

  Widget _buildCreatorView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(
          'Центр настроек уведомлений',
          'Полная настройка категорий, каналов доставки, тихих часов, ограничений и состава счётчика.',
        ),
        const SizedBox(height: 12),
        _buildMessageBox(),
        if (_message.isNotEmpty) const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle(
                  'Категории уведомлений',
                  'Какие события могут приходить вам в систему уведомлений.',
                ),
                const SizedBox(height: 12),
                ..._categoryLabels.entries.map((entry) {
                  return SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: _categories[entry.key] ?? false,
                    onChanged: (value) {
                      setState(() {
                        _categories[entry.key] = value;
                      });
                    },
                  );
                }),
              ],
            ),
          ),
        ),
        _buildChannelsSection(),
        _buildSwitchCard(
          title: 'Тестовые промо самому себе',
          subtitle:
              'Разрешает получать тестовые промо-события создателя в ваш центр событий.',
          value: _promoOptIn,
          onChanged: (value) {
            setState(() {
              _promoOptIn = value;
            });
          },
        ),
        _buildSwitchCard(
          title: 'Уведомления об обновлениях',
          subtitle:
              'Разрешает отдельные уведомления об обновлениях поверх обычной проверки версии.',
          value: _updatesOptIn,
          onChanged: (value) {
            setState(() {
              _updatesOptIn = value;
            });
          },
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle(
                  'Тихие часы',
                  'Действуют только для несрочных уведомлений: акций, обновлений и событий с низким приоритетом.',
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Использовать тихие часы'),
                  subtitle: const Text(
                    'Срочные рабочие уведомления и уведомления безопасности не задерживаются.',
                  ),
                  value: _quietHoursEnabled,
                  onChanged: (value) {
                    setState(() {
                      _quietHoursEnabled = value;
                    });
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _quietFromCtrl,
                        decoration: const InputDecoration(
                          labelText: 'С',
                          hintText: '22:00',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _quietToCtrl,
                        decoration: const InputDecoration(
                          labelText: 'До',
                          hintText: '08:00',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Без сводки'),
                      selected: _digestMode == 'off',
                      onSelected: (_) {
                        setState(() {
                          _digestMode = 'off';
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Сводка несрочных раз в день'),
                      selected: _digestMode == 'daily_non_urgent',
                      onSelected: (_) {
                        setState(() {
                          _digestMode = 'daily_non_urgent';
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Сводка всего задержанного'),
                      selected: _digestMode == 'daily_all_delayed',
                      onSelected: (_) {
                        setState(() {
                          _digestMode = 'daily_all_delayed';
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle(
                  'Ограничение частоты',
                  'Не даём несрочным уведомлениям перегружать вас в течение дня.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _promoCapCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Акции и промо в день',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _updatesCapCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Обновления в день',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _lowPriorityCapCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Несрочных служебных событий в день',
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle(
                  'Что входит в счётчик уведомлений',
                  'Сервер считает единый счётчик и синхронизирует его между веб-версией и приложением.',
                ),
                const SizedBox(height: 12),
                ..._badgeLabels.entries.map((entry) {
                  return SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: _badgePreferences[entry.key] ?? false,
                    onChanged: (value) {
                      setState(() {
                        _badgePreferences[entry.key] = value;
                      });
                    },
                  );
                }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('Сохранить настройки'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isCreatorBaseRole ? 'Настройки уведомлений' : 'Уведомления Феникс',
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_isClientBaseRole)
                      _buildClientView()
                    else if (_isStaffSimplifiedRole)
                      _buildStaffView()
                    else
                      _buildCreatorView(),
                  ],
                ),
              ),
      ),
    );
  }
}

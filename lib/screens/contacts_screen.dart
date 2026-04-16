import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../services/invite_referral_service.dart';
import '../widgets/app_avatar.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final List<Map<String, dynamic>> _contacts = <Map<String, dynamic>>[];
  final List<_PhonebookMatchRow> _phonebookMatches = <_PhonebookMatchRow>[];
  final List<_InviteCandidateRow> _inviteCandidates = <_InviteCandidateRow>[];

  bool _loadingContacts = true;
  bool _matchingPhonebook = false;
  bool _sharingInvite = false;
  bool _phonebookImported = false;
  String _contactsError = '';
  String _query = '';
  PendingInviteReferral? _pendingInviteReferral;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleQueryChanged);
    unawaited(_loadContacts(force: true));
    unawaited(_loadPendingInviteReferral());
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleQueryChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    final next = _searchController.text.trim();
    if (_query == next) return;
    setState(() => _query = next);
  }

  Future<void> _loadPendingInviteReferral() async {
    try {
      final referral = await inviteReferralService.load();
      final currentUserId = (authService.currentUser?.id ?? '').trim();
      if (!mounted) {
        if (referral != null && referral.referrerUserId != currentUserId) {
          _pendingInviteReferral = referral;
        }
        return;
      }
      setState(() {
        _pendingInviteReferral =
            referral == null || referral.referrerUserId == currentUserId
            ? null
            : referral;
      });
    } catch (_) {}
  }

  Future<void> _clearPendingInviteReferral() async {
    await inviteReferralService.clear();
    if (!mounted) return;
    setState(() => _pendingInviteReferral = null);
  }

  String _peerId(Map<String, dynamic> peer) {
    return (peer['id'] ?? peer['contact_user_id'] ?? '').toString().trim();
  }

  bool _isInContacts(Map<String, dynamic> peer) {
    final raw = peer['is_in_contacts'];
    if (raw is bool) return raw;
    final value = '${raw ?? ''}'.toLowerCase().trim();
    return value == 'true' || value == '1' || value == 't' || value == 'yes';
  }

  String _normalizeDigits(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  String _contactTitle(Map<String, dynamic> peer) {
    final alias = (peer['alias_name'] ?? '').toString().trim();
    if (alias.isNotEmpty) return alias;
    final name = (peer['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final email = (peer['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    final phone = (peer['phone'] ?? '').toString().trim();
    if (phone.isNotEmpty) return phone;
    return 'Пользователь';
  }

  String _contactSubtitle(Map<String, dynamic> peer) {
    final phone = (peer['phone'] ?? '').toString().trim();
    final email = (peer['email'] ?? '').toString().trim();
    final role = (peer['role'] ?? '').toString().trim();
    final parts = <String>[
      if (phone.isNotEmpty) phone,
      if (email.isNotEmpty) email,
      if (role.isNotEmpty) 'Роль: $role',
    ];
    return parts.join(' • ');
  }

  Future<void> _loadContacts({bool force = false}) async {
    if (_loadingContacts && !force) return;
    setState(() {
      _loadingContacts = true;
      _contactsError = '';
    });
    try {
      final resp = await authService.dio.get('/api/chats/contacts');
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! List) {
        throw Exception('Неверный ответ сервера');
      }
      final loaded = List<Map<String, dynamic>>.from(data['data']);
      loaded.sort((a, b) {
        final an = _contactTitle(a).toLowerCase();
        final bn = _contactTitle(b).toLowerCase();
        return an.compareTo(bn);
      });
      if (!mounted) return;
      setState(() {
        _contacts
          ..clear()
          ..addAll(loaded);
        _loadingContacts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
        _contactsError = _extractDioError(e);
      });
    }
  }

  String _extractDioError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) {
        final value = data['error'].toString().trim();
        if (value.isNotEmpty) return value;
      }
      final status = error.response?.statusCode;
      if (status == 404) return 'Не найдено';
      if (status == 401) return 'Сессия истекла';
      if (status == 403) return 'Недостаточно прав';
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Нет соединения с сервером';
      }
    }
    return error.toString().trim().isEmpty ? 'Неизвестная ошибка' : error.toString().trim();
  }

  List<Map<String, dynamic>> _filteredContacts() {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return List<Map<String, dynamic>>.from(_contacts);
    return _contacts.where((peer) {
      final blobs = <String>[
        _contactTitle(peer).toLowerCase(),
        _contactSubtitle(peer).toLowerCase(),
      ];
      return blobs.any((value) => value.contains(query));
    }).toList(growable: false);
  }

  Future<bool> _openDirectForUser(String userId) async {
    if (userId.trim().isEmpty) return false;
    try {
      final resp = await authService.dio.post(
        '/api/chats/direct/open',
        data: {'user_id': userId.trim()},
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
        throw Exception('Не удалось открыть чат');
      }
      final payload = Map<String, dynamic>.from(data['data'] as Map);
      final chat = payload['chat'] is Map
          ? Map<String, dynamic>.from(payload['chat'] as Map)
          : <String, dynamic>{};
      final peer = payload['peer'] is Map
          ? Map<String, dynamic>.from(payload['peer'] as Map)
          : <String, dynamic>{};
      final chatId = (chat['id'] ?? '').toString().trim();
      if (chatId.isEmpty || !mounted) return false;
      final chatTitle = (chat['display_title'] ?? '').toString().trim().isNotEmpty
          ? (chat['display_title'] ?? '').toString().trim()
          : _contactTitle(peer);
      final chatSettings = chat['settings'] is Map
          ? Map<String, dynamic>.from(chat['settings'] as Map)
          : null;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: chatTitle,
            chatType: (chat['type'] ?? '').toString(),
            chatSettings: chatSettings,
          ),
        ),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      showGlobalAppNotice(
        'Не удалось открыть ЛС: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
    return false;
  }

  Future<void> _addToContacts(Map<String, dynamic> peer) async {
    final userId = _peerId(peer);
    if (userId.isEmpty) return;
    try {
      await authService.dio.post('/api/chats/contacts', data: {'user_id': userId});
      if (!mounted) return;
      showGlobalAppNotice('Контакт добавлен', tone: AppNoticeTone.success);
      await _loadContacts(force: true);
      setState(() {
        for (var i = 0; i < _phonebookMatches.length; i += 1) {
          final row = _phonebookMatches[i];
          if (_peerId(row.peer) != userId) continue;
          _phonebookMatches[i] = row.copyWith(
            peer: <String, dynamic>{...row.peer, 'is_in_contacts': true},
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Не удалось добавить контакт: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _removeContact(Map<String, dynamic> peer) async {
    final userId = _peerId(peer);
    if (userId.isEmpty) return;
    try {
      await authService.dio.delete('/api/chats/contacts/$userId');
      if (!mounted) return;
      setState(() {
        _contacts.removeWhere((item) => _peerId(item) == userId);
      });
      showGlobalAppNotice('Контакт удалён', tone: AppNoticeTone.info);
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Не удалось удалить контакт: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<String> _loadInviteLink() async {
    Response<dynamic> resp;
    try {
      resp = await authService.dio.get('/api/profile/group-invite');
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      resp = await authService.dio.get('/api/profile/tenant/client-invite');
    }
    final data = resp.data;
    if (data is! Map || data['ok'] != true || data['data'] is! Map) {
      throw Exception('Не удалось получить ссылку приглашения');
    }
    final row = Map<String, dynamic>.from(data['data'] as Map);
    final code = (row['code'] ?? '').toString().trim().toUpperCase();
    final tenantCode = (row['tenant_code'] ?? '').toString().trim().toLowerCase();
    var inviteLink = (row['invite_link'] ?? '').toString().trim();
    if (inviteLink.isEmpty) {
      final qp = <String, String>{if (code.isNotEmpty) 'invite': code};
      if (tenantCode.isNotEmpty) qp['tenant'] = tenantCode;
      inviteLink = Uri.base.replace(queryParameters: qp, fragment: '').toString();
    }
    final referrerId = (authService.currentUser?.id ?? '').trim();
    final referrerName = (authService.currentUser?.name ?? '').trim();
    final uri = Uri.parse(inviteLink);
    final params = Map<String, String>.from(uri.queryParameters);
    if (referrerId.isNotEmpty) params['referrer'] = referrerId;
    if (referrerName.isNotEmpty) params['referrer_name'] = referrerName;
    return uri.replace(queryParameters: params).toString();
  }

  Future<void> _shareInvite(_InviteCandidateRow row) async {
    if (_sharingInvite) return;
    setState(() => _sharingInvite = true);
    try {
      final inviteLink = await _loadInviteLink();
      final name = row.displayName.trim();
      final text = [
        if (name.isNotEmpty) '$name,',
        'Приглашаю тебя в Феникс. Подключайся по ссылке:',
        inviteLink,
      ].join('\n');
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Не удалось подготовить приглашение: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _sharingInvite = false);
    }
  }

  String _tenantHash(String digitsCore10) {
    final tenantId = (authService.currentUser?.tenantId ?? '').trim();
    return crypto.sha256.convert(utf8.encode('$tenantId:$digitsCore10')).toString();
  }

  Future<void> _importPhonebook() async {
    if (_matchingPhonebook) return;
    setState(() => _matchingPhonebook = true);
    try {
      final permissionStatus = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (permissionStatus != PermissionStatus.granted &&
          permissionStatus != PermissionStatus.limited) {
        if (!mounted) return;
        showGlobalAppNotice(
          'Доступ к контактам не предоставлен',
          tone: AppNoticeTone.warning,
        );
        return;
      }
      final deviceContacts = await FlutterContacts.getAll(
        properties: {ContactProperty.phone},
      );
      final payload = <Map<String, dynamic>>[];
      for (final contact in deviceContacts) {
        final hashes = <String>{};
        for (final phone in contact.phones) {
          final digits = _normalizeDigits(phone.number);
          if (digits.length < 10) continue;
          hashes.add(_tenantHash(digits.substring(digits.length - 10)));
        }
        if (hashes.isEmpty) continue;
        payload.add({
          'local_id': contact.id,
          'display_name': contact.displayName,
          'phone_hashes': hashes.toList(growable: false),
        });
      }
      final resp = await authService.dio.post(
        '/api/chats/contacts/phonebook/match',
        data: {'contacts': payload},
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
        throw Exception('Неверный ответ сервера');
      }
      final result = Map<String, dynamic>.from(data['data'] as Map);
      final matchesRaw = result['matches'] is List
          ? List<Map<String, dynamic>>.from(result['matches'] as List)
          : const <Map<String, dynamic>>[];
      final invitesRaw = result['invites'] is List
          ? List<Map<String, dynamic>>.from(result['invites'] as List)
          : const <Map<String, dynamic>>[];
      final contactIds = _contacts.map(_peerId).where((id) => id.isNotEmpty).toSet();
      if (!mounted) return;
      setState(() {
        _phonebookImported = true;
        _phonebookMatches
          ..clear()
          ..addAll(
            matchesRaw.map((row) {
              final peer = row['peer'] is Map
                  ? Map<String, dynamic>.from(row['peer'] as Map)
                  : <String, dynamic>{};
              final peerId = _peerId(peer);
              return _PhonebookMatchRow(
                localId: (row['local_id'] ?? '').toString().trim(),
                displayName: (row['display_name'] ?? '').toString().trim(),
                peer: <String, dynamic>{
                  ...peer,
                  if (peerId.isNotEmpty && contactIds.contains(peerId))
                    'is_in_contacts': true,
                },
              );
            }),
          );
        _inviteCandidates
          ..clear()
          ..addAll(
            invitesRaw.map(
              (row) => _InviteCandidateRow(
                localId: (row['local_id'] ?? '').toString().trim(),
                displayName: (row['display_name'] ?? '').toString().trim(),
              ),
            ),
          );
      });
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Не удалось импортировать контакты: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _matchingPhonebook = false);
    }
  }

  Widget _buildContactTile(Map<String, dynamic> peer) {
    final title = _contactTitle(peer);
    final subtitle = _contactSubtitle(peer);
    final userId = _peerId(peer);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        title: title,
        imageUrl: (peer['avatar_url'] ?? '').toString().trim().isEmpty
            ? null
            : (peer['avatar_url'] ?? '').toString().trim(),
        focusX: double.tryParse('${peer['avatar_focus_x'] ?? 0}') ?? 0,
        focusY: double.tryParse('${peer['avatar_focus_y'] ?? 0}') ?? 0,
        zoom: double.tryParse('${peer['avatar_zoom'] ?? 1}') ?? 1,
        radius: 20,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: userId.isEmpty ? null : () => _openDirectForUser(userId),
      trailing: IconButton(
        tooltip: 'Удалить из контактов',
        onPressed: userId.isEmpty ? null : () => _removeContact(peer),
        icon: const Icon(Icons.person_remove_alt_1_outlined),
      ),
    );
  }

  Widget _buildPhonebookMatchTile(_PhonebookMatchRow row) {
    final peer = row.peer;
    final userId = _peerId(peer);
    final title = row.displayName.isNotEmpty ? row.displayName : _contactTitle(peer);
    final subtitle = _contactSubtitle(peer);
    final inContacts = _isInContacts(peer);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        title: title,
        imageUrl: (peer['avatar_url'] ?? '').toString().trim().isEmpty
            ? null
            : (peer['avatar_url'] ?? '').toString().trim(),
        focusX: double.tryParse('${peer['avatar_focus_x'] ?? 0}') ?? 0,
        focusY: double.tryParse('${peer['avatar_focus_y'] ?? 0}') ?? 0,
        zoom: double.tryParse('${peer['avatar_zoom'] ?? 1}') ?? 1,
        radius: 20,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle.isEmpty ? 'Есть в Фениксе' : subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 6,
        children: [
          if (!inContacts)
            IconButton(
              tooltip: 'Добавить в контакты',
              onPressed: userId.isEmpty ? null : () => _addToContacts(peer),
              icon: const Icon(Icons.person_add_alt_1_rounded),
            ),
          IconButton(
            tooltip: 'Написать',
            onPressed: userId.isEmpty ? null : () => _openDirectForUser(userId),
            icon: const Icon(Icons.forum_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildInviteTile(_InviteCandidateRow row) {
    final title = row.displayName.isNotEmpty ? row.displayName : 'Контакт без имени';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Text(title.trim().isEmpty ? '?' : title.trim().substring(0, 1).toUpperCase()),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: const Text('Не найден в Фениксе. Можно отправить приглашение.'),
      trailing: IconButton(
        tooltip: 'Пригласить',
        onPressed: _sharingInvite ? null : () => _shareInvite(row),
        icon: const Icon(Icons.share_outlined),
      ),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
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
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // ignore: use_null_aware_elements
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildPendingInviteReferralCard(PendingInviteReferral referral) {
    final title = referral.referrerName.trim().isNotEmpty
        ? referral.referrerName.trim()
        : 'пригласивший контакт';
    return _buildSectionCard(
      icon: Icons.mark_email_unread_outlined,
      title: 'Вас пригласили в Phoenix',
      subtitle:
          'После входа можно сразу открыть ЛС с тем, кто прислал приглашение.',
      action: IconButton(
        tooltip: 'Скрыть',
        onPressed: _clearPendingInviteReferral,
        icon: const Icon(Icons.close_rounded),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Пригласил: $title',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Код группы: ${referral.inviteCode}${referral.tenantCode.trim().isNotEmpty ? ' • tenant ${referral.tenantCode.trim()}' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: referral.referrerUserId.trim().isEmpty
                    ? null
                    : () async {
                        final opened = await _openDirectForUser(
                          referral.referrerUserId,
                        );
                        if (opened) {
                          await _clearPendingInviteReferral();
                        }
                      },
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('Написать'),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _clearPendingInviteReferral,
                child: const Text('Скрыть'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredContacts = _filteredContacts();
    final query = _query.trim().toLowerCase();
    final visibleMatches = query.isEmpty
        ? _phonebookMatches
        : _phonebookMatches.where((row) {
            final text = '${row.displayName} ${_contactTitle(row.peer)} ${_contactSubtitle(row.peer)}'.toLowerCase();
            return text.contains(query);
          }).toList(growable: false);
    final visibleInvites = query.isEmpty
        ? _inviteCandidates
        : _inviteCandidates.where((row) {
            final text = row.displayName.toLowerCase();
            return text.contains(query);
          }).toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Контакты'),
        actions: [
          IconButton(
            tooltip: 'Импортировать контакты',
            onPressed: _matchingPhonebook ? null : _importPhonebook,
            icon: _matchingPhonebook
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_search_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_pendingInviteReferral case final referral?)
              _buildPendingInviteReferralCard(referral),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Поиск по контактам и совпадениям',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              icon: Icons.contacts_outlined,
              title: 'Контакты Феникса',
              subtitle: 'Люди, которых вы уже добавили в список контактов.',
              action: IconButton(
                tooltip: 'Обновить',
                onPressed: () => _loadContacts(force: true),
                icon: const Icon(Icons.refresh_rounded),
              ),
              child: _loadingContacts
                  ? const Center(child: CircularProgressIndicator())
                  : _contactsError.isNotEmpty
                  ? Text(_contactsError)
                  : filteredContacts.isEmpty
                  ? const Text('Контактов пока нет')
                  : Column(
                      children: filteredContacts.map(_buildContactTile).toList(),
                    ),
            ),
            _buildSectionCard(
              icon: Icons.phone_android_outlined,
              title: 'Контакты телефона',
              subtitle: _phonebookImported
                  ? 'Совпадения из вашей телефонной книги внутри текущей группы.'
                  : 'Нажмите на импорт, чтобы найти людей из телефонной книги в Фениксе.',
              action: FilledButton.icon(
                onPressed: _matchingPhonebook ? null : _importPhonebook,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Импорт'),
              ),
              child: !_phonebookImported && !_matchingPhonebook
                  ? const Text('Импорт контактов запускается только по явному действию.')
                  : visibleMatches.isEmpty
                  ? const Text('Совпадений пока нет')
                  : Column(
                      children: visibleMatches.map(_buildPhonebookMatchTile).toList(),
                    ),
            ),
            _buildSectionCard(
              icon: Icons.share_outlined,
              title: 'Пригласить в Феникс',
              subtitle: 'Контакты из телефонной книги, которых ещё нет в приложении.',
              child: visibleInvites.isEmpty
                  ? const Text('Кандидатов для приглашения пока нет')
                  : Column(
                      children: visibleInvites.map(_buildInviteTile).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhonebookMatchRow {
  const _PhonebookMatchRow({
    required this.localId,
    required this.displayName,
    required this.peer,
  });

  final String localId;
  final String displayName;
  final Map<String, dynamic> peer;

  _PhonebookMatchRow copyWith({Map<String, dynamic>? peer}) {
    return _PhonebookMatchRow(
      localId: localId,
      displayName: displayName,
      peer: peer ?? this.peer,
    );
  }
}

class _InviteCandidateRow {
  const _InviteCandidateRow({required this.localId, required this.displayName});

  final String localId;
  final String displayName;
}

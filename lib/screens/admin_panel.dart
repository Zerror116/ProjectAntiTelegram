// lib/screens/admin_panel.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import '../main.dart';
import 'chat_screen.dart';
import '../utils/date_time_utils.dart';
import '../widgets/input_language_badge.dart';

const String _defaultMapLightTiles =
    'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
const String _defaultMapDarkTiles =
    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
const String _mapTileLightUrl = String.fromEnvironment(
  'FENIX_MAP_TILE_LIGHT',
  defaultValue: _defaultMapLightTiles,
);
const String _mapTileDarkUrl = String.fromEnvironment(
  'FENIX_MAP_TILE_DARK',
  defaultValue: _defaultMapDarkTiles,
);
const String _mapTileSubdomainsRaw = String.fromEnvironment(
  'FENIX_MAP_TILE_SUBDOMAINS',
  defaultValue: 'a,b,c,d',
);
const String _mapAttributionText = String.fromEnvironment(
  'FENIX_MAP_ATTRIBUTION',
  defaultValue: '© OpenStreetMap contributors © CARTO',
);

class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminTabSpec {
  const _AdminTabSpec({
    required this.id,
    required this.label,
    required this.builder,
  });

  final String id;
  final String label;
  final Widget Function() builder;
}

class _AdminPanelState extends State<AdminPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  StreamSubscription? _authSub;
  List<_AdminTabSpec> _visibleTabs = const <_AdminTabSpec>[];
  final bool _showKeysTab = false;
  final _channelTitleCtrl = TextEditingController();
  final _channelDescriptionCtrl = TextEditingController();
  final _deliveryThresholdCtrl = TextEditingController();
  final _deliveryOriginCtrl = TextEditingController();
  final _courierNamesCtrl = TextEditingController();
  final _tenantNameCtrl = TextEditingController();
  final _tenantNotesCtrl = TextEditingController();
  final _tenantMonthsCtrl = TextEditingController(text: '1');
  final _inviteMaxUsesCtrl = TextEditingController();
  final _inviteExpiresDaysCtrl = TextEditingController(text: '30');
  final _inviteNotesCtrl = TextEditingController();
  final _auditActionCtrl = TextEditingController();
  final _notificationQuietFromCtrl = TextEditingController();
  final _notificationQuietToCtrl = TextEditingController();
  final _supportTemplateTitleCtrl = TextEditingController();
  final _supportTemplateBodyCtrl = TextEditingController();
  final _roleTemplateTitleCtrl = TextEditingController();
  final _roleTemplateCodeCtrl = TextEditingController();
  final _roleTemplateDescriptionCtrl = TextEditingController();
  final _roleUserSearchCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _publishing = false;
  bool _dispatchingOrders = false;
  bool _avatarUpdating = false;
  bool _deliveryLoading = false;
  bool _deliverySaving = false;
  bool _supportLoading = false;
  bool _supportArchiveBusy = false;
  bool _supportTemplatesLoading = false;
  bool _supportTemplateSaving = false;
  bool _supportQuickReplyBusy = false;
  bool _tenantsLoading = false;
  bool _tenantActionLoading = false;
  bool _invitesLoading = false;
  bool _inviteActionLoading = false;
  bool _financeLoading = false;
  bool _controlLoading = false;
  bool _diagnosticsLoading = false;
  bool _smartNotifyLoading = false;
  bool _returnsActionBusy = false;
  bool _demoModeBusy = false;
  bool _roleTemplateSaving = false;
  bool _roleAssignBusy = false;
  bool _roleUsersLoading = false;
  StreamSubscription? _eventsSub;

  String _message = '';
  String _newChannelVisibility = 'public';
  String _deliveryViewMode = 'map';
  String _deliveryOriginLabel = 'Точка отправки';
  String _financePeriod = 'month';
  String _smartNotifyType = 'order';
  String _smartNotifyPriority = 'high';
  double? _deliveryOriginLat;
  double? _deliveryOriginLng;

  List<Map<String, dynamic>> _channels = [];
  List<Map<String, dynamic>> _pendingPosts = [];
  List<Map<String, dynamic>> _lastPublished = [];
  List<Map<String, dynamic>> _lastDispatchedOrders = [];
  List<Map<String, dynamic>> _deliveryBatches = [];
  List<Map<String, dynamic>> _supportActiveTickets = [];
  List<Map<String, dynamic>> _supportArchivedTickets = [];
  List<Map<String, dynamic>> _supportTemplates = [];
  List<Map<String, dynamic>> _auditLogs = [];
  List<Map<String, dynamic>> _antifraudEvents = [];
  List<Map<String, dynamic>> _antifraudBlocks = [];
  List<Map<String, dynamic>> _returnsWorkflow = [];
  List<Map<String, dynamic>> _roleUsers = [];
  List<Map<String, dynamic>> _smartNotifyHistory = [];
  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _tenantInvites = [];
  Map<String, dynamic>? _deliveryActiveBatch;
  Map<String, dynamic>? _financeData;
  Map<String, dynamic>? _rolesDraft;
  Map<String, dynamic>? _diagnosticsData;
  Map<String, dynamic>? _smartNotifySettings;
  int _reservedPendingTotal = 0;
  int _reservedPendingUnits = 0;
  String _lastGeneratedTenantKey = '';
  bool _tenantApiAllowed = true;
  bool _inviteApiAllowed = true;
  String _inviteRole = 'client';
  String _lastInviteCode = '';
  String _lastInviteLink = '';
  final Map<String, String> _ticketTemplateById = {};
  final Map<String, String> _roleSelectionByUserId = {};

  final Map<String, Map<String, dynamic>> _channelOverviews = {};
  final Set<String> _overviewLoading = <String>{};
  final Set<String> _blacklistBusy = <String>{};

  @override
  void initState() {
    super.initState();
    _rebuildVisibleTabs(force: true, notify: false);
    _reloadAll();
    _eventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if (type == 'delivery:updated' && _canViewDeliveryTab()) {
        unawaited(_loadDeliveryDashboard());
        return;
      }
      if (type == 'claims:updated' && _canViewSupportTab()) {
        unawaited(_loadReturnsWorkflow(silent: true));
        final data = event['data'];
        if (mounted && data is Map) {
          final status = (data['status'] ?? '').toString().trim();
          final claimType = (data['claim_type'] ?? '').toString().trim();
          showAppNotice(
            context,
            status == 'pending'
                ? 'Новая заявка: ${claimType == 'discount' ? 'скидка' : 'возврат'}'
                : 'Обновлен статус заявки по возврату/скидке',
            tone: AppNoticeTone.warning,
            duration: const Duration(seconds: 2),
          );
        }
      }
    });
    _authSub = authService.authStream.listen((_) {
      final changed = _rebuildVisibleTabs();
      if (changed) {
        unawaited(_reloadAll());
      }
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _eventsSub?.cancel();
    _authSub?.cancel();
    _channelTitleCtrl.dispose();
    _channelDescriptionCtrl.dispose();
    _deliveryThresholdCtrl.dispose();
    _deliveryOriginCtrl.dispose();
    _courierNamesCtrl.dispose();
    _tenantNameCtrl.dispose();
    _tenantNotesCtrl.dispose();
    _tenantMonthsCtrl.dispose();
    _inviteMaxUsesCtrl.dispose();
    _inviteExpiresDaysCtrl.dispose();
    _inviteNotesCtrl.dispose();
    _auditActionCtrl.dispose();
    _notificationQuietFromCtrl.dispose();
    _notificationQuietToCtrl.dispose();
    _supportTemplateTitleCtrl.dispose();
    _supportTemplateBodyCtrl.dispose();
    _roleTemplateTitleCtrl.dispose();
    _roleTemplateCodeCtrl.dispose();
    _roleTemplateDescriptionCtrl.dispose();
    _roleUserSearchCtrl.dispose();
    super.dispose();
  }

  String _activeMapTileUrl(ThemeData theme) {
    return theme.brightness == Brightness.dark
        ? _mapTileDarkUrl
        : _mapTileLightUrl;
  }

  List<String> _activeMapSubdomains(String urlTemplate) {
    if (!urlTemplate.contains('{s}')) return const <String>[];
    return _mapTileSubdomainsRaw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.map((e) => _asMap(e)).toList();
  }

  Map<String, dynamic> _settingsOf(Map<String, dynamic> channel) {
    return _asMap(channel['settings']);
  }

  String _channelIdOf(Map<String, dynamic> channel) {
    return (channel['id'] ?? '').toString();
  }

  String _roleLabel(String role) {
    final normalized = role.toLowerCase().trim();
    if (normalized == 'tenant') return 'Арендатор';
    if (normalized == 'admin') return 'Админ';
    if (normalized == 'worker') return 'Рабочий';
    return 'Клиент';
  }

  bool _isCreatorBase() {
    final baseRole = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return baseRole == 'creator';
  }

  bool _hasPermission(String key) {
    return authService.hasPermission(key);
  }

  bool _ensurePermission(String key, String deniedMessage) {
    if (_hasPermission(key)) return true;
    if (mounted) {
      setState(() => _message = deniedMessage);
    }
    return false;
  }

  bool _hasAnyPermission(List<String> keys) {
    for (final key in keys) {
      if (_hasPermission(key)) return true;
    }
    return false;
  }

  bool _canViewCreateTab() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasAnyPermission(const [
      'product.publish',
      'tenant.users.manage',
      'delivery.manage',
    ]);
  }

  bool _canViewChannelsTab() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasAnyPermission(const ['product.publish', 'tenant.users.manage']);
  }

  bool _canViewModerationTab() {
    return _hasAnyPermission(const ['product.publish', 'reservation.fulfill']);
  }

  bool _canViewDeliveryTab() {
    return _hasPermission('delivery.manage') || _isCreatorBase();
  }

  bool _canViewSupportTab() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasPermission('chat.write.support');
  }

  List<_AdminTabSpec> _buildVisibleTabs() {
    final tabs = <_AdminTabSpec>[
      if (_canViewCreateTab())
        _AdminTabSpec(
          id: 'create',
          label: 'Создание',
          builder: _buildCreateTab,
        ),
      if (_canViewChannelsTab())
        _AdminTabSpec(
          id: 'channels',
          label: 'Каналы',
          builder: _buildSettingsTab,
        ),
      if (_canViewModerationTab())
        _AdminTabSpec(
          id: 'moderation',
          label: 'Модерация',
          builder: _buildModerationTab,
        ),
      if (_canViewDeliveryTab())
        _AdminTabSpec(
          id: 'delivery',
          label: 'Доставка',
          builder: _buildDeliveryTab,
        ),
      if (_canViewSupportTab())
        _AdminTabSpec(
          id: 'support',
          label: 'Поддержка',
          builder: _buildSupportTab,
        ),
    ];
    if (tabs.isNotEmpty) return tabs;
    return <_AdminTabSpec>[
      _AdminTabSpec(
        id: 'no_access',
        label: 'Доступ',
        builder: _buildNoAccessTab,
      ),
    ];
  }

  bool _rebuildVisibleTabs({bool force = false, bool notify = true}) {
    final nextTabs = _buildVisibleTabs();
    final prevTabs = _visibleTabs;
    final unchanged =
        !force &&
        prevTabs.length == nextTabs.length &&
        List.generate(prevTabs.length, (i) => prevTabs[i].id).join('|') ==
            List.generate(nextTabs.length, (i) => nextTabs[i].id).join('|');
    if (unchanged && _tabController != null) {
      return false;
    }

    final oldId = (() {
      final controller = _tabController;
      if (controller == null || prevTabs.isEmpty) return null;
      final safeIndex = controller.index.clamp(0, prevTabs.length - 1);
      return prevTabs[safeIndex].id;
    })();

    _tabController?.dispose();
    _visibleTabs = nextTabs;

    final mappedIndex = oldId == null
        ? 0
        : nextTabs.indexWhere((tab) => tab.id == oldId);
    final initialIndex = mappedIndex >= 0 ? mappedIndex : 0;

    _tabController = TabController(
      length: nextTabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );

    if (notify && mounted) {
      setState(() {});
    }
    return true;
  }

  void _animateToTab(String tabId) {
    final controller = _tabController;
    if (controller == null) return;
    final nextIndex = _visibleTabs.indexWhere((tab) => tab.id == tabId);
    if (nextIndex < 0) return;
    controller.animateTo(nextIndex);
  }

  int _toInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  String _formatProductLabel(dynamic productCode, dynamic shelfNumber) {
    final code = _toInt(productCode, fallback: 0);
    final shelf = _toInt(shelfNumber, fallback: 1);
    final codePart = code > 0 ? '$code' : '—';
    final shelfPart = shelf > 0 ? shelf.toString().padLeft(2, '0') : '—';
    return '$codePart--$shelfPart';
  }

  double _toFocus(dynamic value) {
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return 0;
    return parsed.clamp(-1.0, 1.0).toDouble();
  }

  double _toAvatarZoom(dynamic value) {
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return 1;
    return parsed.clamp(1.0, 4.0).toDouble();
  }

  double? _toNullableDouble(dynamic value) {
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  Offset _clampAvatarOffset({
    required Offset offset,
    required int sourceWidth,
    required int sourceHeight,
    required double previewSize,
    required double cutoutSize,
    required double zoom,
  }) {
    final baseScale = math.max(
      previewSize / sourceWidth,
      previewSize / sourceHeight,
    );
    final renderedWidth = sourceWidth * baseScale * zoom;
    final renderedHeight = sourceHeight * baseScale * zoom;

    final maxX = math.max(0.0, (renderedWidth - cutoutSize) / 2);
    final maxY = math.max(0.0, (renderedHeight - cutoutSize) / 2);

    return Offset(
      offset.dx.clamp(-maxX, maxX).toDouble(),
      offset.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  Future<String> _exportAvatarCrop({
    required String sourcePath,
    required int sourceWidth,
    required int sourceHeight,
    required double previewSize,
    required double cutoutSize,
    required Offset offset,
    required double zoom,
  }) async {
    final bytes = await File(sourcePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Не удалось прочитать изображение');
    }

    final baseScale = math.max(
      previewSize / sourceWidth,
      previewSize / sourceHeight,
    );
    final effectiveScale = baseScale * zoom;
    final renderedWidth = sourceWidth * effectiveScale;
    final renderedHeight = sourceHeight * effectiveScale;

    final imageLeft = (previewSize - renderedWidth) / 2 + offset.dx;
    final imageTop = (previewSize - renderedHeight) / 2 + offset.dy;
    final cutoutLeft = (previewSize - cutoutSize) / 2;
    final cutoutTop = (previewSize - cutoutSize) / 2;

    final srcXf = (cutoutLeft - imageLeft) / effectiveScale;
    final srcYf = (cutoutTop - imageTop) / effectiveScale;
    final srcWf = cutoutSize / effectiveScale;
    final srcHf = cutoutSize / effectiveScale;

    final srcX = srcXf.floor().clamp(0, decoded.width - 1);
    final srcY = srcYf.floor().clamp(0, decoded.height - 1);
    final srcW = srcWf.ceil().clamp(1, decoded.width - srcX);
    final srcH = srcHf.ceil().clamp(1, decoded.height - srcY);
    final srcSide = math.min(srcW, srcH);

    final cropped = img.copyCrop(
      decoded,
      x: srcX,
      y: srcY,
      width: srcSide,
      height: srcSide,
    );
    final resized = img.copyResize(
      cropped,
      width: 512,
      height: 512,
      interpolation: img.Interpolation.cubic,
    );

    final outputBytes = img.encodeJpg(resized, quality: 92);
    final outputPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}channel_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(outputPath).writeAsBytes(outputBytes, flush: true);
    return outputPath;
  }

  String _displayName(
    Map<String, dynamic> row, {
    String fallback = 'Пользователь',
  }) {
    final name = (row['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final email = (row['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    return fallback;
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) return value;
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  void _emitChatUpdatedIfPresent(dynamic responseData) {
    if (responseData is Map && responseData['data'] is Map) {
      final updated = Map<String, dynamic>.from(responseData['data']);
      chatEventsController.add({
        'type': 'chat:updated',
        'data': {'chat': updated},
      });
    }
  }

  Future<void> _reloadAll() async {
    final canLoadChannels = _canViewCreateTab() || _canViewChannelsTab();
    if (canLoadChannels) {
      await _loadChannels();
    } else if (mounted && _loading) {
      setState(() => _loading = false);
    }
    if (_canViewModerationTab()) {
      await _loadPendingPosts();
    }
    if (_canViewDeliveryTab()) {
      await _loadDeliveryDashboard();
    }
    if (_canViewSupportTab()) {
      await _loadSupportTickets();
      await _loadSupportTemplates(silent: true);
      await _loadReturnsWorkflow(silent: true);
    }
    if (_isCreatorBase() && _hasPermission('diagnostics.view')) {
      await _loadDiagnostics(silent: true);
    }
    if (_isCreatorBase() && _hasPermission('notifications.manage')) {
      await _loadSmartNotificationSettings(silent: true);
    }
    if (_showKeysTab) {
      await _loadTenants();
      await _loadTenantInvites();
    }
  }

  int _tenantMonthsOrDefault() {
    final parsed = int.tryParse(_tenantMonthsCtrl.text.trim());
    if (parsed == null) return 1;
    return parsed.clamp(1, 24);
  }

  Future<void> _loadTenants({bool silent = false}) async {
    if (!_showKeysTab) return;
    if (!silent && mounted) {
      setState(() => _tenantsLoading = true);
    } else {
      _tenantsLoading = true;
    }
    try {
      final resp = await authService.dio.get('/api/admin/tenants');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _tenantApiAllowed = true;
          _tenants = List<Map<String, dynamic>>.from(data['data']);
        });
      } else if (mounted) {
        setState(() {
          _tenantApiAllowed = false;
          _message = 'Не удалось загрузить ключи арендаторов';
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = _extractDioError(e);
      setState(() {
        _tenantApiAllowed = false;
        _message = 'Ключи недоступны: $msg';
      });
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
    final months = _tenantMonthsOrDefault();
    final notes = _tenantNotesCtrl.text.trim();
    setState(() {
      _tenantActionLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/tenants',
        data: {
          'name': name,
          'months': months,
          if (notes.isNotEmpty) 'notes': notes,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final created = Map<String, dynamic>.from(data['data']);
        final key = (created['access_key'] ?? '').toString();
        final warning = (created['warning'] ?? '').toString().trim();
        if (mounted) {
          setState(() {
            _lastGeneratedTenantKey = key;
            _tenantNameCtrl.clear();
            _tenantNotesCtrl.clear();
            _tenantMonthsCtrl.text = '1';
            _message = warning.isNotEmpty
                ? 'Ключ создан. $warning'
                : 'Ключ арендатора создан';
          });
        }
        await _loadTenants(silent: true);
      } else {
        setState(() => _message = 'Не удалось создать ключ');
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
        setState(
          () => _message = status == 'active'
              ? 'Ключ активирован'
              : 'Ключ заблокирован',
        );
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

  int? _toPositiveIntOrNull(String raw, {int min = 1, int max = 100000}) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return null;
    return parsed.clamp(min, max);
  }

  Future<void> _loadTenantInvites({bool silent = false}) async {
    if (!_showKeysTab) return;
    if (!silent && mounted) {
      setState(() => _invitesLoading = true);
    } else {
      _invitesLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/tenant/invites',
        queryParameters: {'include_inactive': 1},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _inviteApiAllowed = true;
          _tenantInvites = List<Map<String, dynamic>>.from(data['data']);
        });
      } else if (mounted) {
        setState(() => _inviteApiAllowed = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _inviteApiAllowed = false);
    } finally {
      if (mounted) {
        setState(() => _invitesLoading = false);
      } else {
        _invitesLoading = false;
      }
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
    final notes = _inviteNotesCtrl.text.trim();
    setState(() {
      _inviteActionLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/tenant/invites',
        data: {
          'role': _inviteRole,
          if (maxUses != null) 'max_uses': maxUses,
          if (expiresDays != null) 'expires_days': expiresDays,
          if (notes.isNotEmpty) 'notes': notes,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final row = Map<String, dynamic>.from(data['data']);
        if (mounted) {
          setState(() {
            _lastInviteCode = (row['code'] ?? '').toString();
            _lastInviteLink = (row['invite_link'] ?? '').toString();
            _inviteNotesCtrl.clear();
            _message = 'Код приглашения создан';
          });
        }
        await _loadTenantInvites(silent: true);
      } else {
        setState(() => _message = 'Не удалось создать код приглашения');
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
        data: {'is_active': active},
      );
      await _loadTenantInvites(silent: true);
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
      await authService.dio.delete('/api/admin/tenant/invites/$inviteId');
      await _loadTenantInvites(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления кода: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _inviteActionLoading = false);
    }
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final resp = await authService.dio.get('/api/admin/channels');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final channels = List<Map<String, dynamic>>.from(data['data']);
        final ids = channels
            .map(_channelIdOf)
            .where((v) => v.isNotEmpty)
            .toSet();
        _channelOverviews.removeWhere((key, _) => !ids.contains(key));
        if (mounted) {
          setState(() => _channels = channels);
        }

        for (final channel in channels.take(3)) {
          final id = _channelIdOf(channel);
          if (id.isEmpty) continue;
          unawaited(_loadChannelOverview(id, silent: true));
        }
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось загрузить каналы');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки каналов: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>?> _loadChannelOverview(
    String channelId, {
    bool force = false,
    bool silent = false,
  }) async {
    if (channelId.isEmpty) return null;
    if (!force && _channelOverviews.containsKey(channelId)) {
      return _channelOverviews[channelId];
    }
    if (_overviewLoading.contains(channelId)) {
      return _channelOverviews[channelId];
    }

    if (mounted) {
      setState(() => _overviewLoading.add(channelId));
    }

    try {
      final resp = await authService.dio.get(
        '/api/admin/channels/$channelId/overview',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final map = Map<String, dynamic>.from(data['data']);
        if (mounted) {
          setState(() => _channelOverviews[channelId] = map);
        }
        return map;
      }
      if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить обзор канала');
      }
      return null;
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка обзора канала: ${_extractDioError(e)}',
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _overviewLoading.remove(channelId));
      }
    }
  }

  Future<void> _loadPendingPosts() async {
    try {
      final resp = await authService.dio.get(
        '/api/admin/channels/pending_posts',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (mounted) {
          final meta = _asMap(data['meta']);
          setState(() {
            _pendingPosts = List<Map<String, dynamic>>.from(data['data']);
            _reservedPendingTotal = _toInt(meta['reserved_pending_total']);
            _reservedPendingUnits = _toInt(meta['reserved_pending_units']);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки очереди: ${_extractDioError(e)}',
        );
      }
    }
  }

  Future<void> _loadFinanceSummary({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _financeLoading = true);
    } else {
      _financeLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/finance/summary',
        queryParameters: {'period': _financePeriod},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        if (!mounted) return;
        setState(() => _financeData = Map<String, dynamic>.from(data['data']));
      } else if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить финансы');
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _message = 'Ошибка финансов: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _financeLoading = false);
      } else {
        _financeLoading = false;
      }
    }
  }

  Future<void> _loadSupportTemplates({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _supportTemplatesLoading = true);
    } else {
      _supportTemplatesLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/support/templates',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _supportTemplates = List<Map<String, dynamic>>.from(data['data']);
        });
      } else if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить шаблоны поддержки');
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка шаблонов поддержки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _supportTemplatesLoading = false);
      } else {
        _supportTemplatesLoading = false;
      }
    }
  }

  Future<void> _createSupportTemplate() async {
    final title = _supportTemplateTitleCtrl.text.trim();
    final body = _supportTemplateBodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _message = 'Заполни название и текст шаблона');
      return;
    }
    setState(() {
      _supportTemplateSaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/ops/support/templates',
        data: {'title': title, 'body': body, 'category': 'general'},
      );
      _supportTemplateTitleCtrl.clear();
      _supportTemplateBodyCtrl.clear();
      await _loadSupportTemplates(silent: true);
      if (mounted) {
        setState(() => _message = 'Шаблон поддержки сохранен');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка сохранения шаблона: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _supportTemplateSaving = false);
      }
    }
  }

  Future<void> _sendSupportQuickReply(Map<String, dynamic> ticket) async {
    final ticketId = (ticket['id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    final templateId = (_ticketTemplateById[ticketId] ?? '').trim();
    if (templateId.isEmpty) {
      setState(() => _message = 'Выбери шаблон для быстрого ответа');
      return;
    }
    setState(() {
      _supportQuickReplyBusy = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/ops/support/tickets/$ticketId/quick-reply',
        data: {'template_id': templateId},
      );
      await _loadSupportTickets(silent: true);
      if (mounted) {
        setState(() => _message = 'Быстрый ответ отправлен');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка быстрого ответа: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _supportQuickReplyBusy = false);
      }
    }
  }

  Future<void> _loadControlCenter({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _controlLoading = true);
    } else {
      _controlLoading = true;
    }
    try {
      final responses = await Future.wait([
        authService.dio.get(
          '/api/admin/ops/audit/logs',
          queryParameters: {
            if (_auditActionCtrl.text.trim().isNotEmpty)
              'action': _auditActionCtrl.text.trim(),
            'limit': 80,
          },
        ),
        authService.dio.get(
          '/api/admin/ops/antifraud/events',
          queryParameters: {'limit': 60},
        ),
        authService.dio.get(
          '/api/admin/ops/antifraud/blocks',
          queryParameters: {'active_only': 1},
        ),
        authService.dio.get('/api/admin/ops/returns/workflow'),
      ]);
      if (!mounted) return;
      final auditData = responses[0].data;
      final eventsData = responses[1].data;
      final blocksData = responses[2].data;
      final returnsData = responses[3].data;

      dynamic rolesData = const <String, dynamic>{};
      dynamic roleUsersData = const <String, dynamic>{};
      try {
        final rolesResp = await authService.dio.get(
          '/api/admin/ops/roles/constructor-draft',
        );
        rolesData = rolesResp.data;
      } catch (_) {}
      try {
        final usersResp = await authService.dio.get(
          '/api/admin/ops/roles/users',
          queryParameters: {
            if (_roleUserSearchCtrl.text.trim().isNotEmpty)
              'search': _roleUserSearchCtrl.text.trim(),
            'limit': 200,
          },
        );
        roleUsersData = usersResp.data;
      } catch (_) {}
      setState(() {
        _auditLogs =
            auditData is Map &&
                auditData['ok'] == true &&
                auditData['data'] is List
            ? List<Map<String, dynamic>>.from(auditData['data'])
            : <Map<String, dynamic>>[];
        _antifraudEvents =
            eventsData is Map &&
                eventsData['ok'] == true &&
                eventsData['data'] is List
            ? List<Map<String, dynamic>>.from(eventsData['data'])
            : <Map<String, dynamic>>[];
        _antifraudBlocks =
            blocksData is Map &&
                blocksData['ok'] == true &&
                blocksData['data'] is List
            ? List<Map<String, dynamic>>.from(blocksData['data'])
            : <Map<String, dynamic>>[];
        _rolesDraft =
            rolesData is Map &&
                rolesData['ok'] == true &&
                rolesData['data'] is Map
            ? Map<String, dynamic>.from(rolesData['data'])
            : null;
        _roleUsers =
            roleUsersData is Map &&
                roleUsersData['ok'] == true &&
                roleUsersData['data'] is List
            ? List<Map<String, dynamic>>.from(roleUsersData['data'])
            : <Map<String, dynamic>>[];
        _returnsWorkflow =
            returnsData is Map &&
                returnsData['ok'] == true &&
                returnsData['data'] is List
            ? List<Map<String, dynamic>>.from(returnsData['data'])
            : <Map<String, dynamic>>[];
        for (final row in _roleUsers) {
          final userId = (row['id'] ?? '').toString().trim();
          if (userId.isEmpty) continue;
          final templateId = (row['template_id'] ?? '').toString().trim();
          _roleSelectionByUserId[userId] = templateId.isEmpty
              ? 'none'
              : templateId;
        }
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка центра контроля: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _controlLoading = false);
      } else {
        _controlLoading = false;
      }
    }
  }

  Future<void> _exportAuditLogsCsv() async {
    if (kIsWeb) {
      setState(
        () => _message = 'CSV экспорт аудита сейчас доступен в desktop версии',
      );
      return;
    }
    try {
      final resp = await authService.dio.get<List<int>>(
        '/api/admin/ops/audit/logs/export',
        queryParameters: {
          if (_auditActionCtrl.text.trim().isNotEmpty)
            'action': _auditActionCtrl.text.trim(),
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = resp.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Пустой CSV');
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить CSV журнала',
        fileName: 'audit_log.csv',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (path == null || path.trim().isEmpty) {
        setState(() => _message = 'Сохранение CSV отменено');
        return;
      }
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        setState(() => _message = 'CSV сохранен: $path');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка CSV: ${_extractDioError(e)}');
      }
    }
  }

  Future<void> _releaseAntifraudBlock(String id) async {
    setState(() => _message = '');
    try {
      await authService.dio.patch(
        '/api/admin/ops/antifraud/blocks/$id/release',
      );
      await _loadControlCenter(silent: true);
      if (mounted) {
        setState(() => _message = 'Блокировка снята');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка снятия блокировки: ${_extractDioError(e)}',
        );
      }
    }
  }

  Future<void> _openRoleTemplateEditor({Map<String, dynamic>? template}) async {
    if (!_ensurePermission(
      'tenant.users.manage',
      'Недостаточно прав для управления шаблонами ролей',
    )) {
      return;
    }
    final modules = _asMapList(_rolesDraft?['modules']);
    if (modules.isEmpty) {
      setState(() => _message = 'Список модулей прав пока недоступен');
      return;
    }

    final isEdit = template != null;
    final existingPermissions = _asMap(template?['permissions']);
    _roleTemplateTitleCtrl.text = (template?['title'] ?? '').toString();
    _roleTemplateCodeCtrl.text = (template?['code'] ?? '').toString();
    _roleTemplateDescriptionCtrl.text = (template?['description'] ?? '')
        .toString();

    final selected = <String, bool>{};
    for (final module in modules) {
      final key = (module['key'] ?? '').toString();
      if (key.isEmpty) continue;
      selected[key] = existingPermissions[key] == true;
    }
    selected['all'] = existingPermissions['all'] == true;

    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(isEdit ? 'Редактировать шаблон' : 'Новый шаблон'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _roleTemplateTitleCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Название',
                            border: OutlineInputBorder(),
                          ),
                          controller: _roleTemplateTitleCtrl,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _roleTemplateCodeCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Code (a-z,0-9,-,_)',
                            border: OutlineInputBorder(),
                          ),
                          controller: _roleTemplateCodeCtrl,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _roleTemplateDescriptionCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Описание',
                            border: OutlineInputBorder(),
                          ),
                          controller: _roleTemplateDescriptionCtrl,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Полный доступ (all)'),
                        value: selected['all'] == true,
                        onChanged: (v) {
                          setDialogState(() {
                            selected['all'] = v;
                            if (v) {
                              for (final module in modules) {
                                final key = (module['key'] ?? '').toString();
                                if (key.isNotEmpty) selected[key] = true;
                              }
                            }
                          });
                        },
                      ),
                      const Divider(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: modules.map((module) {
                          final key = (module['key'] ?? '').toString();
                          final title = (module['title'] ?? key).toString();
                          final on = selected[key] == true;
                          return FilterChip(
                            selected: on,
                            label: Text(title),
                            onSelected: (value) {
                              setDialogState(() {
                                selected[key] = value;
                                if (!value) selected['all'] = false;
                              });
                            },
                          );
                        }).toList(),
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
                FilledButton(
                  onPressed: () {
                    final permissions = <String, dynamic>{};
                    if (selected['all'] == true) {
                      permissions['all'] = true;
                    } else {
                      for (final module in modules) {
                        final key = (module['key'] ?? '').toString();
                        if (key.isNotEmpty && selected[key] == true) {
                          permissions[key] = true;
                        }
                      }
                    }
                    Navigator.pop(ctx, {
                      'title': _roleTemplateTitleCtrl.text.trim(),
                      'code': _roleTemplateCodeCtrl.text.trim(),
                      'description': _roleTemplateDescriptionCtrl.text.trim(),
                      'permissions': permissions,
                    });
                  },
                  child: Text(isEdit ? 'Сохранить' : 'Создать'),
                ),
              ],
            );
          },
        );
      },
    );

    if (payload == null) return;
    await _saveRoleTemplate(payload, id: (template?['id'] ?? '').toString());
  }

  Future<void> _saveRoleTemplate(
    Map<String, dynamic> payload, {
    String id = '',
  }) async {
    if (!_ensurePermission(
      'tenant.users.manage',
      'Недостаточно прав для сохранения шаблона ролей',
    )) {
      return;
    }
    if (_roleTemplateSaving) return;
    setState(() {
      _roleTemplateSaving = true;
      _message = '';
    });
    try {
      final isEdit = id.trim().isNotEmpty;
      if (isEdit) {
        await authService.dio.patch(
          '/api/admin/ops/roles/templates/$id',
          data: payload,
        );
      } else {
        await authService.dio.post(
          '/api/admin/ops/roles/templates',
          data: payload,
        );
      }
      await _loadControlCenter(silent: true);
      if (mounted) {
        setState(
          () =>
              _message = isEdit ? 'Шаблон роли обновлен' : 'Шаблон роли создан',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка шаблона ролей: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _roleTemplateSaving = false);
      }
    }
  }

  Future<void> _deleteRoleTemplate(Map<String, dynamic> template) async {
    if (!_ensurePermission(
      'tenant.users.manage',
      'Недостаточно прав для удаления шаблона ролей',
    )) {
      return;
    }
    final id = (template['id'] ?? '').toString().trim();
    if (id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить шаблон роли?'),
        content: const Text(
          'Шаблон будет удалён, а его назначения пользователям будут сброшены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _message = '');
    try {
      await authService.dio.delete('/api/admin/ops/roles/templates/$id');
      await _loadControlCenter(silent: true);
      if (mounted) {
        setState(() => _message = 'Шаблон роли удален');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка удаления шаблона: ${_extractDioError(e)}',
        );
      }
    }
  }

  Future<void> _assignRoleTemplateToUser({
    required String userId,
    required String templateId,
  }) async {
    if (!_ensurePermission(
      'tenant.users.manage',
      'Недостаточно прав для назначения прав пользователю',
    )) {
      return;
    }
    if (userId.trim().isEmpty || _roleAssignBusy) return;
    setState(() {
      _roleAssignBusy = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/ops/roles/assign',
        data: {
          'user_id': userId,
          'template_id': templateId == 'none' ? '' : templateId,
        },
      );
      await _loadControlCenter(silent: true);
      if (mounted) {
        setState(() => _message = 'Права пользователя обновлены');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка назначения прав: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _roleAssignBusy = false);
      }
    }
  }

  Future<void> _loadRoleUsersOnly() async {
    if (!_ensurePermission(
      'tenant.users.manage',
      'Недостаточно прав для просмотра пользователей роли',
    )) {
      return;
    }
    if (_roleUsersLoading) return;
    setState(() {
      _roleUsersLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/roles/users',
        queryParameters: {
          if (_roleUserSearchCtrl.text.trim().isNotEmpty)
            'search': _roleUserSearchCtrl.text.trim(),
          'limit': 200,
        },
      );
      final data = resp.data;
      final users = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _roleUsers = users;
        for (final row in users) {
          final userId = (row['id'] ?? '').toString().trim();
          if (userId.isEmpty) continue;
          final templateId = (row['template_id'] ?? '').toString().trim();
          _roleSelectionByUserId[userId] = templateId.isEmpty
              ? 'none'
              : templateId;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _message = 'Ошибка списка пользователей: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _roleUsersLoading = false);
      }
    }
  }

  Future<void> _applyReturnsAction(
    Map<String, dynamic> claim,
    String action,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для управления возвратами',
    )) {
      return;
    }
    final claimId = (claim['id'] ?? '').toString().trim();
    if (claimId.isEmpty) return;
    String? amount;
    if (action == 'approve_discount') {
      amount = await _askText(
        title: 'Сумма скидки',
        label: 'Введите сумму скидки',
        initial: (claim['requested_amount'] ?? '').toString(),
      );
      if (amount == null) return;
    }
    setState(() {
      _returnsActionBusy = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/ops/returns/workflow/$claimId/action',
        data: {
          'action': action,
          if (amount != null) 'approved_amount': double.tryParse(amount),
        },
      );
      await _loadReturnsWorkflow(silent: true);
      if (mounted) {
        setState(() => _message = 'Статус заявки обновлен');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка workflow: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _returnsActionBusy = false);
      }
    }
  }

  Future<void> _loadDiagnostics({bool silent = false}) async {
    if (!_isCreatorBase()) return;
    if (!silent && mounted) {
      setState(() => _diagnosticsLoading = true);
    } else {
      _diagnosticsLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/diagnostics/center',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        if (!mounted) return;
        setState(
          () => _diagnosticsData = Map<String, dynamic>.from(data['data']),
        );
      } else if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить диагностику');
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _message = 'Ошибка диагностики: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _diagnosticsLoading = false);
      } else {
        _diagnosticsLoading = false;
      }
    }
  }

  Future<void> _loadSmartNotificationSettings({bool silent = false}) async {
    if (!_isCreatorBase()) return;
    if (!silent && mounted) {
      setState(() => _smartNotifyLoading = true);
    } else {
      _smartNotifyLoading = true;
    }
    try {
      final responses = await Future.wait([
        authService.dio.get('/api/admin/ops/notifications/settings'),
        authService.dio.get(
          '/api/admin/ops/notifications/history',
          queryParameters: {'limit': 30},
        ),
      ]);
      final data = responses[0].data;
      final historyData = responses[1].data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final settings = Map<String, dynamic>.from(data['data']);
        final history =
            historyData is Map &&
                historyData['ok'] == true &&
                historyData['data'] is List
            ? List<Map<String, dynamic>>.from(historyData['data'])
            : <Map<String, dynamic>>[];
        if (!mounted) return;
        setState(() {
          _smartNotifySettings = settings;
          _smartNotifyHistory = history;
          _notificationQuietFromCtrl.text = (settings['quiet_from'] ?? '')
              .toString();
          _notificationQuietToCtrl.text = (settings['quiet_to'] ?? '')
              .toString();
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка smart-уведомлений: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _smartNotifyLoading = false);
      } else {
        _smartNotifyLoading = false;
      }
    }
  }

  Future<void> _saveSmartNotificationSettings() async {
    if (!_isCreatorBase()) return;
    final current = _smartNotifySettings ?? const <String, dynamic>{};
    final enabledTypes = _asMap(current['enabled_types']);
    final priorities = _asMap(current['priorities']);
    setState(() => _smartNotifyLoading = true);
    try {
      await authService.dio.put(
        '/api/admin/ops/notifications/settings',
        data: {
          'enabled_types': {
            'order': enabledTypes['order'] != false,
            'support': enabledTypes['support'] != false,
            'delivery': enabledTypes['delivery'] != false,
          },
          'priorities': {
            'order': (priorities['order'] ?? 'high').toString(),
            'support': (priorities['support'] ?? 'normal').toString(),
            'delivery': (priorities['delivery'] ?? 'high').toString(),
          },
          'quiet_hours_enabled': current['quiet_hours_enabled'] == true,
          'quiet_from': _notificationQuietFromCtrl.text.trim(),
          'quiet_to': _notificationQuietToCtrl.text.trim(),
          'test_mode': true,
        },
      );
      await _loadSmartNotificationSettings(silent: true);
      if (mounted) {
        setState(() => _message = 'Настройки smart-уведомлений сохранены');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка smart-настроек: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _smartNotifyLoading = false);
    }
  }

  Future<void> _sendSmartNotificationTest() async {
    if (!_isCreatorBase()) return;
    setState(() => _smartNotifyLoading = true);
    try {
      await authService.dio.post(
        '/api/admin/ops/notifications/test',
        data: {
          'type': _smartNotifyType,
          'priority': _smartNotifyPriority,
          'title': 'Тест: ${_smartNotifyType.toUpperCase()}',
          'message':
              'Проверка типа $_smartNotifyType с приоритетом $_smartNotifyPriority',
        },
      );
      await _loadSmartNotificationSettings(silent: true);
      if (mounted) {
        setState(() => _message = 'Тестовое уведомление отправлено');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка теста уведомления: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _smartNotifyLoading = false);
    }
  }

  Future<void> _runDemoModeSeed() async {
    if (!_isCreatorBase()) return;
    setState(() {
      _demoModeBusy = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/ops/demo-mode/seed',
        data: {'clients': 12, 'products': 20},
      );
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      await _reloadAll();
      if (mounted) {
        setState(
          () => _message =
              'Демо-режим готов: клиенты ${payload['clients_created_or_reused'] ?? 0}, посты ${payload['products_queued'] ?? 0}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка demo-режима: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) setState(() => _demoModeBusy = false);
    }
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<bool> _downloadOpsDocument({
    required String kind,
    required String format,
    required String batchId,
  }) async {
    if (kind != 'finance_summary' && batchId.trim().isEmpty) return false;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get<List<int>>(
        '/api/admin/ops/documents/export',
        queryParameters: {
          'kind': kind,
          'format': format,
          if (batchId.trim().isNotEmpty) 'batch_id': batchId,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = resp.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Пустой файл');
      }
      if (kIsWeb) {
        throw Exception('Экспорт сейчас доступен в desktop версии');
      }
      final ext = format == 'pdf' ? 'pdf' : 'xlsx';
      final filePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить документ',
        fileName: kind == 'finance_summary'
            ? 'finance_summary.$ext'
            : '${kind}_$batchId.$ext',
        type: FileType.custom,
        allowedExtensions: [ext],
      );
      if (filePath == null || filePath.trim().isEmpty) {
        if (mounted) {
          setState(() => _message = 'Сохранение документа отменено');
        }
        return false;
      }
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        setState(() => _message = 'Документ сохранен: $filePath');
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка документа: ${_extractDioError(e)}');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _openRouteOrderEditor() async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для ручной правки маршрута',
    )) {
      return;
    }
    final activeBatch = _deliveryActiveBatch;
    final batchId = (activeBatch?['id'] ?? '').toString();
    if (batchId.isEmpty) return;
    final customers = _asMapList(activeBatch?['customers'])
        .where((item) => (item['call_status'] ?? '').toString() == 'accepted')
        .toList();
    if (customers.isEmpty) {
      setState(() => _message = 'Нет подтвержденных клиентов для сортировки');
      return;
    }
    customers.sort((a, b) {
      final ar = _toInt(a['route_order'], fallback: 10000);
      final br = _toInt(b['route_order'], fallback: 10000);
      return ar.compareTo(br);
    });

    final reordered = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) {
        final local = customers
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: true);
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: const Text('Ручной порядок маршрута'),
            content: SizedBox(
              width: 520,
              height: 480,
              child: ReorderableListView.builder(
                itemCount: local.length,
                onReorder: (oldIndex, newIndex) {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = local.removeAt(oldIndex);
                  local.insert(newIndex, item);
                  setLocalState(() {});
                },
                itemBuilder: (context, i) {
                  final row = local[i];
                  final name = (row['customer_name'] ?? 'Клиент').toString();
                  final address = (row['address_text'] ?? '').toString();
                  return ListTile(
                    key: ValueKey(row['id']),
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(name),
                    subtitle: Text(address),
                    trailing: const Icon(Icons.drag_indicator),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, local),
                child: const Text('Сохранить порядок'),
              ),
            ],
          ),
        );
      },
    );
    if (reordered == null) return;

    setState(() => _deliverySaving = true);
    try {
      final payload = reordered.asMap().entries.map((entry) {
        return {
          'customer_id': (entry.value['id'] ?? '').toString(),
          'route_order': entry.key + 1,
        };
      }).toList();
      await authService.dio.patch(
        '/api/admin/delivery/batches/$batchId/route-order',
        data: {'orders': payload},
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Маршрут обновлен вручную');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка маршрута: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  String _formatMoney(dynamic value) {
    final n = (value is num)
        ? value.toDouble()
        : double.tryParse('$value') ?? 0;
    return '${n.toStringAsFixed(2)} RUB';
  }

  String _formatDateTimeLabel(dynamic raw) {
    return formatDateTimeValue(raw, fallback: '');
  }

  Color _deliveryRouteColor(ThemeData theme, int index) {
    const palette = [
      Color(0xFFEF5350),
      Color(0xFF42A5F5),
      Color(0xFF66BB6A),
      Color(0xFFFFA726),
      Color(0xFFAB47BC),
      Color(0xFF26A69A),
    ];
    return palette[index % palette.length];
  }

  Widget _buildDeliveryMapView(List<Map<String, dynamic>> customers) {
    final theme = Theme.of(context);
    final activeBatch = _deliveryActiveBatch;
    final activeBatchId = (activeBatch?['id'] ?? '').toString();
    final originLat =
        _toNullableDouble(activeBatch?['route_origin_lat']) ??
        _deliveryOriginLat ??
        53.195878;
    final originLng =
        _toNullableDouble(activeBatch?['route_origin_lng']) ??
        _deliveryOriginLng ??
        50.100202;
    final originLabel =
        (activeBatch?['route_origin_label'] ?? _deliveryOriginLabel).toString();
    final originAddress =
        (activeBatch?['route_origin_address'] ?? _deliveryOriginCtrl.text)
            .toString()
            .trim();
    final originPoint = LatLng(originLat, originLng);
    final points = <LatLng>[originPoint];
    final markers = <Marker>[];
    final routes = <String, List<Map<String, dynamic>>>{};

    for (final customer in customers) {
      final lat = _toNullableDouble(customer['lat']);
      final lng = _toNullableDouble(customer['lng']);
      if (lat == null || lng == null) continue;
      final point = LatLng(lat, lng);
      points.add(point);
      final courierKey = (customer['courier_name'] ?? '').toString().trim();
      final routeKey = courierKey.isEmpty ? '_pending' : courierKey;
      routes
          .putIfAbsent(routeKey, () => <Map<String, dynamic>>[])
          .add(customer);
    }

    final polylines = <Polyline>[];
    final routeEntries =
        routes.entries.where((entry) => entry.key != '_pending').toList()
          ..sort((a, b) => a.key.compareTo(b.key));

    for (var index = 0; index < routeEntries.length; index += 1) {
      final entry = routeEntries[index];
      final routeColor = _deliveryRouteColor(theme, index);
      final ordered = [...entry.value]
        ..sort((a, b) {
          final left = _toInt(a['route_order'], fallback: 9999);
          final right = _toInt(b['route_order'], fallback: 9999);
          return left.compareTo(right);
        });
      final routePoints = <LatLng>[originPoint];
      for (final customer in ordered) {
        final lat = _toNullableDouble(customer['lat']);
        final lng = _toNullableDouble(customer['lng']);
        if (lat == null || lng == null) continue;
        routePoints.add(LatLng(lat, lng));
      }
      if (routePoints.length > 1) {
        polylines.add(
          Polyline(
            points: routePoints,
            strokeWidth: 4,
            color: routeColor.withValues(alpha: 0.88),
          ),
        );
      }
    }

    for (var index = 0; index < customers.length; index += 1) {
      final customer = customers[index];
      final lat = _toNullableDouble(customer['lat']);
      final lng = _toNullableDouble(customer['lng']);
      if (lat == null || lng == null) continue;
      final routeOrder = _toInt(customer['route_order'], fallback: index + 1);
      final courierName = (customer['courier_name'] ?? '').toString().trim();
      final routeColor = courierName.isEmpty
          ? theme.colorScheme.outline
          : _deliveryRouteColor(
              theme,
              routeEntries
                  .indexWhere((entry) => entry.key == courierName)
                  .clamp(0, routeEntries.isEmpty ? 0 : routeEntries.length - 1),
            );
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 104,
          height: 58,
          child: GestureDetector(
            onTap: activeBatchId.isEmpty
                ? null
                : () => _reassignDeliveryCustomer(activeBatchId, customer),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: routeColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    courierName.isEmpty ? '?' : '$routeOrder',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    (customer['customer_name'] ?? 'Клиент').toString(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    markers.insert(
      0,
      Marker(
        point: originPoint,
        width: 150,
        height: 70,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.warehouse_outlined,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                originLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 480,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: originPoint,
                  initialZoom: 8.4,
                ),
                children: [
                  Builder(
                    builder: (context) {
                      final tileUrl = _activeMapTileUrl(theme);
                      final subdomains = _activeMapSubdomains(tileUrl);
                      return TileLayer(
                        urlTemplate: tileUrl,
                        subdomains: subdomains,
                        userAgentPackageName: 'projectantitelegram',
                      );
                    },
                  ),
                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        _mapAttributionText,
                        textStyle: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
                  MarkerLayer(markers: markers),
                ],
              ),
              if (points.length <= 1)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 280),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Text(
                      'Карта Самарской области готова.\n'
                      'Точки и линии появятся после подтверждения адресов.\n'
                      '${originAddress.isNotEmpty ? 'Старт: $originAddress' : 'Старт пока не задан, используется центр Самары.'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < routeEntries.length; index += 1)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _deliveryRouteColor(
                    theme,
                    index,
                  ).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _deliveryRouteColor(
                      theme,
                      index,
                    ).withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  '${routeEntries[index].key}: ${routeEntries[index].value.length} адресов',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (routes.containsKey('_pending'))
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Без маршрута: ${routes['_pending']!.length}',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Карта Самарской области для текущего листа доставки. Маршрут начинается от точки отправки, старается делить доставки поровну и уменьшать пересечения. Нажми на точку клиента, чтобы перекинуть его на другого курьера.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _deliveryBatchStatusLabel(String raw) {
    switch (raw) {
      case 'calling':
        return 'Ожидаем ответы по рассылке';
      case 'couriers_assigned':
        return 'Маршрут собран';
      case 'handed_off':
        return 'Передано курьерам';
      case 'completed':
        return 'Завершено';
      case 'cancelled':
        return 'Отменено';
      default:
        return raw.isEmpty ? 'Черновик' : raw;
    }
  }

  String _deliveryCustomerStatusLabel(String raw) {
    switch (raw) {
      case 'offer_sent':
        return 'Рассылка отправлена, ждем ответ';
      case 'awaiting_call':
        return 'Готов к рассылке';
      case 'accepted':
        return 'Согласен на доставку';
      case 'declined':
        return 'Отказался';
      case 'preparing_delivery':
        return 'Идет подготовка';
      case 'handing_to_courier':
        return 'Передается курьеру';
      case 'in_delivery':
        return 'У курьера';
      case 'completed':
        return 'Доставлено';
      case 'returned_to_cart':
        return 'Вернули в корзину';
      case 'removed':
        return 'Убрали из маршрута';
      case 'pending':
      default:
        return 'Еще не отправлено';
    }
  }

  Future<void> _loadDeliveryDashboard() async {
    final effectiveRole = authService.effectiveRole.toLowerCase().trim();
    if (effectiveRole != 'admin' &&
        effectiveRole != 'tenant' &&
        effectiveRole != 'creator') {
      if (mounted) {
        setState(() {
          _deliveryLoading = false;
          _deliveryActiveBatch = null;
          _deliveryBatches = [];
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _deliveryLoading = true;
      });
    }
    try {
      final resp = await authService.dio.get('/api/admin/delivery/dashboard');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        final settings = _asMap(payload['settings']);
        final threshold = settings['threshold_amount'];
        final originAddress = (settings['route_origin_address'] ?? '')
            .toString();
        final originLabel = (settings['route_origin_label'] ?? 'Точка отправки')
            .toString();
        _deliveryThresholdCtrl.text = _toInt(
          threshold,
          fallback: 1500,
        ).toString();
        _deliveryOriginCtrl.text = originAddress;
        if (mounted) {
          setState(() {
            _deliveryBatches = _asMapList(payload['batches']);
            _deliveryActiveBatch = payload['active_batch'] is Map
                ? Map<String, dynamic>.from(payload['active_batch'])
                : null;
            _deliveryOriginLabel = originLabel;
            _deliveryOriginLat = _toNullableDouble(
              settings['route_origin_lat'],
            );
            _deliveryOriginLng = _toNullableDouble(
              settings['route_origin_lng'],
            );
          });
        }
      }
    } catch (e) {
      if (e is DioException && e.response?.statusCode == 403) {
        if (mounted) {
          setState(() {
            _deliveryActiveBatch = null;
            _deliveryBatches = [];
          });
        }
        return;
      }
      if (mounted) {
        setState(() => _message = 'Ошибка доставки: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliveryLoading = false);
      }
    }
  }

  String _supportCategoryLabel(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'product':
        return 'Товар';
      case 'delivery':
        return 'Доставка';
      case 'cart':
        return 'Корзина';
      default:
        return 'Общий';
    }
  }

  String _supportStatusLabel(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'open':
        return 'Открыт';
      case 'waiting_customer':
        return 'Ждём клиента';
      case 'resolved':
        return 'Решён';
      case 'archived':
        return 'В архиве';
      default:
        return 'Неизвестно';
    }
  }

  Future<void> _loadSupportTickets({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _supportLoading = true);
    } else {
      _supportLoading = true;
    }
    try {
      final activeResp = await authService.dio.get(
        '/api/support/tickets',
        queryParameters: {'status': 'open,waiting_customer,resolved'},
      );
      final archivedResp = await authService.dio.get(
        '/api/support/tickets',
        queryParameters: {'status': 'archived', 'include_archived': 1},
      );

      final activeData = activeResp.data;
      final archivedData = archivedResp.data;
      if (!mounted) return;
      setState(() {
        _supportActiveTickets =
            activeData is Map &&
                activeData['ok'] == true &&
                activeData['data'] is List
            ? List<Map<String, dynamic>>.from(activeData['data'])
            : [];
        _supportArchivedTickets =
            archivedData is Map &&
                archivedData['ok'] == true &&
                archivedData['data'] is List
            ? List<Map<String, dynamic>>.from(archivedData['data'])
            : [];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка поддержки: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportLoading = false);
      } else {
        _supportLoading = false;
      }
    }
  }

  Future<void> _loadReturnsWorkflow({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _returnsActionBusy = true);
    } else {
      _returnsActionBusy = true;
    }
    try {
      final resp = await authService.dio.get('/api/admin/ops/returns/workflow');
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        _returnsWorkflow =
            data is Map && data['ok'] == true && data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : <Map<String, dynamic>>[];
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка возвратов/скидок: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _returnsActionBusy = false);
      } else {
        _returnsActionBusy = false;
      }
    }
  }

  Future<void> _archiveSupportTicket(Map<String, dynamic> ticket) async {
    final ticketId = (ticket['id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    setState(() {
      _supportArchiveBusy = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/support/tickets/$ticketId/archive',
        data: {'reason': 'admin_archive'},
      );
      await _loadSupportTickets(silent: true);
      if (!mounted) return;
      setState(() => _message = 'Тикет перенесён в архив');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Ошибка архива поддержки: ${_extractDioError(e)}';
      });
    } finally {
      if (mounted) {
        setState(() => _supportArchiveBusy = false);
      } else {
        _supportArchiveBusy = false;
      }
    }
  }

  Future<void> _openSupportChat(Map<String, dynamic> ticket) async {
    final chatId = (ticket['chat_id'] ?? '').toString().trim();
    if (chatId.isEmpty) return;
    final chatTitle = (ticket['chat_title'] ?? 'Поддержка').toString();
    final ticketId = (ticket['id'] ?? '').toString().trim();
    final settings = _asMap(ticket['chat_settings']);
    final normalizedSettings = <String, dynamic>{
      ...settings,
      'kind': settings['kind'] ?? 'support_ticket',
      'support_ticket': true,
      if (ticketId.isNotEmpty)
        'support_ticket_id': settings['support_ticket_id'] ?? ticketId,
    };
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId,
          chatTitle: chatTitle,
          chatType: (ticket['chat_type'] ?? 'private').toString(),
          chatSettings: normalizedSettings,
        ),
      ),
    );
  }

  Future<void> _openDirectChatWithUser(Map<String, dynamic> claim) async {
    final userId = (claim['user_id'] ?? '').toString().trim();
    if (userId.isEmpty) return;
    try {
      final resp = await authService.dio.post(
        '/api/chats/direct/open',
        data: {'user_id': userId},
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
        throw Exception('Не удалось открыть чат с клиентом');
      }
      final payload = Map<String, dynamic>.from(data['data']);
      final chat = payload['chat'] is Map
          ? Map<String, dynamic>.from(payload['chat'])
          : <String, dynamic>{};
      final peer = payload['peer'] is Map
          ? Map<String, dynamic>.from(payload['peer'])
          : <String, dynamic>{};
      final chatId = (chat['id'] ?? '').toString().trim();
      if (chatId.isEmpty) {
        throw Exception('Не удалось открыть чат с клиентом');
      }
      final chatTitle = _displayName(peer, fallback: 'Пользователь');
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: chatTitle,
            chatType: (chat['type'] ?? '').toString(),
            chatSettings: chat['settings'] is Map
                ? Map<String, dynamic>.from(chat['settings'])
                : null,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось открыть ЛС: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _saveDeliverySettings() async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для управления доставкой',
    )) {
      return;
    }
    final threshold = int.tryParse(_deliveryThresholdCtrl.text.trim());
    if (threshold == null || threshold < 0) {
      setState(() => _message = 'Введите корректную сумму для доставки');
      return;
    }
    final originAddress = _deliveryOriginCtrl.text.trim();
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/delivery/settings',
        data: {
          'threshold_amount': threshold,
          'route_origin_label': _deliveryOriginLabel,
          'route_origin_address': originAddress,
        },
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Порог доставки сохранен');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка порога: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _generateDeliveryBatch() async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для запуска рассылки доставки',
    )) {
      return;
    }
    final threshold = int.tryParse(_deliveryThresholdCtrl.text.trim());
    if (threshold == null || threshold < 0) {
      setState(() => _message = 'Введите корректную сумму для доставки');
      return;
    }
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/delivery/broadcast',
        data: {'threshold_amount': threshold},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final payload = data['data'] is Map
            ? Map<String, dynamic>.from(data['data'])
            : <String, dynamic>{};
        await _loadDeliveryDashboard();
        if (mounted) {
          final sentTotal = payload['sent_total'] is num
              ? (payload['sent_total'] as num).toInt()
              : 0;
          final addedTotal = payload['added_to_existing_batch'] is num
              ? (payload['added_to_existing_batch'] as num).toInt()
              : 0;
          setState(
            () => _message = sentTotal > 0 || addedTotal > 0
                ? 'Рассылка отправлена: $sentTotal${addedTotal > 0 ? ' (добавлено в лист: $addedTotal)' : ''}'
                : (payload['message']?.toString() ??
                      'Нет клиентов для рассылки'),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка рассылки: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _resetDeliveryTesting() async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для очистки доставки',
    )) {
      return;
    }
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post('/api/admin/delivery/reset');
      final data = resp.data;
      await _loadDeliveryDashboard();
      if (mounted) {
        final payload = data is Map && data['data'] is Map
            ? Map<String, dynamic>.from(data['data'])
            : <String, dynamic>{};
        setState(
          () => _message =
              'Доставка очищена. Чатов: ${payload['cleared_chats'] ?? 0}, пользователей: ${payload['affected_users'] ?? 0}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка очистки доставки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  String _trimClockValue(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value);
    if (match == null) return value;
    final hours = int.tryParse(match.group(1) ?? '');
    final minutes = int.tryParse(match.group(2) ?? '');
    if (hours == null || minutes == null) return value;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }

  Future<Map<String, String>?> _askDeliveryDecisionData({
    required String initialAddress,
    required String initialAfter,
    required String initialBefore,
    required String title,
  }) async {
    final addressCtrl = TextEditingController(text: initialAddress);
    final afterCtrl = TextEditingController(text: initialAfter);
    final beforeCtrl = TextEditingController(text: initialBefore);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: addressCtrl,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    hintText: 'Самара, улица, дом, подъезд',
                    border: OutlineInputBorder(),
                    labelText: 'Адрес доставки',
                  ),
                  controller: addressCtrl,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: afterCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          hintText: '10:00',
                          labelText: 'После',
                          border: OutlineInputBorder(),
                        ),
                        controller: afterCtrl,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: beforeCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          hintText: '16:00',
                          labelText: 'До',
                          border: OutlineInputBorder(),
                        ),
                        controller: beforeCtrl,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Оставь время пустым, если клиенту без разницы. Базовое окно доставки: 10:00-16:00.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop({
              'address_text': addressCtrl.text.trim(),
              'preferred_time_from': _trimClockValue(afterCtrl.text),
              'preferred_time_to': _trimClockValue(beforeCtrl.text),
            }),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<Map<String, dynamic>?> _askDeliveryLogisticsData(
    Map<String, dynamic> customer,
  ) async {
    final packageCtrl = TextEditingController(
      text: _toInt(customer['package_places'], fallback: 1).toString(),
    );
    final bulkyCountCtrl = TextEditingController(
      text: _toInt(customer['bulky_places'], fallback: 0).toString(),
    );
    final bulkyNoteCtrl = TextEditingController(
      text: (customer['bulky_note'] ?? '').toString(),
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Логистика клиента'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: packageCtrl,
                keyboardType: TextInputType.number,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Сколько мест',
                    border: OutlineInputBorder(),
                  ),
                  controller: packageCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bulkyCountCtrl,
                keyboardType: TextInputType.number,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Количество габаритов',
                    border: OutlineInputBorder(),
                  ),
                  controller: bulkyCountCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bulkyNoteCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Что относится к габариту',
                    border: OutlineInputBorder(),
                  ),
                  controller: bulkyNoteCtrl,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop({
              'package_places': int.tryParse(packageCtrl.text.trim()) ?? 0,
              'bulky_places': int.tryParse(bulkyCountCtrl.text.trim()) ?? 0,
              'bulky_note': bulkyNoteCtrl.text.trim(),
            }),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _setDeliveryDecision(
    String batchId,
    Map<String, dynamic> customer, {
    required bool accepted,
  }) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для изменения решения по доставке',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (customerId.isEmpty) return;

    String addressText = '';
    String preferredTimeFrom = '';
    String preferredTimeTo = '';
    if (accepted) {
      final result = await _askDeliveryDecisionData(
        initialAddress: (customer['address_text'] ?? '').toString(),
        initialAfter: ((customer['preferred_time_from'] ?? '').toString())
            .replaceAll(':00.000000', '')
            .replaceAll(':00', ''),
        initialBefore: ((customer['preferred_time_to'] ?? '').toString())
            .replaceAll(':00.000000', '')
            .replaceAll(':00', ''),
        title: 'Адрес доставки',
      );
      if (result == null || (result['address_text'] ?? '').isEmpty) return;
      addressText = (result['address_text'] ?? '').trim();
      preferredTimeFrom = (result['preferred_time_from'] ?? '').trim();
      preferredTimeTo = (result['preferred_time_to'] ?? '').trim();
    }

    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/decision',
        data: {
          'accepted': accepted,
          if (accepted) 'address_text': addressText,
          if (accepted && preferredTimeFrom.isNotEmpty)
            'preferred_time_from': preferredTimeFrom,
          if (accepted && preferredTimeTo.isNotEmpty)
            'preferred_time_to': preferredTimeTo,
        },
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(
          () => _message = accepted
              ? 'Доставка подтверждена вручную'
              : 'Отказ от доставки сохранен',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = accepted
              ? 'Ошибка подтверждения доставки: ${_extractDioError(e)}'
              : 'Ошибка отказа от доставки: ${_extractDioError(e)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  String _formatClockLabel(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    if (value.isEmpty) return '';
    if (value.length >= 5 && value[2] == ':') {
      return value.substring(0, 5);
    }
    return value;
  }

  Future<void> _editDeliveryLogistics(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для редактирования логистики',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (customerId.isEmpty) return;
    final result = await _askDeliveryLogisticsData(customer);
    if (result == null) return;

    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/logistics',
        data: result,
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Логистика клиента обновлена');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка логистики: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _manualAddDeliveryCustomer(String batchId) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для ручного добавления клиента',
    )) {
      return;
    }
    final phoneCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final afterCtrl = TextEditingController();
    final beforeCtrl = TextEditingController();
    final packageCtrl = TextEditingController(text: '1');
    final bulkyCountCtrl = TextEditingController(text: '0');
    final bulkyNoteCtrl = TextEditingController();

    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить клиента по телефону'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Номер телефона',
                      border: OutlineInputBorder(),
                    ),
                    controller: phoneCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addressCtrl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Адрес доставки',
                      hintText: 'Самара, улица, дом, подъезд',
                      border: OutlineInputBorder(),
                    ),
                    controller: addressCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: afterCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'После',
                            hintText: '10:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: afterCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: beforeCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'До',
                            hintText: '16:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: beforeCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: packageCtrl,
                        keyboardType: TextInputType.number,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Сколько мест',
                            border: OutlineInputBorder(),
                          ),
                          controller: packageCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: bulkyCountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Габаритов',
                            border: OutlineInputBorder(),
                          ),
                          controller: bulkyCountCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bulkyNoteCtrl,
                  minLines: 2,
                  maxLines: 3,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Описание габарита',
                      border: OutlineInputBorder(),
                    ),
                    controller: bulkyNoteCtrl,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop({
              'phone': phoneCtrl.text.trim(),
              'address_text': addressCtrl.text.trim(),
              'preferred_time_from': _trimClockValue(afterCtrl.text),
              'preferred_time_to': _trimClockValue(beforeCtrl.text),
              'package_places': int.tryParse(packageCtrl.text.trim()) ?? 0,
              'bulky_places': int.tryParse(bulkyCountCtrl.text.trim()) ?? 0,
              'bulky_note': bulkyNoteCtrl.text.trim(),
            }),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (payload == null) return;

    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/manual-add',
        data: payload,
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Клиент добавлен в доставку');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка добавления клиента: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<bool> _downloadDeliveryExcel(String batchId) async {
    if (batchId.trim().isEmpty) return false;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get<List<int>>(
        '/api/admin/delivery/batches/$batchId/export',
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = resp.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Пустой файл Excel');
      }
      if (kIsWeb) {
        throw Exception('Excel-экспорт сейчас доступен в desktop версии');
      }
      final filePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить Excel доставки',
        fileName: 'delivery_$batchId.xlsx',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (filePath == null || filePath.trim().isEmpty) {
        if (mounted) {
          setState(() => _message = 'Сохранение Excel отменено');
        }
        return false;
      }
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        setState(() => _message = 'Excel сохранен: $filePath');
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка Excel: ${_extractDioError(e)}');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _reassignDeliveryCustomer(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для смены курьера',
    )) {
      return;
    }
    final courierNames = (_deliveryActiveBatch?['courier_names'] is List)
        ? List<String>.from(
            (_deliveryActiveBatch?['courier_names'] as List).map(
              (item) => item.toString(),
            ),
          )
        : const <String>[];
    if (courierNames.isEmpty) {
      setState(
        () => _message =
            'Сначала нажми "Распределить по курьерам", чтобы появилась сетка курьеров',
      );
      return;
    }

    final currentCourier = (customer['locked_courier_name'] ?? '')
        .toString()
        .trim();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          'Курьер для ${(customer['customer_name'] ?? 'клиента').toString()}',
        ),
        children: [
          for (final courier in courierNames)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(courier),
              child: Row(
                children: [
                  Icon(
                    courier == currentCourier
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(courier)),
                ],
              ),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: const Text('Авто-распределение'),
          ),
        ],
      ),
    );
    if (selected == null) return;

    final customerId = (customer['id'] ?? '').toString().trim();
    if (customerId.isEmpty) return;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/reassign',
        data: {if (selected.isNotEmpty) 'courier_name': selected},
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(
          () => _message = selected.isEmpty
              ? 'Клиент возвращен в авто-распределение'
              : 'Клиент закреплен за курьером $selected',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка смены курьера: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _assignCouriers(String batchId) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для распределения курьеров',
    )) {
      return;
    }
    final courierNames = _courierNamesCtrl.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (courierNames.isEmpty) {
      setState(
        () => _message = 'Введите имена курьеров, каждое с новой строки',
      );
      return;
    }
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/assign-couriers',
        data: {'courier_names': courierNames},
      );
      await _loadDeliveryDashboard();
      var excelSaved = true;
      if (!kIsWeb) {
        excelSaved = await _downloadDeliveryExcel(batchId);
      }
      if (mounted) {
        setState(
          () => _message = excelSaved
              ? 'Маршрут собран и Excel подготовлен'
              : _message,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка курьеров: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _confirmDeliveryHandoff(String batchId) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для передачи курьерам',
    )) {
      return;
    }
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/confirm-handoff',
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Лист доставки передан курьерам');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка передачи: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _completeDeliveryBatch(String batchId) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для завершения доставки',
    )) {
      return;
    }
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/complete',
      );
      await _loadDeliveryDashboard();
      var excelSaved = true;
      if (!kIsWeb) {
        excelSaved = await _downloadDeliveryExcel(batchId);
      }
      if (mounted) {
        setState(
          () => _message = excelSaved
              ? 'Доставка завершена, архив Excel сохранен'
              : 'Доставка завершена',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка завершения доставки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _removeDeliveryCustomerFromRoute(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для изменения маршрута',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (customerId.isEmpty) return;
    final name = (customer['customer_name'] ?? 'клиента').toString();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Убрать из маршрута'),
        content: Text(
          'Вернуть $name обратно в корзину и на полку?\n'
          'Товары исчезнут из текущего маршрута доставки.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Вернуть в корзину'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/remove-from-route',
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Клиент возвращен из маршрута в корзину');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _message = 'Ошибка возврата из маршрута: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deliverySaving = false);
      }
    }
  }

  Future<void> _createChannel() async {
    final title = _channelTitleCtrl.text.trim();
    final description = _channelDescriptionCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _message = 'Введите название канала');
      return;
    }

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels',
        data: {
          'title': title,
          'description': description,
          'visibility': _newChannelVisibility,
        },
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        final data = resp.data;
        Map<String, dynamic>? createdChat;
        if (data is Map && data['data'] is Map) {
          createdChat = Map<String, dynamic>.from(data['data']);
        }
        if (createdChat != null) {
          chatEventsController.add({
            'type': 'chat:created',
            'data': {'chat': createdChat},
          });
        }
        _channelTitleCtrl.clear();
        _channelDescriptionCtrl.clear();
        await _reloadAll();
        if (mounted) {
          setState(() => _message = 'Канал создан');
          _animateToTab('channels');
        }
      } else {
        setState(() => _message = 'Не удалось создать канал');
      }
    } catch (e) {
      setState(
        () => _message = 'Ошибка создания канала: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteChannel(String channelId, String title) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить канал'),
        content: Text(
          'Удалить канал "$title"?\n'
          'Это удалит сообщения в этом канале.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      await authService.dio.delete('/api/admin/channels/$channelId');
      chatEventsController.add({
        'type': 'chat:deleted',
        'data': {'chatId': channelId},
      });
      _channelOverviews.remove(channelId);
      await _reloadAll();
      if (mounted) setState(() => _message = 'Канал удалён');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка удаления канала: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveChannelSettings({
    required String channelId,
    required String title,
    required String description,
    required String visibility,
    required double avatarFocusX,
    required double avatarFocusY,
    required bool isMain,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      if (mounted) {
        setState(() => _message = 'Название канала не может быть пустым');
      }
      return;
    }

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final payload = {
        'title': cleanTitle,
        'description': description.trim(),
        'avatar_focus_x': avatarFocusX,
        'avatar_focus_y': avatarFocusY,
        if (!isMain) 'visibility': visibility,
      };
      final resp = await authService.dio.patch(
        '/api/admin/channels/$channelId',
        data: payload,
      );
      _emitChatUpdatedIfPresent(resp.data);
      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) {
        setState(() => _message = 'Настройки канала сохранены');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка сохранения канала: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_AvatarPlacementResult?> _showAvatarPlacementDialog({
    required String filePath,
    required double initialFocusX,
    required double initialFocusY,
    required double initialZoom,
  }) async {
    final imageFile = File(filePath);
    final sourceBytes = await imageFile.readAsBytes();
    final source = img.decodeImage(sourceBytes);
    if (source == null) {
      if (mounted) {
        setState(() => _message = 'Не удалось прочитать изображение');
      }
      return null;
    }

    return showDialog<_AvatarPlacementResult>(
      context: context,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        final maxDialogWidth = media.size.width - 40;
        final maxDialogHeight = media.size.height - 160;
        final dialogWidth = maxDialogWidth.clamp(280.0, 420.0);
        final previewByWidth = (dialogWidth - 32).clamp(220.0, 340.0);
        final previewByHeight = (maxDialogHeight - 180).clamp(180.0, 340.0);
        final previewSize = math.min(previewByWidth, previewByHeight);
        final cutoutSize = (previewSize * 0.58).clamp(110.0, 190.0).toDouble();

        final baseScale = math.max(
          previewSize / source.width,
          previewSize / source.height,
        );
        final minZoom = math
            .max(
              cutoutSize / (source.width * baseScale),
              cutoutSize / (source.height * baseScale),
            )
            .clamp(0.2, 1.0)
            .toDouble();
        const maxZoom = 4.0;
        final initialRenderedWidth = source.width * baseScale * initialZoom;
        final initialRenderedHeight = source.height * baseScale * initialZoom;
        final initialMaxX = math.max(
          0.0,
          (initialRenderedWidth - cutoutSize) / 2,
        );
        final initialMaxY = math.max(
          0.0,
          (initialRenderedHeight - cutoutSize) / 2,
        );

        var offset = Offset(
          initialFocusX.clamp(-1.0, 1.0) * initialMaxX,
          initialFocusY.clamp(-1.0, 1.0) * initialMaxY,
        );
        var zoom = initialZoom.clamp(minZoom, maxZoom).toDouble();
        offset = _clampAvatarOffset(
          offset: offset,
          sourceWidth: source.width,
          sourceHeight: source.height,
          previewSize: previewSize,
          cutoutSize: cutoutSize,
          zoom: zoom,
        );

        var scaleBase = zoom;
        var startOffset = offset;
        var startFocal = Offset.zero;
        var exporting = false;
        var localError = '';

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text('Позиция аватарки'),
              content: SizedBox(
                width: dialogWidth,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Тяните фото для позиции. Колесо мыши или щипок меняет масштаб.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Listener(
                        onPointerSignal: (event) {
                          if (event is! PointerScrollEvent) return;
                          setModalState(() {
                            final next =
                                zoom +
                                (event.scrollDelta.dy > 0 ? -0.08 : 0.08);
                            zoom = next.clamp(minZoom, maxZoom).toDouble();
                            offset = _clampAvatarOffset(
                              offset: offset,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              zoom: zoom,
                            );
                          });
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (details) {
                            scaleBase = zoom;
                            startOffset = offset;
                            startFocal = details.localFocalPoint;
                          },
                          onScaleUpdate: (details) {
                            setModalState(() {
                              zoom = (scaleBase * details.scale)
                                  .clamp(minZoom, maxZoom)
                                  .toDouble();
                              final translated =
                                  details.localFocalPoint - startFocal;
                              offset = _clampAvatarOffset(
                                offset: startOffset + translated,
                                sourceWidth: source.width,
                                sourceHeight: source.height,
                                previewSize: previewSize,
                                cutoutSize: cutoutSize,
                                zoom: zoom,
                              );
                            });
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SizedBox(
                              width: previewSize,
                              height: previewSize,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(color: Colors.black12),
                                  Transform.translate(
                                    offset: offset,
                                    child: Transform.scale(
                                      scale: zoom,
                                      child: Image.file(
                                        imageFile,
                                        width: previewSize,
                                        height: previewSize,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                  CustomPaint(
                                    painter: _CircleCutoutPainter(
                                      cutoutRadius: cutoutSize / 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Масштаб: ${(zoom * 100).round()}%',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Уменьшить',
                            onPressed: () {
                              setModalState(() {
                                zoom = (zoom - 0.1).clamp(minZoom, maxZoom);
                                offset = _clampAvatarOffset(
                                  offset: offset,
                                  sourceWidth: source.width,
                                  sourceHeight: source.height,
                                  previewSize: previewSize,
                                  cutoutSize: cutoutSize,
                                  zoom: zoom,
                                );
                              });
                            },
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          IconButton(
                            tooltip: 'Увеличить',
                            onPressed: () {
                              setModalState(() {
                                zoom = (zoom + 0.1).clamp(minZoom, maxZoom);
                                offset = _clampAvatarOffset(
                                  offset: offset,
                                  sourceWidth: source.width,
                                  sourceHeight: source.height,
                                  previewSize: previewSize,
                                  cutoutSize: cutoutSize,
                                  zoom: zoom,
                                );
                              });
                            },
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                      Slider(
                        value: zoom,
                        min: minZoom,
                        max: maxZoom,
                        divisions: ((maxZoom - minZoom) * 20).round().clamp(
                          1,
                          100,
                        ),
                        onChanged: (v) {
                          setModalState(() {
                            zoom = v;
                            offset = _clampAvatarOffset(
                              offset: offset,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              zoom: zoom,
                            );
                          });
                        },
                      ),
                      if (localError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
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
                  onPressed: exporting ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: exporting
                      ? null
                      : () {
                          setModalState(() {
                            zoom = 1.0.clamp(minZoom, maxZoom).toDouble();
                            offset = Offset.zero;
                            localError = '';
                          });
                        },
                  child: const Text('Сброс'),
                ),
                ElevatedButton(
                  onPressed: exporting
                      ? null
                      : () async {
                          setModalState(() {
                            exporting = true;
                            localError = '';
                          });
                          try {
                            final croppedPath = await _exportAvatarCrop(
                              sourcePath: filePath,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              offset: offset,
                              zoom: zoom,
                            );
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop(
                              _AvatarPlacementResult(croppedPath: croppedPath),
                            );
                          } catch (_) {
                            setModalState(() {
                              exporting = false;
                              localError = 'Не удалось подготовить аватарку';
                            });
                          }
                        },
                  child: exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Использовать'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _pickAndUploadChannelAvatar(Map<String, dynamic> channel) async {
    final channelId = _channelIdOf(channel);
    if (channelId.isEmpty) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.single.path;
    if (path == null || path.isEmpty) {
      if (mounted) {
        setState(() => _message = 'Не удалось получить путь к файлу');
      }
      return;
    }

    final settings = _settingsOf(channel);
    final placement = await _showAvatarPlacementDialog(
      filePath: path,
      initialFocusX: _toFocus(settings['avatar_focus_x']),
      initialFocusY: _toFocus(settings['avatar_focus_y']),
      initialZoom: _toAvatarZoom(settings['avatar_zoom']),
    );
    if (placement == null) return;

    setState(() {
      _avatarUpdating = true;
      _message = '';
    });
    try {
      final uploadPath = placement.croppedPath;
      final fileName = uploadPath.split(Platform.pathSeparator).last;
      final form = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(uploadPath, filename: fileName),
      });
      final resp = await authService.dio.post(
        '/api/admin/channels/$channelId/avatar',
        data: form,
      );
      _emitChatUpdatedIfPresent(resp.data);

      await authService.dio.patch(
        '/api/admin/channels/$channelId',
        data: {'avatar_focus_x': 0, 'avatar_focus_y': 0, 'avatar_zoom': 1},
      );

      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) setState(() => _message = 'Аватарка канала обновлена');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки аватарки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUpdating = false);
      try {
        await File(placement.croppedPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _removeChannelAvatar(String channelId) async {
    setState(() {
      _avatarUpdating = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.delete(
        '/api/admin/channels/$channelId/avatar',
      );
      _emitChatUpdatedIfPresent(resp.data);
      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) setState(() => _message = 'Аватарка канала удалена');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка удаления аватарки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUpdating = false);
    }
  }

  Future<void> _addToBlacklist(String channelId, String userId) async {
    if (_blacklistBusy.contains(channelId)) return;
    setState(() => _blacklistBusy.add(channelId));
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels/$channelId/blacklist',
        data: {'user_id': userId},
      );
      final data = resp.data;
      if (data is Map &&
          data['data'] is Map &&
          data['data']['channel'] is Map) {
        chatEventsController.add({
          'type': 'chat:updated',
          'data': {'chat': Map<String, dynamic>.from(data['data']['channel'])},
        });
      }
      await _loadChannelOverview(channelId, force: true, silent: true);
      await _loadChannels();
      if (mounted) {
        setState(() => _message = 'Пользователь добавлен в черный список');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка черного списка: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _blacklistBusy.remove(channelId));
    }
  }

  Future<void> _removeFromBlacklist(String channelId, String userId) async {
    if (_blacklistBusy.contains(channelId)) return;
    setState(() => _blacklistBusy.add(channelId));
    try {
      final resp = await authService.dio.delete(
        '/api/admin/channels/$channelId/blacklist/$userId',
      );
      final data = resp.data;
      if (data is Map &&
          data['data'] is Map &&
          data['data']['channel'] is Map) {
        chatEventsController.add({
          'type': 'chat:updated',
          'data': {'chat': Map<String, dynamic>.from(data['data']['channel'])},
        });
      }
      await _loadChannelOverview(channelId, force: true, silent: true);
      await _loadChannels();
      if (mounted) {
        setState(() => _message = 'Пользователь убран из черного списка');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка черного списка: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _blacklistBusy.remove(channelId));
    }
  }

  Future<void> _dispatchClientOrders() async {
    if (!_ensurePermission(
      'reservation.fulfill',
      'Недостаточно прав для отправки заказов клиентов',
    )) {
      return;
    }
    setState(() {
      _dispatchingOrders = true;
      _message = '';
      _lastDispatchedOrders = [];
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/orders/dispatch_reserved',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        final orders = payload['orders'] is List
            ? List<Map<String, dynamic>>.from(payload['orders'])
            : <Map<String, dynamic>>[];
        if (mounted) {
          setState(() {
            _lastDispatchedOrders = orders;
            _message = orders.isEmpty
                ? 'Новых заказов клиентов нет'
                : 'Заказы клиентов отправлены: ${orders.length}';
          });
        }
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось отправить заказы клиентов');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message =
              'Ошибка отправки заказов клиентов: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _dispatchingOrders = false);
    }
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

  Future<void> _publishPendingPosts() async {
    if (!_ensurePermission(
      'product.publish',
      'Недостаточно прав для публикации постов',
    )) {
      return;
    }
    setState(() {
      _publishing = true;
      _message = '';
      _lastPublished = [];
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels/publish_pending',
        data: const {},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final published = data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : <Map<String, dynamic>>[];
        if (mounted) {
          setState(() {
            _lastPublished = published;
            _message = published.isEmpty
                ? 'Нет постов для публикации'
                : 'Опубликовано постов: ${published.length}. ID товаров выведены ниже.';
          });
        }
        await _loadPendingPosts();
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось опубликовать посты');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка публикации: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _editPendingPost(Map<String, dynamic> post) async {
    final titleCtrl = TextEditingController(
      text: (post['product_title'] ?? '').toString(),
    );
    final descriptionCtrl = TextEditingController(
      text: (post['product_description'] ?? '').toString(),
    );
    final priceCtrl = TextEditingController(
      text: (post['product_price'] ?? '').toString(),
    );
    final quantityCtrl = TextEditingController(
      text: (post['product_quantity'] ?? '').toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изменить пост в модерации'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Название товара',
                      border: OutlineInputBorder(),
                    ),
                    controller: titleCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionCtrl,
                  minLines: 3,
                  maxLines: 5,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Описание',
                      border: OutlineInputBorder(),
                    ),
                    controller: descriptionCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: priceCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Цена',
                            border: OutlineInputBorder(),
                          ),
                          controller: priceCtrl,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: quantityCtrl,
                        keyboardType: TextInputType.number,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Кол-во',
                            border: OutlineInputBorder(),
                          ),
                          controller: quantityCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Полка назначается автоматически по дате.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final title = titleCtrl.text.trim();
    final description = descriptionCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim().replaceAll(',', '.'));
    final quantity = int.tryParse(quantityCtrl.text.trim());

    if (title.isEmpty) {
      setState(() => _message = 'Название товара обязательно');
      return;
    }
    if (description.length < 2) {
      setState(() => _message = 'Описание должно быть осмысленным');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _message = 'Цена должна быть больше нуля');
      return;
    }
    if (quantity == null || quantity <= 0) {
      setState(() => _message = 'Количество должно быть больше нуля');
      return;
    }
    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/channels/pending_posts/${post['id']}',
        data: {
          'title': title,
          'description': description,
          'price': price,
          'quantity': quantity,
        },
      );
      await _loadPendingPosts();
      if (!mounted) return;
      setState(() => _message = 'Пост в модерации обновлен');
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка изменения поста: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _openChannelSettingsDialog(Map<String, dynamic> channel) async {
    final id = _channelIdOf(channel);
    if (id.isEmpty) return;

    final settings = _settingsOf(channel);
    final systemKey = (settings['system_key'] ?? '').toString();
    final isMain = systemKey == 'main_channel';

    final titleCtrl = TextEditingController(
      text: (channel['title'] ?? 'Канал').toString(),
    );
    final descCtrl = TextEditingController(
      text: (settings['description'] ?? '').toString(),
    );
    var visibility =
        (settings['visibility'] ?? 'public').toString() == 'private'
        ? 'private'
        : 'public';
    var focusX = _toFocus(settings['avatar_focus_x']);
    var focusY = _toFocus(settings['avatar_focus_y']);
    final zoom = _toAvatarZoom(settings['avatar_zoom']);
    final avatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var saving = false;
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: Text(
                'Настройки: ${(channel['title'] ?? 'Канал').toString()}',
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: _buildChannelAvatar(
                          title: titleCtrl.text.trim().isEmpty
                              ? (channel['title'] ?? 'Канал').toString()
                              : titleCtrl.text,
                          imageUrl: avatarUrl,
                          focusX: focusX,
                          focusY: focusY,
                          zoom: zoom,
                          radius: 34,
                          fallbackIcon: Icons.campaign_outlined,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: titleCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Название канала',
                            border: OutlineInputBorder(),
                          ),
                          controller: titleCtrl,
                        ),
                        onChanged: (_) => setModalState(() {}),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: descCtrl,
                        minLines: 2,
                        maxLines: 4,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Описание',
                            border: OutlineInputBorder(),
                          ),
                          controller: descCtrl,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (!isMain)
                        DropdownButtonFormField<String>(
                          value: visibility,
                          decoration: const InputDecoration(
                            labelText: 'Тип канала',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'public',
                              child: Text('Публичный'),
                            ),
                            DropdownMenuItem(
                              value: 'private',
                              child: Text('Частный'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setModalState(() => visibility = v);
                          },
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Основной канал всегда публичный. Изменение типа отключено.',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Позиция аватарки задается на этапе загрузки фото перетаскиванием.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                ElevatedButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          setModalState(() => saving = true);
                          await _saveChannelSettings(
                            channelId: id,
                            title: titleCtrl.text,
                            description: descCtrl.text,
                            visibility: visibility,
                            avatarFocusX: focusX,
                            avatarFocusY: focusY,
                            isMain: isMain,
                          );
                          if (!mounted) return;
                          if (Navigator.of(ctx).canPop()) {
                            Navigator.of(ctx).pop();
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(saving ? 'Сохранение...' : 'Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    titleCtrl.dispose();
    descCtrl.dispose();
  }

  Future<void> _openClientsDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final clients = _asMapList(overview['clients']);
    final stats = _asMap(overview['stats']);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Клиенты канала "$channelTitle"'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: clients.isEmpty
              ? const Center(child: Text('Клиенты не найдены'))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Всего клиентов: ${_toInt(stats['clients_total'])}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: clients.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final c = clients[index];
                          final blocked = c['is_blacklisted'] == true;
                          final phone = (c['phone'] ?? '').toString().trim();
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              child: Text(
                                _displayName(
                                  c,
                                  fallback: 'Клиент',
                                )[0].toUpperCase(),
                              ),
                            ),
                            title: Text(_displayName(c, fallback: 'Клиент')),
                            subtitle: Text(
                              [
                                (c['email'] ?? '').toString(),
                                if (phone.isNotEmpty) 'Тел: $phone',
                              ].where((v) => v.trim().isNotEmpty).join('\n'),
                            ),
                            isThreeLine: phone.isNotEmpty,
                            trailing: blocked
                                ? const Icon(Icons.block, color: Colors.red)
                                : null,
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openMediaDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final media = _asMapList(overview['media']);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Медиа канала "$channelTitle"'),
        content: SizedBox(
          width: 680,
          height: 480,
          child: media.isEmpty
              ? const Center(child: Text('В канале пока нет медиа'))
              : GridView.builder(
                  itemCount: media.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.86,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final item = media[index];
                    final url = _resolveImageUrl(
                      (item['image_url'] ?? '').toString(),
                    );
                    final caption = (item['text'] ?? '').toString().trim();
                    return Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              child: url == null
                                  ? Container(
                                      color: Colors.grey.shade200,
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.photo_outlined),
                                    )
                                  : Image.network(
                                      url,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              caption.isEmpty ? 'Без подписи' : caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBlacklistDialog(
    String channelId,
    String channelTitle,
  ) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final blacklist = _asMapList(overview['blacklist']);
    final clients = _asMapList(overview['clients']);
    final blacklistedIds = blacklist
        .map((b) => (b['user_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final candidates = clients
        .where((c) => !blacklistedIds.contains((c['user_id'] ?? '').toString()))
        .take(80)
        .toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Черный список "$channelTitle"'),
        content: SizedBox(
          width: 620,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Заблокировано: ${blacklist.length}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: blacklist.isEmpty
                    ? const Center(child: Text('Черный список пуст'))
                    : ListView.separated(
                        itemCount: blacklist.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final item = blacklist[i];
                          final user = _asMap(item['user']);
                          final userId = (item['user_id'] ?? '').toString();
                          final title = user.isEmpty
                              ? userId
                              : _displayName(user, fallback: userId);
                          return ListTile(
                            dense: true,
                            title: Text(title),
                            subtitle: Text(
                              [
                                (user['email'] ?? '').toString(),
                                (user['phone'] ?? '').toString(),
                              ].where((v) => v.trim().isNotEmpty).join('\n'),
                            ),
                            isThreeLine: ((user['phone'] ?? '')
                                .toString()
                                .trim()
                                .isNotEmpty),
                            trailing: IconButton(
                              tooltip: 'Разблокировать',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: _blacklistBusy.contains(channelId)
                                  ? null
                                  : () async {
                                      Navigator.of(ctx).pop();
                                      await _removeFromBlacklist(
                                        channelId,
                                        userId,
                                      );
                                      if (!mounted) return;
                                      await _openBlacklistDialog(
                                        channelId,
                                        channelTitle,
                                      );
                                    },
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Добавить клиента в черный список:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 150,
                child: candidates.isEmpty
                    ? const Center(
                        child: Text('Нет доступных клиентов для добавления'),
                      )
                    : ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (context, i) {
                          final c = candidates[i];
                          final userId = (c['user_id'] ?? '').toString();
                          return ListTile(
                            dense: true,
                            title: Text(_displayName(c, fallback: 'Клиент')),
                            subtitle: Text((c['email'] ?? '').toString()),
                            trailing: IconButton(
                              tooltip: 'Заблокировать',
                              icon: const Icon(Icons.block, color: Colors.red),
                              onPressed: _blacklistBusy.contains(channelId)
                                  ? null
                                  : () async {
                                      Navigator.of(ctx).pop();
                                      await _addToBlacklist(channelId, userId);
                                      if (!mounted) return;
                                      await _openBlacklistDialog(
                                        channelId,
                                        channelTitle,
                                      );
                                    },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelAvatar({
    required String title,
    required String? imageUrl,
    required double focusX,
    required double focusY,
    required double zoom,
    required double radius,
    required IconData fallbackIcon,
  }) {
    final initials = title.trim().isEmpty
        ? '?'
        : title
              .trim()
              .split(' ')
              .where((part) => part.isNotEmpty)
              .map((part) => part[0])
              .take(2)
              .join()
              .toUpperCase();

    if (imageUrl == null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.grey.shade200,
        child: initials == '?'
            ? Icon(fallbackIcon, color: Colors.grey.shade700)
            : Text(initials),
      );
    }

    final size = radius * 2;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade200,
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment(focusX, focusY),
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              alignment: Alignment(focusX, focusY),
              errorBuilder: (_, __, ___) => Center(
                child: Text(
                  initials,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNoAccessTab() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 46,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Недостаточно прав для раздела администрирования',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Обратитесь к арендатору или создателю, чтобы выдать нужные права.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _channelTitleCtrl,
          decoration: withInputLanguageBadge(
            const InputDecoration(
              labelText: 'Название канала',
              border: OutlineInputBorder(),
            ),
            controller: _channelTitleCtrl,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _channelDescriptionCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: withInputLanguageBadge(
            const InputDecoration(
              labelText: 'Описание канала (опционально)',
              border: OutlineInputBorder(),
            ),
            controller: _channelDescriptionCtrl,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _newChannelVisibility,
          decoration: const InputDecoration(
            labelText: 'Тип нового канала',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'public',
              child: Text('Публичный (видят все)'),
            ),
            DropdownMenuItem(
              value: 'private',
              child: Text('Частный (для рабочих/админов)'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _newChannelVisibility = v);
          },
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _createChannel,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add),
            label: Text(_saving ? 'Создание...' : 'Создать канал'),
          ),
        ),
        const SizedBox(height: 16),
        if (_showKeysTab && _invitesLoading)
          const Center(child: CircularProgressIndicator())
        else if (_showKeysTab && _inviteApiAllowed) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Коды приглашения в ваш проект',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _inviteRole,
                    decoration: const InputDecoration(
                      labelText: 'Роль по приглашению',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'client', child: Text('Клиент')),
                      DropdownMenuItem(value: 'worker', child: Text('Рабочий')),
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
                        labelText: 'Сколько раз можно использовать код',
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
          ..._tenantInvites.take(10).map((invite) {
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
      ],
    );
  }

  Widget _buildChannelCard(Map<String, dynamic> channel) {
    final id = _channelIdOf(channel);
    final title = (channel['title'] ?? 'Канал').toString();
    final settings = _settingsOf(channel);
    final description = (settings['description'] ?? '').toString();
    final visibility =
        (settings['visibility'] ?? 'public').toString() == 'private'
        ? 'private'
        : 'public';
    final avatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );
    final systemKey = (settings['system_key'] ?? '').toString();
    final isMain = systemKey == 'main_channel';
    final isReserved = systemKey == 'reserved_orders';
    final isPostsArchive = systemKey == 'posts_archive';
    final isSystemChannel = systemKey.trim().isNotEmpty;
    final canDelete = !isSystemChannel;
    final focusX = _toFocus(settings['avatar_focus_x']);
    final focusY = _toFocus(settings['avatar_focus_y']);
    final avatarZoom = _toAvatarZoom(settings['avatar_zoom']);

    final overview = _channelOverviews[id];
    final overviewStats = _asMap(overview?['stats']);
    final overviewMedia = _asMapList(overview?['media']);
    final overviewBlacklist = _asMapList(overview?['blacklist']);

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded) {
            unawaited(_loadChannelOverview(id, silent: true));
          }
        },
        leading: _buildChannelAvatar(
          title: title,
          imageUrl: avatarUrl,
          focusX: focusX,
          focusY: focusY,
          zoom: avatarZoom,
          radius: 20,
          fallbackIcon: Icons.campaign_outlined,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          isMain
              ? 'Основной канал • всегда публичный'
              : isReserved
              ? 'Системный канал сборки заказов'
              : isPostsArchive
              ? 'Системный архив постов'
              : (visibility == 'private' ? 'Частный канал' : 'Публичный канал'),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (description.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  description,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _openChannelSettingsDialog(channel),
                icon: const Icon(Icons.tune),
                label: const Text('Настроить'),
              ),
              OutlinedButton.icon(
                onPressed: _avatarUpdating
                    ? null
                    : () => _pickAndUploadChannelAvatar(channel),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Аватарка'),
              ),
              if (avatarUrl != null)
                OutlinedButton.icon(
                  onPressed: _avatarUpdating
                      ? null
                      : () => _removeChannelAvatar(id),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Убрать фото'),
                ),
              OutlinedButton.icon(
                onPressed: _overviewLoading.contains(id)
                    ? null
                    : () => _loadChannelOverview(id, force: true),
                icon: const Icon(Icons.analytics_outlined),
                label: Text(
                  _overviewLoading.contains(id)
                      ? 'Загрузка...'
                      : 'Обновить данные',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: id));
                  setState(() => _message = 'ID канала скопирован');
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Скопировать ID'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_overviewLoading.contains(id) &&
              !_channelOverviews.containsKey(id))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          else if (overview != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatChip(
                  'Клиенты',
                  _toInt(overviewStats['clients_total']).toString(),
                ),
                _buildStatChip(
                  'Участники',
                  _toInt(overviewStats['members_total']).toString(),
                ),
                _buildStatChip(
                  'Медиа',
                  _toInt(overviewStats['media_total']).toString(),
                ),
                _buildStatChip(
                  'Сообщения',
                  _toInt(overviewStats['messages_total']).toString(),
                ),
                _buildStatChip(
                  'За 24ч',
                  _toInt(overviewStats['messages_24h']).toString(),
                ),
                _buildStatChip(
                  'Черный список',
                  _toInt(overviewStats['blacklisted_total']).toString(),
                ),
                _buildStatChip(
                  'В очереди',
                  _toInt(overviewStats['pending_posts_total']).toString(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _openClientsDialog(id, title),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Список клиентов'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _openMediaDialog(id, title),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Список медиа'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _openBlacklistDialog(id, title),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('Черный список'),
                ),
              ],
            ),
            if (overviewMedia.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Последние фото:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: overviewMedia.length > 8
                      ? 8
                      : overviewMedia.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final item = overviewMedia[i];
                    final url = _resolveImageUrl(
                      (item['image_url'] ?? '').toString(),
                    );
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 72,
                        child: url == null
                            ? Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.photo_outlined),
                              )
                            : Image.network(url, fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (overviewBlacklist.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'В черном списке:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: overviewBlacklist.take(6).map((entry) {
                  final user = _asMap(entry['user']);
                  final userId = (entry['user_id'] ?? '').toString();
                  final label = user.isEmpty
                      ? userId
                      : _displayName(user, fallback: userId);
                  return Chip(
                    label: Text(label),
                    onDeleted: _blacklistBusy.contains(id)
                        ? null
                        : () => _removeFromBlacklist(id, userId),
                  );
                }).toList(),
              ),
            ],
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _saving
                  ? null
                  : (!canDelete ? null : () => _deleteChannel(id, title)),
              icon: Icon(
                Icons.delete_outline,
                color: canDelete ? Colors.red : Colors.grey,
              ),
              label: Text(
                canDelete ? 'Удалить канал' : 'Системный канал',
                style: TextStyle(color: canDelete ? Colors.red : Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    final compact = MediaQuery.of(context).size.width < 640;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_channels.isEmpty) {
      return const Center(child: Text('Каналы пока не созданы'));
    }

    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView.separated(
        padding: EdgeInsets.all(compact ? 10 : 16),
        itemCount: _channels.length,
        separatorBuilder: (_, __) => SizedBox(height: compact ? 8 : 12),
        itemBuilder: (context, index) => _buildChannelCard(_channels[index]),
      ),
    );
  }

  Widget _buildModerationChip(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildModerationTab() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 640;
    return RefreshIndicator(
      onRefresh: _loadPendingPosts,
      child: ListView(
        padding: EdgeInsets.all(compact ? 10 : 16),
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  'В очереди: ${_pendingPosts.length}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  'Забронировано и не обработано: $_reservedPendingTotal',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  'Штук в резерве: $_reservedPendingUnits',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 10 : 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_publishing || !_hasPermission('product.publish'))
                  ? null
                  : _publishPendingPosts,
              icon: _publishing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.campaign),
              label: Text(
                _publishing ? 'Публикация...' : 'Отправить посты на каналы',
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  (_dispatchingOrders || !_hasPermission('reservation.fulfill'))
                  ? null
                  : _dispatchClientOrders,
              icon: _dispatchingOrders
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.assignment_turned_in_outlined),
              label: Text(
                _dispatchingOrders ? 'Отправка заказов...' : 'Заказы клиентов',
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_pendingPosts.isEmpty)
            const Text('Очередь пустая')
          else
            ..._pendingPosts.map((p) {
              final title = (p['product_title'] ?? 'Товар').toString();
              final description = (p['product_description'] ?? '').toString();
              final channel = (p['channel_title'] ?? 'Основной канал')
                  .toString();
              final workerName =
                  (p['queued_by_name'] ?? p['queued_by_email'] ?? 'Работник')
                      .toString();
              final productLabel = _formatProductLabel(
                p['product_code'],
                p['product_shelf_number'],
              );
              final imageUrl = _resolveImageUrl(
                (p['product_image_url'] ?? '').toString(),
              );
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: 96,
                            height: 96,
                            child: imageUrl != null
                                ? Image.network(
                                    imageUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, error, stackTrace) =>
                                        Container(
                                          color: theme
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          alignment: Alignment.center,
                                          child: const Icon(
                                            Icons.photo_outlined,
                                          ),
                                        ),
                                  )
                                : Container(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.photo_outlined),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _buildModerationChip('ID $productLabel'),
                                  _buildModerationChip(
                                    '${_toInt(p['product_price'])} RUB',
                                  ),
                                  _buildModerationChip(
                                    'x${_toInt(p['product_quantity'])}',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$workerName · $channel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: _saving ? null : () => _editPendingPost(p),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Изменить'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          if (_lastPublished.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Опубликованные товары и их ID:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._lastPublished.map((item) {
              final channelTitle = (item['channel_title'] ?? 'Канал')
                  .toString();
              final productLabel =
                  item['product_label']?.toString() ??
                  _formatProductLabel(
                    item['product_code'],
                    item['shelf_number'],
                  );
              final productId = item['product_id']?.toString() ?? '—';
              return Card(
                child: ListTile(
                  title: Text('ID товара: $productLabel'),
                  subtitle: Text('Канал: $channelTitle\nDB ID: $productId'),
                ),
              );
            }),
          ],
          if (_lastDispatchedOrders.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Отправленные заказы клиентов:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._lastDispatchedOrders.map((item) {
              final clientName = (item['client_name'] ?? '—').toString();
              final productLabel =
                  item['product_label']?.toString() ??
                  _formatProductLabel(
                    item['product_code'],
                    item['product_shelf_number'],
                  );
              final quantity = (item['quantity'] ?? '—').toString();
              final shelf = (item['shelf_number'] ?? 'не назначена').toString();
              return Card(
                child: ListTile(
                  title: Text('Клиент: $clientName'),
                  subtitle: Text(
                    'ID товара: $productLabel\n'
                    'Количество: $quantity\n'
                    'Полка: $shelf',
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildSupportTicketCard(
    Map<String, dynamic> ticket, {
    required bool archived,
  }) {
    final theme = Theme.of(context);
    final ticketId = (ticket['id'] ?? '').toString().trim();
    final customer = (ticket['customer_name'] ?? 'Клиент').toString();
    final assignee = (ticket['assignee_name'] ?? '—').toString();
    final category = _supportCategoryLabel(
      (ticket['category'] ?? '').toString(),
    );
    final status = _supportStatusLabel((ticket['status'] ?? '').toString());
    final subject = (ticket['subject'] ?? '').toString().trim();
    final updatedAt = _formatDateTimeLabel(ticket['updated_at']);
    final archiveReason = (ticket['archive_reason'] ?? '').toString().trim();

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
                    subject.isNotEmpty ? subject : 'Тикет поддержки',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildModerationChip(status),
              ],
            ),
            const SizedBox(height: 8),
            Text('Категория: $category'),
            Text('Клиент: $customer'),
            Text('Ответственный: $assignee'),
            if (updatedAt.isNotEmpty) Text('Обновлён: $updatedAt'),
            if (archiveReason.isNotEmpty)
              Text('Причина архива: $archiveReason'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _openSupportChat(ticket),
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Открыть чат'),
                ),
                if (!archived)
                  OutlinedButton.icon(
                    onPressed: _supportArchiveBusy
                        ? null
                        : () => _archiveSupportTicket(ticket),
                    icon: const Icon(Icons.archive_outlined),
                    label: Text(
                      _supportArchiveBusy ? 'Сохранение...' : 'В архив',
                    ),
                  ),
                if (ticketId.isNotEmpty)
                  _buildModerationChip('ID ${ticketId.substring(0, 8)}'),
              ],
            ),
            if (!archived && _supportTemplates.isNotEmpty) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: (_ticketTemplateById[ticketId] ?? '').isEmpty
                    ? null
                    : _ticketTemplateById[ticketId],
                isExpanded: true,
                items: _supportTemplates.map((template) {
                  final id = (template['id'] ?? '').toString();
                  final title = (template['title'] ?? 'Шаблон').toString();
                  return DropdownMenuItem<String>(
                    value: id,
                    child: Text(title),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _ticketTemplateById[ticketId] = value ?? '');
                },
                decoration: const InputDecoration(
                  labelText: 'Быстрый шаблон ответа',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _supportQuickReplyBusy
                      ? null
                      : () => _sendSupportQuickReply(ticket),
                  icon: const Icon(Icons.flash_on_outlined),
                  label: Text(
                    _supportQuickReplyBusy ? 'Отправка...' : 'Отправить шаблон',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSupportTab() {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadSupportTickets(silent: true);
        await _loadSupportTemplates(silent: true);
        await _loadReturnsWorkflow(silent: true);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Поддержка',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: _supportLoading
                    ? null
                    : () async {
                        await _loadSupportTickets(silent: true);
                        await _loadReturnsWorkflow(silent: true);
                      },
                icon: const Icon(Icons.refresh),
                tooltip: 'Обновить',
              ),
            ],
          ),
          if (_supportLoading &&
              _supportActiveTickets.isEmpty &&
              _supportArchivedTickets.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Шаблоны ответов',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: _supportTemplatesLoading
                            ? null
                            : () => _loadSupportTemplates(),
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Обновить шаблоны',
                      ),
                    ],
                  ),
                  if (_supportTemplatesLoading)
                    const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _supportTemplateTitleCtrl,
                    decoration: withInputLanguageBadge(
                      const InputDecoration(
                        labelText: 'Название шаблона',
                        border: OutlineInputBorder(),
                      ),
                      controller: _supportTemplateTitleCtrl,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _supportTemplateBodyCtrl,
                    minLines: 2,
                    maxLines: 4,
                    decoration: withInputLanguageBadge(
                      const InputDecoration(
                        labelText: 'Текст шаблона',
                        hintText:
                            'Можно использовать: {customer_name}, {cart_total}, {processed_total}, {delivery_status}',
                        border: OutlineInputBorder(),
                      ),
                      controller: _supportTemplateBodyCtrl,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _supportTemplateSaving
                          ? null
                          : _createSupportTemplate,
                      icon: const Icon(Icons.add_comment_outlined),
                      label: Text(
                        _supportTemplateSaving
                            ? 'Сохранение...'
                            : 'Сохранить шаблон',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Возвраты и скидки',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (_returnsActionBusy && _returnsWorkflow.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 8),
          if (_returnsWorkflow.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('Заявок на возврат/скидку пока нет'),
              ),
            )
          else
            ..._returnsWorkflow.take(20).map((claim) {
              final status = (claim['workflow_status_label'] ?? '')
                  .toString()
                  .trim();
              final customer = (claim['customer_name'] ?? 'Клиент')
                  .toString()
                  .trim();
              final product = (claim['product_title'] ?? 'Товар')
                  .toString()
                  .trim();
              final claimType = (claim['claim_type'] ?? '').toString().trim();
              final requested = _formatMoney(claim['requested_amount']);
              final approved = _formatMoney(claim['approved_amount']);
              final actions = (claim['available_actions'] is List)
                  ? List<String>.from(claim['available_actions'])
                  : const <String>[];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$customer • $product',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Тип: ${claimType == 'discount' ? 'Скидка' : 'Возврат'} • Статус: $status',
                      ),
                      Text('Запрошено: $requested • Подтверждено: $approved'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => _openDirectChatWithUser(claim),
                            icon: const Icon(Icons.forum_outlined),
                            label: const Text('Связаться с клиентом'),
                          ),
                          ...actions.map((action) {
                            final title = action == 'approve_return'
                                ? 'Подтв. возврат'
                                : action == 'approve_discount'
                                ? 'Подтв. скидку'
                                : action == 'reject'
                                ? 'Отклонить'
                                : 'Закрыть';
                            return OutlinedButton(
                              onPressed: _returnsActionBusy
                                  ? null
                                  : () => _applyReturnsAction(claim, action),
                              child: Text(title),
                            );
                          }),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 12),
          Text(
            'Активные тикеты',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_supportActiveTickets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('Активных тикетов пока нет'),
              ),
            )
          else
            ..._supportActiveTickets.map(
              (ticket) => _buildSupportTicketCard(ticket, archived: false),
            ),
          const SizedBox(height: 16),
          Text(
            'Архив поддержки',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_supportArchivedTickets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('Архив поддержки пуст'),
              ),
            )
          else
            ..._supportArchivedTickets.map(
              (ticket) => _buildSupportTicketCard(ticket, archived: true),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    IconData icon = Icons.insights_outlined,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: 210,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildFinanceTab() {
    final summary = _asMap(_financeData?['summary']);
    final byDay = _asMapList(_financeData?['by_day']);
    final periodLabels = {
      'day': 'День',
      'week': 'Неделя',
      'month': 'Месяц',
      'all': 'Все время',
    };
    return RefreshIndicator(
      onRefresh: () => _loadFinanceSummary(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Финансовый модуль',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: _financeLoading ? null : () => _loadFinanceSummary(),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                onPressed: _financeLoading
                    ? null
                    : () => _downloadOpsDocument(
                        kind: 'finance_summary',
                        format: 'excel',
                        batchId: '',
                      ),
                icon: const Icon(Icons.download_outlined),
                tooltip: 'Экспорт XLSX',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: periodLabels.entries.map((entry) {
              return ChoiceChip(
                selected: _financePeriod == entry.key,
                label: Text(entry.value),
                onSelected: _financeLoading
                    ? null
                    : (selected) {
                        if (!selected) return;
                        setState(() => _financePeriod = entry.key);
                        _loadFinanceSummary();
                      },
              );
            }).toList(),
          ),
          if (_financeLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _metricCard(
                title: 'Выручка',
                value: _formatMoney(summary['revenue']),
                icon: Icons.trending_up,
              ),
              _metricCard(
                title: 'Маржа',
                value: _formatMoney(summary['margin']),
                icon: Icons.show_chart,
              ),
              _metricCard(
                title: 'Прибыль',
                value: _formatMoney(summary['profit']),
                icon: Icons.account_balance_wallet_outlined,
              ),
              _metricCard(
                title: 'Средний чек',
                value: _formatMoney(summary['avg_check']),
                icon: Icons.receipt_long_outlined,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Динамика по дням (последние 30 дней)',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (byDay.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Нет данных для выбранного периода'),
              ),
            )
          else
            ...byDay.reversed.take(14).map((row) {
              return Card(
                child: ListTile(
                  dense: true,
                  title: Text((row['bucket'] ?? '').toString()),
                  subtitle: Text(
                    'Выручка: ${_formatMoney(row['revenue'])}\n'
                    'Прибыль: ${_formatMoney(row['profit'])}',
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildControlTab() {
    final rolesTemplates = _asMapList(_rolesDraft?['templates']);
    final roleModules = _asMapList(_rolesDraft?['modules']);
    final returnItems = _returnsWorkflow.take(20).toList();
    final diagnostics = _asMap(_diagnosticsData);
    final monitoring = _asMap(diagnostics['monitoring']);
    final smartNotify = _asMap(_smartNotifySettings);
    final canManageRoleTemplates =
        _isCreatorBase() || _hasPermission('tenant.users.manage');
    return RefreshIndicator(
      onRefresh: () async {
        await _loadControlCenter();
        await _loadDiagnostics();
        await _loadSmartNotificationSettings();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Контроль и безопасность',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: _controlLoading
                    ? null
                    : () async {
                        await _loadControlCenter();
                        await _loadDiagnostics();
                      },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_controlLoading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audit log',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _auditActionCtrl,
                          decoration: withInputLanguageBadge(
                            const InputDecoration(
                              labelText: 'Фильтр action',
                              border: OutlineInputBorder(),
                            ),
                            controller: _auditActionCtrl,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        onPressed: _controlLoading
                            ? null
                            : () => _loadControlCenter(),
                        icon: const Icon(Icons.filter_alt_outlined),
                        label: const Text('Применить'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _exportAuditLogsCsv,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('CSV'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_auditLogs.isEmpty)
                    const Text('Пока нет записей в журнале')
                  else
                    ..._auditLogs.take(8).map((log) {
                      final created = _formatDateTimeLabel(log['created_at']);
                      final action = (log['action'] ?? '—').toString();
                      final actor = (log['actor_name'] ?? 'Система').toString();
                      final entity = (log['entity_type'] ?? '').toString();
                      return ListTile(
                        dense: true,
                        title: Text(action),
                        subtitle: Text('$created • $actor • $entity'),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Антифрод',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (_antifraudBlocks.isEmpty)
                    const Text('Активных блокировок нет')
                  else
                    ..._antifraudBlocks.take(8).map((block) {
                      final id = (block['id'] ?? '').toString();
                      return ListTile(
                        dense: true,
                        title: Text(
                          (block['user_name'] ?? 'Пользователь').toString(),
                        ),
                        subtitle: Text(
                          '${(block['reason'] ?? '').toString()}\nДо: ${_formatDateTimeLabel(block['blocked_until'])}',
                        ),
                        isThreeLine: true,
                        trailing: OutlinedButton(
                          onPressed: id.isEmpty
                              ? null
                              : () => _releaseAntifraudBlock(id),
                          child: const Text('Снять'),
                        ),
                      );
                    }),
                  const SizedBox(height: 8),
                  Text(
                    'Событий антифрода за период: ${_antifraudEvents.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Роли и права-конструктор (черновик)',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    (_rolesDraft?['description'] ?? '').toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!canManageRoleTemplates)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'У вас режим просмотра конструктора ролей. Для изменений требуется право tenant.users.manage.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            (_roleTemplateSaving || !canManageRoleTemplates)
                            ? null
                            : () => _openRoleTemplateEditor(),
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Новый шаблон'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            (_roleUsersLoading || !canManageRoleTemplates)
                            ? null
                            : () => _loadRoleUsersOnly(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Обновить пользователей'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (rolesTemplates.isEmpty)
                    const Text('Шаблоны ролей пока не найдены')
                  else
                    ...rolesTemplates.take(10).map((row) {
                      final title = (row['title'] ?? 'Шаблон').toString();
                      final code = (row['code'] ?? '').toString();
                      final assigned = _toInt(row['assigned_users']);
                      final perms = _asMap(row['permissions']);
                      final isSystem = row['is_system'] == true;
                      final enabledCount = perms['all'] == true
                          ? roleModules.length
                          : roleModules
                                .where(
                                  (module) =>
                                      perms[(module['key'] ?? '').toString()] ==
                                      true,
                                )
                                .length;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          title: Text(
                            '$title (${code.isEmpty ? 'custom' : code})',
                          ),
                          subtitle: Text(
                            'Права: ${perms['all'] == true ? 'полный доступ' : '$enabledCount'} • Назначено: $assigned',
                          ),
                          trailing: Wrap(
                            spacing: 6,
                            children: [
                              OutlinedButton(
                                onPressed:
                                    isSystem ||
                                        _roleTemplateSaving ||
                                        !canManageRoleTemplates
                                    ? null
                                    : () => _openRoleTemplateEditor(
                                        template: row,
                                      ),
                                child: const Text('Изменить'),
                              ),
                              OutlinedButton(
                                onPressed:
                                    isSystem ||
                                        _roleTemplateSaving ||
                                        !canManageRoleTemplates
                                    ? null
                                    : () => _deleteRoleTemplate(row),
                                child: const Text('Удалить'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _roleUserSearchCtrl,
                    decoration: withInputLanguageBadge(
                      InputDecoration(
                        labelText: 'Поиск пользователя (имя, email, телефон)',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed:
                              _roleUsersLoading || !canManageRoleTemplates
                              ? null
                              : () => _loadRoleUsersOnly(),
                          icon: const Icon(Icons.search),
                        ),
                      ),
                      controller: _roleUserSearchCtrl,
                    ),
                    onSubmitted: (_) => _loadRoleUsersOnly(),
                  ),
                  const SizedBox(height: 8),
                  if (_roleUsers.isEmpty)
                    const Text('Пользователи не найдены')
                  else
                    ..._roleUsers.take(20).map((user) {
                      final userId = (user['id'] ?? '').toString().trim();
                      final userName = _displayName(
                        user,
                        fallback: 'Пользователь',
                      );
                      final roleName = _roleLabel(
                        (user['role'] ?? '').toString(),
                      );
                      final phone = (user['phone'] ?? '').toString().trim();
                      final email = (user['email'] ?? '').toString().trim();
                      final selectedTemplate =
                          _roleSelectionByUserId[userId] ?? 'none';
                      final items = <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: 'none',
                          child: Text('Без шаблона'),
                        ),
                        ...rolesTemplates.map((t) {
                          final id = (t['id'] ?? '').toString().trim();
                          final title = (t['title'] ?? 'Шаблон').toString();
                          return DropdownMenuItem<String>(
                            value: id,
                            child: Text(title),
                          );
                        }),
                      ];
                      final currentValue =
                          items.any((item) => item.value == selectedTemplate)
                          ? selectedTemplate
                          : 'none';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$userName • $roleName',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                phone.isNotEmpty
                                    ? 'Телефон: $phone'
                                    : (email.isNotEmpty
                                          ? 'Email: $email'
                                          : 'Контакт не указан'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      value: currentValue,
                                      isExpanded: true,
                                      items: items,
                                      onChanged: (value) {
                                        if (value == null || userId.isEmpty) {
                                          return;
                                        }
                                        setState(() {
                                          _roleSelectionByUserId[userId] =
                                              value;
                                        });
                                      },
                                      decoration: const InputDecoration(
                                        labelText: 'Шаблон прав',
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    onPressed:
                                        userId.isEmpty ||
                                            _roleAssignBusy ||
                                            !canManageRoleTemplates
                                        ? null
                                        : () => _assignRoleTemplateToUser(
                                            userId: userId,
                                            templateId:
                                                _roleSelectionByUserId[userId] ??
                                                'none',
                                          ),
                                    child: const Text('Назначить'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Возвраты и скидки (workflow прототип)',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (returnItems.isEmpty)
                    const Text('Нет заявок на возврат/скидку')
                  else
                    ...returnItems.map((claim) {
                      final status = (claim['workflow_status_label'] ?? '')
                          .toString();
                      final customer = (claim['customer_name'] ?? 'Клиент')
                          .toString();
                      final product = (claim['product_title'] ?? 'Товар')
                          .toString();
                      final actions = (claim['available_actions'] is List)
                          ? List<String>.from(claim['available_actions'])
                          : const <String>[];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$customer • $product',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'Статус: $status • Запрошено: ${_formatMoney(claim['requested_amount'])}',
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: actions.map((action) {
                                  final title = action == 'approve_return'
                                      ? 'Подтв. возврат'
                                      : action == 'approve_discount'
                                      ? 'Подтв. скидку'
                                      : action == 'reject'
                                      ? 'Отклонить'
                                      : 'Закрыть';
                                  return OutlinedButton(
                                    onPressed:
                                        (_returnsActionBusy ||
                                            !_hasPermission('delivery.manage'))
                                        ? null
                                        : () => _applyReturnsAction(
                                            claim,
                                            action,
                                          ),
                                    child: Text(title),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          if (_isCreatorBase()) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Умные уведомления (тест)',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          onPressed: _smartNotifyLoading
                              ? null
                              : () => _loadSmartNotificationSettings(),
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _smartNotifyType,
                            items: const [
                              DropdownMenuItem(
                                value: 'order',
                                child: Text('Заказ'),
                              ),
                              DropdownMenuItem(
                                value: 'support',
                                child: Text('Поддержка'),
                              ),
                              DropdownMenuItem(
                                value: 'delivery',
                                child: Text('Доставка'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _smartNotifyType = v);
                            },
                            decoration: const InputDecoration(
                              labelText: 'Тип',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _smartNotifyPriority,
                            items: const [
                              DropdownMenuItem(
                                value: 'low',
                                child: Text('Низкий'),
                              ),
                              DropdownMenuItem(
                                value: 'normal',
                                child: Text('Обычный'),
                              ),
                              DropdownMenuItem(
                                value: 'high',
                                child: Text('Высокий'),
                              ),
                              DropdownMenuItem(
                                value: 'critical',
                                child: Text('Критичный'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _smartNotifyPriority = v);
                            },
                            decoration: const InputDecoration(
                              labelText: 'Приоритет',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _notificationQuietFromCtrl,
                            decoration: withInputLanguageBadge(
                              const InputDecoration(
                                labelText: 'Тихие часы с (HH:mm)',
                                border: OutlineInputBorder(),
                              ),
                              controller: _notificationQuietFromCtrl,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _notificationQuietToCtrl,
                            decoration: withInputLanguageBadge(
                              const InputDecoration(
                                labelText: 'Тихие часы до (HH:mm)',
                                border: OutlineInputBorder(),
                              ),
                              controller: _notificationQuietToCtrl,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: smartNotify['quiet_hours_enabled'] == true,
                      onChanged: (v) {
                        setState(() {
                          _smartNotifySettings = {
                            ...smartNotify,
                            'quiet_hours_enabled': v,
                          };
                        });
                      },
                      title: const Text('Включить тихие часы'),
                      subtitle: const Text(
                        'В тесте уведомления будут помечаться как тихие внутри этого окна',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _smartNotifyLoading
                              ? null
                              : _saveSmartNotificationSettings,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Сохранить'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _smartNotifyLoading
                              ? null
                              : _sendSmartNotificationTest,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Тест отправки'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'История тестовых уведомлений',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (_smartNotifyHistory.isEmpty)
                      const Text('Пока нет событий')
                    else
                      ..._smartNotifyHistory.take(8).map((event) {
                        final type = (event['event_type'] ?? '').toString();
                        final priority = (event['priority'] ?? '').toString();
                        final title = (event['title'] ?? 'Уведомление')
                            .toString();
                        final isQuiet = event['is_quiet'] == true;
                        return ListTile(
                          dense: true,
                          title: Text(title),
                          subtitle: Text(
                            '${_formatDateTimeLabel(event['created_at'])} • $type • $priority${isQuiet ? ' • тихо' : ''}',
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Центр диагностики создателя',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (_diagnosticsLoading)
                      const LinearProgressIndicator()
                    else ...[
                      Text(
                        'API uptime: ${_toInt(_asMap(diagnostics['api'])['uptime_sec'])} сек',
                      ),
                      Text(
                        'DB latency: ${_toInt(_asMap(diagnostics['database'])['latency_ms'])} ms',
                      ),
                      Text(
                        'Socket clients: ${_toInt(_asMap(diagnostics['socket'])['connected_clients'])}',
                      ),
                      Text(
                        'Monitoring: критичные ${_toInt(monitoring['critical'])}, ошибки ${_toInt(monitoring['error'])}',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Демо-режим: тестовые клиенты, товары, корзины в 1 клик',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _demoModeBusy ? null : _runDemoModeSeed,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(_demoModeBusy ? 'Запуск...' : 'Запустить'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildDeliveryCustomerCard(
    String batchId,
    Map<String, dynamic> customer,
  ) {
    final theme = Theme.of(context);
    final name = (customer['customer_name'] ?? 'Клиент').toString();
    final phone = (customer['customer_phone'] ?? '—').toString();
    final sum = _formatMoney(
      customer['agreed_sum'] ?? customer['processed_sum'],
    );
    final shelf = (customer['shelf_number'] ?? 'не назначена').toString();
    final address = (customer['address_text'] ?? '').toString().trim();
    final status = _deliveryCustomerStatusLabel(
      (customer['delivery_status'] ?? customer['call_status'] ?? '').toString(),
    );
    final courierName = (customer['courier_name'] ?? '').toString().trim();
    final routeOrder = (customer['route_order'] ?? '').toString().trim();
    final etaFrom = _formatDateTimeLabel(customer['eta_from']);
    final etaTo = _formatDateTimeLabel(customer['eta_to']);
    final preferredAfter = _formatClockLabel(customer['preferred_time_from']);
    final preferredBefore = _formatClockLabel(customer['preferred_time_to']);
    final lockedCourierName = (customer['locked_courier_name'] ?? '')
        .toString()
        .trim();
    final packagePlaces = _toInt(customer['package_places'], fallback: 1);
    final bulkyPlaces = _toInt(customer['bulky_places'], fallback: 0);
    final bulkyNote = (customer['bulky_note'] ?? '').toString().trim();
    final items = _asMapList(customer['items']);
    final itemsCount = items.fold<int>(
      0,
      (sum, item) => sum + _toInt(item['quantity'], fallback: 0),
    );

    final callStatus = (customer['call_status'] ?? '').toString().trim();
    final canManualDecide = callStatus == 'pending';
    final batchStatus = (_deliveryActiveBatch?['status'] ?? '')
        .toString()
        .trim();
    final canRemoveFromRoute =
        callStatus == 'accepted' &&
        batchStatus != 'completed' &&
        batchStatus != 'cancelled';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text('Телефон: $phone'),
            Text('Сумма в доставке: $sum'),
            Text('Полка: $shelf'),
            Text('Статус доставки: $status'),
            Text(
              'Ответ в личке: ${callStatus == 'accepted'
                  ? 'Согласен'
                  : callStatus == 'declined'
                  ? 'Отказался'
                  : callStatus == 'removed'
                  ? 'Убрали из маршрута'
                  : callStatus == 'pending'
                  ? 'Ожидаем ответ'
                  : '—'}',
            ),
            if (address.isNotEmpty) Text('Адрес: $address'),
            if (preferredAfter.isNotEmpty || preferredBefore.isNotEmpty)
              Text(
                'Пожелание по времени: ${[if (preferredAfter.isNotEmpty) 'после $preferredAfter', if (preferredBefore.isNotEmpty) 'до $preferredBefore'].join(', ')}',
              ),
            if (courierName.isNotEmpty) Text('Курьер: $courierName'),
            if (lockedCourierName.isNotEmpty)
              Text('Закреплен за курьером: $lockedCourierName'),
            if (routeOrder.isNotEmpty) Text('Порядок по маршруту: $routeOrder'),
            if (etaFrom.isNotEmpty || etaTo.isNotEmpty)
              Text('Окно доставки: $etaFrom - $etaTo'),
            Text('Мест: $packagePlaces'),
            if (bulkyPlaces > 0 || bulkyNote.isNotEmpty)
              Text(
                bulkyNote.isNotEmpty
                    ? 'Габарит ($bulkyPlaces): $bulkyNote'
                    : 'Габарит: $bulkyPlaces',
              ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Товаров по штукам: $itemsCount',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (canManualDecide) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _setDeliveryDecision(
                            batchId,
                            customer,
                            accepted: true,
                          ),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Подтвердить за клиента'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _setDeliveryDecision(
                            batchId,
                            customer,
                            accepted: false,
                          ),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Отказать за клиента'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _editDeliveryLogistics(batchId, customer),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('Логистика'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _reassignDeliveryCustomer(batchId, customer),
                    icon: const Icon(Icons.swap_horiz_outlined),
                    label: const Text('Курьер'),
                  ),
                  if (canRemoveFromRoute)
                    OutlinedButton.icon(
                      onPressed: _deliverySaving
                          ? null
                          : () => _removeDeliveryCustomerFromRoute(
                              batchId,
                              customer,
                            ),
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Вернуть в корзину'),
                    ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _editDeliveryLogistics(batchId, customer),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('Логистика'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving
                        ? null
                        : () => _reassignDeliveryCustomer(batchId, customer),
                    icon: const Icon(Icons.swap_horiz_outlined),
                    label: const Text('Курьер'),
                  ),
                  if (canRemoveFromRoute)
                    OutlinedButton.icon(
                      onPressed: _deliverySaving
                          ? null
                          : () => _removeDeliveryCustomerFromRoute(
                              batchId,
                              customer,
                            ),
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Вернуть в корзину'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeliveryTab() {
    final activeBatch = _deliveryActiveBatch;
    final customers = _asMapList(activeBatch?['customers']);

    return RefreshIndicator(
      onRefresh: _loadDeliveryDashboard,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _deliveryThresholdCtrl,
            keyboardType: TextInputType.number,
            decoration: withInputLanguageBadge(
              const InputDecoration(
                labelText: 'Сумма для попадания в доставку',
                border: OutlineInputBorder(),
                helperText: 'Сумма в RUB',
              ),
              controller: _deliveryThresholdCtrl,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deliveryOriginCtrl,
            minLines: 2,
            maxLines: 3,
            decoration: withInputLanguageBadge(
              const InputDecoration(
                labelText: 'Точка отправки курьеров',
                hintText: 'Самара, адрес склада или точки старта',
                border: OutlineInputBorder(),
                helperText: 'Отсюда начинается маршрут каждого курьера',
              ),
              controller: _deliveryOriginCtrl,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Как это работает',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Сохрани порог суммы для доставки.\n'
                    '2. Укажи точку отправки курьеров.\n'
                    '3. Нажми "Отправить рассылку" — система сама напишет клиентам в личные сообщения.\n'
                    '4. Клиент ответит Да или Нет. Если Да, он сразу отправит адрес и пожелание по времени.\n'
                    '5. Здесь можно вручную добавить клиента по телефону, поправить логистику и выгрузить Excel.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _deliverySaving ? null : _saveDeliverySettings,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _deliverySaving ? 'Сохранение...' : 'Сохранить порог',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _deliverySaving ? null : _generateDeliveryBatch,
                  icon: const Icon(Icons.campaign_outlined),
                  label: const Text('Отправить рассылку'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _deliverySaving ? null : _resetDeliveryTesting,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Очистить доставку'),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment<String>(
                value: 'list',
                icon: Icon(Icons.view_agenda_outlined),
                label: Text('Список'),
              ),
              ButtonSegment<String>(
                value: 'map',
                icon: Icon(Icons.map_outlined),
                label: Text('Карта'),
              ),
            ],
            selected: {_deliveryViewMode},
            onSelectionChanged: (selection) {
              setState(() => _deliveryViewMode = selection.first);
            },
          ),
          const SizedBox(height: 12),
          if (_deliveryLoading && activeBatch == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (activeBatch == null) ...[
            if (_deliveryViewMode == 'map')
              _buildDeliveryMapView(const [])
            else
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Активного листа доставки пока нет.\nСистема возьмет клиентов, у которых сумма обработанных товаров достигла порога.',
                  ),
                ),
              ),
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (activeBatch['delivery_label'] ?? 'Лист доставки')
                          .toString(),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Дата: ${_formatDateTimeLabel(activeBatch['delivery_date'])}',
                    ),
                    Text(
                      'Статус: ${_deliveryBatchStatusLabel((activeBatch['status'] ?? '').toString())}',
                    ),
                    Text(
                      'Клиентов: ${activeBatch['customers_total'] ?? customers.length}',
                    ),
                    Text('Подтвердили: ${activeBatch['accepted_total'] ?? 0}'),
                    if (((activeBatch['route_origin_address'] ?? '')
                            .toString()
                            .trim())
                        .isNotEmpty)
                      Text(
                        'Старт маршрута: ${(activeBatch['route_origin_address'] ?? '').toString()}',
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _courierNamesCtrl,
                      minLines: 2,
                      maxLines: 5,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Курьеры (каждое имя с новой строки)',
                          border: OutlineInputBorder(),
                        ),
                        controller: _courierNamesCtrl,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : () => _assignCouriers(
                                  (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.route_outlined),
                          label: const Text('Распределить по курьерам'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : () => _manualAddDeliveryCustomer(
                                  (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                          label: const Text('Добавить клиента'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : _openRouteOrderEditor,
                          icon: const Icon(Icons.drag_indicator_outlined),
                          label: const Text('Ручной порядок'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _deliverySaving ||
                                  (activeBatch['status'] ?? '').toString() ==
                                      'completed'
                              ? null
                              : () => _confirmDeliveryHandoff(
                                  (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.done_all_outlined),
                          label: const Text('Передать курьерам'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _deliverySaving ||
                                  (activeBatch['status'] ?? '').toString() !=
                                      'handed_off'
                              ? null
                              : () => _completeDeliveryBatch(
                                  (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.assignment_turned_in_outlined),
                          label: const Text('Курьер закончил доставку'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : () => _downloadDeliveryExcel(
                                  (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.table_view_outlined),
                          label: const Text('Excel'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : () => _downloadOpsDocument(
                                  kind: 'route_sheet',
                                  format: 'pdf',
                                  batchId: (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('PDF маршрут'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _deliverySaving
                              ? null
                              : () => _downloadOpsDocument(
                                  kind: 'packing_checklist',
                                  format: 'excel',
                                  batchId: (activeBatch['id'] ?? '').toString(),
                                ),
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: const Text('Чек-лист сборки'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_deliveryViewMode == 'map')
              _buildDeliveryMapView(customers)
            else
              ...customers.map(
                (customer) => _buildDeliveryCustomerCard(
                  (activeBatch['id'] ?? '').toString(),
                  customer,
                ),
              ),
          ],
          if (_deliveryBatches.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Последние листы доставки',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ..._deliveryBatches.map((batch) {
              return Card(
                child: ListTile(
                  title: Text(
                    (batch['delivery_label'] ?? 'Лист доставки').toString(),
                  ),
                  subtitle: Text(
                    'Дата: ${_formatDateTimeLabel(batch['delivery_date'])}\n'
                    'Статус: ${_deliveryBatchStatusLabel((batch['status'] ?? '').toString())}\n'
                    'Клиентов: ${(batch['customers_total'] ?? 0).toString()}',
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildKeysTab() {
    if (!_showKeysTab) {
      return const Center(child: Text('Доступ только создателю'));
    }
    if (!_tenantApiAllowed) {
      return RefreshIndicator(
        onRefresh: _loadTenants,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'API ключей недоступен для этой учетной записи. Вкладка работает только для платформенного создателя.',
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTenants,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
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
          ),
          const SizedBox(height: 12),
          if (_tenantsLoading)
            const Center(child: CircularProgressIndicator())
          else if (_tenants.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Арендаторы пока не созданы'),
              ),
            )
          else
            ..._tenants.map((tenant) {
              final id = (tenant['id'] ?? '').toString();
              final name = (tenant['name'] ?? '').toString();
              final code = (tenant['code'] ?? '').toString();
              final status = (tenant['status'] ?? '').toString();
              final keyMask = (tenant['access_key_mask'] ?? '—').toString();
              final subscription = _formatDateTimeLabel(
                tenant['subscription_expires_at'],
              );
              final isActive = status == 'active';
              return Card(
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
                      if (subscription.isNotEmpty)
                        Text('Подписка до: $subscription'),
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
                            label: Text(
                              isActive ? 'Отключить' : 'Активировать',
                            ),
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
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 700;
    if (_tabController == null || _visibleTabs.isEmpty) {
      _rebuildVisibleTabs(force: true, notify: false);
    }
    final controller = _tabController;
    final tabs = _visibleTabs.map((tab) => Tab(text: tab.label)).toList();
    final tabViews = _visibleTabs.map((tab) => tab.builder()).toList();
    if (controller == null || tabs.isEmpty || tabViews.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Админ-панель')),
        body: SafeArea(child: _buildNoAccessTab()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Админ-панель'),
        bottom: TabBar(
          controller: controller,
          tabs: tabs,
          isScrollable: compact,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_message.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 16,
                  12,
                  compact ? 10 : 16,
                  0,
                ),
                child: Text(
                  _message,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Expanded(
              child: TabBarView(controller: controller, children: tabViews),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPlacementResult {
  const _AvatarPlacementResult({required this.croppedPath});

  final String croppedPath;
}

class _CircleCutoutPainter extends CustomPainter {
  const _CircleCutoutPainter({required this.cutoutRadius});

  final double cutoutRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final overlayPath = ui.Path()
      ..fillType = ui.PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: cutoutRadius));

    canvas.drawPath(
      overlayPath,
      Paint()..color = Colors.black.withValues(alpha: 0.38),
    );

    canvas.drawCircle(
      center,
      cutoutRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.86)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleCutoutPainter oldDelegate) {
    return oldDelegate.cutoutRadius != cutoutRadius;
  }
}

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
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../services/sticker_print_service.dart';
import 'admin_promotion_center_screen.dart';
import 'chat_screen.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';
import '../utils/phone_utils.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/delivery_address_picker_dialog.dart';
import '../widgets/input_language_badge.dart';

const String _defaultMapLightTiles =
    'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
const String _mapTileLightUrl = String.fromEnvironment(
  'FENIX_MAP_TILE_LIGHT',
  defaultValue: _defaultMapLightTiles,
);
const String _mapTileSubdomainsRaw = String.fromEnvironment(
  'FENIX_MAP_TILE_SUBDOMAINS',
  defaultValue: 'a,b,c,d',
);
const String _mapAttributionText = String.fromEnvironment(
  'FENIX_MAP_ATTRIBUTION',
  defaultValue: '© OpenStreetMap contributors © CARTO',
);
const List<Map<String, String>> _supportTemplateTokens = [
  {'token': '{customer_name}', 'title': 'Имя клиента'},
  {'token': '{cart_total}', 'title': 'Сумма корзины'},
  {'token': '{processed_total}', 'title': 'Обработано'},
  {'token': '{claims_total}', 'title': 'Сумма брака'},
  {'token': '{delivery_status}', 'title': 'Статус доставки'},
  {'token': '{subject}', 'title': 'Тема заявки'},
  {'token': '{message_text}', 'title': 'Текст сообщения клиента'},
];
const List<String> _supportTriggerExamples = [
  'время+доставки',
  'когда+доставка',
  'статус+доставки',
  'сумма+корзины',
  'фото+товара',
];
const String _supportDraftTitleKey = 'admin.support_template.draft.title';
const String _supportDraftBodyKey = 'admin.support_template.draft.body';
const String _supportDraftTriggerKey = 'admin.support_template.draft.trigger';
const String _supportDraftProbeKey = 'admin.support_template.draft.probe';
const String _supportDraftPriorityKey = 'admin.support_template.draft.priority';
const String _supportDraftAutoReplyKey = 'admin.support_template.draft.auto';
const String _supportDraftElseKey = 'admin.support_template.draft.else';

class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminTabSpec {
  const _AdminTabSpec({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String label;
  final IconData icon;
  final Widget Function() builder;
}

class _AdminPanelState extends State<AdminPanel> with TickerProviderStateMixin {
  static const Duration _clientCartUndoDelay = Duration(seconds: 2);

  TabController? _tabController;
  StreamSubscription? _authSub;
  List<_AdminTabSpec> _visibleTabs = const <_AdminTabSpec>[];
  final bool _showKeysTab = false;
  final _channelTitleCtrl = TextEditingController();
  final _channelDescriptionCtrl = TextEditingController();
  final _deliveryThresholdCtrl = TextEditingController();
  final _publicationIntervalCtrl = TextEditingController(text: '2');
  final _deliveryOriginCtrl = TextEditingController();
  final _deliveryManualPhonesCtrl = TextEditingController();
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
  final _supportTemplateTriggerCtrl = TextEditingController();
  final _supportTemplateTriggerProbeCtrl = TextEditingController();
  final _supportTemplatePriorityCtrl = TextEditingController(text: '100');
  final _supportFaqQuestionCtrl = TextEditingController();
  final _supportFaqAnswerCtrl = TextEditingController();
  final _supportFaqKeywordsCtrl = TextEditingController();
  final _supportFaqSortOrderCtrl = TextEditingController(text: '100');
  final _roleTemplateTitleCtrl = TextEditingController();
  final _roleTemplateCodeCtrl = TextEditingController();
  final _roleTemplateDescriptionCtrl = TextEditingController();
  final _roleUserSearchCtrl = TextEditingController();
  final _clientCartSearchCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _publishing = false;
  bool _pendingPostsLoading = false;
  bool _tenantFeatureSettingsLoading = false;
  bool _tenantFeatureSettingsSaving = false;
  bool _revisionDeleteRequestsLoading = false;
  bool _dispatchingOrders = false;
  bool _avatarUpdating = false;
  bool _deliveryLoading = false;
  bool _deliverySaving = false;
  bool _deliveryManualPhonesBusy = false;
  bool _supportLoading = false;
  bool _supportArchiveBusy = false;
  bool _supportTemplatesLoading = false;
  bool _supportTemplateSaving = false;
  bool _supportFaqLoading = false;
  bool _supportFaqSaving = false;
  bool _supportQuickReplyBusy = false;
  bool _supportTemplateAutoReply = true;
  bool _supportTemplateElseFallback = false;
  bool _supportFaqIsActive = true;
  bool _supportNotificationsLoading = false;
  bool _returnsAnalyticsLoading = false;
  bool _defectStatsLoading = false;
  bool _supportDraftRestoreInProgress = false;
  bool _clientCartSearchLoading = false;
  bool _clientCartLoading = false;
  bool _clientCartActionBusy = false;
  bool _clientCartUndoPending = false;
  bool _tenantsLoading = false;
  bool _tenantActionLoading = false;
  bool _invitesLoading = false;
  bool _inviteActionLoading = false;
  bool _financeLoading = false;
  bool _controlLoading = false;
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
  String _supportTemplateCategory = 'general';
  String _supportFaqCategory = 'general';
  double? _deliveryOriginLat;
  double? _deliveryOriginLng;

  List<Map<String, dynamic>> _channels = [];
  List<Map<String, dynamic>> _pendingPosts = [];
  Map<String, dynamic> _tenantFeatureSettings = <String, dynamic>{};
  List<Map<String, dynamic>> _revisionDeleteRequests = [];
  List<Map<String, dynamic>> _activePublishBatches = [];
  List<Map<String, dynamic>> _lastDispatchedOrders = [];
  List<Map<String, dynamic>> _deliveryBatches = [];
  List<Map<String, dynamic>> _deliveryCityRates = [];
  List<Map<String, dynamic>> _supportPendingTickets = [];
  List<Map<String, dynamic>> _supportActiveTickets = [];
  List<Map<String, dynamic>> _supportArchivedTickets = [];
  List<Map<String, dynamic>> _supportTemplates = [];
  List<Map<String, dynamic>> _supportFaqEntries = [];
  List<Map<String, dynamic>> _supportNotificationItems = [];
  List<Map<String, dynamic>> _clientCartUsers = [];
  List<Map<String, dynamic>> _selectedClientCartItems = [];
  List<Map<String, dynamic>> _auditLogs = [];
  List<Map<String, dynamic>> _antifraudEvents = [];
  List<Map<String, dynamic>> _antifraudBlocks = [];
  List<Map<String, dynamic>> _returnsWorkflow = [];
  List<Map<String, dynamic>> _roleUsers = [];
  List<Map<String, dynamic>> _smartNotifyHistory = [];
  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _tenantInvites = [];
  Map<String, dynamic>? _deliveryActiveBatch;
  Map<String, dynamic>? _deliveryEligiblePreview;
  Map<String, dynamic>? _deliveryManualPhonesResult;
  Map<String, dynamic>? _financeData;
  Map<String, dynamic>? _rolesDraft;
  Map<String, dynamic>? _smartNotifySettings;
  Map<String, dynamic>? _selectedClientCartUser;
  Map<String, dynamic>? _supportNotificationSummary;
  Map<String, dynamic>? _returnsAnalytics;
  Map<String, dynamic>? _defectStats;
  Map<String, dynamic>? _publishingSummary;
  int _reservedPendingTotal = 0;
  int _reservedPendingUnits = 0;
  int _deliveryEligiblePreviewPage = 0;
  String _lastGeneratedTenantKey = '';
  bool _tenantApiAllowed = true;
  bool _inviteApiAllowed = true;
  String _inviteRole = 'client';
  String _lastInviteCode = '';
  String _lastInviteLink = '';
  String _editingSupportTemplateId = '';
  String _editingSupportFaqId = '';
  final Map<String, String> _ticketTemplateById = {};
  final Map<String, String> _roleSelectionByUserId = {};
  final Set<String> _supportClaimBusyTicketIds = <String>{};
  final Set<String> _supportFinishBusyTicketIds = <String>{};
  final Set<String> _cartRetentionBusyIds = <String>{};
  final Set<String> _revisionDeleteDecisionBusyIds = <String>{};
  Timer? _supportDraftSaveTimer;
  Timer? _clientCartUndoTimer;
  Timer? _publishProgressTimer;
  Timer? _pendingPostsRefreshDebounce;
  Timer? _channelsRefreshDebounce;
  Timer? _deliveryRefreshDebounce;
  Timer? _supportRefreshDebounce;
  Timer? _claimsRefreshDebounce;
  Future<void> Function()? _clientCartPendingCommit;
  VoidCallback? _clientCartPendingRollback;
  String _clientCartPendingLabel = '';

  final Map<String, Map<String, dynamic>> _channelOverviews = {};
  final Map<String, Timer> _channelOverviewRefreshDebounces = {};
  final Set<String> _overviewLoading = <String>{};
  final Set<String> _blacklistBusy = <String>{};
  bool _isDisposed = false;
  final Set<String> _loadedTabs = <String>{};

  @override
  void initState() {
    super.initState();
    _bindSupportTemplateDraftAutosave();
    unawaited(_restoreSupportTemplateDraft());
    _rebuildVisibleTabs(force: true, notify: false);
    unawaited(_loadActiveTabData(silent: false));
    _eventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if (type == 'delivery:updated' && _canViewDeliveryTab()) {
        _scheduleDeliveryRealtimeRefresh();
        return;
      }
      if (type == 'support:queue:changed' && _canViewSupportTab()) {
        _scheduleSupportRealtimeRefresh();
        return;
      }
      if (type == 'catalog:queue:updated' && _canViewModerationTab()) {
        _schedulePendingPostsRealtimeRefresh();
        final channelId = _realtimeChannelIdOf(event['data']);
        if (channelId.isNotEmpty) {
          _scheduleChannelOverviewRealtimeRefresh(channelId);
        }
        return;
      }
      if (type == 'revision:delete-request:updated' &&
          _canViewModerationTab()) {
        unawaited(_loadRevisionDeleteRequests(silent: true));
        return;
      }
      if (type == 'chat:created' || type == 'chat:deleted') {
        if (_canViewCreateTab() || _canViewChannelsTab()) {
          _scheduleChannelsRealtimeRefresh();
        }
        return;
      }
      if (type == 'chat:updated' ||
          type == 'channel:updated' ||
          type == 'channel:members:updated' ||
          type == 'channel:media:updated') {
        final channelId = _realtimeChannelIdOf(event['data']);
        if (_canViewCreateTab() || _canViewChannelsTab()) {
          if (type == 'channel:updated') {
            _scheduleChannelsRealtimeRefresh();
          }
          if (channelId.isNotEmpty) {
            _scheduleChannelOverviewRealtimeRefresh(channelId);
          }
        }
        return;
      }
      if (type == 'claims:updated' && _canViewSupportTab()) {
        _scheduleClaimsRealtimeRefresh();
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
      if (!mounted || _isDisposed) return;
      final changed = _rebuildVisibleTabs();
      if (changed) {
        unawaited(_reloadAll());
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    final controller = _tabController;
    _tabController = null;
    controller?.dispose();
    _eventsSub?.cancel();
    _authSub?.cancel();
    _unbindSupportTemplateDraftAutosave();
    _supportDraftSaveTimer?.cancel();
    _clientCartUndoTimer?.cancel();
    _publishProgressTimer?.cancel();
    _pendingPostsRefreshDebounce?.cancel();
    _channelsRefreshDebounce?.cancel();
    _deliveryRefreshDebounce?.cancel();
    _supportRefreshDebounce?.cancel();
    _claimsRefreshDebounce?.cancel();
    for (final timer in _channelOverviewRefreshDebounces.values) {
      timer.cancel();
    }
    _channelOverviewRefreshDebounces.clear();
    _clientCartPendingCommit = null;
    _clientCartPendingRollback = null;
    _channelTitleCtrl.dispose();
    _channelDescriptionCtrl.dispose();
    _deliveryThresholdCtrl.dispose();
    _publicationIntervalCtrl.dispose();
    _deliveryOriginCtrl.dispose();
    _deliveryManualPhonesCtrl.dispose();
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
    _supportTemplateTriggerCtrl.dispose();
    _supportTemplateTriggerProbeCtrl.dispose();
    _supportTemplatePriorityCtrl.dispose();
    _supportFaqQuestionCtrl.dispose();
    _supportFaqAnswerCtrl.dispose();
    _supportFaqKeywordsCtrl.dispose();
    _supportFaqSortOrderCtrl.dispose();
    _roleTemplateTitleCtrl.dispose();
    _roleTemplateCodeCtrl.dispose();
    _roleTemplateDescriptionCtrl.dispose();
    _roleUserSearchCtrl.dispose();
    _clientCartSearchCtrl.dispose();
    super.dispose();
  }

  String _activeMapTileUrl(ThemeData _) {
    return _mapTileLightUrl;
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

  bool _boolValue(dynamic raw) {
    if (raw is bool) return raw;
    final normalized = '${raw ?? ''}'.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  bool get _tenantCustomWorkflowsEnabled =>
      _boolValue(_tenantFeatureSettings['custom_workflows_enabled']);

  int get _publicationIntervalMs {
    final raw = _tenantFeatureSettings['publication_interval_ms'];
    final parsed = _toInt(raw, fallback: 2000);
    return parsed.clamp(500, 10 * 60 * 1000).toInt();
  }

  String _formatIntervalSeconds(int milliseconds) {
    final seconds = milliseconds / 1000;
    if ((seconds - seconds.round()).abs() < 0.001) {
      return seconds.round().toString();
    }
    return seconds.toStringAsFixed(1);
  }

  int? _parsePublicationIntervalInputMs() {
    final raw = _publicationIntervalCtrl.text.trim().replaceAll(',', '.');
    final seconds = double.tryParse(raw);
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    final milliseconds = (seconds * 1000).round();
    return milliseconds.clamp(500, 10 * 60 * 1000).toInt();
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

  bool _isAdminBase() {
    final baseRole = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return baseRole == 'admin';
  }

  bool _isAdminViewRole() {
    return authService.effectiveRole.toLowerCase().trim() == 'admin';
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
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasAnyPermission(const ['product.publish', 'reservation.fulfill']);
  }

  bool _canPublishProducts() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasPermission('product.publish');
  }

  bool _canDeletePendingPost() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    return role == 'admin' || role == 'tenant';
  }

  bool _canViewDeliveryTab() {
    return _hasPermission('delivery.manage') || _isCreatorBase();
  }

  bool _canEditDeliveryPricing() {
    if (_isCreatorBase()) return true;
    final effectiveRole = authService.effectiveRole.toLowerCase().trim();
    final baseRole = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return effectiveRole == 'tenant' || baseRole == 'tenant';
  }

  bool _canViewSupportTab() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasPermission('chat.write.support');
  }

  bool _canManageSupportKnowledgeBase() {
    if (_isCreatorBase()) return true;
    return authService.effectiveRole.toLowerCase().trim() == 'admin';
  }

  bool _canForceCloseSupportTicket() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasPermission('chat.write.support');
  }

  bool _canViewClientCartsTab() {
    if (_isCreatorBase()) return true;
    final role = authService.effectiveRole;
    if (role == 'admin' || role == 'tenant') return true;
    return _hasAnyPermission(const ['delivery.manage', 'tenant.users.manage']);
  }

  bool _canViewPromotionsTab() {
    return _isAdminViewRole();
  }

  List<_AdminTabSpec> _buildVisibleTabs() {
    final tabs = <_AdminTabSpec>[
      if (_canViewClientCartsTab())
        _AdminTabSpec(
          id: 'client_carts',
          label: 'Корзины',
          icon: Icons.shopping_cart_outlined,
          builder: _buildClientCartsTab,
        ),
      if (_canViewModerationTab())
        _AdminTabSpec(
          id: 'moderation',
          label: 'Модерация',
          icon: Icons.fact_check_outlined,
          builder: _buildModerationTab,
        ),
      if (_canViewCreateTab())
        _AdminTabSpec(
          id: 'create',
          label: 'Создание',
          icon: Icons.add_box_outlined,
          builder: _buildCreateTab,
        ),
      if (_canViewChannelsTab())
        _AdminTabSpec(
          id: 'channels',
          label: 'Каналы',
          icon: Icons.campaign_outlined,
          builder: _buildSettingsTab,
        ),
      if (_canViewPromotionsTab())
        _AdminTabSpec(
          id: 'promotions',
          label: 'Промо',
          icon: Icons.local_offer_outlined,
          builder: _buildPromotionsTab,
        ),
      if (_canViewDeliveryTab())
        _AdminTabSpec(
          id: 'delivery',
          label: 'Доставка',
          icon: Icons.local_shipping_outlined,
          builder: _buildDeliveryTab,
        ),
      if (_canViewSupportTab())
        _AdminTabSpec(
          id: 'support',
          label: 'Поддержка',
          icon: Icons.support_agent_outlined,
          builder: _buildSupportTab,
        ),
    ];
    if (tabs.isNotEmpty) return tabs;
    return <_AdminTabSpec>[
      _AdminTabSpec(
        id: 'no_access',
        label: 'Доступ',
        icon: Icons.lock_outline,
        builder: _buildNoAccessTab,
      ),
    ];
  }

  bool _rebuildVisibleTabs({bool force = false, bool notify = true}) {
    if (_isDisposed) return false;
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

    final previousController = _tabController;
    _tabController = null;
    previousController?.dispose();
    _visibleTabs = nextTabs;
    _loadedTabs.clear();

    final mappedIndex = oldId == null
        ? 0
        : nextTabs.indexWhere((tab) => tab.id == oldId);
    final initialIndex = mappedIndex >= 0 ? mappedIndex : 0;

    _tabController = TabController(
      length: nextTabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController?.addListener(_handleActiveTabChanged);

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

  void _handleActiveTabChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    unawaited(_loadActiveTabData(silent: true));
  }

  int _toInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) {
      final parsed = value.toDouble();
      if (parsed.isFinite) return parsed;
      return fallback;
    }
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return fallback;
    return parsed;
  }

  String _formatProductLabel(
    dynamic productCode,
    dynamic shelfNumber, {
    dynamic manualShelfLabel,
  }) {
    final code = _toInt(productCode, fallback: 0);
    final shelf = _toInt(shelfNumber, fallback: 1);
    final manualShelf = (manualShelfLabel ?? '').toString().trim();
    final codePart = code > 0 ? '$code' : '—';
    final shelfPart = manualShelf.isNotEmpty
        ? manualShelf
        : (shelf > 0 ? shelf.toString().padLeft(2, '0') : '—');
    return '$codePart--$shelfPart';
  }

  String _displayShelfValue(dynamic shelfLabel, dynamic shelfNumber) {
    final label = (shelfLabel ?? '').toString().trim();
    if (label.isNotEmpty) return label;
    final rawNumber = (shelfNumber ?? '').toString().trim();
    if (rawNumber.isNotEmpty) return rawNumber;
    return 'не назначена';
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
      width: 1024,
      height: 1024,
      interpolation: img.Interpolation.cubic,
    );

    final outputBytes = img.encodeJpg(resized, quality: 95);
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
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
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

  List<TextEditingController> _supportDraftControllers() => [
    _supportTemplateTitleCtrl,
    _supportTemplateBodyCtrl,
    _supportTemplateTriggerCtrl,
    _supportTemplateTriggerProbeCtrl,
    _supportTemplatePriorityCtrl,
  ];

  void _bindSupportTemplateDraftAutosave() {
    for (final controller in _supportDraftControllers()) {
      controller.addListener(_scheduleSupportTemplateDraftSave);
    }
  }

  void _unbindSupportTemplateDraftAutosave() {
    for (final controller in _supportDraftControllers()) {
      controller.removeListener(_scheduleSupportTemplateDraftSave);
    }
  }

  void _scheduleSupportTemplateDraftSave() {
    if (_supportDraftRestoreInProgress) return;
    _supportDraftSaveTimer?.cancel();
    _supportDraftSaveTimer = Timer(const Duration(milliseconds: 550), () {
      unawaited(_saveSupportTemplateDraft());
    });
  }

  Future<void> _saveSupportTemplateDraft() async {
    if (_supportDraftRestoreInProgress) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final title = _supportTemplateTitleCtrl.text.trim();
      final body = _supportTemplateBodyCtrl.text.trim();
      final trigger = _supportTemplateTriggerCtrl.text.trim();
      final probe = _supportTemplateTriggerProbeCtrl.text.trim();
      final priorityRaw = _supportTemplatePriorityCtrl.text.trim();
      final priority = priorityRaw.isEmpty ? '100' : priorityRaw;

      final hasDraft =
          title.isNotEmpty ||
          body.isNotEmpty ||
          trigger.isNotEmpty ||
          probe.isNotEmpty ||
          priority != '100' ||
          !_supportTemplateAutoReply ||
          _supportTemplateElseFallback;
      if (!hasDraft) {
        await _clearSupportTemplateDraft();
        return;
      }

      await prefs.setString(_supportDraftTitleKey, title);
      await prefs.setString(_supportDraftBodyKey, body);
      await prefs.setString(_supportDraftTriggerKey, trigger);
      await prefs.setString(_supportDraftProbeKey, probe);
      await prefs.setString(_supportDraftPriorityKey, priority);
      await prefs.setBool(_supportDraftAutoReplyKey, _supportTemplateAutoReply);
      await prefs.setBool(_supportDraftElseKey, _supportTemplateElseFallback);
    } catch (_) {
      // Draft autosave is a helper feature; ignore storage failures.
    }
  }

  Future<void> _clearSupportTemplateDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_supportDraftTitleKey);
      await prefs.remove(_supportDraftBodyKey);
      await prefs.remove(_supportDraftTriggerKey);
      await prefs.remove(_supportDraftProbeKey);
      await prefs.remove(_supportDraftPriorityKey);
      await prefs.remove(_supportDraftAutoReplyKey);
      await prefs.remove(_supportDraftElseKey);
    } catch (_) {
      // Ignore local draft cleanup errors.
    }
  }

  Future<void> _restoreSupportTemplateDraft() async {
    _supportDraftRestoreInProgress = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final title = prefs.getString(_supportDraftTitleKey) ?? '';
      final body = prefs.getString(_supportDraftBodyKey) ?? '';
      final trigger = prefs.getString(_supportDraftTriggerKey) ?? '';
      final probe = prefs.getString(_supportDraftProbeKey) ?? '';
      final priority = prefs.getString(_supportDraftPriorityKey) ?? '100';
      final autoReply = prefs.getBool(_supportDraftAutoReplyKey);
      final elseFallback = prefs.getBool(_supportDraftElseKey);

      _supportTemplateTitleCtrl.text = title;
      _supportTemplateBodyCtrl.text = body;
      _supportTemplateTriggerCtrl.text = trigger;
      _supportTemplateTriggerProbeCtrl.text = probe;
      _supportTemplatePriorityCtrl.text = priority;

      if (!mounted) return;
      setState(() {
        if (autoReply != null) {
          _supportTemplateAutoReply = autoReply;
        }
        if (elseFallback != null) {
          _supportTemplateElseFallback = elseFallback;
          if (elseFallback &&
              !_isFallbackTriggerRule(_supportTemplateTriggerCtrl.text)) {
            _supportTemplateTriggerCtrl.text = '*';
          }
        }
      });
    } catch (_) {
      // Ignore draft restore issues.
    } finally {
      _supportDraftRestoreInProgress = false;
    }
  }

  String _activeTabId() {
    final controller = _tabController;
    if (controller == null || _visibleTabs.isEmpty) return '';
    final index = controller.index.clamp(0, _visibleTabs.length - 1).toInt();
    return _visibleTabs[index].id;
  }

  Future<void> _loadActiveTabData({
    bool silent = true,
    bool force = false,
  }) async {
    final tabId = _activeTabId();
    if (tabId.isEmpty) return;
    if (!force && _loadedTabs.contains(tabId)) return;
    _loadedTabs.add(tabId);
    switch (tabId) {
      case 'client_carts':
        return;
      case 'moderation':
        await Future.wait([
          _loadTenantFeatureSettings(silent: silent),
          _loadPendingPosts(),
          _loadRevisionDeleteRequests(silent: silent),
        ]);
        return;
      case 'create':
      case 'channels':
        await _loadChannels();
        return;
      case 'delivery':
        await _loadDeliveryDashboard();
        return;
      case 'support':
        await _loadSupportTickets(silent: silent);
        await _loadSupportTemplates(silent: true);
        await _loadSupportFaqEntries(silent: true);
        await _loadReturnsWorkflow(silent: true);
        await _loadSupportNotificationCenter(silent: true);
        await _loadReturnsAnalytics(silent: true);
        await _loadDefectStats(silent: true);
        return;
      default:
        return;
    }
  }

  Future<void> _reloadAll({bool forceAll = false}) async {
    if (!forceAll) {
      await _loadActiveTabData(silent: false, force: true);
      return;
    }
    final canLoadChannels = _canViewCreateTab() || _canViewChannelsTab();
    if (canLoadChannels) {
      await _loadChannels();
    } else if (mounted && _loading) {
      setState(() => _loading = false);
    }
    if (_canViewModerationTab()) {
      await _loadPendingPosts();
      await _loadRevisionDeleteRequests(silent: true);
    }
    if (_canViewDeliveryTab()) {
      await _loadDeliveryDashboard();
    }
    if (_canViewSupportTab()) {
      await _loadSupportTickets();
      await _loadSupportTemplates(silent: true);
      await _loadSupportFaqEntries(silent: true);
      await _loadReturnsWorkflow(silent: true);
      await _loadSupportNotificationCenter(silent: true);
      await _loadReturnsAnalytics(silent: true);
      await _loadDefectStats(silent: true);
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
          'max_uses': maxUses,
          'expires_days': expiresDays,
          'notes': notes.isNotEmpty ? notes : null,
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

  Future<void> _renameInviteCode(String inviteId, String currentCode) async {
    if (!_isCreatorBase()) {
      if (mounted) {
        setState(
          () => _message = 'Изменять код приглашения может только Создатель',
        );
      }
      return;
    }
    final ctrl = TextEditingController(text: currentCode.trim());
    final nextCode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить код приглашения'),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Новый код',
            hintText: 'INV-XXXX-XXXX',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final normalized = (nextCode ?? '').trim().toUpperCase();
    if (normalized.isEmpty || normalized == currentCode.trim().toUpperCase()) {
      return;
    }
    setState(() => _inviteActionLoading = true);
    try {
      await authService.dio.patch(
        '/api/admin/tenant/invites/$inviteId/code',
        data: {'code': normalized},
      );
      if (mounted) {
        setState(() => _message = 'Код приглашения обновлен');
      }
      await _loadTenantInvites(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка изменения кода: ${_extractDioError(e)}',
      );
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
    final channel = _channels.firstWhere(
      (item) => _channelIdOf(item) == channelId,
      orElse: () => const <String, dynamic>{},
    );
    final settings = _settingsOf(channel);
    final kind = (settings['kind'] ?? '').toString().trim().toLowerCase();
    final adminOnly = _boolValue(settings['admin_only']);
    final isSystemOverviewBlocked =
        (kind.isNotEmpty && kind != 'channel') || adminOnly;
    if (isSystemOverviewBlocked) {
      return null;
    }
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
    if (_pendingPostsLoading) return;
    _pendingPostsLoading = true;
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
            _activePublishBatches = _asMapList(meta['active_publish_batches']);
            _publishingSummary = _asMap(meta['publishing_summary']);
          });
          _syncPublishProgressPolling();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки очереди: ${_extractDioError(e)}',
        );
      }
    } finally {
      _pendingPostsLoading = false;
    }
  }

  Future<void> _loadTenantFeatureSettings({bool silent = true}) async {
    if (_tenantFeatureSettingsLoading) return;
    _tenantFeatureSettingsLoading = true;
    try {
      final resp = await authService.dio.get(
        '/api/admin/tenant/feature-settings',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final settings = Map<String, dynamic>.from(data['data'] as Map);
        if (!mounted) return;
        setState(() {
          _tenantFeatureSettings = settings;
          _publicationIntervalCtrl.text = _formatIntervalSeconds(
            _toInt(settings['publication_interval_ms'], fallback: 2000),
          );
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message =
              'Ошибка загрузки настроек группы: ${_extractDioError(e)}',
        );
      }
    } finally {
      _tenantFeatureSettingsLoading = false;
    }
  }

  Future<void> _loadRevisionDeleteRequests({bool silent = true}) async {
    if (_revisionDeleteRequestsLoading) return;
    _revisionDeleteRequestsLoading = true;
    try {
      final resp = await authService.dio.get(
        '/api/admin/revision/delete-requests',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final items = data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : <Map<String, dynamic>>[];
        if (!mounted) return;
        setState(() {
          _revisionDeleteRequests = items;
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message =
              'Ошибка загрузки запросов ревизии: ${_extractDioError(e)}',
        );
      }
    } finally {
      _revisionDeleteRequestsLoading = false;
    }
  }

  Future<void> _savePublicationIntervalSetting() async {
    final intervalMs = _parsePublicationIntervalInputMs();
    if (intervalMs == null) {
      setState(() => _message = 'Введите интервал в секундах');
      return;
    }
    setState(() {
      _tenantFeatureSettingsSaving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.patch(
        '/api/admin/tenant/feature-settings',
        data: {'publication_interval_ms': intervalMs},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final settings = Map<String, dynamic>.from(data['data'] as Map);
        if (!mounted) return;
        setState(() {
          _tenantFeatureSettings = settings;
          _publicationIntervalCtrl.text = _formatIntervalSeconds(
            _toInt(settings['publication_interval_ms'], fallback: intervalMs),
          );
          _message = 'Интервал публикации сохранён';
        });
      } else if (mounted) {
        setState(() => _message = 'Не удалось сохранить интервал');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _message = 'Ошибка сохранения интервала: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _tenantFeatureSettingsSaving = false);
    }
  }

  Future<void> _decideRevisionDeleteRequest(
    Map<String, dynamic> request,
    bool approve,
  ) async {
    final id = (request['id'] ?? '').toString().trim();
    if (id.isEmpty || _revisionDeleteDecisionBusyIds.contains(id)) return;
    setState(() {
      _revisionDeleteDecisionBusyIds.add(id);
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/revision/delete-requests/$id/decision',
        data: {'decision': approve ? 'approved' : 'rejected'},
      );
      if (!mounted) return;
      setState(() {
        _message = approve
            ? 'Удаление товара одобрено'
            : 'Удаление товара отклонено';
      });
      showAppNotice(
        context,
        approve ? 'Товар удалён из ревизии' : 'Запрос на удаление отклонён',
        tone: approve ? AppNoticeTone.success : AppNoticeTone.info,
      );
      await Future.wait([
        _loadRevisionDeleteRequests(silent: true),
        _loadPendingPosts(),
      ]);
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка решения по удалению: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _revisionDeleteDecisionBusyIds.remove(id);
        });
      } else {
        _revisionDeleteDecisionBusyIds.remove(id);
      }
    }
  }

  void _schedulePendingPostsRealtimeRefresh() {
    _pendingPostsRefreshDebounce?.cancel();
    _pendingPostsRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || _isDisposed) return;
      unawaited(_loadPendingPosts());
    });
  }

  String _realtimeChannelIdOf(Object? data) {
    if (data is! Map) return '';
    final map = Map<String, dynamic>.from(data);
    final direct =
        (map['channel_id'] ??
                map['channelId'] ??
                map['chatId'] ??
                map['chat_id'] ??
                map['entity_id'] ??
                '')
            .toString()
            .trim();
    if (direct.isNotEmpty) return direct;
    final chat = map['chat'];
    if (chat is Map) {
      return (chat['id'] ?? chat['chat_id'] ?? '').toString().trim();
    }
    final message = map['message'];
    if (message is Map) {
      return (message['chat_id'] ?? message['chatId'] ?? '').toString().trim();
    }
    return '';
  }

  void _scheduleChannelsRealtimeRefresh() {
    _channelsRefreshDebounce?.cancel();
    _channelsRefreshDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _isDisposed) return;
      unawaited(_loadChannels());
    });
  }

  void _scheduleDeliveryRealtimeRefresh() {
    _deliveryRefreshDebounce?.cancel();
    _deliveryRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _isDisposed) return;
      if (_activeTabId() != 'delivery') return;
      unawaited(_loadDeliveryDashboard());
    });
  }

  void _scheduleSupportRealtimeRefresh() {
    _supportRefreshDebounce?.cancel();
    _supportRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _isDisposed) return;
      if (_activeTabId() != 'support') return;
      unawaited(_loadSupportTickets(silent: true));
      unawaited(_loadSupportNotificationCenter(silent: true));
    });
  }

  void _scheduleClaimsRealtimeRefresh() {
    _claimsRefreshDebounce?.cancel();
    _claimsRefreshDebounce = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || _isDisposed) return;
      if (_activeTabId() != 'support') return;
      unawaited(_loadReturnsWorkflow(silent: true));
      unawaited(_loadSupportNotificationCenter(silent: true));
      unawaited(_loadReturnsAnalytics(silent: true));
      unawaited(_loadDefectStats(silent: true));
    });
  }

  void _scheduleChannelOverviewRealtimeRefresh(String channelId) {
    final normalized = channelId.trim();
    if (normalized.isEmpty || !_channelOverviews.containsKey(normalized)) {
      return;
    }
    _channelOverviewRefreshDebounces[normalized]?.cancel();
    _channelOverviewRefreshDebounces[normalized] = Timer(
      const Duration(milliseconds: 400),
      () {
        _channelOverviewRefreshDebounces.remove(normalized);
        if (!mounted || _isDisposed) return;
        unawaited(_loadChannelOverview(normalized, force: true, silent: true));
      },
    );
  }

  bool get _hasActivePublishBatches => _activePublishBatches.isNotEmpty;

  void _syncPublishProgressPolling() {
    final shouldPoll = _hasActivePublishBatches;
    if (!shouldPoll) {
      _publishProgressTimer?.cancel();
      _publishProgressTimer = null;
      return;
    }
    if (_publishProgressTimer != null) return;
    _publishProgressTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || _isDisposed) return;
      unawaited(_loadPendingPosts());
    });
  }

  String _publicationStatusLabel(Map<String, dynamic> post) {
    final status = (post['publish_status'] ?? 'pending').toString().trim();
    switch (status) {
      case 'queued':
        return 'В очереди';
      case 'publishing':
        return 'Публикуется';
      case 'failed':
        return 'Ошибка публикации';
      case 'published':
        return 'Опубликован';
      default:
        return 'Ожидает';
    }
  }

  Color _publicationStatusColor(ThemeData theme, String status) {
    switch (status) {
      case 'queued':
        return theme.colorScheme.secondaryContainer;
      case 'publishing':
        return theme.colorScheme.primaryContainer;
      case 'failed':
        return theme.colorScheme.errorContainer;
      case 'published':
        return theme.colorScheme.tertiaryContainer;
      default:
        return theme.colorScheme.surfaceContainerHighest;
    }
  }

  String _formatPublicationDelay(dynamic rawValue) {
    final millis = _toInt(rawValue);
    if (millis <= 0) return 'сейчас';
    final seconds = math.max(1, (millis / 1000).ceil());
    return '~$seconds сек';
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
        queryParameters: {
          if (_canManageSupportKnowledgeBase()) 'include_inactive': 1,
        },
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

  Future<void> _loadSupportFaqEntries({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _supportFaqLoading = true);
    } else {
      _supportFaqLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/support/faq',
        queryParameters: {
          if (_canManageSupportKnowledgeBase()) 'include_inactive': 1,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _supportFaqEntries = List<Map<String, dynamic>>.from(data['data']);
        });
      } else if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить FAQ поддержки');
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка FAQ поддержки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _supportFaqLoading = false);
      } else {
        _supportFaqLoading = false;
      }
    }
  }

  List<DropdownMenuItem<String>> _supportCategoryDropdownItems() {
    return const <String>['general', 'product', 'delivery', 'cart']
        .map(
          (value) => DropdownMenuItem<String>(
            value: value,
            child: Text(_supportCategoryLabel(value)),
          ),
        )
        .toList();
  }

  String _supportTemplatePreview(Map<String, dynamic> template) {
    final body = (template['body'] ?? '').toString().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (body.isEmpty) return 'Без текста';
    if (body.length <= 90) return body;
    return '${body.substring(0, 87)}...';
  }

  void _resetSupportTemplateEditor({bool clearMessage = false}) {
    _supportTemplateTitleCtrl.clear();
    _supportTemplateBodyCtrl.clear();
    _supportTemplateTriggerCtrl.clear();
    _supportTemplateTriggerProbeCtrl.clear();
    _supportTemplatePriorityCtrl.text = '100';
    _supportDraftSaveTimer?.cancel();
    unawaited(_clearSupportTemplateDraft());
    void apply() {
      _editingSupportTemplateId = '';
      _supportTemplateCategory = 'general';
      _supportTemplateAutoReply = true;
      _supportTemplateElseFallback = false;
      if (clearMessage) {
        _message = '';
      }
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _editSupportTemplate(Map<String, dynamic> template) {
    final triggerRule = (template['trigger_rule'] ?? '').toString().trim();
    _supportTemplateTitleCtrl.text = (template['title'] ?? '').toString();
    _supportTemplateBodyCtrl.text = (template['body'] ?? '').toString();
    _supportTemplateTriggerCtrl.text = triggerRule == '*' ? '*' : triggerRule;
    _supportTemplateTriggerProbeCtrl.clear();
    _supportTemplatePriorityCtrl.text = (template['priority'] ?? 100)
        .toString();
    setState(() {
      _editingSupportTemplateId = (template['id'] ?? '').toString().trim();
      _supportTemplateCategory = (template['category'] ?? 'general')
          .toString()
          .trim()
          .toLowerCase();
      _supportTemplateAutoReply = template['auto_reply_enabled'] == true;
      _supportTemplateElseFallback = triggerRule == '*';
      _message =
          'Редактируем шаблон "${(template['title'] ?? 'Шаблон').toString()}"';
    });
  }

  Future<void> _saveSupportTemplate() async {
    final title = _supportTemplateTitleCtrl.text.trim();
    final body = _supportTemplateBodyCtrl.text.trim();
    final rawTriggerRule = _supportTemplateTriggerCtrl.text.trim();
    final fallbackMode =
        _supportTemplateElseFallback || _isFallbackTriggerRule(rawTriggerRule);
    final triggerRule = fallbackMode ? '*' : rawTriggerRule;
    final priority =
        int.tryParse(_supportTemplatePriorityCtrl.text.trim()) ?? 100;
    if (title.isEmpty || body.isEmpty) {
      setState(() => _message = 'Заполни название и текст шаблона');
      return;
    }
    if (_supportTemplateAutoReply && triggerRule.isEmpty) {
      setState(
        () => _message =
            'Для автоответа укажи триггер (например: время+доставки)',
      );
      return;
    }
    final editingId = _editingSupportTemplateId.trim();
    setState(() {
      _supportTemplateSaving = true;
      _message = '';
    });
    try {
      final payload = {
        'title': title,
        'body': body,
        'category': _supportTemplateCategory,
        'trigger_rule': triggerRule,
        'auto_reply_enabled': _supportTemplateAutoReply,
        'priority': priority,
      };
      if (editingId.isEmpty) {
        await authService.dio.post(
          '/api/admin/ops/support/templates',
          data: payload,
        );
      } else {
        await authService.dio.patch(
          '/api/admin/ops/support/templates/$editingId',
          data: payload,
        );
      }
      _resetSupportTemplateEditor();
      await _loadSupportTemplates(silent: true);
      if (mounted) {
        setState(() {
          _message = editingId.isEmpty
              ? 'Шаблон поддержки сохранён'
              : 'Шаблон поддержки обновлён';
        });
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

  Future<void> _toggleSupportTemplateActive(
    Map<String, dynamic> template,
  ) async {
    final templateId = (template['id'] ?? '').toString().trim();
    if (templateId.isEmpty) return;
    final nextActive = !(template['is_active'] == true);
    setState(() {
      _supportTemplateSaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/ops/support/templates/$templateId',
        data: {'is_active': nextActive},
      );
      await _loadSupportTemplates(silent: true);
      if (!mounted) return;
      setState(() {
        _message = nextActive
            ? 'Шаблон снова активен'
            : 'Шаблон скрыт из быстрых ответов';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка шаблона: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportTemplateSaving = false);
      } else {
        _supportTemplateSaving = false;
      }
    }
  }

  void _resetSupportFaqEditor({bool clearMessage = false}) {
    _supportFaqQuestionCtrl.clear();
    _supportFaqAnswerCtrl.clear();
    _supportFaqKeywordsCtrl.clear();
    _supportFaqSortOrderCtrl.text = '100';
    void apply() {
      _editingSupportFaqId = '';
      _supportFaqCategory = 'general';
      _supportFaqIsActive = true;
      if (clearMessage) {
        _message = '';
      }
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _editSupportFaq(Map<String, dynamic> entry) {
    _supportFaqQuestionCtrl.text = (entry['question'] ?? '').toString();
    _supportFaqAnswerCtrl.text = (entry['answer'] ?? '').toString();
    final keywords = entry['keywords'];
    _supportFaqKeywordsCtrl.text = keywords is List
        ? keywords.join(', ')
        : (keywords ?? '').toString();
    _supportFaqSortOrderCtrl.text = (entry['sort_order'] ?? 100).toString();
    setState(() {
      _editingSupportFaqId = (entry['id'] ?? '').toString().trim();
      _supportFaqCategory = (entry['category'] ?? 'general')
          .toString()
          .trim()
          .toLowerCase();
      _supportFaqIsActive = entry['is_active'] != false;
      _message = 'Редактируем карточку FAQ';
    });
  }

  Future<void> _saveSupportFaqEntry() async {
    final question = _supportFaqQuestionCtrl.text.trim();
    final answer = _supportFaqAnswerCtrl.text.trim();
    final sortOrder = int.tryParse(_supportFaqSortOrderCtrl.text.trim()) ?? 100;
    if (question.isEmpty || answer.isEmpty) {
      setState(() => _message = 'Заполни вопрос и ответ для FAQ');
      return;
    }
    final editingId = _editingSupportFaqId.trim();
    setState(() {
      _supportFaqSaving = true;
      _message = '';
    });
    try {
      final payload = {
        'question': question,
        'answer': answer,
        'category': _supportFaqCategory,
        'keywords': _supportFaqKeywordsCtrl.text.trim(),
        'sort_order': sortOrder,
        'is_active': _supportFaqIsActive,
      };
      if (editingId.isEmpty) {
        await authService.dio.post('/api/admin/ops/support/faq', data: payload);
      } else {
        await authService.dio.patch(
          '/api/admin/ops/support/faq/$editingId',
          data: payload,
        );
      }
      _resetSupportFaqEditor();
      await _loadSupportFaqEntries(silent: true);
      if (!mounted) return;
      setState(() {
        _message = editingId.isEmpty ? 'FAQ сохранён' : 'FAQ обновлён';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка FAQ: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportFaqSaving = false);
      } else {
        _supportFaqSaving = false;
      }
    }
  }

  Future<void> _toggleSupportFaqActive(Map<String, dynamic> entry) async {
    final faqId = (entry['id'] ?? '').toString().trim();
    if (faqId.isEmpty) return;
    final nextActive = !(entry['is_active'] == true);
    setState(() {
      _supportFaqSaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/ops/support/faq/$faqId',
        data: {'is_active': nextActive},
      );
      await _loadSupportFaqEntries(silent: true);
      if (!mounted) return;
      setState(() {
        _message = nextActive
            ? 'FAQ снова показывается клиентам'
            : 'FAQ скрыт из подсказок';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка FAQ: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportFaqSaving = false);
      } else {
        _supportFaqSaving = false;
      }
    }
  }

  Future<void> _deleteSupportFaqEntry(Map<String, dynamic> entry) async {
    final faqId = (entry['id'] ?? '').toString().trim();
    if (faqId.isEmpty) return;
    setState(() {
      _supportFaqSaving = true;
      _message = '';
    });
    try {
      await authService.dio.delete('/api/admin/ops/support/faq/$faqId');
      if (_editingSupportFaqId == faqId) {
        _resetSupportFaqEditor();
      }
      await _loadSupportFaqEntries(silent: true);
      if (!mounted) return;
      setState(() => _message = 'FAQ удалён');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления FAQ: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportFaqSaving = false);
      } else {
        _supportFaqSaving = false;
      }
    }
  }

  void _insertTokenToController(
    TextEditingController controller,
    String token,
  ) {
    final text = controller.text;
    final selection = controller.selection;
    final hasSelection =
        selection.start >= 0 &&
        selection.end >= 0 &&
        selection.start <= text.length &&
        selection.end <= text.length;

    final start = hasSelection
        ? math.min(selection.start, selection.end)
        : text.length;
    final end = hasSelection
        ? math.max(selection.start, selection.end)
        : text.length;
    final nextText = text.replaceRange(start, end, token);
    final nextOffset = start + token.length;

    controller.value = controller.value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
      composing: TextRange.empty,
    );
  }

  void _insertSupportTemplateToken(String token, {bool toTitle = false}) {
    final controller = toTitle
        ? _supportTemplateTitleCtrl
        : _supportTemplateBodyCtrl;
    _insertTokenToController(controller, token);
  }

  String _normalizeSupportMatchText(String raw) {
    return raw
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^a-z0-9а-я]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeSupportStem(String word) {
    final normalized = _normalizeSupportMatchText(word).replaceAll(' ', '');
    if (normalized.isEmpty) return '';
    return normalized.length <= 4 ? normalized : normalized.substring(0, 4);
  }

  bool _supportWordMatches(String messageWord, String termWord) {
    final left = messageWord.trim();
    final right = termWord.trim();
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    if (left.contains(right) || right.contains(left)) return true;
    return _normalizeSupportStem(left) == _normalizeSupportStem(right);
  }

  bool _supportTermMatches(String normalizedMessage, String term) {
    final normalizedTerm = _normalizeSupportMatchText(term);
    if (normalizedTerm.isEmpty) return false;
    if (normalizedMessage.contains(normalizedTerm)) return true;

    final messageWords = normalizedMessage
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .toList();
    final termWords = normalizedTerm
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .toList();
    if (messageWords.isEmpty || termWords.isEmpty) return false;

    return termWords.every(
      (termWord) => messageWords.any(
        (messageWord) => _supportWordMatches(messageWord, termWord),
      ),
    );
  }

  bool _isFallbackTriggerRule(String rawRule) {
    final normalized = rawRule.toLowerCase().trim();
    return normalized == '*' ||
        normalized == 'else' ||
        normalized == 'fallback' ||
        normalized == 'иначе';
  }

  List<List<String>> _parseSupportTriggerGroups(String rawRule) {
    if (_isFallbackTriggerRule(rawRule)) return const <List<String>>[];
    final rule = rawRule.trim();
    if (rule.isEmpty) return const <List<String>>[];
    return rule
        .split(RegExp(r'[|\n;]'))
        .map((group) => group.trim())
        .where((group) => group.isNotEmpty)
        .map(
          (group) => group
              .split('+')
              .map((term) => _normalizeSupportMatchText(term))
              .where((term) => term.isNotEmpty)
              .toList(),
        )
        .where((group) => group.isNotEmpty)
        .toList();
  }

  bool _supportTriggerMatches(String rawRule, String messageText) {
    if (_isFallbackTriggerRule(rawRule)) return true;
    final groups = _parseSupportTriggerGroups(rawRule);
    if (groups.isEmpty) return false;
    final normalizedMessage = _normalizeSupportMatchText(messageText);
    if (normalizedMessage.isEmpty) return false;
    for (final group in groups) {
      final allTermsFound = group.every(
        (term) => _supportTermMatches(normalizedMessage, term),
      );
      if (allTermsFound) return true;
    }
    return false;
  }

  void _setSupportTemplateFallback(bool value) {
    setState(() {
      _supportTemplateElseFallback = value;
      if (value) {
        _supportTemplateTriggerCtrl.text = '*';
        _supportTemplateTriggerCtrl.selection = TextSelection.collapsed(
          offset: _supportTemplateTriggerCtrl.text.length,
        );
      } else if (_isFallbackTriggerRule(_supportTemplateTriggerCtrl.text)) {
        _supportTemplateTriggerCtrl.clear();
      }
    });
    _scheduleSupportTemplateDraftSave();
  }

  void _appendSupportTriggerExample(String triggerRule) {
    if (_supportTemplateElseFallback) return;
    final token = triggerRule.trim();
    if (token.isEmpty) return;
    final current = _supportTemplateTriggerCtrl.text.trim();
    if (current.isEmpty) {
      _supportTemplateTriggerCtrl.text = token;
      _supportTemplateTriggerCtrl.selection = TextSelection.collapsed(
        offset: _supportTemplateTriggerCtrl.text.length,
      );
      _scheduleSupportTemplateDraftSave();
      return;
    }
    if (current.split('|').map((s) => s.trim()).contains(token)) return;
    final next = '$current|$token';
    _supportTemplateTriggerCtrl.text = next;
    _supportTemplateTriggerCtrl.selection = TextSelection.collapsed(
      offset: next.length,
    );
    _scheduleSupportTemplateDraftSave();
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
      await _loadSupportNotificationCenter(silent: true);
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
    String? resolutionNote;
    if (action == 'approve_discount') {
      amount = await _askText(
        title: 'Сумма скидки',
        label: 'Введите сумму скидки',
        initial: (claim['requested_amount'] ?? '').toString(),
      );
      if (amount == null) return;
    }
    if (action == 'reject') {
      resolutionNote = await _askText(
        title: 'Причина отказа',
        label: 'Напишите причину отказа',
      );
      if (resolutionNote == null || resolutionNote.trim().length < 3) {
        if (mounted) {
          setState(
            () => _message = 'Причина отказа должна быть не короче 3 символов',
          );
        }
        return;
      }
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
          if (resolutionNote != null) 'resolution_note': resolutionNote.trim(),
        },
      );
      await _loadReturnsWorkflow(silent: true);
      await _loadSupportNotificationCenter(silent: true);
      await _loadReturnsAnalytics(silent: true);
      await _loadDefectStats(silent: true);
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

  bool _isSelectedClientCartUser(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) return false;
    return (_selectedClientCartUser?['id'] ?? '').toString().trim() ==
        normalized;
  }

  Future<void> _reloadClientCartIfStillSelected(String userId) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !_isSelectedClientCartUser(normalized)) return;
    await _loadSelectedClientCart(normalized);
  }

  Future<void> _scheduleClientCartUndoAction({
    required String label,
    required Future<void> Function() commit,
    VoidCallback? rollback,
  }) async {
    if (_clientCartUndoPending) {
      if (mounted) {
        setState(
          () => _message =
              'Уже есть действие с таймером. Отмените его или дождитесь завершения.',
        );
      }
      return;
    }
    _clientCartPendingCommit = commit;
    _clientCartPendingRollback = rollback;
    _clientCartPendingLabel = label;
    _clientCartUndoTimer?.cancel();
    _clientCartUndoTimer = Timer(_clientCartUndoDelay, () {
      unawaited(_commitPendingClientCartAction());
    });

    if (mounted) {
      setState(() {
        _clientCartUndoPending = true;
        _message = '$label: можно отменить в течение 2 секунд';
      });
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          duration: _clientCartUndoDelay,
          content: Text('$label через 2 секунды'),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: _cancelPendingClientCartAction,
          ),
        ),
      );
    }
  }

  void _cancelPendingClientCartAction() {
    if (!_clientCartUndoPending) return;
    _clientCartUndoTimer?.cancel();
    _clientCartUndoTimer = null;
    final rollback = _clientCartPendingRollback;
    _clientCartPendingCommit = null;
    _clientCartPendingRollback = null;
    _clientCartPendingLabel = '';
    rollback?.call();
    if (mounted) {
      setState(() {
        _clientCartUndoPending = false;
        _message = 'Действие отменено';
      });
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    }
  }

  Future<void> _commitPendingClientCartAction() async {
    if (!_clientCartUndoPending) return;
    _clientCartUndoTimer?.cancel();
    _clientCartUndoTimer = null;
    final commit = _clientCartPendingCommit;
    final label = _clientCartPendingLabel;
    _clientCartPendingCommit = null;
    _clientCartPendingRollback = null;
    _clientCartPendingLabel = '';
    if (commit == null) {
      if (mounted) {
        setState(() => _clientCartUndoPending = false);
      } else {
        _clientCartUndoPending = false;
      }
      return;
    }

    if (mounted) {
      setState(() {
        _clientCartActionBusy = true;
        _clientCartUndoPending = false;
      });
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    } else {
      _clientCartActionBusy = true;
      _clientCartUndoPending = false;
    }
    try {
      await commit();
      if (mounted) {
        setState(() => _message = '$label выполнено');
      }
    } catch (e) {
      final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();
      if (userId.isNotEmpty) {
        try {
          await _loadSelectedClientCart(userId);
        } catch (_) {}
      }
      if (mounted) {
        setState(
          () => _message = 'Ошибка применения действия: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _clientCartActionBusy = false);
      } else {
        _clientCartActionBusy = false;
      }
    }
  }

  Future<void> _searchClientCartsByPhone() async {
    final query = _clientCartSearchCtrl.text.trim();
    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) {
      setState(() => _message = 'Введите минимум 4 цифры номера');
      return;
    }
    setState(() {
      _clientCartSearchLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/cart/admin/clients/by-phone',
        queryParameters: {'q': digits, 'limit': 30},
      );
      final data = resp.data;
      final users = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _clientCartUsers = users;
        final selectedId = (_selectedClientCartUser?['id'] ?? '').toString();
        if (selectedId.isEmpty ||
            !users.any((user) => (user['id'] ?? '').toString() == selectedId)) {
          _selectedClientCartUser = null;
          _selectedClientCartItems = [];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка поиска клиента: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _clientCartSearchLoading = false);
      }
    }
  }

  Future<void> _loadSelectedClientCart(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return;
    setState(() {
      _clientCartLoading = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/cart/admin/clients/$id/cart',
      );
      final data = resp.data;
      final payload = data is Map && data['ok'] == true && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _selectedClientCartUser = payload['user'] is Map
            ? Map<String, dynamic>.from(payload['user'])
            : null;
        _selectedClientCartItems = payload['items'] is List
            ? List<Map<String, dynamic>>.from(payload['items'])
            : <Map<String, dynamic>>[];
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка корзины клиента: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _clientCartLoading = false);
      }
    }
  }

  Future<void> _editSelectedCartItem(Map<String, dynamic> item) async {
    final itemId = (item['id'] ?? '').toString().trim();
    if (itemId.isEmpty || _clientCartActionBusy || _clientCartUndoPending) {
      return;
    }
    final currentPrice = (item['custom_price'] ?? item['price'] ?? '')
        .toString()
        .trim();
    final currentDescription =
        (item['custom_description'] ?? item['description'] ?? '').toString();
    final nextPrice = await _askText(
      title: 'Цена для позиции',
      label: 'Введите цену (пусто = цена товара)',
      initial: currentPrice,
    );
    if (nextPrice == null) return;
    final nextDescription = await _askText(
      title: 'Описание для позиции',
      label: 'Введите описание (пусто = описание товара)',
      initial: currentDescription,
    );
    if (nextDescription == null) return;

    final normalizedPriceRaw = nextPrice.trim().replaceAll(',', '.');
    final parsedPrice = normalizedPriceRaw.isEmpty
        ? null
        : double.tryParse(normalizedPriceRaw);
    if (normalizedPriceRaw.isNotEmpty &&
        (parsedPrice == null || parsedPrice < 0)) {
      if (mounted) {
        setState(() => _message = 'Введите корректную цену');
      }
      return;
    }
    final normalizedDescription = nextDescription.trim().isEmpty
        ? null
        : nextDescription.trim();
    final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();

    final index = _selectedClientCartItems.indexWhere(
      (row) => (row['id'] ?? '').toString().trim() == itemId,
    );
    final previousItem = index >= 0
        ? Map<String, dynamic>.from(_selectedClientCartItems[index])
        : null;
    if (index >= 0 && mounted) {
      final optimistic = Map<String, dynamic>.from(
        _selectedClientCartItems[index],
      );
      optimistic['custom_price'] = parsedPrice;
      optimistic['custom_description'] = normalizedDescription;
      if (parsedPrice != null) {
        optimistic['price'] = parsedPrice;
        final qty = _toInt(optimistic['quantity'], fallback: 1);
        optimistic['line_total'] = parsedPrice * qty;
      }
      if (normalizedDescription != null) {
        optimistic['description'] = normalizedDescription;
      }
      setState(() => _selectedClientCartItems[index] = optimistic);
    }

    await _scheduleClientCartUndoAction(
      label: 'Изменение позиции корзины',
      rollback: previousItem == null || index < 0 || !mounted
          ? null
          : () {
              if (!mounted) return;
              if (!_isSelectedClientCartUser(userId)) return;
              final currentIndex = _selectedClientCartItems.indexWhere(
                (row) => (row['id'] ?? '').toString().trim() == itemId,
              );
              if (currentIndex < 0) return;
              setState(
                () => _selectedClientCartItems[currentIndex] = previousItem,
              );
            },
      commit: () async {
        await authService.dio.patch(
          '/api/cart/admin/cart-items/$itemId',
          data: {
            'custom_price': parsedPrice,
            'custom_description': normalizedDescription,
          },
        );
        await _reloadClientCartIfStillSelected(userId);
      },
    );
  }

  Future<void> _removeSelectedCartItem(Map<String, dynamic> item) async {
    final itemId = (item['id'] ?? '').toString().trim();
    final title = (item['title'] ?? 'Товар').toString().trim();
    if (itemId.isEmpty || _clientCartActionBusy || _clientCartUndoPending) {
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить позицию'),
        content: Text('Удалить "$title" из корзины клиента?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();
    final index = _selectedClientCartItems.indexWhere(
      (row) => (row['id'] ?? '').toString().trim() == itemId,
    );
    final removedItem = index >= 0
        ? Map<String, dynamic>.from(_selectedClientCartItems[index])
        : null;
    if (index >= 0 && mounted) {
      setState(() => _selectedClientCartItems.removeAt(index));
    }

    await _scheduleClientCartUndoAction(
      label: 'Удаление "$title"',
      rollback: removedItem == null || index < 0 || !mounted
          ? null
          : () {
              if (!mounted) return;
              if (!_isSelectedClientCartUser(userId)) return;
              final alreadyRestored = _selectedClientCartItems.any(
                (row) => (row['id'] ?? '').toString().trim() == itemId,
              );
              if (alreadyRestored) return;
              final safeIndex = index.clamp(0, _selectedClientCartItems.length);
              setState(
                () => _selectedClientCartItems.insert(
                  safeIndex.toInt(),
                  removedItem,
                ),
              );
            },
      commit: () async {
        await authService.dio.delete('/api/cart/admin/cart-items/$itemId');
        await _reloadClientCartIfStillSelected(userId);
      },
    );
  }

  Future<void> _clearSelectedClientCart() async {
    final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();
    if (userId.isEmpty || _clientCartActionBusy || _clientCartUndoPending) {
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Расформировать корзину'),
        content: const Text('Полностью очистить корзину выбранного клиента?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final previousItems = _selectedClientCartItems
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (mounted) {
      setState(() => _selectedClientCartItems = <Map<String, dynamic>>[]);
    }

    await _scheduleClientCartUndoAction(
      label: 'Расформирование корзины',
      rollback: !mounted
          ? null
          : () {
              if (!mounted) return;
              if (!_isSelectedClientCartUser(userId)) return;
              setState(() {
                _selectedClientCartItems = previousItems
                    .map((row) => Map<String, dynamic>.from(row))
                    .toList();
              });
            },
      commit: () async {
        await authService.dio.post(
          '/api/cart/admin/clients/$userId/cart/clear',
        );
        await _reloadClientCartIfStillSelected(userId);
      },
    );
  }

  String _cartRetentionUserIdOf(Map<String, dynamic> event) {
    final direct = (event['cart_owner_id'] ?? event['user_id'] ?? '')
        .toString()
        .trim();
    if (direct.isNotEmpty) return direct;
    final id = (event['id'] ?? '').toString().trim();
    const prefix = 'cart-retention:';
    if (id.startsWith(prefix)) return id.substring(prefix.length).trim();
    return '';
  }

  Future<void> _dismantleCartRetentionItem(Map<String, dynamic> event) async {
    final userId = _cartRetentionUserIdOf(event);
    final eventId = (event['id'] ?? 'cart-retention:$userId').toString().trim();
    if (userId.isEmpty || _cartRetentionBusyIds.contains(eventId)) return;

    final title = (event['title'] ?? 'Расформировать корзину').toString();
    final subtitle = (event['subtitle'] ?? '').toString();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Расформировать корзину'),
        content: Text(
          [
            title,
            if (subtitle.trim().isNotEmpty) subtitle.trim(),
            '',
            'Все товары из корзины клиента вернутся в доступные остатки.',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Расформировать'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _cartRetentionBusyIds.add(eventId);
      _message = '';
    });
    try {
      await authService.dio.post('/api/cart/admin/clients/$userId/cart/clear');
      await _loadSupportNotificationCenter(silent: true);
      final selectedId = (_selectedClientCartUser?['id'] ?? '')
          .toString()
          .trim();
      if (selectedId == userId) {
        await _loadSelectedClientCart(userId);
      }
      if (_clientCartSearchCtrl.text.trim().isNotEmpty) {
        await _searchClientCartsByPhone();
      }
      if (!mounted) return;
      setState(() => _message = 'Корзина расформирована');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка расформировки: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _cartRetentionBusyIds.remove(eventId));
      } else {
        _cartRetentionBusyIds.remove(eventId);
      }
    }
  }

  Future<void> _blockSelectedClient() async {
    final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();
    if (userId.isEmpty || _clientCartActionBusy || _clientCartUndoPending) {
      return;
    }
    final reason = await _askText(
      title: 'Блокировка клиента',
      label: 'Причина блокировки',
      initial: 'Вас заблокировали за нарушение правил',
    );
    if (reason == null || reason.trim().isEmpty) return;
    setState(() => _clientCartActionBusy = true);
    try {
      await authService.dio.post(
        '/api/cart/admin/clients/$userId/block',
        data: {'reason': reason.trim()},
      );
      await _loadSelectedClientCart(userId);
      await _searchClientCartsByPhone();
      if (!mounted) return;
      setState(() => _message = 'Клиент заблокирован');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка блокировки: ${_extractDioError(e)}');
    } finally {
      if (mounted) setState(() => _clientCartActionBusy = false);
    }
  }

  Future<void> _markSelectedClientSelfPickup() async {
    final userId = (_selectedClientCartUser?['id'] ?? '').toString().trim();
    if (userId.isEmpty || _clientCartActionBusy || _clientCartUndoPending) {
      return;
    }
    final note = await _askText(
      title: 'Самовывоз сегодня',
      label: 'Короткая заметка для истории',
      initial: 'Самовывоз сегодня',
    );
    if (note == null || note.trim().isEmpty) return;
    setState(() => _clientCartActionBusy = true);
    try {
      await authService.dio.post(
        '/api/cart/admin/clients/$userId/self-pickup',
        data: {'note': note.trim()},
      );
      await _loadSelectedClientCart(userId);
      if (!mounted) return;
      setState(() => _message = 'Самовывоз отмечен');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка самовывоза: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _clientCartActionBusy = false);
      } else {
        _clientCartActionBusy = false;
      }
    }
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
          if (kind == 'finance_summary') 'period': _financePeriod,
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
    return '${n.toStringAsFixed(2)} ₽';
  }

  String _formatDateTimeLabel(dynamic raw) {
    return formatDateTimeValue(raw, fallback: '');
  }

  bool get _canPrintDeliverySticker {
    final role = authService.effectiveRole.toLowerCase().trim();
    return isStickerPrintSupported && (role == 'admin' || role == 'creator');
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
    final pendingCustomers =
        routes['_pending'] ?? const <Map<String, dynamic>>[];

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
                        userAgentPackageName: 'projectphoenix',
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
                      'Карта доставки готова.\n'
                      'Точки и линии появятся после подтверждения адресов.\n'
                      '${originAddress.isNotEmpty ? 'Старт: $originAddress' : 'Старт пока не задан, используется точка по умолчанию.'}',
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
            if (pendingCustomers.isNotEmpty)
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
                  'Без маршрута: ${pendingCustomers.length}',
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
          'Карта доставки для текущего листа. Маршрут начинается от точки отправки, старается делить доставки поровну и уменьшать пересечения. Нажми на точку клиента, чтобы перекинуть его на другого курьера.',
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

  String _clientCartStatusLabel(String raw) {
    switch (raw.trim()) {
      case 'pending_processing':
        return 'В обработке';
      case 'processed':
        return 'Обработано';
      case 'preparing_delivery':
        return 'Готовится к доставке';
      case 'handing_to_courier':
        return 'Передаётся курьеру';
      case 'in_delivery':
        return 'В доставке';
      case 'delivered':
        return 'Доставлено';
      case 'cancelled':
        return 'Отменено';
      default:
        return raw.trim().isEmpty ? '—' : raw.trim();
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
          _deliveryEligiblePreview = null;
          _deliveryEligiblePreviewPage = 0;
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
        final deliveryCityRates = settings['city_rates'] is List
            ? List<Map<String, dynamic>>.from(settings['city_rates'])
            : <Map<String, dynamic>>[];
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
            _deliveryEligiblePreview = payload['eligible_preview'] is Map
                ? Map<String, dynamic>.from(payload['eligible_preview'])
                : null;
            _deliveryOriginLabel = originLabel;
            _deliveryCityRates = deliveryCityRates;
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
            _deliveryEligiblePreview = null;
            _deliveryEligiblePreviewPage = 0;
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

  Future<void> _processDeliveryManualPhones() async {
    final rawPhones = _deliveryManualPhonesCtrl.text.trim();
    if (rawPhones.isEmpty) {
      showAppNotice(
        context,
        'Введите номера клиентов',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    setState(() {
      _deliveryManualPhonesBusy = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/delivery/manual-processing-by-phones',
        data: {'phones_text': rawPhones},
      );
      final data = resp.data;
      final payload = data is Map && data['ok'] == true && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      if (!mounted) return;
      final processedCount = _toInt(payload['processed_count']);
      final skippedCount = _toInt(payload['skipped_count']);
      setState(() {
        _deliveryManualPhonesResult = payload;
        _message =
            'Ручная обработка: обработано $processedCount товаров'
            '${skippedCount > 0 ? ', пропущено $skippedCount номеров' : ''}';
      });
      unawaited(_loadDeliveryDashboard());
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка ручной обработки: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _deliveryManualPhonesBusy = false);
      }
    }
  }

  Widget _buildDeliveryManualPhonesCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ручная выгрузка клиентов по номерам',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Вставьте полные номера клиентов, каждый с новой строки. Все найденные необработанные товары будут отмечены как обработанные вручную.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deliveryManualPhonesCtrl,
              minLines: 5,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  labelText: 'Номера клиентов',
                  hintText: '89325429858\n89228000795\n89879804451',
                  border: OutlineInputBorder(),
                ),
                controller: _deliveryManualPhonesCtrl,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _deliveryManualPhonesBusy
                      ? null
                      : _processDeliveryManualPhones,
                  icon: _deliveryManualPhonesBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fact_check_outlined),
                  label: Text(
                    _deliveryManualPhonesBusy
                        ? 'Обработка...'
                        : 'Обработать по номерам',
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _deliveryManualPhonesBusy
                      ? null
                      : () {
                          setState(() {
                            _deliveryManualPhonesCtrl.clear();
                            _deliveryManualPhonesResult = null;
                          });
                        },
                  icon: const Icon(Icons.clear_outlined),
                  label: const Text('Очистить'),
                ),
              ],
            ),
            _buildDeliveryManualPhonesResult(),
          ],
        ),
      ),
    );
  }

  Widget _buildDeliveryManualPhonesResult() {
    final result = _deliveryManualPhonesResult;
    if (result == null || result.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final clients = _asMapList(result['clients']);
    if (clients.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'Результат',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        ...clients.map((client) {
          final products = _asMapList(client['products']);
          final found = client['found'] == true;
          final hasProducts = products.isNotEmpty;
          final phone = (client['phone'] ?? client['raw_phone'] ?? '')
              .toString()
              .trim();
          final clientName = (client['client_name'] ?? 'Клиент').toString();
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.45,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasProducts
                          ? Icons.check_circle_outline
                          : found
                          ? Icons.info_outline
                          : Icons.person_off_outlined,
                      color: hasProducts
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        found ? '$clientName • $phone' : 'Не найден • $phone',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Chip(
                      label: Text(
                        hasProducts
                            ? 'Обработано: ${products.length}'
                            : found
                            ? 'Пропущено: нет товаров'
                            : 'Пропущено: нет клиента',
                      ),
                    ),
                  ],
                ),
                if (found && products.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Необработанных товаров у клиента нет.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ] else if (products.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...products.map(_buildDeliveryManualPhoneProductTile),
                ],
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDeliveryManualPhoneProductTile(Map<String, dynamic> product) {
    final theme = Theme.of(context);
    final imageUrl = _resolveImageUrl((product['image_url'] ?? '').toString());
    final productCode = product['product_code'];
    final shelfNumber = product['product_shelf_number'];
    final title = (product['title'] ?? 'Товар').toString();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 62,
              height: 62,
              child: imageUrl == null
                  ? Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : AdaptiveNetworkImage(imageUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Chip(label: Text('ID товара: ${productCode ?? '—'}')),
                    Chip(label: Text('Полка: ${shelfNumber ?? '—'}')),
                    const Chip(label: Text('Ручное')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        return 'Общий вопрос';
    }
  }

  String _supportStatusLabel(String raw, {bool hasAssignee = false}) {
    switch (raw.trim().toLowerCase()) {
      case 'waiting_customer':
        return 'Ждём ваш ответ';
      case 'resolved':
        return 'Решено';
      case 'archived':
        return 'Закрыто';
      case 'open':
        return hasAssignee ? 'В работе' : 'Новая заявка';
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
      Response<dynamic>? queueResp;
      try {
        queueResp = await authService.dio.get('/api/support/tickets/queue');
      } on DioException catch (e) {
        if (e.response?.statusCode != 403) rethrow;
      }
      final activeResp = await authService.dio.get(
        '/api/support/tickets',
        queryParameters: {'status': 'open,waiting_customer,resolved'},
      );
      final archivedResp = await authService.dio.get(
        '/api/support/tickets',
        queryParameters: {'status': 'archived', 'include_archived': 1},
      );

      final queueData = queueResp?.data;
      final activeData = activeResp.data;
      final archivedData = archivedResp.data;
      if (!mounted) return;
      setState(() {
        _supportPendingTickets =
            queueData is Map &&
                queueData['ok'] == true &&
                queueData['data'] is List
            ? List<Map<String, dynamic>>.from(queueData['data'])
            : [];
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

  Future<void> _loadSupportNotificationCenter({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _supportNotificationsLoading = true);
    } else {
      _supportNotificationsLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/notifications/center',
        queryParameters: {'limit': 60},
      );
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        final payload = data is Map && data['ok'] == true && data['data'] is Map
            ? Map<String, dynamic>.from(data['data'])
            : <String, dynamic>{};
        _supportNotificationSummary = payload['summary'] is Map
            ? Map<String, dynamic>.from(payload['summary'])
            : <String, dynamic>{};
        _supportNotificationItems = payload['items'] is List
            ? List<Map<String, dynamic>>.from(payload['items'])
            : <Map<String, dynamic>>[];
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка центра уведомлений: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _supportNotificationsLoading = false);
      } else {
        _supportNotificationsLoading = false;
      }
    }
  }

  Future<void> _loadReturnsAnalytics({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _returnsAnalyticsLoading = true);
    } else {
      _returnsAnalyticsLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/returns/analytics',
        queryParameters: {'days': 30, 'top_limit': 8},
      );
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        _returnsAnalytics =
            data is Map && data['ok'] == true && data['data'] is Map
            ? Map<String, dynamic>.from(data['data'])
            : <String, dynamic>{};
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка аналитики возвратов: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _returnsAnalyticsLoading = false);
      } else {
        _returnsAnalyticsLoading = false;
      }
    }
  }

  Future<void> _loadDefectStats({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _defectStatsLoading = true);
    } else {
      _defectStatsLoading = true;
    }
    try {
      final resp = await authService.dio.get('/api/admin/defects/stats');
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        _defectStats = data is Map && data['ok'] == true
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка статистики брака: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _defectStatsLoading = false);
      } else {
        _defectStatsLoading = false;
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

  Future<void> _claimSupportTicket(Map<String, dynamic> ticket) async {
    final ticketId = (ticket['id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    if (_supportClaimBusyTicketIds.contains(ticketId)) return;
    setState(() {
      _supportClaimBusyTicketIds.add(ticketId);
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/support/tickets/$ticketId/claim',
      );
      final data = resp.data;
      await _loadSupportTickets(silent: true);
      await _loadSupportNotificationCenter(silent: true);
      if (!mounted) return;
      setState(() => _message = 'Вопрос взят в работу');

      final chatId = data is Map && data['ok'] == true && data['data'] is Map
          ? ((data['data']['chat_id'] ?? '').toString().trim())
          : '';
      if (chatId.isNotEmpty) {
        var updatedTicket = <String, dynamic>{
          ...ticket,
          'chat_id': chatId,
          'assignee_id': authService.currentUser?.id,
          'status': 'open',
        };
        for (final item in _supportActiveTickets) {
          if ((item['id'] ?? '').toString().trim() == ticketId) {
            updatedTicket = item;
            break;
          }
        }
        await _openSupportChat(updatedTicket);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка назначения: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportClaimBusyTicketIds.remove(ticketId));
      } else {
        _supportClaimBusyTicketIds.remove(ticketId);
      }
    }
  }

  Future<void> _resolveSupportTicket(Map<String, dynamic> ticket) async {
    final ticketId = (ticket['id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    if (_supportFinishBusyTicketIds.contains(ticketId)) return;
    setState(() {
      _supportFinishBusyTicketIds.add(ticketId);
      _message = '';
    });
    try {
      await authService.dio.post('/api/support/tickets/$ticketId/resolve');
      await _loadSupportTickets(silent: true);
      await _loadSupportNotificationCenter(silent: true);
      unawaited(refreshSupportQueueNotices());
      if (!mounted) return;
      setState(() => _message = 'Обращение отмечено как решённое');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка завершения: ${_extractDioError(e)}');
    } finally {
      if (mounted) {
        setState(() => _supportFinishBusyTicketIds.remove(ticketId));
      } else {
        _supportFinishBusyTicketIds.remove(ticketId);
      }
    }
  }

  Future<void> _archiveSupportTicket(
    Map<String, dynamic> ticket, {
    bool force = false,
  }) async {
    final ticketId = (ticket['id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    if (_supportFinishBusyTicketIds.contains(ticketId)) return;
    setState(() {
      _supportArchiveBusy = true;
      _supportFinishBusyTicketIds.add(ticketId);
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/support/tickets/$ticketId/archive',
        data: {
          'reason': force ? 'forced_admin_archive' : 'assignee_finished',
          if (force) 'force': true,
        },
      );
      await _loadSupportTickets(silent: true);
      await _loadSupportNotificationCenter(silent: true);
      unawaited(refreshSupportQueueNotices());
      if (!mounted) return;
      setState(() => _message = 'Диалог закончен');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Ошибка архива поддержки: ${_extractDioError(e)}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _supportArchiveBusy = false;
          _supportFinishBusyTicketIds.remove(ticketId);
        });
      } else {
        _supportArchiveBusy = false;
        _supportFinishBusyTicketIds.remove(ticketId);
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
      'support_ticket_status': (ticket['status'] ?? '').toString().trim(),
      'support_archived':
          (ticket['status'] ?? '').toString().trim().toLowerCase() ==
          'archived',
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

  Future<void> _openSupportNotificationItem(Map<String, dynamic> event) async {
    final ticketId = (event['id'] ?? '').toString().trim();
    final chatId = (event['chat_id'] ?? '').toString().trim();
    if (chatId.isEmpty) return;
    final settings = _asMap(event['chat_settings']);
    final status = (event['status'] ?? '').toString().trim().toLowerCase();
    final normalizedSettings = <String, dynamic>{
      ...settings,
      'kind': settings['kind'] ?? 'support_ticket',
      'support_ticket': true,
      'support_ticket_status': status,
      'support_archived': status == 'archived',
      if (ticketId.isNotEmpty)
        'support_ticket_id': settings['support_ticket_id'] ?? ticketId,
    };
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId,
          chatTitle: (event['related_name'] ?? event['title'] ?? 'Поддержка')
              .toString(),
          chatType: (event['chat_type'] ?? 'private').toString(),
          chatSettings: normalizedSettings,
        ),
      ),
    );
  }

  Future<void> _openDirectChatWithUser(Map<String, dynamic> claim) async {
    final userId = (claim['user_id'] ?? claim['customer_id'] ?? '')
        .toString()
        .trim();
    final currentUserId = authService.currentUser?.id.trim() ?? '';
    if (userId.isNotEmpty &&
        currentUserId.isNotEmpty &&
        userId == currentUserId) {
      showAppNotice(
        context,
        'Это ваша заявка. ЛС с самим собой не открывается.',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final customerEmail = (claim['customer_email'] ?? '').toString().trim();
    final customerPhone = (claim['customer_phone'] ?? '').toString().trim();
    final fallbackQuery = customerPhone.isNotEmpty
        ? customerPhone
        : customerEmail;
    if (userId.isEmpty && fallbackQuery.isEmpty) {
      showAppNotice(
        context,
        'Не удалось определить клиента для открытия ЛС',
        tone: AppNoticeTone.error,
      );
      return;
    }
    try {
      Response<dynamic> resp;
      try {
        resp = await authService.dio.post(
          '/api/chats/direct/open',
          data: userId.isNotEmpty
              ? {'user_id': userId}
              : {'query': fallbackQuery},
        );
      } on DioException catch (e) {
        final statusCode = e.response?.statusCode ?? 0;
        if (statusCode == 404 &&
            userId.isNotEmpty &&
            fallbackQuery.isNotEmpty) {
          resp = await authService.dio.post(
            '/api/chats/direct/open',
            data: {'query': fallbackQuery},
          );
        } else {
          rethrow;
        }
      }
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
    final canEditPricing = _canEditDeliveryPricing();
    final threshold = int.tryParse(_deliveryThresholdCtrl.text.trim());
    if (canEditPricing && (threshold == null || threshold < 0)) {
      setState(() => _message = 'Введите корректную сумму для доставки');
      return;
    }
    final originAddress = _deliveryOriginCtrl.text.trim();
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      final payload = <String, dynamic>{
        'route_origin_label': _deliveryOriginLabel,
        'route_origin_address': originAddress,
      };
      if (canEditPricing) {
        payload['threshold_amount'] = threshold;
        payload['city_rates'] = _deliveryCityRates;
      }
      await authService.dio.patch(
        '/api/admin/delivery/settings',
        data: payload,
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Настройки доставки сохранены');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка настроек: ${_extractDioError(e)}');
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
    final canEditPricing = _canEditDeliveryPricing();
    final threshold = int.tryParse(_deliveryThresholdCtrl.text.trim());
    if (canEditPricing && (threshold == null || threshold < 0)) {
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
        data: {if (canEditPricing) 'threshold_amount': threshold},
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

  Future<Map<String, dynamic>?> _askDeliveryDecisionData({
    required String initialAddress,
    required String initialEntrance,
    required String initialComment,
    required String initialAfter,
    required String initialBefore,
    required String title,
  }) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => DeliveryAddressPickerDialog(
        title: title,
        initialAddressText: initialAddress,
        initialEntrance: initialEntrance,
        initialComment: initialComment,
        initialPreferredTimeFrom: initialAfter,
        initialPreferredTimeTo: initialBefore,
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
    String entrance = '';
    String comment = '';
    double? lat;
    double? lng;
    String? provider;
    String? providerAddressId;
    Map<String, dynamic>? addressStructured;
    bool confirmSelection = false;
    if (accepted) {
      final result = await _askDeliveryDecisionData(
        initialAddress: (customer['address_text'] ?? '').toString(),
        initialEntrance: (customer['entrance'] ?? '').toString(),
        initialComment: (customer['comment'] ?? '').toString(),
        initialAfter: ((customer['preferred_time_from'] ?? '').toString())
            .replaceAll(':00.000000', '')
            .replaceAll(':00', ''),
        initialBefore: ((customer['preferred_time_to'] ?? '').toString())
            .replaceAll(':00.000000', '')
            .replaceAll(':00', ''),
        title: 'Адрес доставки',
      );
      if (result == null || (result['address_text'] ?? '').isEmpty) return;
      addressText = (result['address_text'] ?? '').toString().trim();
      preferredTimeFrom = (result['preferred_time_from'] ?? '')
          .toString()
          .trim();
      preferredTimeTo = (result['preferred_time_to'] ?? '').toString().trim();
      entrance = (result['entrance'] ?? '').toString().trim();
      comment = (result['comment'] ?? '').toString().trim();
      lat = (result['lat'] is num) ? (result['lat'] as num).toDouble() : null;
      lng = (result['lng'] is num) ? (result['lng'] as num).toDouble() : null;
      provider = (result['provider'] ?? '').toString().trim().isEmpty
          ? null
          : (result['provider'] ?? '').toString().trim();
      providerAddressId =
          (result['provider_address_id'] ?? '').toString().trim().isEmpty
          ? null
          : (result['provider_address_id'] ?? '').toString().trim();
      addressStructured = result['address_structured'] is Map
          ? Map<String, dynamic>.from(result['address_structured'] as Map)
          : null;
      confirmSelection = result['confirm_selection'] == true;
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
          if (accepted && lat != null) 'lat': lat,
          if (accepted && lng != null) 'lng': lng,
          if (accepted && entrance.isNotEmpty) 'entrance': entrance,
          if (accepted && comment.isNotEmpty) 'comment': comment,
          if (accepted && provider != null) 'provider': provider,
          if (accepted && providerAddressId != null)
            'provider_address_id': providerAddressId,
          if (accepted && addressStructured != null)
            'address_structured': addressStructured,
          if (accepted && confirmSelection) 'confirm_selection': true,
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

  String _deliveryAssemblyStatusLabel(String raw) {
    switch (raw.trim()) {
      case 'assembling':
        return 'Собирается';
      case 'assembled':
        return 'Собрано';
      case 'issue':
        return 'Есть проблема';
      case 'not_started':
      default:
        return 'Не начато';
    }
  }

  Future<Map<String, dynamic>?> _askDeliveryAssemblyData(
    Map<String, dynamic> customer,
  ) async {
    final rawItems = _asMapList(customer['items']);
    final rows = rawItems.map((item) {
      final manualShelf = (item['manual_shelf_label'] ?? '').toString().trim();
      final shelfFloor = (item['shelf_floor'] ?? '').toString().trim();
      final productShelf = _toInt(
        item['product_shelf_number'] ?? item['shelf_number'],
        fallback: 0,
      );
      final shelfLabel = [
        if (manualShelf.isNotEmpty) manualShelf,
        if (manualShelf.isEmpty && productShelf > 0)
          'Полка ${productShelf.toString().padLeft(2, '0')}',
        if (shelfFloor.isNotEmpty) 'этаж $shelfFloor',
      ].join(' · ');
      final assemblyStatus = (item['assembly_status'] ?? 'pending')
          .toString()
          .trim();
      return <String, dynamic>{
        'id': (item['id'] ?? '').toString(),
        'title': (item['product_title'] ?? 'Товар').toString(),
        'description': (item['product_description'] ?? '').toString(),
        'image_url': (item['product_image_url'] ?? '').toString(),
        'code': item['product_code'],
        'shelf_label': shelfLabel,
        'quantity': _toInt(item['quantity'], fallback: 1),
        'line_total': item['line_total'],
        'collected': assemblyStatus == 'collected',
        'is_bulky': item['is_bulky'] == true,
        'removed': assemblyStatus == 'removed',
        'removed_reason': (item['removed_reason'] ?? '').toString(),
        'bulky_note': (item['bulky_note'] ?? item['product_title'] ?? '')
            .toString(),
      };
    }).toList();
    final reasonCtrls = <String, TextEditingController>{};
    final bulkyCtrls = <String, TextEditingController>{};
    for (final row in rows) {
      final id = row['id'].toString();
      reasonCtrls[id] = TextEditingController(
        text: row['removed_reason'].toString(),
      );
      bulkyCtrls[id] = TextEditingController(
        text: row['bulky_note'].toString(),
      );
    }

    try {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Сборка корзины'),
              content: SizedBox(
                width: 720,
                height: math.min<double>(
                  MediaQuery.of(ctx).size.height * 0.72,
                  620,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final id = row['id'].toString();
                          final removed = row['removed'] == true;
                          final collected = row['collected'] == true;
                          final isBulky = row['is_bulky'] == true;
                          final imageUrl = row['image_url'].toString().trim();
                          final description = row['description']
                              .toString()
                              .trim();
                          final shelfLabel = row['shelf_label']
                              .toString()
                              .trim();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: imageUrl.isEmpty
                                          ? Container(
                                              width: 54,
                                              height: 54,
                                              color: Theme.of(ctx)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              child: const Icon(
                                                Icons
                                                    .image_not_supported_outlined,
                                              ),
                                            )
                                          : Image.network(
                                              imageUrl,
                                              width: 54,
                                              height: 54,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => Container(
                                                    width: 54,
                                                    height: 54,
                                                    color: Theme.of(ctx)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                                    child: const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                    ),
                                                  ),
                                            ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${row['title']} · ${_formatMoney(row['line_total'])}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            'ID: ${row['code'] ?? '—'} · Кол-во: ${row['quantity']}',
                                          ),
                                          if (shelfLabel.isNotEmpty)
                                            Text('Полка: $shelfLabel'),
                                          if (description.isNotEmpty)
                                            Text(
                                              description,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: collected,
                                  onChanged: removed
                                      ? null
                                      : (value) => setDialogState(() {
                                          row['collected'] = value == true;
                                          if (value == true) {
                                            row['removed'] = false;
                                          }
                                        }),
                                  title: const Text('Положил'),
                                  subtitle: const Text(
                                    'Товар физически найден и положен в пакет клиента',
                                  ),
                                ),
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: isBulky,
                                  onChanged: removed || !collected
                                      ? null
                                      : (value) => setDialogState(
                                          () => row['is_bulky'] = value == true,
                                        ),
                                  title: const Text('Габарит'),
                                  subtitle: const Text(
                                    'Напечатается габаритный стикер с названием и ценой товара',
                                  ),
                                ),
                                if (isBulky && !removed)
                                  TextField(
                                    controller: bulkyCtrls[id],
                                    decoration: withInputLanguageBadge(
                                      const InputDecoration(
                                        labelText: 'Что за габарит',
                                        border: OutlineInputBorder(),
                                      ),
                                      controller: bulkyCtrls[id],
                                    ),
                                  ),
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: removed,
                                  onChanged: (value) => setDialogState(() {
                                    row['removed'] = value == true;
                                    if (value == true) {
                                      row['is_bulky'] = false;
                                      row['collected'] = false;
                                    }
                                  }),
                                  title: const Text('Ненаход / убрать'),
                                  subtitle: const Text(
                                    'Товар уйдет в статистику брака/потерь, сумма пересчитается',
                                  ),
                                ),
                                if (removed)
                                  TextField(
                                    controller: reasonCtrls[id],
                                    minLines: 1,
                                    maxLines: 3,
                                    decoration: withInputLanguageBadge(
                                      const InputDecoration(
                                        labelText: 'Причина',
                                        hintText: 'Сломан, потерян, брак...',
                                        border: OutlineInputBorder(),
                                      ),
                                      controller: reasonCtrls[id],
                                    ),
                                  ),
                              ],
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
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop({
                      'items': rows.map((row) {
                        final id = row['id'].toString();
                        return {
                          'id': id,
                          'collected': row['collected'] == true,
                          'assembly_status': row['removed'] == true
                              ? 'removed'
                              : row['collected'] == true
                              ? 'collected'
                              : 'pending',
                          'is_bulky': row['is_bulky'] == true,
                          'removed': row['removed'] == true,
                          'bulky_note': bulkyCtrls[id]?.text.trim() ?? '',
                          'removed_reason': reasonCtrls[id]?.text.trim() ?? '',
                        };
                      }).toList(),
                    });
                  },
                  child: const Text('Сохранить сборку'),
                ),
              ],
            );
          },
        ),
      );
      return result;
    } finally {
      for (final ctrl in reasonCtrls.values) {
        ctrl.dispose();
      }
      for (final ctrl in bulkyCtrls.values) {
        ctrl.dispose();
      }
    }
  }

  Future<int?> _askDeliveryPackagePlacesData(
    Map<String, dynamic> customer,
  ) async {
    final packageCtrl = TextEditingController(
      text: _toInt(customer['package_places'], fallback: 1).toString(),
    );
    try {
      return await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Сколько мест в доставке?'),
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: packageCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Количество мест всего',
                helperText:
                    'Пакеты + габариты. Первый обычный стикер уже напечатан при старте сборки.',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final places = int.tryParse(packageCtrl.text.trim()) ?? 0;
                if (places <= 0) return;
                Navigator.of(ctx).pop(places);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      );
    } finally {
      packageCtrl.dispose();
    }
  }

  Future<void> _startDeliveryAssembly(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для сборки доставки',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (batchId.trim().isEmpty || customerId.isEmpty) return;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/assembly/start',
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() {
          _message = 'Сборка начата. Первый стикер отправлен на печать';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка старта сборки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _deliverySaving = false);
    }
  }

  Future<void> _editDeliveryAssembly(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для сборки доставки',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (batchId.trim().isEmpty || customerId.isEmpty) return;
    final payload = await _askDeliveryAssemblyData(customer);
    if (payload == null) return;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/assembly',
        data: payload,
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Сборка обновлена');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка сборки: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) setState(() => _deliverySaving = false);
    }
  }

  Future<void> _completeDeliveryAssembly(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
    if (!_ensurePermission(
      'delivery.manage',
      'Недостаточно прав для завершения сборки',
    )) {
      return;
    }
    final customerId = (customer['id'] ?? '').toString().trim();
    if (batchId.trim().isEmpty || customerId.isEmpty) return;
    final packagePlaces = await _askDeliveryPackagePlacesData(customer);
    if (packagePlaces == null) return;
    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/$customerId/assembly/complete',
        data: {'package_places': packagePlaces},
      );
      await _loadDeliveryDashboard();
      if (mounted) {
        setState(() => _message = 'Корзина собрана');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка завершения сборки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _deliverySaving = false);
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
                      hintText: 'Город, улица, дом, подъезд',
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
    if (!mounted) return;

    final addressPayload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => DeliveryAddressPickerDialog(
        title: 'Адрес доставки',
        initialAddressText: (payload['address_text'] ?? '').toString(),
        initialPreferredTimeFrom: (payload['preferred_time_from'] ?? '')
            .toString(),
        initialPreferredTimeTo: (payload['preferred_time_to'] ?? '').toString(),
      ),
    );
    if (addressPayload == null) return;
    final nextPayload = <String, dynamic>{...payload, ...addressPayload};

    setState(() {
      _deliverySaving = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/delivery/batches/$batchId/customers/manual-add',
        data: nextPayload,
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

  String _normalizeDeliveryCityName(dynamic raw) {
    return (raw ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _editDeliveryCityRate([Map<String, dynamic>? existing]) async {
    final cityCtrl = TextEditingController(
      text: _normalizeDeliveryCityName(existing?['city']),
    );
    final thresholdCtrl = TextEditingController(
      text: _toDouble(existing?['threshold_amount']).toStringAsFixed(0),
    );
    bool active = existing?['is_active'] != false;

    try {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: Text(existing == null ? 'Добавить город' : 'Город'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: cityCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Город',
                          border: OutlineInputBorder(),
                        ),
                        controller: cityCtrl,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: thresholdCtrl,
                      keyboardType: TextInputType.number,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Порог доставки',
                          suffixText: '₽',
                          border: OutlineInputBorder(),
                        ),
                        controller: thresholdCtrl,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: active,
                      title: const Text('Расценка включена'),
                      onChanged: (value) =>
                          setDialogState(() => active = value),
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
                  onPressed: () {
                    final city = _normalizeDeliveryCityName(cityCtrl.text);
                    final threshold = _toDouble(
                      thresholdCtrl.text.replaceAll(',', '.'),
                      fallback: -1,
                    );
                    if (city.length < 2 || threshold < 0) {
                      return;
                    }
                    Navigator.of(ctx).pop({
                      'city': city,
                      'threshold_amount': threshold,
                      'delivery_fee_amount': 0,
                      'is_active': active,
                    });
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          );
        },
      );
      if (result == null || !mounted) return;
      final cityKey = _normalizeDeliveryCityName(result['city']).toLowerCase();
      if (cityKey.isEmpty) return;
      setState(() {
        final next = List<Map<String, dynamic>>.from(_deliveryCityRates);
        final index = next.indexWhere(
          (rate) =>
              _normalizeDeliveryCityName(rate['city']).toLowerCase() == cityKey,
        );
        if (index >= 0) {
          next[index] = result;
        } else {
          next.add(result);
        }
        next.sort(
          (a, b) => _normalizeDeliveryCityName(
            a['city'],
          ).compareTo(_normalizeDeliveryCityName(b['city'])),
        );
        _deliveryCityRates = next;
      });
    } finally {
      cityCtrl.dispose();
      thresholdCtrl.dispose();
    }
  }

  void _removeDeliveryCityRate(Map<String, dynamic> rate) {
    final cityKey = _normalizeDeliveryCityName(rate['city']).toLowerCase();
    if (cityKey.isEmpty) return;
    setState(() {
      _deliveryCityRates = _deliveryCityRates
          .where(
            (item) =>
                _normalizeDeliveryCityName(item['city']).toLowerCase() !=
                cityKey,
          )
          .toList();
    });
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
    bool keepOriginalFile = false,
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
    if (!mounted) return null;

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
                                      child: Image.memory(
                                        sourceBytes,
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
                          final renderedWidth = source.width * baseScale * zoom;
                          final renderedHeight =
                              source.height * baseScale * zoom;
                          final maxX = math.max(
                            0.0,
                            (renderedWidth - cutoutSize) / 2,
                          );
                          final maxY = math.max(
                            0.0,
                            (renderedHeight - cutoutSize) / 2,
                          );
                          final resolvedFocusX = maxX <= 0
                              ? 0.0
                              : (offset.dx / maxX).clamp(-1.0, 1.0).toDouble();
                          final resolvedFocusY = maxY <= 0
                              ? 0.0
                              : (offset.dy / maxY).clamp(-1.0, 1.0).toDouble();

                          if (keepOriginalFile) {
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop(
                              _AvatarPlacementResult(
                                focusX: resolvedFocusX,
                                focusY: resolvedFocusY,
                                zoom: zoom,
                              ),
                            );
                            return;
                          }
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
                              _AvatarPlacementResult(
                                croppedPath: croppedPath,
                                focusX: 0,
                                focusY: 0,
                                zoom: 1,
                              ),
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
    final settings = _settingsOf(channel);
    final systemKey = (settings['system_key'] ?? '').toString().trim();
    final isSystemChannel = systemKey.isNotEmpty;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (picked == null || picked.files.isEmpty) return;
    final pickedFile = picked.files.single;

    if (kIsWeb) {
      final bytes = pickedFile.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          setState(() => _message = 'Не удалось прочитать выбранный файл');
        }
        return;
      }
      setState(() {
        _avatarUpdating = true;
        _message = '';
      });
      try {
        final fileName = pickedFile.name.trim().isNotEmpty
            ? pickedFile.name.trim()
            : 'channel-avatar.jpg';
        final form = FormData.fromMap({
          'avatar': MultipartFile.fromBytes(bytes, filename: fileName),
        });
        final resp = await authService.dio.post(
          '/api/admin/channels/$channelId/avatar',
          data: form,
        );
        _emitChatUpdatedIfPresent(resp.data);

        // Системные каналы защищены по PATCH-роуту; сам avatar_url уже сохранён POST-роутом.
        if (!isSystemChannel) {
          await authService.dio.patch(
            '/api/admin/channels/$channelId',
            data: {'avatar_focus_x': 0, 'avatar_focus_y': 0, 'avatar_zoom': 1},
          );
        }

        await _loadChannels();
        await _loadChannelOverview(channelId, force: true, silent: true);
        if (mounted) {
          setState(() => _message = 'Аватарка канала обновлена');
        }
      } catch (e) {
        if (mounted) {
          setState(
            () => _message = 'Ошибка загрузки аватарки: ${_extractDioError(e)}',
          );
        }
      } finally {
        if (mounted) setState(() => _avatarUpdating = false);
      }
      return;
    }

    final path = pickedFile.path;
    if (path == null || path.isEmpty) {
      if (mounted) {
        setState(() => _message = 'Не удалось получить путь к файлу');
      }
      return;
    }

    final selectedName = (pickedFile.name).toLowerCase().trim();
    final isGif = selectedName.endsWith('.gif');
    final placement = await _showAvatarPlacementDialog(
      filePath: path,
      initialFocusX: _toFocus(settings['avatar_focus_x']),
      initialFocusY: _toFocus(settings['avatar_focus_y']),
      initialZoom: _toAvatarZoom(settings['avatar_zoom']),
      keepOriginalFile: isGif,
    );
    if (placement == null) return;

    setState(() {
      _avatarUpdating = true;
      _message = '';
    });
    try {
      final uploadPath = placement.croppedPath ?? path;
      final fileName = uploadPath.split(Platform.pathSeparator).last;
      final form = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(uploadPath, filename: fileName),
      });
      final resp = await authService.dio.post(
        '/api/admin/channels/$channelId/avatar',
        data: form,
      );
      _emitChatUpdatedIfPresent(resp.data);

      final focusX = isGif ? placement.focusX : 0;
      final focusY = isGif ? placement.focusY : 0;
      final avatarZoom = isGif ? placement.zoom : 1;
      if (!isSystemChannel) {
        await authService.dio.patch(
          '/api/admin/channels/$channelId',
          data: {
            'avatar_focus_x': focusX,
            'avatar_focus_y': focusY,
            'avatar_zoom': avatarZoom,
          },
        );
      }

      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) {
        setState(
          () => _message = isGif
              ? 'GIF-аватарка канала обновлена'
              : 'Аватарка канала обновлена',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки аватарки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUpdating = false);
      if (placement.croppedPath != null) {
        try {
          await File(placement.croppedPath!).delete();
        } catch (_) {}
      }
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

  String _displayPhone(String raw, {String fallback = '—'}) {
    final formatted = PhoneUtils.formatForDisplay(raw);
    if (formatted.isNotEmpty) return formatted;
    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : fallback;
  }

  Future<void> _printDeliveryCustomerSticker(
    Map<String, dynamic> customer,
  ) async {
    final phone = _displayPhone(
      (customer['customer_phone'] ?? '').toString().trim(),
      fallback: '',
    );
    final name = (customer['customer_name'] ?? 'Клиент').toString().trim();
    if (!_canPrintDeliverySticker) {
      showAppNotice(
        context,
        'Печать доступна только на десктоп-сайте под ролью админа или создателя',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    if (phone.isEmpty) {
      showAppNotice(
        context,
        'У клиента нет телефона для наклейки',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    try {
      await printStickerJob(
        StickerPrintJob(
          phone: phone,
          name: name.isEmpty ? 'Клиент' : name,
          showFooter: true,
          footerText: 'Феникс',
        ),
      );
      if (!mounted) return;
      showAppNotice(
        context,
        'Меню печати клиентской наклейки открыто',
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось открыть печать: $e',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _publishPendingPosts() async {
    if (!_canPublishProducts()) {
      if (mounted) {
        setState(() => _message = 'Недостаточно прав для публикации постов');
      }
      return;
    }
    setState(() {
      _publishing = true;
      _message = '';
    });
    try {
      final payload = <String, dynamic>{};
      if (_tenantCustomWorkflowsEnabled) {
        final intervalMs = _parsePublicationIntervalInputMs();
        if (intervalMs == null) {
          setState(() {
            _publishing = false;
            _message = 'Введите интервал публикации в секундах';
          });
          return;
        }
        payload['publication_interval_ms'] = intervalMs;
      }
      final resp = await authService.dio.post(
        '/api/admin/channels/publish_pending',
        data: payload,
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final acceptedCount = _toInt(data['accepted_count']);
        final runningChannels = _asMapList(data['already_running_channels']);
        if (mounted) {
          setState(() {
            if (acceptedCount > 0) {
              final intervalLabel = _tenantCustomWorkflowsEnabled
                  ? ' · интервал ${_formatIntervalSeconds(_publicationIntervalMs)} сек'
                  : '';
              _message =
                  'Публикация запущена: $acceptedCount постов$intervalLabel';
            } else if (runningChannels.isNotEmpty) {
              _message = 'Публикация уже идёт для выбранного канала';
            } else {
              _message = 'Нет постов для публикации';
            }
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
                          key: ValueKey<String>('visibility-$visibility'),
                          initialValue: visibility,
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
                          if (!ctx.mounted) return;
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

  Future<void> _deletePendingPost(Map<String, dynamic> post) async {
    final title = (post['product_title'] ?? 'этот пост').toString().trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить пост из модерации?'),
        content: Text(
          'Удалить "$title" из очереди модерации?\n\nПосле этого он не уйдёт на канал.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      await authService.dio.delete(
        '/api/admin/channels/pending_posts/${post['id']}',
      );
      await _loadPendingPosts();
      if (!mounted) return;
      setState(() => _message = 'Пост удалён из модерации');
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка удаления поста: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<Map<String, dynamic>?> _editChannelClientName(
    String channelId,
    Map<String, dynamic> client,
  ) async {
    final userId = (client['user_id'] ?? '').toString().trim();
    if (userId.isEmpty) return null;
    final nameCtrl = TextEditingController(
      text: _displayName(client, fallback: 'Клиент'),
    );
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить имя клиента'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: withInputLanguageBadge(
            const InputDecoration(
              labelText: 'Имя клиента',
              border: OutlineInputBorder(),
            ),
            controller: nameCtrl,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (nextName == null) return null;
    final normalizedName = nextName.trim();
    if (normalizedName.length < 2) {
      if (mounted) {
        showAppNotice(
          context,
          'Имя должно содержать минимум 2 символа',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      }
      return null;
    }

    try {
      final resp = await authService.dio.patch(
        '/api/admin/channels/$channelId/clients/$userId/name',
        data: {'name': normalizedName},
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
        return null;
      }
      final updated = Map<String, dynamic>.from(data['data']);
      final overview = _channelOverviews[channelId];
      if (overview != null) {
        final clients = _asMapList(overview['clients']);
        final index = clients.indexWhere(
          (item) => (item['user_id'] ?? '').toString() == userId,
        );
        if (index >= 0) {
          clients[index] = {...clients[index], ...updated};
          setState(() {
            _channelOverviews[channelId] = {...overview, 'clients': clients};
          });
        }
      }
      if (mounted) {
        setState(() => _message = 'Имя клиента изменено');
      }
      return updated;
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка изменения имени: ${_extractDioError(e)}',
        );
      }
      return null;
    }
  }

  Future<void> _openClientsDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    var clients = _asMapList(overview['clients']);
    final stats = _asMap(overview['stats']);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Клиенты канала "$channelTitle"'),
          content: SizedBox(
            width: 620,
            height: 460,
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
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final c = clients[index];
                            final blocked = c['is_blacklisted'] == true;
                            final phone = (c['phone'] ?? '').toString().trim();
                            final city = (c['client_city'] ?? '')
                                .toString()
                                .trim();
                            final displayName = _displayName(
                              c,
                              fallback: 'Клиент',
                            );
                            return ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                child: Text(displayName[0].toUpperCase()),
                              ),
                              title: Text(displayName),
                              subtitle: Text(
                                [
                                  (c['email'] ?? '').toString(),
                                  if (phone.isNotEmpty) 'Тел: $phone',
                                  if (city.isNotEmpty) 'Город: $city',
                                ].where((v) => v.trim().isNotEmpty).join('\n'),
                              ),
                              isThreeLine: phone.isNotEmpty || city.isNotEmpty,
                              trailing: Wrap(
                                spacing: 4,
                                children: [
                                  if (blocked)
                                    const Icon(Icons.block, color: Colors.red),
                                  IconButton(
                                    tooltip: 'Изменить имя',
                                    onPressed: () async {
                                      final updated =
                                          await _editChannelClientName(
                                            channelId,
                                            c,
                                          );
                                      if (updated == null) return;
                                      setDialogState(() {
                                        clients =
                                            List<Map<String, dynamic>>.from(
                                              clients,
                                            );
                                        clients[index] = {
                                          ...clients[index],
                                          ...updated,
                                        };
                                      });
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                ],
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
      ),
    );
  }

  String _channelClientExcelText(Map<String, dynamic> client, String field) {
    switch (field) {
      case 'phone':
        return _displayPhone((client['phone'] ?? '').toString(), fallback: '');
      case 'name':
        return _displayName(client, fallback: 'Клиент');
      case 'sum':
        return _formatMoney(client['total_sum']);
      case 'address':
        return (client['effective_address_text'] ??
                client['delivery_address_text'] ??
                client['saved_address_text'] ??
                '')
            .toString()
            .trim();
      case 'courier':
        return (client['courier_name'] ?? '').toString().trim();
      case 'locality':
        return (client['locality_letter'] ?? '').toString().trim();
      case 'bulky':
        return (client['bulky_text'] ?? '').toString().trim();
      case 'shelf':
        return (client['shelf_label'] ?? '').toString().trim();
      case 'places':
        final places = _toInt(client['package_places']);
        return places > 0 ? places.toString() : '';
      default:
        return '';
    }
  }

  Widget _buildExcelFilterField({
    required TextEditingController controller,
    required String label,
    required VoidCallback onChanged,
    double width = 120,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          border: const OutlineInputBorder(),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          suffixIcon: controller.text.trim().isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    controller.clear();
                    onChanged();
                  },
                ),
        ),
        onChanged: (_) => onChanged(),
      ),
    );
  }

  Future<void> _openClientsExcelDialog(
    String channelId,
    String channelTitle,
  ) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final sourceClients = _asMapList(overview['clients']);
    final filters = <String, TextEditingController>{
      'phone': TextEditingController(),
      'name': TextEditingController(),
      'sum': TextEditingController(),
      'address': TextEditingController(),
      'courier': TextEditingController(),
      'locality': TextEditingController(),
      'bulky': TextEditingController(),
      'shelf': TextEditingController(),
      'places': TextEditingController(),
    };
    final horizontalScrollCtrl = ScrollController();
    final verticalScrollCtrl = ScrollController();

    List<Map<String, dynamic>> filteredRows() {
      return sourceClients.where((client) {
        for (final entry in filters.entries) {
          final query = entry.value.text.trim().toLowerCase();
          if (query.isEmpty) continue;
          final value = _channelClientExcelText(
            client,
            entry.key,
          ).toLowerCase();
          if (!value.contains(query)) return false;
        }
        return true;
      }).toList()..sort((a, b) {
        final left = _toDouble(a['total_sum']);
        final right = _toDouble(b['total_sum']);
        return right.compareTo(left);
      });
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (context, setDialogState) {
            final rows = filteredRows();
            void refreshFilters() => setDialogState(() {});
            final size = MediaQuery.sizeOf(context);
            final dialogWidth = math.min(
              1360.0,
              math.max(360.0, size.width - 24),
            );
            final dialogHeight = math.min(
              680.0,
              math.max(440.0, size.height - 96),
            );
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 20,
              ),
              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              title: Text('Excel: клиенты канала "$channelTitle"'),
              content: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildExcelFilterField(
                            controller: filters['phone']!,
                            label: 'Телефон',
                            onChanged: refreshFilters,
                            width: 125,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['name']!,
                            label: 'Имя',
                            onChanged: refreshFilters,
                            width: 125,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['sum']!,
                            label: 'Сумма',
                            onChanged: refreshFilters,
                            width: 105,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['address']!,
                            label: 'Адрес',
                            onChanged: refreshFilters,
                            width: 190,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['courier']!,
                            label: 'Курьер',
                            onChanged: refreshFilters,
                            width: 110,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['locality']!,
                            label: 'НП',
                            onChanged: refreshFilters,
                            width: 72,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['bulky']!,
                            label: 'Габарит',
                            onChanged: refreshFilters,
                            width: 120,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['shelf']!,
                            label: 'Полка',
                            onChanged: refreshFilters,
                            width: 82,
                          ),
                          const SizedBox(width: 8),
                          _buildExcelFilterField(
                            controller: filters['places']!,
                            label: 'Мест',
                            onChanged: refreshFilters,
                            width: 72,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Строк: ${rows.length} из ${sourceClients.length}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Scrollbar(
                        controller: verticalScrollCtrl,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: verticalScrollCtrl,
                          child: Scrollbar(
                            controller: horizontalScrollCtrl,
                            thumbVisibility: true,
                            notificationPredicate: (notification) =>
                                notification.metrics.axis == Axis.horizontal,
                            child: SingleChildScrollView(
                              controller: horizontalScrollCtrl,
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingRowColor: WidgetStatePropertyAll(
                                  Colors.greenAccent.withValues(alpha: 0.28),
                                ),
                                dataRowMinHeight: 42,
                                dataRowMaxHeight: 72,
                                columnSpacing: 18,
                                columns: const [
                                  DataColumn(label: Text('Телефон')),
                                  DataColumn(label: Text('Имя')),
                                  DataColumn(label: Text('Сумма')),
                                  DataColumn(label: Text('Адрес')),
                                  DataColumn(label: Text('Курьер')),
                                  DataColumn(label: Text('НП')),
                                  DataColumn(label: Text('Габарит')),
                                  DataColumn(label: Text('Полка')),
                                  DataColumn(label: Text('Мест')),
                                ],
                                rows: rows.map((client) {
                                  final address = _channelClientExcelText(
                                    client,
                                    'address',
                                  );
                                  final bulky = _channelClientExcelText(
                                    client,
                                    'bulky',
                                  );
                                  return DataRow(
                                    cells: [
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'phone',
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        SizedBox(
                                          width: 150,
                                          child: Text(
                                            _channelClientExcelText(
                                              client,
                                              'name',
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'sum',
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        SizedBox(
                                          width: 330,
                                          child: Text(
                                            address,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'courier',
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'locality',
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        SizedBox(
                                          width: 230,
                                          child: Text(
                                            bulky,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'shelf',
                                          ),
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          _channelClientExcelText(
                                            client,
                                            'places',
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () {
                    for (final controller in filters.values) {
                      controller.clear();
                    }
                    refreshFilters();
                  },
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Сбросить фильтры'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Закрыть'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      for (final controller in filters.values) {
        controller.dispose();
      }
      horizontalScrollCtrl.dispose();
      verticalScrollCtrl.dispose();
    }
  }

  Future<void> _openMediaDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final media = _asMapList(overview['media']);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text('Медиа канала "$channelTitle"'),
          content: SizedBox(
            width: 680,
            height: 480,
            child: media.isEmpty
                ? const Center(child: Text('В канале пока нет медиа'))
                : GridView.builder(
                    itemCount: media.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
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
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
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
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        alignment: Alignment.center,
                                        child: Icon(
                                          Icons.photo_outlined,
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      )
                                    : AdaptiveNetworkImage(
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
        );
      },
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
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
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
    final theme = Theme.of(context);
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
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: initials == '?'
            ? Icon(fallbackIcon, color: theme.colorScheme.onSurfaceVariant)
            : Text(initials),
      );
    }

    final size = radius * 2;
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment(focusX, focusY),
            child: AdaptiveNetworkImage(
              imageUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: Alignment(focusX, focusY),
              errorBuilder: (context, error, stackTrace) => Center(
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
          key: ValueKey<String>(
            'new-channel-visibility-$_newChannelVisibility',
          ),
          initialValue: _newChannelVisibility,
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
                    key: ValueKey<String>('invite-role-$_inviteRole'),
                    initialValue: _inviteRole,
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
                    if (_isCreatorBase())
                      IconButton(
                        tooltip: 'Переименовать код',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: _inviteActionLoading
                            ? null
                            : () => _renameInviteCode(id, code),
                      ),
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
    final theme = Theme.of(context);
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
    final isOverviewAvailable =
        ((settings['kind'] ?? '').toString().trim().toLowerCase().isEmpty ||
            (settings['kind'] ?? '').toString().trim().toLowerCase() ==
                'channel') &&
        !_boolValue(settings['admin_only']);
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
          if (expanded && isOverviewAvailable) {
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
                onPressed: !isOverviewAvailable || _overviewLoading.contains(id)
                    ? null
                    : () => _loadChannelOverview(id, force: true),
                icon: const Icon(Icons.analytics_outlined),
                label: Text(
                  !isOverviewAvailable
                      ? 'Недоступно'
                      : _overviewLoading.contains(id)
                      ? 'Загрузка...'
                      : 'Обновить данные',
                ),
              ),
              OutlinedButton.icon(
                onPressed: !isOverviewAvailable || _overviewLoading.contains(id)
                    ? null
                    : () => _openClientsExcelDialog(id, title),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Excel'),
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
                    color: theme.colorScheme.onSurface,
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
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
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
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.photo_outlined,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : AdaptiveNetworkImage(url, fit: BoxFit.cover),
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
                    color: theme.colorScheme.onSurface,
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
      if (!_isAdminBase()) {
        return const Center(child: Text('Каналы пока не созданы'));
      }
    }

    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView(
        padding: EdgeInsets.all(compact ? 10 : 16),
        children: [
          if (_channels.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Каналы пока не созданы'),
              ),
            )
          else
            ..._channels.map(
              (channel) => Padding(
                padding: EdgeInsets.only(bottom: compact ? 8 : 12),
                child: _buildChannelCard(channel),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPromotionsTab() {
    final compact = MediaQuery.of(context).size.width < 640;
    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView(
        padding: EdgeInsets.all(compact ? 10 : 16),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Промо-рассылки',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Здесь администратор создаёт акции и промо-уведомления для клиентов. '
                    'Рассылка уходит только клиентам вашего tenant, у которых включены акции и промо.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminPromotionCenterScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Открыть центр промо'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Что заполнять',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Заголовок акции.\n'
                    '2. Короткий текст предложения.\n'
                    '3. Deep link внутри приложения, если нужно открыть конкретный экран.\n'
                    '4. Ссылку на картинку, если акция должна прийти с баннером.',
                  ),
                ],
              ),
            ),
          ),
        ],
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

  Widget _buildRevisionDeleteRequestsSection() {
    final theme = Theme.of(context);
    final pendingRequests = _revisionDeleteRequests
        .where((item) => (item['status'] ?? '').toString().trim() == 'pending')
        .toList();
    if (!_revisionDeleteRequestsLoading && pendingRequests.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.delete_sweep_outlined,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Запросы на удаление из ревизии',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_revisionDeleteRequestsLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (pendingRequests.isEmpty)
              Text(
                'Ожидающих запросов нет',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...pendingRequests.map((request) {
                final id = (request['id'] ?? '').toString().trim();
                final busy = _revisionDeleteDecisionBusyIds.contains(id);
                final imageUrl = _resolveImageUrl(
                  (request['image_url'] ?? '').toString(),
                );
                final productTitle = (request['product_title'] ?? 'Товар')
                    .toString();
                final workerName = (request['worker_name'] ?? 'Рабочий')
                    .toString();
                final reason = (request['reason'] ?? '').toString().trim();
                final productLabel = _formatProductLabel(
                  request['product_code'],
                  request['shelf_number'],
                );
                return Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: imageUrl != null
                              ? AdaptiveNetworkImage(
                                  imageUrl,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, error, stackTrace) =>
                                      Container(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.photo_outlined),
                                      ),
                                )
                              : Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
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
                              productTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$workerName просит удалить · ID $productLabel',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (reason.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                reason,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => _decideRevisionDeleteRequest(
                                          request,
                                          true,
                                        ),
                                  icon: busy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.check_rounded),
                                  label: const Text('Разрешить'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => _decideRevisionDeleteRequest(
                                          request,
                                          false,
                                        ),
                                  icon: const Icon(Icons.close_rounded),
                                  label: const Text('Отклонить'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildModerationTab() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 640;
    final queuedCount = _pendingPosts
        .where(
          (post) =>
              (post['publish_status'] ?? 'pending').toString().trim() ==
              'queued',
        )
        .length;
    final failedCount = _pendingPosts
        .where(
          (post) =>
              (post['publish_status'] ?? 'pending').toString().trim() ==
              'failed',
        )
        .length;
    final currentTitle = (_publishingSummary?['current_product_title'] ?? '')
        .toString()
        .trim();
    final publishProgressLabel = _hasActivePublishBatches
        ? 'Идёт публикация: ${_toInt(_publishingSummary?['published_count'])}/${_toInt(_publishingSummary?['total_count'])}'
        : null;
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          _loadTenantFeatureSettings(silent: true),
          _loadPendingPosts(),
          _loadRevisionDeleteRequests(silent: true),
        ]);
      },
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
              if (queuedCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'В публикации: $queuedCount',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              if (failedCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'Ошибки публикации: $failedCount',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
            ],
          ),
          if (_hasActivePublishBatches) ...[
            SizedBox(height: compact ? 10 : 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    publishProgressLabel ?? 'Идёт публикация',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (currentTitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Сейчас публикуется: $currentTitle',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildModerationChip(
                        'Следующий через: ${_formatPublicationDelay(_publishingSummary?['next_publish_in_ms'])}',
                      ),
                      _buildModerationChip(
                        'Ошибок: ${_toInt(_publishingSummary?['failed_count'])}',
                      ),
                      _buildModerationChip(
                        'Активных каналов: ${_activePublishBatches.length}',
                      ),
                    ],
                  ),
                  if (_activePublishBatches.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ..._activePublishBatches.take(3).map((batch) {
                      final channelTitle = (batch['channel_title'] ?? 'Канал')
                          .toString();
                      final batchCurrentTitle =
                          (batch['current_product_title'] ?? '').toString();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '$channelTitle · ${_toInt(batch['published_count'])}/${_toInt(batch['total_count'])}'
                          '${batchCurrentTitle.isNotEmpty ? ' · $batchCurrentTitle' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],
          if (_tenantCustomWorkflowsEnabled) ...[
            SizedBox(height: compact ? 10 : 14),
            Card(
              child: Padding(
                padding: EdgeInsets.all(compact ? 12 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Интервал публикации',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Пауза между постами в Основной канал для этой группы.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _publicationIntervalCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Секунд между постами',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _tenantFeatureSettingsSaving
                              ? null
                              : _savePublicationIntervalSetting,
                          icon: _tenantFeatureSettingsSaving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: const Text('Сохранить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_revisionDeleteRequestsLoading ||
              _revisionDeleteRequests.any(
                (item) => (item['status'] ?? '').toString().trim() == 'pending',
              )) ...[
            SizedBox(height: compact ? 10 : 14),
            _buildRevisionDeleteRequestsSection(),
          ],
          SizedBox(height: compact ? 10 : 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed:
                  (_publishing ||
                      _hasActivePublishBatches ||
                      !_canPublishProducts())
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
                  : _hasActivePublishBatches
                  ? const Icon(Icons.schedule_send_outlined)
                  : const Icon(Icons.campaign),
              label: Text(
                _publishing
                    ? 'Запуск публикации...'
                    : _hasActivePublishBatches
                    ? 'Публикация уже идёт'
                    : 'Отправить посты на каналы',
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
              final publishStatus = (p['publish_status'] ?? 'pending')
                  .toString()
                  .trim();
              final productLabel = _formatProductLabel(
                p['product_code'],
                p['product_shelf_number'],
                manualShelfLabel: p['manual_shelf_label'],
              );
              final manualShelfLabel = (p['manual_shelf_label'] ?? '')
                  .toString()
                  .trim();
              final shelfFloor = (p['shelf_floor'] ?? '').toString().trim();
              final pickupOnly = _boolValue(p['pickup_only']);
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
                                ? AdaptiveNetworkImage(
                                    imageUrl,
                                    width: 96,
                                    height: 96,
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
                                  if (manualShelfLabel.isNotEmpty)
                                    _buildModerationChip(
                                      'Полка: $manualShelfLabel',
                                    ),
                                  if (shelfFloor.isNotEmpty)
                                    _buildModerationChip('Этаж: $shelfFloor'),
                                  if (pickupOnly)
                                    _buildModerationChip('Самовывоз'),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _publicationStatusColor(
                                        theme,
                                        publishStatus,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _publicationStatusLabel(p),
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                  _buildModerationChip(
                                    _formatMoney(p['product_price']),
                                  ),
                                  _buildModerationChip(
                                    'x${_toInt(p['product_quantity'])}',
                                  ),
                                  if (publishStatus == 'failed' &&
                                      (p['publish_error_code'] ?? '')
                                          .toString()
                                          .trim()
                                          .isNotEmpty)
                                    _buildModerationChip(
                                      'Код: ${(p['publish_error_code'] ?? '').toString()}',
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
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed:
                                  _saving ||
                                      publishStatus == 'queued' ||
                                      publishStatus == 'publishing'
                                  ? null
                                  : () => _editPendingPost(p),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              label: const Text('Изменить'),
                            ),
                            if (_canDeletePendingPost())
                              OutlinedButton.icon(
                                onPressed:
                                    _saving ||
                                        publishStatus == 'queued' ||
                                        publishStatus == 'publishing'
                                    ? null
                                    : () => _deletePendingPost(p),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                label: const Text('Удалить'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    if (publishStatus == 'failed' &&
                        (p['publish_error_message'] ?? '')
                            .toString()
                            .trim()
                            .isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        (p['publish_error_message'] ?? '').toString(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
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
              final shelf = _displayShelfValue(
                item['shelf_label'],
                item['shelf_number'],
              );
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
    bool pending = false,
  }) {
    final theme = Theme.of(context);
    final ticketId = (ticket['id'] ?? '').toString().trim();
    final customer = (ticket['customer_name'] ?? 'Клиент').toString();
    final assignee = (ticket['assignee_name'] ?? '—').toString();
    final hasAssignee =
        !pending && assignee.trim().isNotEmpty && assignee.trim() != '—';
    final category = _supportCategoryLabel(
      (ticket['category'] ?? '').toString(),
    );
    final statusRaw = (ticket['status'] ?? '').toString().trim().toLowerCase();
    final status = (ticket['status_display'] ?? '').toString().trim().isNotEmpty
        ? (ticket['status_display'] ?? '').toString().trim()
        : _supportStatusLabel(statusRaw, hasAssignee: hasAssignee);
    final statusHint = (ticket['status_hint'] ?? '').toString().trim();
    final subject = (ticket['subject'] ?? '').toString().trim();
    final updatedAt = _formatDateTimeLabel(ticket['updated_at']);
    final archiveReason = (ticket['archive_reason'] ?? '').toString().trim();
    final productTitle = (ticket['product_title'] ?? '').toString().trim();
    final claimBusy = _supportClaimBusyTicketIds.contains(ticketId);
    final finishBusy = _supportFinishBusyTicketIds.contains(ticketId);
    final quickReplyTemplates =
        _supportTemplates
            .where((template) => template['is_active'] != false)
            .toList()
          ..sort((a, b) {
            final categoryCompare =
                _supportCategoryLabel(
                  (a['category'] ?? '').toString(),
                ).compareTo(
                  _supportCategoryLabel((b['category'] ?? '').toString()),
                );
            if (categoryCompare != 0) return categoryCompare;
            return (a['title'] ?? '').toString().compareTo(
              (b['title'] ?? '').toString(),
            );
          });
    final isTemplateEnabled =
        !archived && !pending && quickReplyTemplates.isNotEmpty;
    final canResolve = !archived && !pending && statusRaw != 'resolved';

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
            Text('Ответственный: ${pending ? 'Свободный' : assignee}'),
            if (productTitle.isNotEmpty) Text('Товар: $productTitle'),
            if (updatedAt.isNotEmpty) Text('Обновлён: $updatedAt'),
            if (statusHint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  statusHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (archiveReason.isNotEmpty)
              Text('Причина архива: $archiveReason'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (pending)
                  FilledButton.icon(
                    onPressed: claimBusy
                        ? null
                        : () => _claimSupportTicket(ticket),
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: Text(
                      claimBusy ? 'Назначаем...' : 'Ответить на вопрос',
                    ),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: () => _openSupportChat(ticket),
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('Открыть чат'),
                  ),
                if (canResolve)
                  OutlinedButton.icon(
                    onPressed: finishBusy
                        ? null
                        : () => _resolveSupportTicket(ticket),
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(
                      finishBusy ? 'Отмечаем...' : 'Отметить решённой',
                    ),
                  ),
                if (!archived && !pending && _canForceCloseSupportTicket())
                  OutlinedButton.icon(
                    onPressed: finishBusy || _supportArchiveBusy
                        ? null
                        : () => _archiveSupportTicket(ticket, force: true),
                    icon: const Icon(Icons.archive_outlined),
                    label: Text(
                      finishBusy || _supportArchiveBusy
                          ? 'Закрываем...'
                          : 'Закрыть сразу',
                    ),
                  ),
                if (ticketId.isNotEmpty)
                  _buildModerationChip('ID ${ticketId.substring(0, 8)}'),
              ],
            ),
            if (isTemplateEnabled) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey<String>('ticket-template-$ticketId'),
                initialValue: (_ticketTemplateById[ticketId] ?? '').isEmpty
                    ? null
                    : _ticketTemplateById[ticketId],
                isExpanded: true,
                items: quickReplyTemplates.map((template) {
                  final id = (template['id'] ?? '').toString();
                  final title = (template['title'] ?? 'Шаблон').toString();
                  final categoryLabel = _supportCategoryLabel(
                    (template['category'] ?? '').toString(),
                  );
                  final preview = _supportTemplatePreview(template);
                  return DropdownMenuItem<String>(
                    value: id,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$categoryLabel • $title'),
                        Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
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
    final triggerRuleInput = _supportTemplateTriggerCtrl.text.trim();
    final triggerRuleForPreview = _supportTemplateElseFallback
        ? '*'
        : triggerRuleInput;
    final parsedTriggerGroups = _parseSupportTriggerGroups(
      triggerRuleForPreview,
    );
    final triggerProbeText = _supportTemplateTriggerProbeCtrl.text.trim();
    final showTriggerProbeResult =
        triggerProbeText.isNotEmpty &&
        (_supportTemplateElseFallback || parsedTriggerGroups.isNotEmpty);
    final triggerProbeMatches = showTriggerProbeResult
        ? _supportTriggerMatches(triggerRuleForPreview, triggerProbeText)
        : false;
    final notificationsSummary = _asMap(_supportNotificationSummary);
    final returnsSummary = _asMap(_returnsAnalytics?['summary']);
    final returnsTopProducts = _asMapList(_returnsAnalytics?['top_products']);
    final defectStatsEnabled = _boolValue(_defectStats?['enabled']);
    final defectStatsData = _asMap(_defectStats?['data']);
    final defectStatsCounts = _asMap(defectStatsData['counts']);
    final defectStatsItems = _asMapList(defectStatsData['items']);
    final canForceCloseSupport = _canForceCloseSupportTicket();
    final canManageSupportKnowledgeBase = _canManageSupportKnowledgeBase();

    return RefreshIndicator(
      onRefresh: () async {
        await _loadSupportTickets(silent: true);
        await _loadSupportTemplates(silent: true);
        await _loadSupportFaqEntries(silent: true);
        await _loadReturnsWorkflow(silent: true);
        await _loadSupportNotificationCenter(silent: true);
        await _loadReturnsAnalytics(silent: true);
        await _loadDefectStats(silent: true);
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
                        await _loadSupportTemplates(silent: true);
                        await _loadSupportFaqEntries(silent: true);
                        await _loadReturnsWorkflow(silent: true);
                        await _loadSupportNotificationCenter(silent: true);
                        await _loadReturnsAnalytics(silent: true);
                        await _loadDefectStats(silent: true);
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
          Text(
            'Оперативная сводка',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (_supportNotificationsLoading && _supportNotificationItems.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildModerationChip(
                        'Внимание: ${_toInt(notificationsSummary['total_attention'])}',
                      ),
                      _buildModerationChip(
                        'Открытые тикеты: ${_toInt(notificationsSummary['support_open'])}',
                      ),
                      _buildModerationChip(
                        'Ждут клиента: ${_toInt(notificationsSummary['support_waiting_customer'])}',
                      ),
                      _buildModerationChip(
                        'Новые претензии: ${_toInt(notificationsSummary['claims_pending'])}',
                      ),
                      _buildModerationChip(
                        'Расформировка корзин: ${_toInt(notificationsSummary['stale_carts'])}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_supportNotificationItems.isEmpty)
                    Text(
                      'Уведомлений пока нет',
                      style: Theme.of(context).textTheme.bodyMedium,
                    )
                  else
                    ..._supportNotificationItems.take(8).map((event) {
                      final title = (event['title'] ?? 'Событие').toString();
                      final subtitle = (event['subtitle'] ?? '').toString();
                      final typeLabel = (event['type_label'] ?? 'Система')
                          .toString();
                      final statusLabel = (event['status_label'] ?? '')
                          .toString();
                      final eventType = (event['type'] ?? '').toString().trim();
                      final isSupportEvent = eventType == 'support_ticket';
                      final isCartRetentionEvent =
                          eventType == 'cart_retention';
                      final cartRetentionUserId = isCartRetentionEvent
                          ? _cartRetentionUserIdOf(event)
                          : '';
                      final cartRetentionBusy = _cartRetentionBusyIds.contains(
                        (event['id'] ?? 'cart-retention:$cartRetentionUserId')
                            .toString()
                            .trim(),
                      );
                      final supportStatus = (event['status'] ?? '')
                          .toString()
                          .trim()
                          .toLowerCase();
                      final supportTicketId = (event['id'] ?? '')
                          .toString()
                          .trim();
                      final supportFinishBusy = _supportFinishBusyTicketIds
                          .contains(supportTicketId);
                      final priority = (event['priority'] ?? 'normal')
                          .toString();
                      final timeLabel = _formatDateTimeLabel(event['event_at']);
                      Color priorityColor;
                      if (priority == 'high') {
                        priorityColor = Theme.of(context).colorScheme.error;
                      } else if (priority == 'low') {
                        priorityColor = Theme.of(context).colorScheme.outline;
                      } else {
                        priorityColor = Theme.of(context).colorScheme.primary;
                      }

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(title),
                              subtitle: Text(
                                [
                                  typeLabel,
                                  if (statusLabel.isNotEmpty) statusLabel,
                                  if (subtitle.isNotEmpty) subtitle,
                                  if (timeLabel.isNotEmpty) timeLabel,
                                ].join(' • '),
                              ),
                              leading: Icon(
                                eventType == 'claim'
                                    ? Icons.assignment_return_outlined
                                    : eventType == 'cart_retention'
                                    ? Icons.warning_amber_rounded
                                    : Icons.support_agent_outlined,
                                color: priorityColor,
                              ),
                            ),
                            if (isSupportEvent)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (((event['chat_id'] ?? '')
                                            .toString()
                                            .trim())
                                        .isNotEmpty)
                                      FilledButton.tonalIcon(
                                        onPressed: () =>
                                            _openSupportNotificationItem(event),
                                        icon: const Icon(Icons.forum_outlined),
                                        label: const Text('Открыть чат'),
                                      ),
                                    if (supportStatus != 'resolved')
                                      OutlinedButton.icon(
                                        onPressed: supportFinishBusy
                                            ? null
                                            : () => _resolveSupportTicket({
                                                'id': supportTicketId,
                                                'chat_id': event['chat_id'],
                                              }),
                                        icon: const Icon(
                                          Icons.verified_outlined,
                                        ),
                                        label: Text(
                                          supportFinishBusy
                                              ? 'Отмечаем...'
                                              : 'Отметить решённой',
                                        ),
                                      ),
                                    if (canForceCloseSupport)
                                      OutlinedButton.icon(
                                        onPressed:
                                            supportFinishBusy ||
                                                _supportArchiveBusy
                                            ? null
                                            : () => _archiveSupportTicket(
                                                {
                                                  'id': supportTicketId,
                                                  'chat_id': event['chat_id'],
                                                },
                                                force:
                                                    supportStatus ==
                                                        'waiting_customer' ||
                                                    supportStatus ==
                                                        'resolved' ||
                                                    supportStatus == 'open',
                                              ),
                                        icon:
                                            supportFinishBusy ||
                                                _supportArchiveBusy
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.archive_outlined,
                                              ),
                                        label: Text(
                                          supportFinishBusy ||
                                                  _supportArchiveBusy
                                              ? 'Закрываем...'
                                              : 'Закрыть сразу',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            if (isCartRetentionEvent)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed:
                                          cartRetentionUserId.isEmpty ||
                                              cartRetentionBusy
                                          ? null
                                          : () => _dismantleCartRetentionItem(
                                              event,
                                            ),
                                      icon: cartRetentionBusy
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.playlist_remove_outlined,
                                            ),
                                      label: Text(
                                        cartRetentionBusy
                                            ? 'Расформировываем...'
                                            : 'Расформировать',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Аналитика возвратов и брака (30 дней)',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (_returnsAnalyticsLoading && _returnsAnalytics == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildModerationChip(
                        'Всего заявок: ${_toInt(returnsSummary['total_claims'])}',
                      ),
                      _buildModerationChip(
                        'Ожидают: ${_toInt(returnsSummary['pending_claims'])}',
                      ),
                      _buildModerationChip(
                        'Отклонено: ${_toInt(returnsSummary['rejected_claims'])}',
                      ),
                      _buildModerationChip(
                        'Сумма брака: ${_formatMoney(returnsSummary['defect_sum'])}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Возвраты: ${_formatMoney(returnsSummary['returns_sum'])} • '
                    'Скидки: ${_formatMoney(returnsSummary['discounts_sum'])}',
                  ),
                  const SizedBox(height: 8),
                  if (returnsTopProducts.isEmpty)
                    Text(
                      'Топ проблемных товаров пока пуст',
                      style: Theme.of(context).textTheme.bodyMedium,
                    )
                  else
                    ...returnsTopProducts.take(5).map((row) {
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          (row['product_title'] ?? 'Товар').toString(),
                        ),
                        subtitle: Text(
                          'Заявок: ${_toInt(row['total_claims'])} • '
                          'Сумма: ${_formatMoney(row['approved_sum'])}',
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          if (defectStatsEnabled) ...[
            const SizedBox(height: 12),
            Text(
              'Статистика брака группы',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (_defectStatsLoading && _defectStats == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildModerationChip(
                          'Неделя: ${_toInt(defectStatsCounts['week'])}',
                        ),
                        _buildModerationChip(
                          '2 недели: ${_toInt(defectStatsCounts['two_weeks'])}',
                        ),
                        _buildModerationChip(
                          'Месяц: ${_toInt(defectStatsCounts['month'])}',
                        ),
                        _buildModerationChip(
                          'Всего: ${_toInt(defectStatsCounts['total'])}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (defectStatsItems.isEmpty)
                      Text(
                        'Список брака пока пуст',
                        style: Theme.of(context).textTheme.bodyMedium,
                      )
                    else
                      ...defectStatsItems.take(12).map((item) {
                        final title = (item['title'] ?? 'Товар').toString();
                        final reason = (item['reason'] ?? 'Причина не указана')
                            .toString();
                        final uploader =
                            (item['uploaded_by_name'] ??
                                    item['uploaded_by_email'] ??
                                    'Неизвестно')
                                .toString();
                        final sourceLabel = (item['source_label'] ?? 'Брак')
                            .toString();
                        final createdAt = _formatDateTimeLabel(
                          item['created_at'],
                        );
                        final imageUrl = _resolveImageUrl(
                          (item['image_url'] ?? '').toString(),
                        );

                        return Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 58,
                                  height: 58,
                                  child: imageUrl == null
                                      ? Container(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest,
                                          child: Icon(
                                            Icons.image_not_supported_outlined,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        )
                                      : AdaptiveNetworkImage(
                                          imageUrl,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Причина: $reason',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      [
                                        'Выложил: $uploader',
                                        sourceLabel,
                                        if (createdAt.isNotEmpty) createdAt,
                                      ].join(' • '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          canManageSupportKnowledgeBase
                              ? 'Шаблоны ответов'
                              : 'Быстрые ответы поддержки',
                          style: const TextStyle(fontWeight: FontWeight.w700),
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
                  if (canManageSupportKnowledgeBase) ...[
                    TextField(
                      controller: _supportTemplateTitleCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Название шаблона',
                          hintText: 'Например: Статус доставки',
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
                          labelText: 'Текст ответа',
                          hintText:
                              'Напишите понятный готовый ответ для клиента',
                          border: OutlineInputBorder(),
                        ),
                        controller: _supportTemplateBodyCtrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey<String>(
                        'support-template-category-$_supportTemplateCategory',
                      ),
                      initialValue: _supportTemplateCategory,
                      items: _supportCategoryDropdownItems(),
                      onChanged: _supportTemplateSaving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _supportTemplateCategory = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'Категория',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      title: const Text('Дополнительно'),
                      subtitle: const Text(
                        'Триггеры, автоответ и служебные настройки',
                      ),
                      children: [
                        SwitchListTile.adaptive(
                          value: _supportTemplateElseFallback,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Шаблон по умолчанию'),
                          subtitle: const Text(
                            'Сработает, если другие правила не подошли',
                          ),
                          onChanged: _supportTemplateSaving
                              ? null
                              : _setSupportTemplateFallback,
                        ),
                        TextField(
                          controller: _supportTemplateTriggerCtrl,
                          enabled: !_supportTemplateElseFallback,
                          onChanged: (_) {
                            if (!_supportTemplateElseFallback &&
                                _isFallbackTriggerRule(
                                  _supportTemplateTriggerCtrl.text,
                                )) {
                              _setSupportTemplateFallback(true);
                              return;
                            }
                            setState(() {});
                          },
                          decoration: withInputLanguageBadge(
                            InputDecoration(
                              labelText: 'Ключевые слова',
                              hintText:
                                  'Например: время+доставки|когда+доставка',
                              helperText: _supportTemplateElseFallback
                                  ? 'Сейчас включён fallback-режим.'
                                  : 'Формат: слово+слово|другая+группа',
                              border: const OutlineInputBorder(),
                            ),
                            controller: _supportTemplateTriggerCtrl,
                          ),
                        ),
                        if (!_supportTemplateElseFallback) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _supportTriggerExamples
                                .map(
                                  (example) => ActionChip(
                                    onPressed: _supportTemplateSaving
                                        ? null
                                        : () => _appendSupportTriggerExample(
                                            example,
                                          ),
                                    avatar: const Icon(Icons.rule, size: 16),
                                    label: Text(example),
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Логика: "+" = и, "|" = или. Пример: время+доставки|когда+доставка',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          if (parsedTriggerGroups.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: parsedTriggerGroups
                                  .asMap()
                                  .entries
                                  .map(
                                    (entry) => Chip(
                                      avatar: const Icon(
                                        Icons.account_tree,
                                        size: 16,
                                      ),
                                      label: Text(
                                        'IF ${entry.key + 1}: ${entry.value.join(' + ')}',
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ],
                        const SizedBox(height: 8),
                        TextField(
                          controller: _supportTemplateTriggerProbeCtrl,
                          onChanged: (_) => setState(() {}),
                          decoration: withInputLanguageBadge(
                            const InputDecoration(
                              labelText: 'Проверка правила',
                              hintText: 'Введите пример сообщения клиента',
                              border: OutlineInputBorder(),
                            ),
                            controller: _supportTemplateTriggerProbeCtrl,
                          ),
                        ),
                        if (triggerProbeText.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            showTriggerProbeResult
                                ? (triggerProbeMatches
                                      ? (_supportTemplateElseFallback
                                            ? 'Результат: сработает как шаблон по умолчанию.'
                                            : 'Результат: правило совпало, шаблон сработает.')
                                      : 'Результат: правило не совпало.')
                                : 'Результат: добавьте правило или включите шаблон по умолчанию.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: showTriggerProbeResult
                                      ? (triggerProbeMatches
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Theme.of(
                                                context,
                                              ).colorScheme.error)
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: SwitchListTile.adaptive(
                                value: _supportTemplateAutoReply,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Автоответ по правилу'),
                                onChanged: _supportTemplateSaving
                                    ? null
                                    : (value) {
                                        setState(
                                          () =>
                                              _supportTemplateAutoReply = value,
                                        );
                                        _scheduleSupportTemplateDraftSave();
                                      },
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: _supportTemplatePriorityCtrl,
                                keyboardType: TextInputType.number,
                                decoration: withInputLanguageBadge(
                                  const InputDecoration(
                                    labelText: 'Порядок',
                                    hintText: '100',
                                    border: OutlineInputBorder(),
                                  ),
                                  controller: _supportTemplatePriorityCtrl,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Команды для вставки',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _supportTemplateTokens.map((item) {
                            final token = (item['token'] ?? '').trim();
                            final title = (item['title'] ?? token).trim();
                            return ActionChip(
                              onPressed: _supportTemplateSaving
                                  ? null
                                  : () => _insertSupportTemplateToken(token),
                              avatar: const Icon(Icons.functions, size: 16),
                              label: Text(token),
                              tooltip: title,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Нажмите на команду, чтобы вставить её в текст по курсору',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Вставить в название',
                              onSelected: (token) {
                                if (_supportTemplateSaving) return;
                                _insertSupportTemplateToken(
                                  token,
                                  toTitle: true,
                                );
                              },
                              itemBuilder: (context) =>
                                  _supportTemplateTokens.map((item) {
                                    final token = (item['token'] ?? '').trim();
                                    final title = (item['title'] ?? token)
                                        .trim();
                                    return PopupMenuItem<String>(
                                      value: token,
                                      child: Text('$title: $token'),
                                    );
                                  }).toList(),
                              child: const Chip(
                                avatar: Icon(Icons.title, size: 16),
                                label: Text('Вставить в название'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_editingSupportTemplateId.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: _supportTemplateSaving
                                ? null
                                : () => _resetSupportTemplateEditor(
                                    clearMessage: true,
                                  ),
                            icon: const Icon(Icons.close),
                            label: const Text('Сбросить'),
                          ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _supportTemplateSaving
                              ? null
                              : _saveSupportTemplate,
                          icon: Icon(
                            _editingSupportTemplateId.isEmpty
                                ? Icons.add_comment_outlined
                                : Icons.save_outlined,
                          ),
                          label: Text(
                            _supportTemplateSaving
                                ? 'Сохранение...'
                                : _editingSupportTemplateId.isEmpty
                                ? 'Сохранить шаблон'
                                : 'Обновить шаблон',
                          ),
                        ),
                      ],
                    ),
                  ] else
                    Text(
                      'Здесь видны готовые ответы, которыми сотрудники пользуются в очереди поддержки.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Готовые шаблоны',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_supportTemplates.isEmpty)
                    const Text('Шаблоны пока не созданы')
                  else
                    ..._supportTemplates.map((template) {
                      final title = (template['title'] ?? 'Шаблон').toString();
                      final category = _supportCategoryLabel(
                        (template['category'] ?? '').toString(),
                      );
                      final preview = _supportTemplatePreview(template);
                      final isActive = template['is_active'] != false;
                      final isAutoReply =
                          template['auto_reply_enabled'] == true;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '$category • $title',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  _buildModerationChip(
                                    isActive ? 'Активен' : 'Скрыт',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                preview,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _buildModerationChip(
                                    isAutoReply
                                        ? 'Автоответ'
                                        : 'Только вручную',
                                  ),
                                  _buildModerationChip(
                                    'Порядок ${(template['priority'] ?? 100).toString()}',
                                  ),
                                ],
                              ),
                              if (canManageSupportKnowledgeBase) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _supportTemplateSaving
                                          ? null
                                          : () =>
                                                _editSupportTemplate(template),
                                      icon: const Icon(Icons.edit_outlined),
                                      label: const Text('Редактировать'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _supportTemplateSaving
                                          ? null
                                          : () => _toggleSupportTemplateActive(
                                              template,
                                            ),
                                      icon: Icon(
                                        isActive
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                      label: Text(
                                        isActive ? 'Скрыть' : 'Показать',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
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
                          'Частые вопросы',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: _supportFaqLoading
                            ? null
                            : () => _loadSupportFaqEntries(),
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Обновить FAQ',
                      ),
                    ],
                  ),
                  if (_supportFaqLoading)
                    const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 8),
                  if (canManageSupportKnowledgeBase) ...[
                    TextField(
                      controller: _supportFaqQuestionCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Вопрос',
                          hintText: 'Например: Как узнать статус доставки?',
                          border: OutlineInputBorder(),
                        ),
                        controller: _supportFaqQuestionCtrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _supportFaqAnswerCtrl,
                      minLines: 2,
                      maxLines: 4,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Ответ',
                          hintText:
                              'Напишите короткий и понятный ответ для клиента',
                          border: OutlineInputBorder(),
                        ),
                        controller: _supportFaqAnswerCtrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey<String>(
                        'support-faq-category-$_supportFaqCategory',
                      ),
                      initialValue: _supportFaqCategory,
                      items: _supportCategoryDropdownItems(),
                      onChanged: _supportFaqSaving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _supportFaqCategory = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'Категория',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _supportFaqKeywordsCtrl,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Ключевые слова',
                          hintText:
                              'Например: доставка, курьер, адрес, когда привезут',
                          border: OutlineInputBorder(),
                        ),
                        controller: _supportFaqKeywordsCtrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: SwitchListTile.adaptive(
                            value: _supportFaqIsActive,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Показывать клиентам'),
                            onChanged: _supportFaqSaving
                                ? null
                                : (value) {
                                    setState(() => _supportFaqIsActive = value);
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: _supportFaqSortOrderCtrl,
                            keyboardType: TextInputType.number,
                            decoration: withInputLanguageBadge(
                              const InputDecoration(
                                labelText: 'Порядок',
                                hintText: '100',
                                border: OutlineInputBorder(),
                              ),
                              controller: _supportFaqSortOrderCtrl,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_editingSupportFaqId.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: _supportFaqSaving
                                ? null
                                : () => _resetSupportFaqEditor(
                                    clearMessage: true,
                                  ),
                            icon: const Icon(Icons.close),
                            label: const Text('Сбросить'),
                          ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _supportFaqSaving
                              ? null
                              : _saveSupportFaqEntry,
                          icon: Icon(
                            _editingSupportFaqId.isEmpty
                                ? Icons.help_center_outlined
                                : Icons.save_outlined,
                          ),
                          label: Text(
                            _supportFaqSaving
                                ? 'Сохранение...'
                                : _editingSupportFaqId.isEmpty
                                ? 'Сохранить FAQ'
                                : 'Обновить FAQ',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ] else
                    Text(
                      'Эти карточки видят клиенты до создания обращения. Редактирование доступно администратору и создателю.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (_supportFaqEntries.isEmpty)
                    const Text('FAQ пока пуст')
                  else
                    ..._supportFaqEntries.map((entry) {
                      final question = (entry['question'] ?? 'Вопрос')
                          .toString()
                          .trim();
                      final answer = (entry['answer'] ?? '').toString().trim();
                      final category = _supportCategoryLabel(
                        (entry['category'] ?? '').toString(),
                      );
                      final isActive = entry['is_active'] != false;
                      final keywords = entry['keywords'];
                      final keywordsText = keywords is List
                          ? keywords.join(', ')
                          : (keywords ?? '').toString();
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      question,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  _buildModerationChip(
                                    isActive ? 'Активен' : 'Скрыт',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(category),
                              if (answer.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(answer),
                              ],
                              if (keywordsText.trim().isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Ключевые слова: $keywordsText',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                              if (canManageSupportKnowledgeBase) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _supportFaqSaving
                                          ? null
                                          : () => _editSupportFaq(entry),
                                      icon: const Icon(Icons.edit_outlined),
                                      label: const Text('Редактировать'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _supportFaqSaving
                                          ? null
                                          : () =>
                                                _toggleSupportFaqActive(entry),
                                      icon: Icon(
                                        isActive
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                      label: Text(
                                        isActive ? 'Скрыть' : 'Показать',
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _supportFaqSaving
                                          ? null
                                          : () => _deleteSupportFaqEntry(entry),
                                      icon: const Icon(Icons.delete_outline),
                                      label: const Text('Удалить'),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
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
              final discountDecision = (claim['customer_discount_status'] ?? '')
                  .toString()
                  .trim();
              final resolutionNote = (claim['resolution_note'] ?? '')
                  .toString()
                  .trim();
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
                      if (claimType == 'discount' &&
                          discountDecision.isNotEmpty)
                        Text(
                          discountDecision == 'pending'
                              ? 'Решение клиента: ожидается'
                              : discountDecision == 'accepted'
                              ? 'Решение клиента: скидка принята'
                              : discountDecision == 'rejected'
                              ? 'Решение клиента: скидка отклонена'
                              : 'Решение клиента: $discountDecision',
                        ),
                      Text('Запрошено: $requested • Подтверждено: $approved'),
                      if (resolutionNote.isNotEmpty)
                        Text(
                          'Комментарий: $resolutionNote',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
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
            'Запросы на ответ',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_supportPendingTickets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('Свободных запросов сейчас нет'),
              ),
            )
          else
            ..._supportPendingTickets.map(
              (ticket) => _buildSupportTicketCard(
                ticket,
                archived: false,
                pending: true,
              ),
            ),
          const SizedBox(height: 16),
          Text(
            'Мои активные чаты поддержки',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_supportActiveTickets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('У вас нет активных чатов поддержки'),
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

  Widget _buildClientCartsTab() {
    final selectedUser = _selectedClientCartUser;
    final selectedUserId = (selectedUser?['id'] ?? '').toString().trim();
    final selectedUserName = _displayName(
      selectedUser ?? const <String, dynamic>{},
      fallback: 'Клиент',
    );
    final selectedUserPhone = (selectedUser?['phone'] ?? '').toString().trim();
    final selectedUserEmail = (selectedUser?['email'] ?? '').toString().trim();
    final selectedUserBlocked = selectedUser?['is_active'] == false;
    final total = _selectedClientCartItems.fold<double>(
      0,
      (sum, item) =>
          sum +
          (_toDouble(item['line_total']) > 0
              ? _toDouble(item['line_total'])
              : (_toDouble(item['price']) * _toInt(item['quantity']))),
    );

    return RefreshIndicator(
      onRefresh: () async {
        if (_clientCartSearchCtrl.text.trim().isNotEmpty) {
          await _searchClientCartsByPhone();
        }
        if (selectedUserId.isNotEmpty) {
          await _loadSelectedClientCart(selectedUserId);
        }
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Корзины клиентов',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _clientCartSearchCtrl,
            keyboardType: TextInputType.phone,
            decoration: withInputLanguageBadge(
              const InputDecoration(
                labelText: 'Последние 4 цифры номера',
                hintText: 'Например: 1234',
                border: OutlineInputBorder(),
              ),
              controller: _clientCartSearchCtrl,
            ),
            onSubmitted: (_) => _searchClientCartsByPhone(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _clientCartSearchLoading
                    ? null
                    : _searchClientCartsByPhone,
                icon: _clientCartSearchLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.search),
                label: const Text('Найти клиентов'),
              ),
              if (selectedUserId.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _clientCartLoading
                      ? null
                      : () => _loadSelectedClientCart(selectedUserId),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Обновить корзину'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_clientCartUsers.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'После ввода номера здесь появятся найденные клиенты',
                ),
              ),
            )
          else
            ..._clientCartUsers.map((user) {
              final userId = (user['id'] ?? '').toString().trim();
              final isSelected = userId.isNotEmpty && userId == selectedUserId;
              final title = _displayName(user, fallback: 'Клиент');
              final subtitleParts = <String>[
                if ((user['phone'] ?? '').toString().trim().isNotEmpty)
                  (user['phone'] ?? '').toString().trim(),
                if ((user['email'] ?? '').toString().trim().isNotEmpty)
                  (user['email'] ?? '').toString().trim(),
              ];
              return Card(
                color: isSelected
                    ? Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withValues(alpha: 0.35)
                    : null,
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(title),
                  subtitle: Text(
                    subtitleParts.isEmpty
                        ? 'Без контактов'
                        : subtitleParts.join(' • '),
                  ),
                  trailing: user['is_active'] == false
                      ? const Icon(Icons.block, color: Colors.red)
                      : const Icon(Icons.chevron_right),
                  onTap: userId.isEmpty
                      ? null
                      : () => _loadSelectedClientCart(userId),
                ),
              );
            }),
          if (selectedUserId.isNotEmpty) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selectedUserName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    if (selectedUserPhone.isNotEmpty ||
                        selectedUserEmail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          [
                            if (selectedUserPhone.isNotEmpty) selectedUserPhone,
                            if (selectedUserEmail.isNotEmpty) selectedUserEmail,
                          ].join(' • '),
                        ),
                      ),
                    if (selectedUserBlocked)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Клиент заблокирован',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'Позиций: ${_selectedClientCartItems.length} • Сумма: ${_formatMoney(total)}',
                    ),
                    if (_clientCartUndoPending)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Есть отложенное действие (2 сек). Можно отменить через кнопку "Отменить" внизу экрана. Переход по другим клиентам не блокируется.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              _clientCartActionBusy ||
                                  _clientCartUndoPending ||
                                  _selectedClientCartItems.isEmpty
                              ? null
                              : _clearSelectedClientCart,
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: const Text('Расформировать корзину'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _clientCartActionBusy ||
                                  _clientCartUndoPending ||
                                  _selectedClientCartItems.isEmpty
                              ? null
                              : _markSelectedClientSelfPickup,
                          icon: const Icon(Icons.storefront_outlined),
                          label: const Text('Самовывоз сегодня'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _clientCartActionBusy ||
                                  _clientCartUndoPending ||
                                  selectedUserBlocked
                              ? null
                              : _blockSelectedClient,
                          icon: const Icon(Icons.block_outlined),
                          label: const Text('Заблокировать клиента'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_clientCartLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_selectedClientCartItems.isEmpty && !_clientCartLoading)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('У клиента нет активных товаров в корзине'),
                ),
              )
            else
              ..._selectedClientCartItems.map((item) {
                final title = (item['title'] ?? 'Товар').toString().trim();
                final qty = _toInt(item['quantity']);
                final status = (item['status'] ?? '').toString().trim();
                final statusLabel = _clientCartStatusLabel(status);
                final price = _toDouble(item['price']);
                final lineTotal = _toDouble(item['line_total']) > 0
                    ? _toDouble(item['line_total'])
                    : price * qty;
                final linkedToDelivery = item['linked_to_delivery'] == true;
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text('Количество: $qty • Статус: $statusLabel'),
                        Text(
                          'Цена: ${_formatMoney(price)} • Сумма: ${_formatMoney(lineTotal)}',
                        ),
                        if (linkedToDelivery)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              'Товар уже в маршруте доставки',
                              style: TextStyle(
                                color: Colors.orange,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed:
                                  _clientCartActionBusy ||
                                      _clientCartUndoPending
                                  ? null
                                  : () => _editSelectedCartItem(item),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Изменить цену/описание'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _clientCartActionBusy ||
                                      _clientCartUndoPending ||
                                      linkedToDelivery
                                  ? null
                                  : () => _removeSelectedCartItem(item),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Удалить товар'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
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
    final visibleByDay = byDay
        .where(
          (row) =>
              _toDouble(row['revenue']) > 0 ||
              _toDouble(row['profit']) != 0 ||
              _toDouble(row['cost']) > 0,
        )
        .toList();
    final periodLabels = {
      'day': 'День',
      'week': 'Неделя',
      'month': 'Месяц',
      'last_month': 'Прошлый месяц',
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
            'Динамика по дням',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (visibleByDay.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Нет данных за выбранный период'),
              ),
            )
          else
            ...visibleByDay.reversed.take(14).map((row) {
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
    final smartNotify = _asMap(_smartNotifySettings);
    final canManageRoleTemplates =
        _isCreatorBase() || _hasPermission('tenant.users.manage');
    return RefreshIndicator(
      onRefresh: () async {
        await _loadControlCenter();
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
                                      key: ValueKey<String>(
                                        'role-selection-$userId-$currentValue',
                                      ),
                                      initialValue: currentValue,
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
                            key: ValueKey<String>(
                              'smart-notify-type-$_smartNotifyType',
                            ),
                            initialValue: _smartNotifyType,
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
                            key: ValueKey<String>(
                              'smart-notify-priority-$_smartNotifyPriority',
                            ),
                            initialValue: _smartNotifyPriority,
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

  String _deliveryCallStatusLabel(Map<String, dynamic> customer) {
    final callStatus = (customer['call_status'] ?? '').toString().trim();
    final deliveryStatus = (customer['delivery_status'] ?? '')
        .toString()
        .trim();
    if (callStatus == 'accepted') return 'Согласился';
    if (callStatus == 'declined') return 'Отказался';
    if (callStatus == 'removed' || deliveryStatus == 'returned_to_cart') {
      return 'Убрали из маршрута';
    }
    if (callStatus == 'pending') {
      if (deliveryStatus == 'offer_sent') {
        return 'Нужно звонить вручную, если не ответит';
      }
      return 'Нужно звонить вручную';
    }
    return callStatus.isEmpty ? '—' : callStatus;
  }

  Widget _buildDeliveryEligiblePreviewCard() {
    final preview = _deliveryEligiblePreview;
    if (preview == null) return const SizedBox.shrink();
    final customers = _asMapList(preview['customers']);
    final eligibleCount = _toInt(preview['eligible_count']);
    final belowCount = _toInt(preview['below_threshold_count']);
    final threshold = _formatMoney(preview['threshold_amount']);
    final eligibleSum = _formatMoney(preview['eligible_sum']);
    final theme = Theme.of(context);
    const pageSize = 10;
    final totalPages = customers.isEmpty
        ? 1
        : ((customers.length + pageSize - 1) ~/ pageSize);
    final currentPage = _deliveryEligiblePreviewPage
        .clamp(0, totalPages - 1)
        .toInt();
    final startIndex = currentPage * pageSize;
    final endIndex = math.min(startIndex + pageSize, customers.length);
    final pageCustomers = customers.skip(startIndex).take(pageSize).toList();

    Widget compactCell(
      String text, {
      required double width,
      FontWeight? weight,
      TextAlign align = TextAlign.left,
      Color? color,
    }) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(fontWeight: weight, color: color),
        ),
      );
    }

    Widget compactRow(
      Map<String, dynamic> customer,
      int index, {
      required bool isOdd,
    }) {
      final name = (customer['customer_name'] ?? 'Клиент').toString();
      final phone = _displayPhone(
        (customer['customer_phone'] ?? '').toString(),
      );
      final sum = _formatMoney(customer['processed_sum']);
      final city = _normalizeDeliveryCityName(customer['client_city']);
      final cityThreshold = _formatMoney(
        customer['delivery_threshold_amount'] ?? preview['threshold_amount'],
      );
      final shelf = _displayShelfValue(
        customer['shelf_label'],
        customer['shelf_number'],
      );
      final itemsCount = _toInt(customer['processed_items_count']);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isOdd
              ? theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                )
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            compactCell(
              '${startIndex + index + 1}',
              width: 34,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            compactCell(name, width: 160, weight: FontWeight.w700),
            compactCell(phone, width: 135),
            compactCell(sum, width: 105, align: TextAlign.right),
            const SizedBox(width: 14),
            compactCell(city.isEmpty ? '—' : city, width: 120),
            compactCell(cityThreshold, width: 105, align: TextAlign.right),
            const SizedBox(width: 14),
            compactCell(shelf, width: 115),
            compactCell('$itemsCount шт.', width: 72, align: TextAlign.right),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.delivery_dining_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Готовы к рассылке',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Порог: $threshold • подходят: $eligibleCount • сумма: $eligibleSum',
            ),
            if (belowCount > 0)
              Text(
                'Еще $belowCount клиентов пока ниже порога и не попадут в рассылку.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            if (customers.isEmpty)
              const Text(
                'Пока нет клиентов, которые набрали сумму выше порога доставки.',
              )
            else ...[
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 900),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Row(
                            children: [
                              compactCell(
                                '#',
                                width: 34,
                                weight: FontWeight.w800,
                              ),
                              compactCell(
                                'Клиент',
                                width: 160,
                                weight: FontWeight.w800,
                              ),
                              compactCell(
                                'Телефон',
                                width: 135,
                                weight: FontWeight.w800,
                              ),
                              compactCell(
                                'Сумма',
                                width: 105,
                                weight: FontWeight.w800,
                                align: TextAlign.right,
                              ),
                              const SizedBox(width: 14),
                              compactCell(
                                'Город',
                                width: 120,
                                weight: FontWeight.w800,
                              ),
                              compactCell(
                                'Порог',
                                width: 105,
                                weight: FontWeight.w800,
                                align: TextAlign.right,
                              ),
                              const SizedBox(width: 14),
                              compactCell(
                                'Полка',
                                width: 115,
                                weight: FontWeight.w800,
                              ),
                              compactCell(
                                'Товар',
                                width: 72,
                                weight: FontWeight.w800,
                                align: TextAlign.right,
                              ),
                            ],
                          ),
                        ),
                        ...pageCustomers.asMap().entries.map(
                          (entry) => compactRow(
                            entry.value,
                            entry.key,
                            isOdd: entry.key.isOdd,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (customers.length > pageSize) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Показаны ${startIndex + 1}-$endIndex из ${customers.length}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Предыдущая страница',
                      onPressed: currentPage <= 0
                          ? null
                          : () => setState(
                              () => _deliveryEligiblePreviewPage =
                                  currentPage - 1,
                            ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${currentPage + 1}/$totalPages'),
                    IconButton(
                      tooltip: 'Следующая страница',
                      onPressed: currentPage >= totalPages - 1
                          ? null
                          : () => setState(
                              () => _deliveryEligiblePreviewPage =
                                  currentPage + 1,
                            ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeliveryCustomerCard(
    String batchId,
    Map<String, dynamic> customer,
  ) {
    final theme = Theme.of(context);
    final name = (customer['customer_name'] ?? 'Клиент').toString();
    final phone = _displayPhone((customer['customer_phone'] ?? '').toString());
    final sum = _formatMoney(
      customer['agreed_sum'] ?? customer['processed_sum'],
    );
    final shelf = _displayShelfValue(
      customer['shelf_label'],
      customer['shelf_number'],
    );
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
    final assemblyStatus = (customer['assembly_status'] ?? 'not_started')
        .toString()
        .trim();
    final canStartAssembly =
        callStatus == 'accepted' && assemblyStatus == 'not_started';
    final canEditAssembly =
        callStatus == 'accepted' && assemblyStatus != 'not_started';
    final canCompleteAssembly =
        callStatus == 'accepted' &&
        assemblyStatus != 'not_started' &&
        assemblyStatus != 'assembled';
    final normalStickers = _toInt(customer['normal_stickers_requested']);
    final bulkyStickers = _toInt(customer['bulky_stickers_requested']);
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
            Text('Ответ после рассылки: ${_deliveryCallStatusLabel(customer)}'),
            if (callStatus == 'accepted') ...[
              Text('Сборка: ${_deliveryAssemblyStatusLabel(assemblyStatus)}'),
              Text(
                'Стикеры: обычных $normalStickers · габаритных $bulkyStickers',
              ),
            ],
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
              const SizedBox(height: 6),
              ...items.take(6).map((item) {
                final itemTitle = (item['product_title'] ?? 'Товар')
                    .toString()
                    .trim();
                final itemStatus = (item['assembly_status'] ?? 'pending')
                    .toString()
                    .trim();
                final flags = <String>[
                  if (item['is_bulky'] == true) 'габарит',
                  if (itemStatus == 'removed') 'убран',
                ];
                return Text(
                  '• $itemTitle · ${_formatMoney(item['line_total'])}'
                  '${flags.isNotEmpty ? ' · ${flags.join(', ')}' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              }),
              if (items.length > 6) Text('Ещё товаров: ${items.length - 6}'),
            ],
            if (_canPrintDeliverySticker) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _printDeliveryCustomerSticker(customer),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Распечатать стикер'),
                  ),
                ],
              ),
            ],
            if (callStatus == 'accepted') ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _deliverySaving || !canStartAssembly
                        ? null
                        : () => _startDeliveryAssembly(batchId, customer),
                    icon: const Icon(Icons.playlist_add_check_circle_outlined),
                    label: const Text('Начать сборку'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving || !canEditAssembly
                        ? null
                        : () => _editDeliveryAssembly(batchId, customer),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('Сборка товаров'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _deliverySaving || !canCompleteAssembly
                        ? null
                        : () => _completeDeliveryAssembly(batchId, customer),
                    icon: const Icon(Icons.task_alt_outlined),
                    label: const Text('Собрано'),
                  ),
                ],
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
                  if (callStatus != 'accepted')
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

  Widget _buildDeliveryCityRatesCard() {
    final theme = Theme.of(context);
    final canEditPricing = _canEditDeliveryPricing();
    final defaultThreshold = _formatMoney(
      _toDouble(_deliveryThresholdCtrl.text, fallback: 1500),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Пороги доставки по городам',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _deliverySaving || !canEditPricing
                      ? null
                      : () => _editDeliveryCityRate(),
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Добавить город'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              canEditPricing
                  ? 'Если город не указан здесь, используется общий порог: $defaultThreshold.'
                  : 'Пороги меняет создатель или арендатор. Если город не указан, используется общий порог: $defaultThreshold.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_deliveryCityRates.isEmpty)
              const Text('Отдельных городских порогов пока нет.')
            else
              ..._deliveryCityRates.map((rate) {
                final city = _normalizeDeliveryCityName(rate['city']);
                final threshold = _formatMoney(rate['threshold_amount']);
                final active = rate['is_active'] != false;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      active
                          ? Icons.location_city_outlined
                          : Icons.location_disabled_outlined,
                    ),
                    title: Text(city.isEmpty ? 'Город без названия' : city),
                    subtitle: Text('Порог: $threshold'),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        IconButton(
                          tooltip: 'Изменить',
                          onPressed: _deliverySaving || !canEditPricing
                              ? null
                              : () => _editDeliveryCityRate(rate),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: 'Удалить',
                          onPressed: _deliverySaving || !canEditPricing
                              ? null
                              : () => _removeDeliveryCityRate(rate),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildDeliveryTab() {
    final activeBatch = _deliveryActiveBatch;
    final customers = _asMapList(activeBatch?['customers']);
    final acceptedCount = customers
        .where(
          (customer) =>
              (customer['call_status'] ?? '').toString() == 'accepted',
        )
        .length;
    final declinedCount = customers
        .where(
          (customer) =>
              (customer['call_status'] ?? '').toString() == 'declined',
        )
        .length;
    final manualCallCount = customers
        .where(
          (customer) => (customer['call_status'] ?? '').toString() == 'pending',
        )
        .length;
    final canEditPricing = _canEditDeliveryPricing();
    final assembledAcceptedCount = customers
        .where(
          (customer) =>
              (customer['call_status'] ?? '').toString() == 'accepted' &&
              (customer['assembly_status'] ?? '').toString() == 'assembled',
        )
        .length;

    return RefreshIndicator(
      onRefresh: _loadDeliveryDashboard,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _deliveryThresholdCtrl,
            enabled: canEditPricing,
            keyboardType: TextInputType.number,
            decoration: withInputLanguageBadge(
              InputDecoration(
                labelText: 'Сумма для попадания в доставку',
                border: OutlineInputBorder(),
                helperText: canEditPricing
                    ? 'Сумма в ₽'
                    : 'Порог может менять только создатель или арендатор',
              ),
              controller: _deliveryThresholdCtrl,
            ),
          ),
          const SizedBox(height: 12),
          _buildDeliveryCityRatesCard(),
          const SizedBox(height: 12),
          TextField(
            controller: _deliveryOriginCtrl,
            minLines: 2,
            maxLines: 3,
            decoration: withInputLanguageBadge(
              const InputDecoration(
                labelText: 'Точка отправки курьеров',
                hintText: 'Город, адрес склада или точки старта',
                border: OutlineInputBorder(),
                helperText: 'Отсюда начинается маршрут каждого курьера',
              ),
              controller: _deliveryOriginCtrl,
            ),
          ),
          const SizedBox(height: 12),
          _buildDeliveryManualPhonesCard(),
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
                    _deliverySaving ? 'Сохранение...' : 'Сохранить настройки',
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
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: _deliverySaving ? null : _resetDeliveryTesting,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Очистить доставку'),
              ),
            ],
          ),
          if (_deliveryEligiblePreview != null) ...[
            const SizedBox(height: 12),
            _buildDeliveryEligiblePreviewCard(),
          ],
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
                    Text(
                      'Согласились: ${activeBatch['accepted_total'] ?? acceptedCount}',
                    ),
                    Text(
                      'Собрано корзин: $assembledAcceptedCount/$acceptedCount',
                    ),
                    Text(
                      'Отказались: ${activeBatch['declined_total'] ?? declinedCount}',
                    ),
                    Text('Нужно звонить вручную: $manualCallCount'),
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
                          onPressed:
                              _deliverySaving ||
                                  (acceptedCount > 0 &&
                                      assembledAcceptedCount < acceptedCount)
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
    final tabs = _visibleTabs
        .map(
          (tab) => Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(tab.icon, size: 18),
                const SizedBox(width: 6),
                Text(tab.label),
              ],
            ),
          ),
        )
        .toList();
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
          tabAlignment: compact ? TabAlignment.start : null,
          labelPadding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
          indicatorSize: TabBarIndicatorSize.tab,
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
  const _AvatarPlacementResult({
    this.croppedPath,
    required this.focusX,
    required this.focusY,
    required this.zoom,
  });

  final String? croppedPath;
  final double focusX;
  final double focusY;
  final double zoom;
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

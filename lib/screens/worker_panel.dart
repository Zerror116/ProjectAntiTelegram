// lib/screens/worker_panel.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../services/web_media_capture_permission_service.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';
import '../utils/phone_utils.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_status_badge.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/app_surface_card.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/phoenix_visual_effects.dart';
import '../widgets/product_media_gallery.dart';
import '../widgets/product_photo_crop_dialog.dart';

Future<Uint8List?> _readPickedPlatformFileBytes(PlatformFile file) async {
  final path = (file.path ?? '').trim();
  if (path.isNotEmpty && !kIsWeb) {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
  try {
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

class WorkerPanel extends StatefulWidget {
  const WorkerPanel({super.key});

  @override
  State<WorkerPanel> createState() => _WorkerPanelState();
}

class _WorkerTabSpec {
  const _WorkerTabSpec({
    required this.id,
    required this.label,
    required this.builder,
  });

  final String id;
  final String label;
  final Widget Function() builder;
}

class _RevisionPickedImage {
  const _RevisionPickedImage({
    required this.bytes,
    required this.fileName,
    this.file,
  });

  final Uint8List bytes;
  final String fileName;
  final XFile? file;
}

class _WorkerPanelState extends State<WorkerPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  StreamSubscription? _authSub;
  List<_WorkerTabSpec> _visibleTabs = const <_WorkerTabSpec>[];
  StreamSubscription? _chatEventsSub;
  Timer? _channelsRefreshDebounce;
  Timer? _ownPostsRefreshDebounce;
  Timer? _revisionProductSearchDebounce;

  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _manualShelfLabelCtrl = TextEditingController();
  final _shelfFloorCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _revisionPercentCtrl = TextEditingController(text: '10');
  final _revisionProductIdSearchCtrl = TextEditingController();
  final Map<String, int> _quickDuplicateCounters = {};

  final ImagePicker _imagePicker = ImagePicker();
  XFile? _pickedImage;
  Uint8List? _pickedImageBytes;
  String? _pickedImageUploadFileName;
  String? _existingImageUrl;
  bool _removeImageOnSubmit = false;

  bool get _isMobileWeb =>
      kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _cameraSupported {
    if (kIsWeb) {
      return _isMobileWeb && WebMediaCapturePermissionService.isSupported;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  bool get _preferFilePickerForGallery {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  bool _loadingChannels = true;
  bool _loadingOwnPosts = false;
  bool _posting = false;
  bool _searching = false;
  bool _savingOwnPost = false;
  bool _loadingTenantFeatureSettings = false;
  bool _loadingRevisionShelves = false;
  bool _loadingRevisionPosts = false;
  bool _loadingDeliveryDashboard = false;
  bool _deliverySaving = false;
  bool _runningRevision = false;
  bool _autoHideOldRevisionPosts = true;
  String _message = '';

  double _toDoubleValue(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(
      value?.toString().replaceAll(',', '.') ?? '',
    );
    return parsed ?? fallback;
  }

  int _toIntValue(dynamic value, [int fallback = 0]) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed ?? fallback;
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

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.map((item) => _asMap(item)).toList();
  }

  String _formatMoney(dynamic value) {
    final amount = _toDoubleValue(value, 0);
    return '${amount.toStringAsFixed(2)} ₽';
  }

  String _formatDateTimeLabel(dynamic raw) {
    return formatDateTimeValue(raw, fallback: '');
  }

  String _formatClockLabel(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    if (value.isEmpty) return '';
    if (value.length >= 5 && value[2] == ':') {
      return value.substring(0, 5);
    }
    return value;
  }

  String _displayPhone(String raw, {String fallback = '—'}) {
    final formatted = PhoneUtils.formatForDisplay(raw);
    if (formatted.isNotEmpty) return formatted;
    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : fallback;
  }

  String _displayShelfValue(dynamic shelfLabel, dynamic shelfNumber) {
    final label = (shelfLabel ?? '').toString().trim();
    if (label.isNotEmpty) return label;
    final rawNumber = (shelfNumber ?? '').toString().trim();
    if (rawNumber.isNotEmpty) return rawNumber;
    return 'не назначена';
  }

  bool get _manualShelfEnabled =>
      _toBoolValue(_tenantFeatureSettings['manual_shelf_enabled']);

  bool get _pickupOnlyEnabled =>
      _toBoolValue(_tenantFeatureSettings['pickup_only_enabled']);

  bool get _revisionDeleteApprovalEnabled =>
      _toBoolValue(_tenantFeatureSettings['revision_delete_approval_enabled']);

  double? _parsedRevisionPercent() {
    final raw = _revisionPercentCtrl.text.trim().replaceAll(',', '.');
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || value <= 0 || value > 95) return null;
    return value.abs();
  }

  int? _previewRevisionPrice(dynamic rawPrice) {
    final percent = _parsedRevisionPercent();
    if (percent == null) return null;
    final price = _toDoubleValue(rawPrice, 0);
    if (price <= 0) return null;
    final discounted = price * (1 - percent / 100);
    final roundedDown = (discounted / 50).floor() * 50;
    final safe = roundedDown < 50 ? 50 : roundedDown;
    return safe.toInt();
  }

  List<Map<String, dynamic>> _mediaItemsOf(Map<String, dynamic> item) {
    final raw = item['media'];
    if (raw is List) {
      return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    return const <Map<String, dynamic>>[];
  }

  String? _coverImageOf(
    Map<String, dynamic> item, {
    String fallbackKey = 'image_url',
  }) {
    final cover = _resolveImageUrl((item['cover_image_url'] ?? '').toString());
    if (cover != null) return cover;
    final media = _mediaItemsOf(item);
    for (final candidate in media) {
      final resolved =
          _resolveImageUrl((candidate['card_url'] ?? '').toString()) ??
          _resolveImageUrl((candidate['detail_url'] ?? '').toString()) ??
          _resolveImageUrl((candidate['original_url'] ?? '').toString()) ??
          _resolveImageUrl((candidate['url'] ?? '').toString());
      if (resolved != null) return resolved;
    }
    return _resolveImageUrl((item[fallbackKey] ?? '').toString());
  }

  void _dismissKeyboard() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.hasFocus ?? false) {
      focus?.unfocus();
    }
  }

  String _extractRequestError(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 413) {
        return 'Фото слишком большое для загрузки. Уменьшите размер и попробуйте снова.';
      }
      final data = error.response?.data;
      if (data is Map) {
        final raw = (data['error'] ?? data['message'] ?? '').toString().trim();
        if (raw.isNotEmpty) return raw;
      }
      final message = (error.message ?? '').trim();
      if (message.isNotEmpty) return message;
    }
    return error.toString();
  }

  int _resolveShelfNumberFromValue(dynamic value, {int fallback = 1}) {
    final parsed = _toIntValue(value, fallback);
    if (parsed <= 0) return fallback;
    return parsed;
  }

  String _manualShelfLabel(dynamic value) {
    return (value ?? '').toString().trim();
  }

  String _productCodePart(dynamic productCode) {
    final code = _toIntValue(productCode, 0);
    return code > 0 ? '$code' : '—';
  }

  String _formatProductLabel(
    dynamic productCode,
    dynamic shelfNumber, {
    dynamic manualShelfLabel,
  }) {
    final shelf = _resolveShelfNumberFromValue(shelfNumber, fallback: 1);
    final manualShelf = _manualShelfLabel(manualShelfLabel);
    final shelfPart = manualShelf.isNotEmpty
        ? manualShelf
        : (shelf > 0 ? shelf.toString().padLeft(2, '0') : '—');
    return '${_productCodePart(productCode)}--$shelfPart';
  }

  String? _productCodeFromLabel(String? label) {
    final raw = (label ?? '').trim();
    if (raw.isEmpty) return null;
    final part = raw.split('--').first.trim();
    return part.isEmpty ? null : part;
  }

  String? _shelfLabelFromProductLabel(String? label) {
    final raw = (label ?? '').trim();
    if (raw.isEmpty) return null;
    final parts = raw.split('--');
    if (parts.length < 2) return null;
    final shelf = parts.sublist(1).join('--').trim();
    return shelf.isEmpty || shelf == '—' ? null : shelf;
  }

  String? _placementShelfLabel({
    dynamic shelfNumber,
    dynamic manualShelfLabel,
    String? productLabel,
  }) {
    final manualShelf = _manualShelfLabel(manualShelfLabel);
    if (manualShelf.isNotEmpty) return manualShelf;
    final shelf = _toIntValue(shelfNumber, 0);
    if (shelf > 0) return shelf.toString().padLeft(2, '0');
    return _shelfLabelFromProductLabel(productLabel);
  }

  int _queuedQuantityForProduct(String productId) {
    if (productId.isEmpty) return 0;
    final matches = _ownQueuedPosts.where(
      (row) => (row['product_id'] ?? '').toString() == productId,
    );
    if (matches.isEmpty) return 0;
    final latest = matches.first;
    final byProduct = _toIntValue(latest['product_quantity'], 0);
    if (byProduct > 0) return byProduct;
    final payload = latest['payload'];
    if (payload is Map) {
      return _toIntValue(payload['quantity'], 0);
    }
    return 0;
  }

  List<Map<String, dynamic>> _channels = [];
  String? _selectedChannelId;
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _ownQueuedPosts = [];
  List<Map<String, dynamic>> _revisionShelves = [];
  List<Map<String, dynamic>> _revisionPosts = [];
  List<Map<String, dynamic>> _deliveryBatches = [];
  Map<String, dynamic> _tenantFeatureSettings = <String, dynamic>{};
  Map<String, dynamic>? _deliveryActiveBatch;
  int? _selectedRevisionShelfNumber;
  bool _pickupOnly = false;
  bool _isBulkyProduct = false;

  @override
  void initState() {
    super.initState();
    _rebuildVisibleTabs(force: true, notify: false);
    _loadActiveTabData();
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if ((type == 'chat:created' || type == 'chat:deleted') &&
          (_isActiveTab('new') || _isActiveTab('old'))) {
        _scheduleChannelsRefresh();
      }
      if ((type == 'channel:updated' ||
              type == 'channel:members:updated' ||
              type == 'channel:media:updated' ||
              type == 'socket:connected') &&
          (_isActiveTab('new') || _isActiveTab('old'))) {
        _scheduleChannelsRefresh();
      }
      if (type == 'chat:updated' ||
          type == 'catalog:queue:updated' ||
          type == 'channel:media:updated' ||
          type == 'socket:connected') {
        _ownPostsRefreshDebounce?.cancel();
        _ownPostsRefreshDebounce = Timer(
          const Duration(milliseconds: 650),
          () async {
            if (_isActiveTab('own')) {
              await _loadOwnQueuedPosts();
            }
            if (_isActiveTab('revision')) {
              await _loadRevisionPosts();
            }
          },
        );
      }
      if ((type == 'delivery:updated' || type == 'socket:connected') &&
          _isActiveTab('delivery')) {
        unawaited(_loadDeliveryDashboard());
      }
    });
    _authSub = authService.authStream.listen((_) {
      final changed = _rebuildVisibleTabs();
      if (changed) {
        _loadActiveTabData();
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _authSub?.cancel();
    _channelsRefreshDebounce?.cancel();
    _ownPostsRefreshDebounce?.cancel();
    _revisionProductSearchDebounce?.cancel();
    _tabController?.dispose();
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    _quantityCtrl.dispose();
    _manualShelfLabelCtrl.dispose();
    _shelfFloorCtrl.dispose();
    _searchCtrl.dispose();
    _revisionPercentCtrl.dispose();
    _revisionProductIdSearchCtrl.dispose();
    super.dispose();
  }

  bool _hasAnyPermission(List<String> keys) {
    for (final key in keys) {
      if (authService.hasPermission(key)) return true;
    }
    return false;
  }

  bool _hasFullWorkerMenuAccess() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'creator' || role == 'tenant';
  }

  bool _isKinelTenantScope() {
    final user = authService.currentUser;
    final tenantCode = (user?.tenantCode ?? '').toLowerCase().trim();
    final tenantName = (user?.tenantName ?? '').toLowerCase().trim();
    return tenantCode == 'kinel-8997' ||
        tenantCode.contains('kinel') ||
        tenantName.contains('кинель');
  }

  bool _isAnnaUtevskayaTenantScope() {
    final user = authService.currentUser;
    final tenantCode = [
      authService.creatorTenantScopeCode,
      user?.tenantCode,
    ].whereType<String>().join(' ').toLowerCase().trim();
    final tenantName = (user?.tenantName ?? '').toLowerCase().trim();
    final compactCode = tenantCode.replaceAll(RegExp(r'[\s_-]+'), '');
    final compactName = tenantName.replaceAll(RegExp(r'\s+'), ' ');
    return tenantCode == 'anna-utevskaya-4898' ||
        (compactCode.contains('anna') && compactCode.contains('utev')) ||
        (compactName.contains('анна') && compactName.contains('утев')) ||
        (compactName.contains('anna') && compactName.contains('utev'));
  }

  String get _placementShelfInputLabel {
    final label = (_tenantFeatureSettings['shelf_field_label'] ?? '')
        .toString()
        .trim();
    if (label.isNotEmpty) return label;
    return _isAnnaUtevskayaTenantScope() ? 'Стеллаж' : 'Номер / название полки';
  }

  String get _placementShelfInputHint => _isAnnaUtevskayaTenantScope()
      ? 'Например: 03 или A-2'
      : 'Например: 03, A-2, верхняя';

  String get _placementBoxInputLabel {
    final label = (_tenantFeatureSettings['floor_field_label'] ?? '')
        .toString()
        .trim();
    if (label.isNotEmpty) return label;
    return _isAnnaUtevskayaTenantScope() ? 'Коробка' : 'Этаж / секция';
  }

  String get _placementBoxInputHint =>
      _isAnnaUtevskayaTenantScope() ? 'Номер коробки' : 'Любые символы';

  String get _placementShelfDisplayLabel {
    final label = (_tenantFeatureSettings['shelf_field_label'] ?? '')
        .toString()
        .trim();
    if (label.isNotEmpty) return label;
    return _isAnnaUtevskayaTenantScope() ? 'Стеллаж' : 'Полка';
  }

  String get _placementBoxDisplayLabel {
    final label = (_tenantFeatureSettings['floor_field_label'] ?? '')
        .toString()
        .trim();
    if (label.isNotEmpty) return label;
    return _isAnnaUtevskayaTenantScope() ? 'Коробка' : 'этаж';
  }

  String _productShelfValue(dynamic shelfNumber, dynamic manualShelfLabel) {
    final manualShelf = (manualShelfLabel ?? '').toString().trim();
    if (manualShelf.isNotEmpty) return manualShelf;
    final shelf = _toIntValue(shelfNumber, 0);
    if (shelf > 0) return shelf.toString().padLeft(2, '0');
    final raw = (shelfNumber ?? '').toString().trim();
    return raw.isNotEmpty ? raw : '—';
  }

  String _productBoxValue(dynamic shelfFloor) {
    final value = (shelfFloor ?? '').toString().trim();
    return value.isNotEmpty ? value : '—';
  }

  List<Widget> _ownPostIdentityChips(Map<String, dynamic> post) {
    if (!_isAnnaUtevskayaTenantScope()) {
      return [
        _statChip(
          'ID ${_formatProductLabel(post['product_code'], post['product_shelf_number'], manualShelfLabel: post['manual_shelf_label'])}',
        ),
      ];
    }
    return [
      _statChip('ID товара: ${_productCodePart(post['product_code'])}'),
      _statChip(
        'Стеллаж: ${_productShelfValue(post['product_shelf_number'], post['manual_shelf_label'])}',
      ),
      _statChip('Коробка: ${_productBoxValue(post['shelf_floor'])}'),
    ];
  }

  bool _canViewDeliveryTab() {
    final role = authService.effectiveRole.toLowerCase().trim();
    if (role == 'worker' && _isKinelTenantScope()) return true;
    return false;
  }

  bool _canViewNewTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const ['product.create']);
  }

  bool _canViewOldTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const ['product.requeue', 'product.create']);
  }

  bool _canViewOwnTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const [
      'product.edit.own_pending',
      'product.create',
    ]);
  }

  bool _canViewRevisionTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const [
      'product.requeue',
      'product.edit.own_pending',
      'product.create',
    ]);
  }

  List<_WorkerTabSpec> _buildVisibleTabs() {
    final tabs = <_WorkerTabSpec>[
      if (_canViewNewTab())
        _WorkerTabSpec(
          id: 'new',
          label: 'Новый товар',
          builder: _buildQueueTab,
        ),
      if (_canViewOldTab())
        _WorkerTabSpec(
          id: 'old',
          label: 'Старые товары',
          builder: _buildSearchTab,
        ),
      if (_canViewOwnTab())
        _WorkerTabSpec(
          id: 'own',
          label: 'Свои посты',
          builder: _buildOwnPostsTab,
        ),
      if (_canViewRevisionTab())
        _WorkerTabSpec(
          id: 'revision',
          label: 'Ревизия',
          builder: _buildRevisionTab,
        ),
      if (_canViewDeliveryTab())
        _WorkerTabSpec(
          id: 'delivery',
          label: 'Доставка',
          builder: _buildDeliveryTab,
        ),
    ];
    if (tabs.isNotEmpty) return tabs;
    return <_WorkerTabSpec>[
      _WorkerTabSpec(
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
    if (unchanged && _tabController != null) return false;

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
    _tabController?.addListener(_handleActiveTabChanged);
    if (notify && mounted) {
      setState(() {});
    }
    return true;
  }

  String? _activeTabId() {
    final controller = _tabController;
    if (controller == null || _visibleTabs.isEmpty) return null;
    final index = controller.index.clamp(0, _visibleTabs.length - 1);
    return _visibleTabs[index].id;
  }

  bool _isActiveTab(String id) => _activeTabId() == id;

  void _handleActiveTabChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    _loadActiveTabData();
  }

  void _scheduleChannelsRefresh() {
    _channelsRefreshDebounce?.cancel();
    _channelsRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (_isActiveTab('new') || _isActiveTab('old')) {
        _loadChannels();
      }
    });
  }

  void _animateToTab(String id) {
    final controller = _tabController;
    if (controller == null) return;
    final index = _visibleTabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    if (controller.index == index && !controller.indexIsChanging) return;
    controller.animateTo(index);
  }

  void _loadActiveTabData() {
    switch (_activeTabId()) {
      case 'new':
      case 'old':
        _loadTenantFeatureSettings();
        _loadChannels();
        break;
      case 'own':
        _loadOwnQueuedPosts();
        break;
      case 'revision':
        _loadTenantFeatureSettings();
        _loadRevisionShelves();
        break;
      case 'delivery':
        _loadDeliveryDashboard();
        break;
    }
  }

  Future<void> _loadTenantFeatureSettings({bool silent = true}) async {
    if (_loadingTenantFeatureSettings) return;
    _loadingTenantFeatureSettings = true;
    try {
      final resp = await authService.dio.get(
        '/api/profile/tenant/feature-settings',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        if (!mounted) return;
        setState(() {
          _tenantFeatureSettings = Map<String, dynamic>.from(
            data['data'] as Map,
          );
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message =
              'Ошибка загрузки настроек группы: ${_extractRequestError(e)}',
        );
      }
    } finally {
      _loadingTenantFeatureSettings = false;
    }
  }

  String? _resolveImageUrl(String? raw) {
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  String? _normalizedImageUrlFromForm() {
    if (_removeImageOnSubmit) return null;
    final normalized = _existingImageUrl?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  Map<String, dynamic> _productFromOwnQueuedPost(Map<String, dynamic> post) {
    return {
      'id': (post['product_id'] ?? '').toString(),
      'title': (post['product_title'] ?? '').toString(),
      'description': (post['product_description'] ?? '').toString(),
      'price': post['product_price'],
      'quantity': post['product_quantity'],
      'image_url': (post['product_image_url'] ?? '').toString(),
      'product_code': post['product_code'],
      'shelf_number': post['product_shelf_number'],
      'manual_shelf_label': post['manual_shelf_label'],
      'shelf_floor': post['shelf_floor'],
      'pickup_only': post['pickup_only'],
    };
  }

  Future<void> _showShelfFullscreenNotice({
    required String shelfLabel,
    String? productCodeLabel,
    String? productLabel,
  }) async {
    if (!mounted) return;
    final normalizedShelfLabel = shelfLabel.trim();
    if (normalizedShelfLabel.isEmpty) return;
    final normalizedProductCode =
        (productCodeLabel ?? _productCodeFromLabel(productLabel) ?? '').trim();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'shelf_notice',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final theme = Theme.of(dialogContext);
        return SafeArea(
          child: Material(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.98),
            child: InkWell(
              onTap: () => Navigator.of(dialogContext).pop(),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_2_rounded,
                        size: 72,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Положите товар на полку $normalizedShelfLabel',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (normalizedProductCode.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          'ID товара',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer
                                .withValues(alpha: 0.86),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onErrorContainer
                                .withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: theme.colorScheme.onErrorContainer
                                  .withValues(alpha: 0.18),
                            ),
                          ),
                          child: Text(
                            normalizedProductCode,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Text(
                        'Полка',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer.withValues(
                            alpha: 0.86,
                          ),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onErrorContainer.withValues(
                            alpha: 0.09,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: theme.colorScheme.onErrorContainer
                                .withValues(alpha: 0.18),
                          ),
                        ),
                        child: Text(
                          normalizedShelfLabel,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Нажмите в любом месте, чтобы закрыть',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _resetProductForm() {
    _titleCtrl.clear();
    _descriptionCtrl.clear();
    _priceCtrl.clear();
    _quantityCtrl.text = '1';
    _manualShelfLabelCtrl.clear();
    _shelfFloorCtrl.clear();
    _pickedImage = null;
    _pickedImageBytes = null;
    _pickedImageUploadFileName = null;
    _existingImageUrl = null;
    _removeImageOnSubmit = false;
    _pickupOnly = false;
    _isBulkyProduct = false;
  }

  Color _messageColor(ThemeData theme) {
    final normalized = _message.toLowerCase();
    final isError =
        normalized.contains('ошибка') ||
        normalized.contains('не удалось') ||
        normalized.contains('добавьте') ||
        normalized.contains('введите') ||
        normalized.contains('выберите');
    return isError ? theme.colorScheme.error : theme.colorScheme.primary;
  }

  int _countLetterRunes(String text) {
    var count = 0;
    for (final rune in text.runes) {
      final isLatin =
          (rune >= 0x0041 && rune <= 0x005A) ||
          (rune >= 0x0061 && rune <= 0x007A) ||
          (rune >= 0x00C0 && rune <= 0x024F);
      final isCyrillic =
          (rune >= 0x0400 && rune <= 0x04FF) ||
          (rune >= 0x0500 && rune <= 0x052F);
      final isArmenian = rune >= 0x0530 && rune <= 0x058F;
      final isGreek = rune >= 0x0370 && rune <= 0x03FF;
      final isGeorgian =
          (rune >= 0x10A0 && rune <= 0x10FF) ||
          (rune >= 0x1C90 && rune <= 0x1CBF);
      final isHebrew = rune >= 0x0590 && rune <= 0x05FF;
      final isArabic =
          (rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0750 && rune <= 0x077F) ||
          (rune >= 0x08A0 && rune <= 0x08FF);
      if (isLatin ||
          isCyrillic ||
          isArmenian ||
          isGreek ||
          isGeorgian ||
          isHebrew ||
          isArabic) {
        count += 1;
      }
    }
    return count;
  }

  String? _validateProductFields({
    required String title,
    required String description,
    required double? price,
    required int quantity,
    required bool hasImage,
  }) {
    if (title.isEmpty) {
      return 'Введите название товара';
    }
    if (!hasImage) {
      return 'Добавьте фото товара';
    }
    if (description.isEmpty) {
      return 'Введите описание товара';
    }
    if (_countLetterRunes(description) < 2) {
      return 'Описание должно содержать минимум 2 буквы, а не только цифры';
    }
    if (price == null || price <= 0) {
      return 'Цена должна быть больше нуля';
    }
    if (quantity <= 0) {
      return 'Количество должно быть больше нуля';
    }
    return null;
  }

  Future<void> _openImagePickerSheet() async {
    await _pickImage(ImageSource.gallery);
  }

  String _resolvedPickedFileName(XFile? picked) {
    final preferred = _pickedImageUploadFileName?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return preferred;
    }
    final fromName = picked?.name.trim() ?? '';
    if (fromName.isNotEmpty) return fromName;
    final path = picked?.path.trim() ?? '';
    if (path.isNotEmpty) {
      final normalized = path.replaceAll('\\', '/');
      final fromPath = normalized.split('/').last.trim();
      if (fromPath.isNotEmpty) return fromPath;
    }
    return 'product-photo.jpg';
  }

  Future<void> _cropCurrentPickedImage() async {
    final picked = _pickedImage;
    Uint8List? sourceBytes = _pickedImageBytes;
    if ((sourceBytes == null || sourceBytes.isEmpty) && picked != null) {
      try {
        sourceBytes = await picked.readAsBytes();
      } catch (_) {
        sourceBytes = null;
      }
    }
    if (sourceBytes == null || sourceBytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _message = 'Сначала выберите фото, затем обрежьте его';
      });
      return;
    }

    try {
      if (!mounted) return;
      final result = await showProductPhotoCropDialog(
        context: context,
        sourceBytes: Uint8List.fromList(sourceBytes),
        originalFileName: _resolvedPickedFileName(picked),
      );
      if (result == null || !mounted) return;
      setState(() {
        _pickedImageBytes = result.bytes;
        _pickedImageUploadFileName = result.fileName;
        _removeImageOnSubmit = false;
        _message = '';
      });
      showAppNotice(
        context,
        'Обрезка фото применена',
        tone: AppNoticeTone.success,
        duration: const Duration(milliseconds: 900),
      );
      await playAppSound(AppUiSound.tap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось обрезать фото: $e');
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      var effectiveSource = source;
      if (source == ImageSource.camera && !_cameraSupported) {
        if (mounted) {
          setState(
            () => _message =
                'Камера недоступна на этом устройстве. Выберите фото из файлов.',
          );
        }
        effectiveSource = ImageSource.gallery;
      }

      XFile? picked;
      Uint8List? preloadedBytes;
      String? preloadedFileName;
      if (kIsWeb && effectiveSource == ImageSource.camera) {
        try {
          await WebMediaCapturePermissionService.requestPreferredAccess(
            includeVideo: true,
          );
        } catch (_) {}
        try {
          picked = await _imagePicker.pickImage(
            source: ImageSource.camera,
            preferredCameraDevice: CameraDevice.rear,
          );
        } catch (_) {}
        if (picked == null) {
          final selected = await FilePicker.pickFile(type: FileType.image);
          final bytes = selected == null
              ? null
              : await _readPickedPlatformFileBytes(selected);
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'camera-image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          }
        }
      } else if (effectiveSource == ImageSource.gallery &&
          _preferFilePickerForGallery) {
        if (kIsWeb) {
          // Web: read bytes directly from FilePicker to avoid revoked Blob URLs.
          final selected = await FilePicker.pickFile(type: FileType.image);
          final bytes = selected == null
              ? null
              : await _readPickedPlatformFileBytes(selected);
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          } else if (selected != null) {
            if (!mounted) return;
            setState(() {
              _message = 'Браузер не отдал данные фото. Повторите выбор файла.';
            });
            return;
          }
        } else {
          // Desktop: first try ImagePicker, then fallback to FilePicker.
          try {
            picked = await _imagePicker.pickImage(source: ImageSource.gallery);
          } catch (_) {}

          try {
            if (picked == null) {
              final selected = await FilePicker.pickFile(type: FileType.image);
              final path = selected?.path;
              if (path != null && path.isNotEmpty) {
                picked = XFile(path, name: selected?.name ?? '');
              } else {
                final bytes = selected == null
                    ? null
                    : await _readPickedPlatformFileBytes(selected);
                if (bytes != null && bytes.isNotEmpty) {
                  preloadedBytes = bytes;
                  preloadedFileName = (selected?.name ?? 'image.jpg').trim();
                  picked = XFile.fromData(bytes, name: preloadedFileName);
                }
              }
            }
          } catch (_) {
            // Ignore and handle below.
          }
        }
      } else {
        picked = await _imagePicker.pickImage(source: effectiveSource);
      }

      if (picked == null &&
          (preloadedBytes == null || preloadedBytes.isEmpty)) {
        if (!mounted) return;
        setState(() {
          _message = 'Фото не выбрано';
        });
        return;
      }

      Uint8List pickedBytes;
      if (preloadedBytes != null && preloadedBytes.isNotEmpty) {
        pickedBytes = preloadedBytes;
      } else {
        try {
          pickedBytes = await picked!.readAsBytes();
        } catch (e) {
          if (!mounted) return;
          setState(() => _message = 'Не удалось прочитать фото: $e');
          return;
        }
      }
      if (pickedBytes.isEmpty) {
        if (!mounted) return;
        setState(() => _message = 'Выбрано пустое изображение');
        return;
      }
      final stablePickedBytes = Uint8List.fromList(pickedBytes);

      if (!mounted) return;
      if (preloadedFileName != null && preloadedFileName.isNotEmpty) {
        _pickedImageUploadFileName = preloadedFileName;
      }
      ProductPhotoCropResult? cropResult;
      try {
        cropResult = await showProductPhotoCropDialog(
          context: context,
          sourceBytes: stablePickedBytes,
          originalFileName: _resolvedPickedFileName(picked),
        );
      } catch (cropError) {
        if (!mounted) return;
        setState(() {
          _pickedImage = picked;
          _pickedImageBytes = stablePickedBytes;
          _pickedImageUploadFileName = _resolvedPickedFileName(picked);
          _removeImageOnSubmit = false;
          _message = '';
        });
        showAppNotice(
          context,
          'Обрезка недоступна для этого файла, фото добавлено без обрезки',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
        debugPrint('worker_panel.crop_fallback error=$cropError');
        return;
      }
      if (cropResult == null) {
        return;
      }
      final resolvedCropResult = cropResult;
      if (!mounted) return;
      setState(() {
        _pickedImage = picked;
        _pickedImageBytes = resolvedCropResult.bytes;
        _pickedImageUploadFileName = resolvedCropResult.fileName;
        _removeImageOnSubmit = false;
        _message = '';
      });
      showAppNotice(
        context,
        'Фото добавлено',
        tone: AppNoticeTone.success,
        duration: const Duration(milliseconds: 900),
      );
      await playAppSound(AppUiSound.tap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось выбрать фото: $e');
    }
  }

  void _clearSelectedImage() {
    setState(() {
      _pickedImage = null;
      _pickedImageBytes = null;
      _pickedImageUploadFileName = null;
      _existingImageUrl = null;
      _removeImageOnSubmit = true;
    });
  }

  Future<MultipartFile?> _buildPickedImageMultipart() async {
    final picked = _pickedImage;
    final fileName = _resolvedPickedFileName(picked);
    final preparedBytes = _pickedImageBytes;
    if (preparedBytes != null && preparedBytes.isNotEmpty) {
      return MultipartFile.fromBytes(preparedBytes, filename: fileName);
    }
    if (picked == null) return null;

    if (kIsWeb) {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return null;
      return MultipartFile.fromBytes(bytes, filename: fileName);
    }

    final path = picked.path;
    if (path.isEmpty) return null;
    return MultipartFile.fromFile(path, filename: fileName);
  }

  String _resolvedRevisionFileName(XFile? picked, String? preferred) {
    final explicit = preferred?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final fromName = picked?.name.trim() ?? '';
    if (fromName.isNotEmpty) return fromName;
    final path = picked?.path.trim() ?? '';
    if (path.isNotEmpty) {
      final normalized = path.replaceAll('\\', '/');
      final fromPath = normalized.split('/').last.trim();
      if (fromPath.isNotEmpty) return fromPath;
    }
    return 'revision-photo.jpg';
  }

  Future<_RevisionPickedImage?> _pickRevisionImage(ImageSource source) async {
    try {
      var effectiveSource = source;
      if (source == ImageSource.camera && !_cameraSupported) {
        effectiveSource = ImageSource.gallery;
      }

      XFile? picked;
      Uint8List? preloadedBytes;
      String? preloadedFileName;
      if (kIsWeb && effectiveSource == ImageSource.camera) {
        try {
          await WebMediaCapturePermissionService.requestPreferredAccess(
            includeVideo: true,
          );
        } catch (_) {}
        try {
          picked = await _imagePicker.pickImage(
            source: ImageSource.camera,
            preferredCameraDevice: CameraDevice.rear,
          );
        } catch (_) {}
        if (picked == null) {
          final selected = await FilePicker.pickFile(type: FileType.image);
          final bytes = selected == null
              ? null
              : await _readPickedPlatformFileBytes(selected);
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'camera-image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          }
        }
      } else if (effectiveSource == ImageSource.gallery &&
          _preferFilePickerForGallery) {
        if (kIsWeb) {
          final selected = await FilePicker.pickFile(type: FileType.image);
          final bytes = selected == null
              ? null
              : await _readPickedPlatformFileBytes(selected);
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          }
        } else {
          try {
            picked = await _imagePicker.pickImage(source: ImageSource.gallery);
          } catch (_) {}
          if (picked == null) {
            final selected = await FilePicker.pickFile(type: FileType.image);
            final path = selected?.path;
            if (path != null && path.isNotEmpty) {
              picked = XFile(path, name: selected?.name ?? '');
            } else {
              final bytes = selected == null
                  ? null
                  : await _readPickedPlatformFileBytes(selected);
              if (bytes != null && bytes.isNotEmpty) {
                preloadedBytes = bytes;
                preloadedFileName = (selected?.name ?? 'image.jpg').trim();
                picked = XFile.fromData(bytes, name: preloadedFileName);
              }
            }
          }
        }
      } else {
        picked = await _imagePicker.pickImage(source: effectiveSource);
      }

      Uint8List? pickedBytes = preloadedBytes;
      if ((pickedBytes == null || pickedBytes.isEmpty) && picked != null) {
        pickedBytes = await picked.readAsBytes();
      }
      if (pickedBytes == null || pickedBytes.isEmpty) {
        return null;
      }

      final stableBytes = Uint8List.fromList(pickedBytes);
      final originalFileName = _resolvedRevisionFileName(
        picked,
        preloadedFileName,
      );
      try {
        if (!mounted) return null;
        final cropResult = await showProductPhotoCropDialog(
          context: context,
          sourceBytes: stableBytes,
          originalFileName: originalFileName,
        );
        if (cropResult == null) return null;
        return _RevisionPickedImage(
          bytes: cropResult.bytes,
          fileName: cropResult.fileName,
          file: picked,
        );
      } catch (_) {
        return _RevisionPickedImage(
          bytes: stableBytes,
          fileName: originalFileName,
          file: picked,
        );
      }
    } catch (e) {
      if (!mounted) return null;
      setState(() => _message = 'Не удалось выбрать фото: $e');
      return null;
    }
  }

  Future<MultipartFile> _buildRevisionImageMultipart(
    _RevisionPickedImage image,
  ) async {
    if (image.bytes.isNotEmpty) {
      return MultipartFile.fromBytes(image.bytes, filename: image.fileName);
    }
    final path = image.file?.path ?? '';
    return MultipartFile.fromFile(path, filename: image.fileName);
  }

  Future<void> _openRevisionImagePickerSheet({
    required ValueChanged<_RevisionPickedImage?> onChanged,
  }) async {
    final picked = await _pickRevisionImage(ImageSource.gallery);
    if (picked != null) onChanged(picked);
  }

  Future<FormData> _buildCreateProductPayload({
    required String title,
    required String description,
    required double price,
    required int quantity,
  }) async {
    final map = <String, dynamic>{
      'title': title,
      'description': description,
      'price': price,
      'quantity': quantity,
      'is_bulky': _isBulkyProduct ? 'true' : 'false',
    };
    if (_manualShelfEnabled) {
      map['manual_shelf_label'] = _manualShelfLabelCtrl.text.trim();
      map['shelf_floor'] = _shelfFloorCtrl.text.trim();
    }
    if (_pickupOnlyEnabled) {
      map['pickup_only'] = _pickupOnly ? 'true' : 'false';
    }

    if (_pickedImage != null || (_pickedImageBytes?.isNotEmpty ?? false)) {
      final imageFile = await _buildPickedImageMultipart();
      if (imageFile != null) {
        map['image'] = imageFile;
      }
    } else {
      final imageUrl = _normalizedImageUrlFromForm();
      if (imageUrl != null) {
        map['image_url'] = imageUrl;
      }
    }

    return FormData.fromMap(map);
  }

  Future<FormData> _buildRequeuePayload({
    required Map<String, dynamic> product,
    required String channelId,
    required String title,
    required String description,
    required double price,
    required int quantity,
  }) async {
    final map = <String, dynamic>{
      'channel_id': channelId,
      'title': title,
      'description': description,
      'price': price,
      'quantity': quantity,
      'is_bulky': _isBulkyProduct ? 'true' : 'false',
    };
    if (_manualShelfEnabled) {
      map['manual_shelf_label'] = _manualShelfLabelCtrl.text.trim();
      map['shelf_floor'] = _shelfFloorCtrl.text.trim();
    }
    if (_pickupOnlyEnabled) {
      map['pickup_only'] = _pickupOnly ? 'true' : 'false';
    }

    if (_pickedImage != null || (_pickedImageBytes?.isNotEmpty ?? false)) {
      final imageFile = await _buildPickedImageMultipart();
      if (imageFile != null) {
        map['image'] = imageFile;
      }
    } else if (_removeImageOnSubmit) {
      map['image_url'] = '';
    } else {
      final imageUrl = _normalizedImageUrlFromForm();
      if (imageUrl != null) {
        map['image_url'] = imageUrl;
      } else if ((product['image_url'] ?? '').toString().trim().isNotEmpty) {
        map['image_url'] = (product['image_url'] ?? '').toString().trim();
      }
    }

    return FormData.fromMap(map);
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loadingChannels = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get('/api/worker/channels');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final channels = List<Map<String, dynamic>>.from(data['data']);
        setState(() {
          _channels = channels;
          _selectedChannelId = channels.isNotEmpty
              ? channels.first['id']?.toString()
              : null;
        });
      } else {
        setState(() => _message = 'Не удалось загрузить каналы');
      }
    } catch (e) {
      setState(
        () => _message = 'Ошибка загрузки каналов: ${_extractRequestError(e)}',
      );
    } finally {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  Future<void> _loadOwnQueuedPosts() async {
    if (mounted) {
      setState(() => _loadingOwnPosts = true);
    }
    try {
      final resp = await authService.dio.get('/api/worker/queue/mine');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _ownQueuedPosts = List<Map<String, dynamic>>.from(data['data']);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message =
            'Ошибка загрузки своих постов: ${_extractRequestError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _loadingOwnPosts = false);
      }
    }
  }

  Future<void> _loadRevisionShelves() async {
    if (mounted) {
      setState(() => _loadingRevisionShelves = true);
    }
    try {
      final resp = await authService.dio.get('/api/worker/revision/dates');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final shelves = List<Map<String, dynamic>>.from(data['data']);
        final availableShelves = shelves
            .map((e) => _toIntValue(e['shelf_number'], 0))
            .where((e) => e >= 1 && e <= 10)
            .toList();
        final firstWithPosts = shelves
            .where((e) => _toIntValue(e['posts'], 0) > 0)
            .map((e) => _toIntValue(e['shelf_number'], 0))
            .where((e) => e >= 1 && e <= 10)
            .cast<int?>()
            .firstWhere((_) => true, orElse: () => null);
        final nextSelected =
            (_selectedRevisionShelfNumber != null &&
                availableShelves.contains(_selectedRevisionShelfNumber))
            ? _selectedRevisionShelfNumber
            : (firstWithPosts ??
                  (availableShelves.isNotEmpty ? availableShelves.first : 1));
        if (!mounted) return;
        setState(() {
          _revisionShelves = shelves;
          _selectedRevisionShelfNumber = nextSelected;
        });
        await _loadRevisionPosts();
      } else {
        if (!mounted) return;
        setState(() {
          _revisionShelves = [];
          _selectedRevisionShelfNumber = 1;
          _revisionPosts = [];
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка загрузки полок ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingRevisionShelves = false);
      }
    }
  }

  void _scheduleRevisionProductSearch(String value) {
    _revisionProductSearchDebounce?.cancel();
    _revisionProductSearchDebounce = Timer(
      const Duration(milliseconds: 350),
      () {
        if (!mounted) return;
        unawaited(_loadRevisionPosts());
      },
    );
  }

  Future<void> _loadRevisionPosts() async {
    if (mounted) {
      setState(() => _loadingRevisionPosts = true);
    }
    try {
      final selected = _selectedRevisionShelfNumber ?? 1;
      final productSearch = _revisionProductIdSearchCtrl.text.trim();
      final resp = await authService.dio.get(
        '/api/worker/revision/posts',
        queryParameters: {
          'shelf_number': selected,
          if (productSearch.isNotEmpty) 'product_id': productSearch,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        final posts = payload['posts'] is List
            ? List<Map<String, dynamic>>.from(payload['posts'])
            : <Map<String, dynamic>>[];
        final responseShelf = _toIntValue(payload['shelf_number'], selected);
        final nextSelected = responseShelf >= 1 && responseShelf <= 10
            ? responseShelf
            : selected;
        if (!mounted) return;
        setState(() {
          _revisionPosts = posts;
          _selectedRevisionShelfNumber = nextSelected;
        });
      } else {
        if (!mounted) return;
        setState(() => _revisionPosts = []);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка загрузки постов ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingRevisionPosts = false);
      }
    }
  }

  int _revisionShelfOf(Map<String, dynamic> post) {
    final shelf = _toIntValue(
      post['revision_shelf_number'] ??
          post['shelf_number'] ??
          post['source_product_shelf_number'],
      0,
    );
    return shelf >= 1 && shelf <= 10 ? shelf : 0;
  }

  bool _isRevisionBlocked(Map<String, dynamic> post) {
    return post['revision_allowed'] == false;
  }

  String _revisionBlockedNote(Map<String, dynamic> post) {
    return (post['revision_note'] ?? '').toString().trim();
  }

  bool _oldPostRequeueAllowed(Map<String, dynamic> product) {
    return product['requeue_allowed'] != false;
  }

  bool _oldPostQuickDuplicateAllowed(Map<String, dynamic> product) {
    return product['quick_duplicate_allowed'] != false;
  }

  String _oldPostReuseHint(Map<String, dynamic> product) {
    return (product['reuse_hint'] ?? '').toString().trim();
  }

  void _applyRevisionProductsRemovedLocally(Set<String> productIds) {
    if (productIds.isEmpty || !mounted) return;
    final remainingPosts = _revisionPosts
        .where(
          (post) => !productIds.contains(
            (post['product_id'] ?? '').toString().trim(),
          ),
        )
        .toList();
    final countsByShelf = <int, int>{};
    for (final post in remainingPosts) {
      final shelf = _revisionShelfOf(post);
      if (shelf <= 0) continue;
      countsByShelf.update(shelf, (value) => value + 1, ifAbsent: () => 1);
    }

    final nextShelves = <Map<String, dynamic>>[];
    for (final item in _revisionShelves) {
      final copy = Map<String, dynamic>.from(item);
      final shelf = _toIntValue(copy['shelf_number'], 0);
      final nextCount = countsByShelf[shelf] ?? 0;
      copy['posts'] = nextCount;
      nextShelves.add(copy);
    }

    final nextSelected =
        (_selectedRevisionShelfNumber != null &&
            nextShelves.any(
              (item) =>
                  _toIntValue(item['shelf_number'], 0) ==
                  _selectedRevisionShelfNumber,
            ))
        ? _selectedRevisionShelfNumber
        : (nextShelves.isNotEmpty
              ? _toIntValue(nextShelves.first['shelf_number'], 1)
              : 1);

    setState(() {
      _revisionPosts = remainingPosts;
      _revisionShelves = nextShelves;
      _selectedRevisionShelfNumber = nextSelected;
    });
  }

  void _mergeOwnQueuedPostLocally(Map<String, dynamic> queuedItem) {
    if (!mounted) return;
    final queueId = (queuedItem['queue_id'] ?? queuedItem['id'] ?? '')
        .toString()
        .trim();
    if (queueId.isEmpty) return;

    final payload = queuedItem['payload'] is Map
        ? Map<String, dynamic>.from(queuedItem['payload'])
        : <String, dynamic>{
            'title': queuedItem['product_title'],
            'description': queuedItem['product_description'],
            'price': queuedItem['product_price'],
            'quantity': queuedItem['product_quantity'],
            'shelf_number': queuedItem['product_shelf_number'],
            'image_url': queuedItem['product_image_url'],
          };

    final nextRow = <String, dynamic>{
      'id': queueId,
      'product_id': (queuedItem['product_id'] ?? '').toString(),
      'channel_id': (_selectedChannelId ?? '').toString(),
      'queued_by': authService.currentUser?.id,
      'status': 'pending',
      'is_sent': false,
      'payload': payload,
      'created_at':
          queuedItem['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      'product_code': queuedItem['product_code'],
      'product_shelf_number': queuedItem['product_shelf_number'],
      'product_title': queuedItem['product_title'],
      'product_description': queuedItem['product_description'],
      'product_price': queuedItem['product_price'],
      'product_quantity': queuedItem['product_quantity'],
      'product_image_url': queuedItem['product_image_url'],
    };

    final nextItems = List<Map<String, dynamic>>.from(_ownQueuedPosts);
    final index = nextItems.indexWhere(
      (row) => (row['id'] ?? '').toString().trim() == queueId,
    );
    if (index >= 0) {
      nextItems[index] = {...nextItems[index], ...nextRow};
    } else {
      nextItems.insert(0, nextRow);
    }

    nextItems.sort((a, b) {
      final left =
          DateTime.tryParse((a['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final right =
          DateTime.tryParse((b['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });

    setState(() => _ownQueuedPosts = nextItems);
  }

  Future<void> _selectRevisionShelf(int shelfNumber) async {
    if (shelfNumber < 1 || shelfNumber > 10) return;
    if (_selectedRevisionShelfNumber == shelfNumber) return;
    if (!mounted) return;
    setState(() => _selectedRevisionShelfNumber = shelfNumber);
    await _loadRevisionPosts();
  }

  Future<void> _runAutoRevision() async {
    final rawPercent = _revisionPercentCtrl.text.trim().replaceAll(',', '.');
    final enteredPercent = double.tryParse(rawPercent);
    if (enteredPercent == null) {
      setState(() => _message = 'Введите корректный процент ревизии');
      return;
    }
    if (enteredPercent <= 0 || enteredPercent > 95) {
      setState(
        () => _message = 'Процент снижения должен быть больше 0 и не больше 95',
      );
      return;
    }
    final percent = enteredPercent.abs();
    final selectedShelf = _selectedRevisionShelfNumber ?? 0;
    if (selectedShelf < 1 || selectedShelf > 10) {
      setState(() => _message = 'Выберите полку ревизии');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Авто-ревизия'),
        content: Text(
          'Снизить цены на ${enteredPercent.toStringAsFixed(enteredPercent % 1 == 0 ? 0 : 1)}% и '
          '${_autoHideOldRevisionPosts ? 'скрыть старые версии постов' : 'оставить старые версии'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Запустить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (mounted) {
      setState(() => _runningRevision = true);
    }
    try {
      final resp = await authService.dio.post(
        '/api/worker/revision/auto',
        data: {
          'shelf_number': selectedShelf,
          'percent': percent,
          'hide_old_versions': _autoHideOldRevisionPosts,
        },
      );
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      final updatedCount = _toIntValue(payload['updated_count']);
      final queuedCount = _toIntValue(payload['queued_count'], updatedCount);
      final reusedCount = _toIntValue(payload['reused_pending_count']);
      final queuedItems = payload['queued_items'] is List
          ? List<Map<String, dynamic>>.from(payload['queued_items'])
          : const <Map<String, dynamic>>[];
      final affectedProductIds = queuedItems
          .map((item) => (item['product_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _applyRevisionProductsRemovedLocally(affectedProductIds);
      if (!mounted) return;
      setState(
        () => _message =
            'Авто-ревизия: в очередь поставлено $queuedCount '
            '(обновлено существующих в очереди: $reusedCount). '
            'В канал уйдёт только после кнопки админа "Отправить посты на канал".',
      );
      showAppNotice(
        context,
        'Авто-ревизия поставлена в очередь',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      unawaited(_loadOwnQueuedPosts());
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка авто-ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _runningRevision = false);
      }
    }
  }

  Future<void> _manualRevisionEdit(Map<String, dynamic> post) async {
    if (_isRevisionBlocked(post)) {
      if (!mounted) return;
      final note = _revisionBlockedNote(post);
      setState(
        () => _message = note.isNotEmpty
            ? note
            : 'Этот товар сейчас нельзя ревизовать',
      );
      return;
    }
    final missingPhotoRecovery =
        _toBoolValue(post['creator_missing_photo_recovery']) ||
        _toBoolValue(post['hidden_missing_photo']);
    final existingRevisionImageUrl = missingPhotoRecovery
        ? ''
        : (post['image_url'] ?? '').toString().trim();
    _RevisionPickedImage? revisionImage;
    final titleCtrl = TextEditingController(
      text: (post['title'] ?? '').toString(),
    );
    final descriptionCtrl = TextEditingController(
      text: (post['description'] ?? '').toString(),
    );
    final priceCtrl = TextEditingController(
      text: _toDoubleValue(post['price']).toStringAsFixed(0),
    );
    final quantityCtrl = TextEditingController(
      text: _toIntValue(post['quantity'], 1).toString(),
    );

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            final resolvedExistingImage = _resolveImageUrl(
              existingRevisionImageUrl,
            );
            final hasSelectedRevisionImage = revisionImage != null;
            final hasRevisionImage =
                hasSelectedRevisionImage || resolvedExistingImage != null;
            return AlertDialog(
              title: Text(
                missingPhotoRecovery
                    ? 'Восстановить фото товара'
                    : 'Ручная ревизия товара',
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (missingPhotoRecovery) ...[
                        AppStatusBadge(
                          icon: Icons.photo_camera_back_outlined,
                          label:
                              'Фото было потеряно. Добавьте новое фото, ID товара сохранится.',
                          background: theme.colorScheme.tertiaryContainer
                              .withValues(alpha: 0.52),
                          foreground: theme.colorScheme.onTertiaryContainer,
                          border: theme.colorScheme.tertiary.withValues(
                            alpha: 0.24,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: titleCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Название',
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
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
                      const SizedBox(height: 16),
                      Text(
                        missingPhotoRecovery ? 'Новое фото' : 'Фото товара',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (revisionImage != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            height: 220,
                            child: Image.memory(
                              revisionImage!.bytes,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        )
                      else
                        ProductMediaGallery(
                          coverImageUrl: resolvedExistingImage,
                          media: resolvedExistingImage != null
                              ? [
                                  <String, dynamic>{
                                    'card_url': resolvedExistingImage,
                                    'detail_url': resolvedExistingImage,
                                    'original_url': resolvedExistingImage,
                                  },
                                ]
                              : const <Map<String, dynamic>>[],
                          height: 220,
                          heroLabel: hasRevisionImage ? 'Cover' : 'Нет фото',
                          fit: BoxFit.contain,
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.attach_file),
                              label: Text(
                                hasRevisionImage
                                    ? 'Изменить фото'
                                    : 'Добавить фото',
                              ),
                              onPressed: () async {
                                await _openRevisionImagePickerSheet(
                                  onChanged: (picked) {
                                    setDialogState(() {
                                      revisionImage = picked;
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                          if (revisionImage != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Удалить выбранное фото',
                              onPressed: () {
                                setDialogState(() {
                                  revisionImage = null;
                                });
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(
                    missingPhotoRecovery ? 'Вернуть на канал' : 'Применить',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirm != true) return;

    final title = titleCtrl.text.trim();
    final description = descriptionCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim().replaceAll(',', '.'));
    final quantity = int.tryParse(quantityCtrl.text.trim()) ?? 0;
    final hasImage =
        revisionImage != null ||
        (!missingPhotoRecovery && existingRevisionImageUrl.isNotEmpty);
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      if (!mounted) return;
      setState(() => _message = validationError);
      return;
    }

    if (mounted) {
      setState(() => _runningRevision = true);
    }
    try {
      final entry = {
        'product_id': (post['product_id'] ?? '').toString(),
        'message_id': (post['message_id'] ?? '').toString(),
        'title': title,
        'description': description,
        'price': price,
        'quantity': quantity,
        'shelf_number':
            post['source_product_shelf_number'] ??
            post['product_shelf_number'] ??
            post['shelf_number'],
        'revision_shelf_number':
            post['revision_shelf_number'] ?? post['shelf_number'],
        'image_url': revisionImage == null ? existingRevisionImageUrl : '',
      };
      final Object requestData;
      final pickedRevisionImage = revisionImage;
      if (pickedRevisionImage != null) {
        requestData = FormData.fromMap({
          'entries': jsonEncode([entry]),
          'image': await _buildRevisionImageMultipart(pickedRevisionImage),
        });
      } else {
        requestData = {
          'entries': [entry],
        };
      }
      final resp = await authService.dio.post(
        '/api/worker/revision/manual',
        data: requestData,
      );
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      final queuedItems = payload['queued_items'] is List
          ? List<Map<String, dynamic>>.from(payload['queued_items'])
          : const <Map<String, dynamic>>[];
      final affectedProductIds = queuedItems
          .map((item) => (item['product_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _applyRevisionProductsRemovedLocally(
        affectedProductIds.isEmpty
            ? {(post['product_id'] ?? '').toString().trim()}
            : affectedProductIds,
      );
      if (queuedItems.isNotEmpty) {
        _mergeOwnQueuedPostLocally(queuedItems.first);
      }
      if (!mounted) return;
      setState(
        () => _message = missingPhotoRecovery
            ? 'Фото товара восстановлено и отправлено в очередь'
            : 'Ревизия товара сохранена',
      );
      showAppNotice(
        context,
        missingPhotoRecovery
            ? 'Фото восстановлено. ID товара сохранен'
            : 'Изменения ревизии сохранены',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      unawaited(_loadOwnQueuedPosts());
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка ручной ревизии: ${_extractRequestError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _runningRevision = false);
      }
    }
  }

  Future<void> _requestRevisionDelete(Map<String, dynamic> post) async {
    if (_isRevisionBlocked(post)) {
      if (!mounted) return;
      final note = _revisionBlockedNote(post);
      setState(
        () => _message = note.isNotEmpty
            ? note
            : 'Этот товар сейчас нельзя удалить через ревизию',
      );
      return;
    }
    final reasonCtrl = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Запросить удаление товара?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Администратор получит запрос и решит, удалять этот товар или оставить.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Причина (необязательно)',
                    border: OutlineInputBorder(),
                  ),
                  controller: reasonCtrl,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отправить запрос'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (confirm != true) return;

    final productId = (post['product_id'] ?? post['id'] ?? '')
        .toString()
        .trim();
    if (productId.isEmpty) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось определить товар для удаления');
      return;
    }

    if (mounted) setState(() => _runningRevision = true);
    try {
      await authService.dio.post(
        '/api/worker/revision/delete-request',
        data: {
          'product_id': productId,
          'channel_id': (post['chat_id'] ?? post['channel_id'] ?? '')
              .toString(),
          'message_id': (post['message_id'] ?? '').toString(),
          'reason': reason,
        },
      );
      if (!mounted) return;
      setState(() => _message = 'Запрос на удаление отправлен администратору');
      showAppNotice(
        context,
        'Запрос на удаление отправлен',
        tone: AppNoticeTone.info,
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () =>
            _message = 'Ошибка запроса на удаление: ${_extractRequestError(e)}',
      );
    } finally {
      if (mounted) setState(() => _runningRevision = false);
    }
  }

  Future<void> _queueProduct() async {
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Выберите канал для публикации');
      return;
    }

    final title = _titleCtrl.text.trim();
    final description = _descriptionCtrl.text.trim();
    final priceText = _priceCtrl.text.trim().replaceAll(',', '.');
    final qtyText = _quantityCtrl.text.trim();
    final hasImage =
        _pickedImage != null ||
        (_pickedImageBytes?.isNotEmpty ?? false) ||
        ((_existingImageUrl?.trim().isNotEmpty ?? false) &&
            !_removeImageOnSubmit);

    if (title.isEmpty) {
      setState(() => _message = 'Введите название товара');
      return;
    }
    final price = double.tryParse(priceText);
    final quantity = int.tryParse(qtyText) ?? 1;
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });

    try {
      final payload = await _buildCreateProductPayload(
        title: title,
        description: description,
        price: price!,
        quantity: quantity,
      );

      final resp = await authService.dio.post(
        '/api/worker/channels/$channelId/posts',
        data: payload,
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        final data = resp.data;
        String? queueId;
        String? productLabel;
        String? placementShelfLabel;
        String? placementProductCode;
        if (data is Map && data['data'] is Map) {
          final dataMap = Map<String, dynamic>.from(data['data']);
          final queue = dataMap['queue'];
          if (queue is Map) {
            queueId = queue['id']?.toString();
          }
          productLabel = dataMap['product_label']?.toString();
          final product = dataMap['product'];
          if (product is Map) {
            final manualShelfLabel = product['manual_shelf_label'];
            placementShelfLabel = _placementShelfLabel(
              shelfNumber: product['shelf_number'],
              manualShelfLabel: manualShelfLabel,
              productLabel: productLabel,
            );
            placementProductCode = _productCodePart(product['product_code']);
            productLabel ??= _formatProductLabel(
              product['product_code'],
              product['shelf_number'],
              manualShelfLabel: manualShelfLabel,
            );
          }
        }
        placementShelfLabel ??= _placementShelfLabel(
          productLabel: productLabel,
        );
        placementProductCode ??= _productCodeFromLabel(productLabel);
        setState(() {
          if (productLabel != null && productLabel.isNotEmpty) {
            _message = placementShelfLabel != null
                ? 'Товар отправлен в очередь. ID товара: $productLabel. Полка: $placementShelfLabel'
                : 'Товар отправлен в очередь. ID товара: $productLabel';
          } else if (queueId != null) {
            _message = 'Товар отправлен в очередь. ID заявки: $queueId';
          } else {
            _message = 'Товар отправлен в очередь';
          }
        });
        _resetProductForm();
        await _loadOwnQueuedPosts();
        _animateToTab('own');
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Товар отправлен в очередь. ID: $productLabel'
                : 'Товар отправлен в очередь',
            tone: AppNoticeTone.success,
            duration: const Duration(milliseconds: 1400),
          );
          if (placementShelfLabel != null) {
            await _showShelfFullscreenNotice(
              shelfLabel: placementShelfLabel,
              productCodeLabel: placementProductCode,
              productLabel: productLabel,
            );
          }
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка отправки: ${_extractRequestError(e)}');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _searchOldProducts() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() {
      _searching = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/worker/products/search',
        queryParameters: {'q': q},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final normalized = (data['data'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false);
        setState(() => _searchResults = normalized);
      } else {
        setState(() => _message = 'Не удалось выполнить поиск');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка поиска: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _fillFormFromProduct(Map<String, dynamic> product) {
    final missingPhotoRecovery =
        _toBoolValue(product['creator_missing_photo_recovery']) ||
        _toBoolValue(product['hidden_missing_photo']);
    _titleCtrl.text = (product['title'] ?? '').toString();
    _descriptionCtrl.text = (product['description'] ?? '').toString();
    _priceCtrl.text = (product['price'] ?? '').toString();
    _quantityCtrl.text = '1';
    _manualShelfLabelCtrl.text = (product['manual_shelf_label'] ?? '')
        .toString();
    _shelfFloorCtrl.text = (product['shelf_floor'] ?? '').toString();
    setState(() {
      _pickedImage = null;
      _pickedImageBytes = null;
      _pickedImageUploadFileName = null;
      _existingImageUrl = missingPhotoRecovery
          ? ''
          : (product['image_url'] ?? '').toString();
      _removeImageOnSubmit = missingPhotoRecovery;
      _pickupOnly = _toBoolValue(product['pickup_only']);
      _isBulkyProduct = _toBoolValue(product['is_bulky']);
      _message = missingPhotoRecovery
          ? 'Данные товара подставлены. Добавьте новое фото и отправьте в очередь.'
          : 'Данные товара подставлены. Проверьте и отправьте в очередь.';
    });
    _animateToTab('new');
  }

  Future<void> _requeueProduct(Map<String, dynamic> product) async {
    if (!_oldPostRequeueAllowed(product)) {
      setState(
        () => _message = _oldPostReuseHint(product).isNotEmpty
            ? _oldPostReuseHint(product)
            : 'Этот товар нельзя отправлять через Старые посты.',
      );
      return;
    }
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Сначала выберите канал');
      return;
    }
    final productId = product['id']?.toString();
    if (productId == null || productId.isEmpty) return;

    final title = _titleCtrl.text.trim().isNotEmpty
        ? _titleCtrl.text.trim()
        : (product['title'] ?? '').toString();
    final description = _descriptionCtrl.text.trim().isNotEmpty
        ? _descriptionCtrl.text.trim()
        : (product['description'] ?? '').toString();

    final rawPriceInput = _priceCtrl.text.trim().replaceAll(',', '.');
    final editedPrice = rawPriceInput.isNotEmpty
        ? double.tryParse(rawPriceInput)
        : null;
    if (rawPriceInput.isNotEmpty && editedPrice == null) {
      setState(() => _message = 'Введите корректную цену');
      return;
    }
    final fallbackPrice = _toDoubleValue(product['price'], 0);
    final price = editedPrice ?? fallbackPrice;

    final rawQtyInput = _quantityCtrl.text.trim();
    final editedQty = rawQtyInput.isNotEmpty ? int.tryParse(rawQtyInput) : null;
    if (rawQtyInput.isNotEmpty && (editedQty == null || editedQty <= 0)) {
      setState(() => _message = 'Количество должно быть больше нуля');
      return;
    }
    final fallbackQty = _toIntValue(product['quantity'], 1);
    final quantity = editedQty ?? fallbackQty;
    final existingImage = (product['image_url'] ?? '').toString().trim();
    final hasImage =
        _pickedImage != null ||
        (_pickedImageBytes?.isNotEmpty ?? false) ||
        ((_existingImageUrl?.trim().isNotEmpty ?? false) &&
            !_removeImageOnSubmit) ||
        (existingImage.isNotEmpty && !_removeImageOnSubmit);
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });
    try {
      final payload = await _buildRequeuePayload(
        product: product,
        channelId: channelId,
        title: title,
        description: description,
        price: price,
        quantity: quantity,
      );

      final resp = await authService.dio.post(
        '/api/worker/products/$productId/requeue',
        data: payload,
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        String? productLabel;
        String? placementShelfLabel;
        String? placementProductCode;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          productLabel = body['product_label']?.toString();
          final product = body['product'];
          if (product is Map) {
            final manualShelfLabel = product['manual_shelf_label'];
            placementShelfLabel = _placementShelfLabel(
              shelfNumber: product['shelf_number'],
              manualShelfLabel: manualShelfLabel,
              productLabel: productLabel,
            );
            placementProductCode = _productCodePart(product['product_code']);
            productLabel ??= _formatProductLabel(
              product['product_code'],
              product['shelf_number'],
              manualShelfLabel: manualShelfLabel,
            );
          }
        }
        placementShelfLabel ??= _placementShelfLabel(
          productLabel: productLabel,
        );
        placementProductCode ??= _productCodeFromLabel(productLabel);
        setState(() {
          _message = productLabel != null && productLabel.isNotEmpty
              ? (placementShelfLabel != null
                    ? 'Старый товар отправлен в очередь. ID товара: $productLabel. Полка: $placementShelfLabel'
                    : 'Старый товар отправлен в очередь. ID товара: $productLabel')
              : 'Старый товар отправлен в очередь повторно';
          _removeImageOnSubmit = false;
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Товар снова в очереди. ID: $productLabel'
                : 'Товар снова отправлен в очередь',
            tone: AppNoticeTone.success,
          );
          if (placementShelfLabel != null) {
            await _showShelfFullscreenNotice(
              shelfLabel: placementShelfLabel,
              productCodeLabel: placementProductCode,
              productLabel: productLabel,
            );
          }
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка повторной отправки: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _quickDuplicateProduct(Map<String, dynamic> product) async {
    if (!_oldPostQuickDuplicateAllowed(product)) {
      setState(
        () => _message = _oldPostReuseHint(product).isNotEmpty
            ? _oldPostReuseHint(product)
            : 'Этот товар нельзя дублировать через Старые посты.',
      );
      return;
    }
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Сначала выберите канал');
      return;
    }

    final productId = product['id']?.toString();
    if (productId == null || productId.isEmpty) {
      setState(() => _message = 'Не удалось определить товар');
      return;
    }

    final title = (product['title'] ?? '').toString().trim();
    final description = (product['description'] ?? '').toString().trim();
    final price = _toDoubleValue(product['price'], 0);
    final queuedQuantity = _queuedQuantityForProduct(productId);
    final lastCounter = _quickDuplicateCounters[productId] ?? 0;
    final baseQuantity = queuedQuantity > 0 ? queuedQuantity : lastCounter;
    final quantity = (baseQuantity + 1).clamp(1, 999999);
    final imageUrl = (product['image_url'] ?? '').toString().trim();

    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: imageUrl.isNotEmpty,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/worker/products/$productId/requeue',
        data: {
          'channel_id': channelId,
          'title': title,
          'description': description,
          'price': price,
          'quantity': quantity,
          'image_url': imageUrl,
          'merge_pending': true,
          if (_manualShelfEnabled) ...{
            'manual_shelf_label': (product['manual_shelf_label'] ?? '')
                .toString()
                .trim(),
            'shelf_floor': (product['shelf_floor'] ?? '').toString().trim(),
          },
          if (_pickupOnlyEnabled)
            'pickup_only': _toBoolValue(product['pickup_only'])
                ? 'true'
                : 'false',
        },
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        String? productLabel;
        String? placementShelfLabel;
        String? placementProductCode;
        int? serverQuantity;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          productLabel = body['product_label']?.toString();
          final productMap = body['product'];
          if (productMap is Map) {
            final manualShelfLabel = productMap['manual_shelf_label'];
            serverQuantity = _toIntValue(productMap['quantity'], quantity);
            placementShelfLabel = _placementShelfLabel(
              shelfNumber: productMap['shelf_number'],
              manualShelfLabel: manualShelfLabel,
              productLabel: productLabel,
            );
            placementProductCode = _productCodePart(productMap['product_code']);
            productLabel ??= _formatProductLabel(
              productMap['product_code'],
              productMap['shelf_number'],
              manualShelfLabel: manualShelfLabel,
            );
          }
        }
        _quickDuplicateCounters[productId] = serverQuantity ?? quantity;
        placementShelfLabel ??= _placementShelfLabel(
          productLabel: productLabel,
        );
        placementProductCode ??= _productCodeFromLabel(productLabel);
        setState(() {
          _message = productLabel != null && productLabel.isNotEmpty
              ? (placementShelfLabel != null
                    ? 'Дубль товара отправлен. ID товара: $productLabel. Полка: $placementShelfLabel'
                    : 'Дубль товара отправлен. ID товара: $productLabel')
              : 'Дубль товара отправлен в очередь';
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Дубль готов. ID: $productLabel'
                : 'Товар продублирован в очередь',
            tone: AppNoticeTone.success,
          );
          if (placementShelfLabel != null) {
            await _showShelfFullscreenNotice(
              shelfLabel: placementShelfLabel,
              productCodeLabel: placementProductCode,
              productLabel: productLabel,
            );
          }
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось продублировать товар');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка дубля товара: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Widget _buildPhotoPicker() {
    final theme = Theme.of(context);
    final localPath = _pickedImage?.path.trim();
    final localBytes = _pickedImageBytes;
    final hasLocalPickedImage =
        (localBytes != null && localBytes.isNotEmpty) ||
        (localPath != null && localPath.isNotEmpty);
    final remoteUrl = _resolveImageUrl(_existingImageUrl);
    final hasImage = hasLocalPickedImage || remoteUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Фото товара',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Cover останется совместимым со старым single-image сценарием. Галерея может расширяться additively.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        if (localBytes != null && localBytes.isNotEmpty)
          PhoenixReadyBlink(
            key: ValueKey('worker-photo-bytes-${localBytes.length}'),
            enabled: !performanceModeNotifier.value,
            borderRadius: const BorderRadius.all(Radius.circular(22)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                height: 236,
                child: Image.memory(
                  localBytes,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          )
        else if (localPath != null && localPath.isNotEmpty && !kIsWeb)
          PhoenixReadyBlink(
            key: ValueKey('worker-photo-path-$localPath'),
            enabled: !performanceModeNotifier.value,
            borderRadius: const BorderRadius.all(Radius.circular(22)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                height: 236,
                width: double.infinity,
                child: Image(
                  image: FileImage(File(localPath)),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          )
        else
          ProductMediaGallery(
            coverImageUrl: hasImage ? remoteUrl : null,
            media: hasImage && remoteUrl != null
                ? [
                    <String, dynamic>{
                      'card_url': remoteUrl,
                      'detail_url': remoteUrl,
                      'original_url': remoteUrl,
                    },
                  ]
                : const <Map<String, dynamic>>[],
            height: 236,
            heroLabel: hasImage ? 'Cover' : 'Нет фото',
            fit: BoxFit.contain,
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _openImagePickerSheet,
                icon: const Icon(Icons.attach_file),
                label: Text(hasImage ? 'Изменить фото' : 'Добавить фото'),
              ),
            ),
            if (hasImage) ...[
              const SizedBox(width: 8),
              if (hasLocalPickedImage)
                IconButton(
                  onPressed: _cropCurrentPickedImage,
                  icon: const Icon(Icons.crop),
                  tooltip: 'Обрезать фото',
                ),
              if (hasLocalPickedImage) const SizedBox(width: 2),
              IconButton(
                onPressed: _clearSelectedImage,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Удалить фото',
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildQueueTab() {
    final theme = Theme.of(context);
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(16),
      children: [
        AppSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Новый товар',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                _manualShelfEnabled
                    ? (_isAnnaUtevskayaTenantScope()
                          ? 'Подготовьте карточку товара для очереди публикации. Для этой группы можно вручную указать стеллаж и коробку.'
                          : 'Подготовьте карточку товара для очереди публикации. Для этой группы можно вручную указать полку и этаж.')
                    : 'Подготовьте карточку товара для очереди публикации. Полка назначится автоматически по дате, а фото сразу станет обложкой поста.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loadingChannels)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: PhoenixLoadingView(
                    title: 'Загружаем каналы',
                    subtitle: 'Получаем доступные каналы для публикации',
                    size: 50,
                  ),
                )
              else if (_channels.isEmpty)
                const AppEmptyState(
                  compact: true,
                  badge: 'Каналы',
                  title: 'Основной канал недоступен',
                  subtitle:
                      'Системный канал для публикации не найден. Проверьте инициализацию сервера.',
                  icon: Icons.wifi_tethering_error_rounded,
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey<String?>(_selectedChannelId),
                  initialValue: _selectedChannelId,
                  decoration: const InputDecoration(
                    labelText: 'Канал для публикации',
                    border: OutlineInputBorder(),
                  ),
                  items: _channels
                      .map(
                        (c) => DropdownMenuItem<String>(
                          value: c['id']?.toString(),
                          child: Text((c['title'] ?? 'Канал').toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedChannelId = v),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleCtrl,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Название товара',
                    border: OutlineInputBorder(),
                  ),
                  controller: _titleCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Описание',
                    border: OutlineInputBorder(),
                  ),
                  controller: _descriptionCtrl,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Цена',
                          border: OutlineInputBorder(),
                        ),
                        controller: _priceCtrl,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _quantityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Кол-во',
                          border: OutlineInputBorder(),
                        ),
                        controller: _quantityCtrl,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_manualShelfEnabled) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _manualShelfLabelCtrl,
                        decoration: withInputLanguageBadge(
                          InputDecoration(
                            labelText: _placementShelfInputLabel,
                            hintText: _placementShelfInputHint,
                            border: const OutlineInputBorder(),
                          ),
                          controller: _manualShelfLabelCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _shelfFloorCtrl,
                        decoration: withInputLanguageBadge(
                          InputDecoration(
                            labelText: _placementBoxInputLabel,
                            hintText: _placementBoxInputHint,
                            border: const OutlineInputBorder(),
                          ),
                          controller: _shelfFloorCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ] else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppStatusBadge.preset(context, 'queued', compact: true),
                    _statChip('Полка назначится автоматически'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Номер полки привязывается к дате публикации. Здесь его вручную вводить не нужно.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              CheckboxListTile(
                value: _isBulkyProduct,
                onChanged: (value) {
                  setState(() => _isBulkyProduct = value ?? false);
                },
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Габарит'),
                subtitle: const Text(
                  'Полка и этаж для такого товара не обязательны. При сборке доставки он будет предложен как габарит.',
                ),
              ),
              if (_pickupOnlyEnabled) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _pickupOnly,
                  onChanged: (value) {
                    setState(() => _pickupOnly = value ?? false);
                  },
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Самовывоз'),
                  subtitle: const Text(
                    'Если клиент купит этот товар, корзину нельзя будет отгрузить курьеру.',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildPhotoPicker(),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _posting ? null : _queueProduct,
                  icon: _posting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send),
                  label: Text(_posting ? 'Отправка...' : 'Отправить в очередь'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchTab() {
    final theme = Theme.of(context);
    final searchResults = List<Map<String, dynamic>>.from(_searchResults);
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(16),
      children: [
        const AppSurfaceCard(
          child: Text(
            'Старые посты используйте только для товаров, которых уже нет в Основном канале. Если товар ещё находится в канале, его нужно проводить через Ревизию.',
          ),
        ),
        const SizedBox(height: 12),
        AppSurfaceCard(
          compact: true,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Поиск по ID, названию или описанию',
                      hintText: 'Например 328 или коврик',
                      border: OutlineInputBorder(),
                    ),
                    controller: _searchCtrl,
                  ),
                  onSubmitted: (_) => _searchOldProducts(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _searching ? null : _searchOldProducts,
                icon: const Icon(Icons.search),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_searching)
          ...List.generate(
            3,
            (index) => const AppSkeletonCard(
              margin: EdgeInsets.only(bottom: 10),
              height: 176,
            ),
          ),
        if (!_searching && _searchResults.isEmpty)
          const AppEmptyState(
            title: 'Результаты появятся здесь',
            subtitle: 'Введите ID товара, название или описание.',
            icon: Icons.search_rounded,
          ),
        ...searchResults.map((p) {
          final productId = (p['id'] ?? '').toString().trim();
          final updatedAt = (p['updated_at'] ?? p['created_at'] ?? '')
              .toString()
              .trim();
          final itemKey = productId.isNotEmpty
              ? 'old-search-$productId-$updatedAt'
              : 'old-search-${p.hashCode}-$updatedAt';
          final label = _formatProductLabel(
            p['product_code'],
            p['shelf_number'],
            manualShelfLabel: p['manual_shelf_label'],
          );
          final imageUrl = _coverImageOf(p);
          final mediaItems = _mediaItemsOf(p);
          final requeueAllowed = _oldPostRequeueAllowed(p);
          final quickDuplicateAllowed = _oldPostQuickDuplicateAllowed(p);
          final reuseHint = _oldPostReuseHint(p);
          final hintIsActionable = requeueAllowed || quickDuplicateAllowed;
          return AppSurfaceCard(
            key: ValueKey(itemKey),
            compact: true,
            margin: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 104,
                  child: ProductMediaGallery(
                    coverImageUrl: imageUrl,
                    media: mediaItems,
                    height: 116,
                    borderRadius: 18,
                    heroLabel: 'Архив',
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          AppStatusBadge.preset(
                            context,
                            requeueAllowed ? 'queued' : 'published',
                            compact: true,
                          ),
                          _statChip('ID $label'),
                          _statChip('${p['price']} ₽'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        (p['title'] ?? 'Товар').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        (p['description'] ?? '').toString(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (reuseHint.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        AppStatusBadge(
                          icon: hintIsActionable
                              ? Icons.info_outline_rounded
                              : Icons.block_rounded,
                          label: reuseHint,
                          background: hintIsActionable
                              ? theme.colorScheme.primaryContainer.withValues(
                                  alpha: 0.42,
                                )
                              : theme.colorScheme.tertiaryContainer.withValues(
                                  alpha: 0.52,
                                ),
                          foreground: hintIsActionable
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onTertiaryContainer,
                          border: hintIsActionable
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.18,
                                )
                              : theme.colorScheme.tertiary.withValues(
                                  alpha: 0.18,
                                ),
                          compact: false,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _posting || !quickDuplicateAllowed
                                  ? null
                                  : () => _quickDuplicateProduct(p),
                              icon: const Icon(
                                Icons.copy_all_outlined,
                                size: 18,
                              ),
                              label: const Text('Быстрый дубль'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'fill') {
                                _fillFormFromProduct(p);
                              } else if (v == 'requeue') {
                                _requeueProduct(p);
                              } else if (v == 'quick_requeue') {
                                _quickDuplicateProduct(p);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'quick_requeue',
                                enabled: quickDuplicateAllowed,
                                child: const Text('Быстрый дубль (1 клик)'),
                              ),
                              const PopupMenuItem(
                                value: 'fill',
                                child: Text('Подставить в форму'),
                              ),
                              PopupMenuItem(
                                value: 'requeue',
                                enabled: requeueAllowed,
                                child: const Text('Сразу в очередь'),
                              ),
                            ],
                            child: Container(
                              height: 40,
                              width: 40,
                              decoration: BoxDecoration(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.more_horiz_rounded),
                            ),
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
    );
  }

  Future<void> _editOwnQueuedPost(Map<String, dynamic> post) async {
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
      text: (post['product_quantity'] ?? '1').toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изменить свой пост'),
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
    final quantity = int.tryParse(quantityCtrl.text.trim()) ?? 0;
    final hasImage = ((post['product_image_url'] ?? '')
        .toString()
        .trim()
        .isNotEmpty);
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      if (!mounted) return;
      setState(() => _message = validationError);
      return;
    }

    if (mounted) {
      setState(() => _savingOwnPost = true);
    }
    try {
      await authService.dio.patch(
        '/api/worker/queue/${post['id']}',
        data: {
          'title': title,
          'description': description,
          'price': price,
          'quantity': quantity,
        },
      );
      await _loadOwnQueuedPosts();
      if (!mounted) return;
      setState(() => _message = 'Пост обновлен');
      showAppNotice(context, 'Свой пост обновлен', tone: AppNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка сохранения поста: $e');
    } finally {
      if (mounted) {
        setState(() => _savingOwnPost = false);
      }
    }
  }

  Future<void> _deleteOwnQueuedPost(Map<String, dynamic> post) async {
    final title = (post['product_title'] ?? 'этот пост').toString().trim();
    final payload = post['payload'] is Map<String, dynamic>
        ? post['payload'] as Map<String, dynamic>
        : post['payload'] is Map
        ? Map<String, dynamic>.from(post['payload'])
        : const <String, dynamic>{};
    final isRevisionPost =
        payload['revision_manual'] == true || payload['revision_auto'] == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить свой пост?'),
        content: Text(
          isRevisionPost
              ? 'Удалить "$title" из очереди ревизии?\n\n'
                    'После этого он не уйдёт на канал, а исходный пост вернётся обратно в Основной канал.'
              : 'Удалить "$title" из очереди?\n\nПосле этого пост не уйдёт на канал.',
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

    if (mounted) {
      setState(() => _savingOwnPost = true);
    }
    try {
      await authService.dio.delete('/api/worker/queue/${post['id']}');
      await _loadOwnQueuedPosts();
      if (!mounted) return;
      setState(
        () => _message = isRevisionPost
            ? 'Ревизия снята с очереди, исходный пост возвращён в канал'
            : 'Пост удалён из очереди',
      );
      showAppNotice(
        context,
        isRevisionPost
            ? 'Ревизия снята. Исходный пост снова виден в Основном канале.'
            : 'Пост удалён. Он больше не уйдёт на канал.',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка удаления поста: ${_extractRequestError(e)}',
      );
    } finally {
      if (mounted) {
        setState(() => _savingOwnPost = false);
      }
    }
  }

  Widget _buildOwnPostsTab() {
    final theme = Theme.of(context);
    if (_loadingOwnPosts) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          AppSkeletonCard(height: 176, margin: EdgeInsets.only(bottom: 10)),
          AppSkeletonCard(height: 176, margin: EdgeInsets.only(bottom: 10)),
          AppSkeletonCard(height: 176, margin: EdgeInsets.only(bottom: 10)),
        ],
      );
    }
    if (_ownQueuedPosts.isEmpty) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: const [
          AppEmptyState(
            title: 'У вас пока нет постов в очереди',
            subtitle: 'Отправьте товар в очередь, и он появится здесь.',
            icon: Icons.inventory_2_outlined,
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _loadOwnQueuedPosts,
      child: ListView.separated(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        itemCount: _ownQueuedPosts.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final post = _ownQueuedPosts[index];
          final imageUrl = _coverImageOf(
            post,
            fallbackKey: 'product_image_url',
          );
          final mediaItems = _mediaItemsOf(post);
          return AppSurfaceCard(
            compact: true,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 106,
                      child: ProductMediaGallery(
                        coverImageUrl: imageUrl,
                        media: mediaItems,
                        height: 120,
                        borderRadius: 18,
                        heroLabel: 'Очередь',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (post['product_title'] ?? 'Товар').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            (post['product_description'] ?? '').toString(),
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
                              AppStatusBadge.preset(
                                context,
                                'queued',
                                compact: true,
                              ),
                              ..._ownPostIdentityChips(post),
                              _statChip(
                                '${_toDoubleValue(post['product_price']).toStringAsFixed(0)} ₽',
                              ),
                              _statChip(
                                'x${_toIntValue(post['product_quantity'])}',
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
                        (post['channel_title'] ?? 'Основной канал').toString(),
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
                      alignment: WrapAlignment.end,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _savingOwnPost
                              ? null
                              : () => _editOwnQueuedPost(post),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Изменить'),
                        ),
                        OutlinedButton.icon(
                          onPressed: (_savingOwnPost || _posting)
                              ? null
                              : () => _deleteOwnQueuedPost(post),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Удалить'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _posting
                              ? null
                              : () => _quickDuplicateProduct(
                                  _productFromOwnQueuedPost(post),
                                ),
                          icon: const Icon(
                            Icons.content_copy_outlined,
                            size: 18,
                          ),
                          label: const Text('Дубль'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRevisionTab() {
    final theme = Theme.of(context);
    final selectedShelf = _selectedRevisionShelfNumber ?? 1;
    final selectedShelfData = _revisionShelves
        .where((item) => _toIntValue(item['shelf_number'], 0) == selectedShelf)
        .cast<Map<String, dynamic>?>()
        .firstWhere((_) => true, orElse: () => null);
    final selectedShelfPosts = _toIntValue(selectedShelfData?['posts'], 0);
    final revisionProductSearch = _revisionProductIdSearchCtrl.text.trim();
    final revisionPostsCount = _revisionPosts.length;
    return RefreshIndicator(
      onRefresh: () async {
        await _loadTenantFeatureSettings();
        await _loadRevisionShelves();
      },
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          const AppSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ревизия',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 6),
                Text(
                  'Выберите нужную полку от 01 до 10. Ревизия покажет товары только с этой полки и не зависит от дат, выходных или воскресенья.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_loadingRevisionShelves)
            const AppSkeletonCard(
              margin: EdgeInsets.only(bottom: 10),
              height: 92,
              showImage: false,
            )
          else if (_revisionShelves.isEmpty)
            const AppEmptyState(
              badge: 'Ревизия',
              title: 'Нет полок для ревизии',
              subtitle:
                  'Когда в канале появятся подходящие товары, здесь появится выбор полок.',
              icon: Icons.tune_rounded,
            )
          else
            AppSurfaceCard(
              compact: true,
              child: DropdownButtonFormField<int>(
                key: ValueKey('revision-shelf-$selectedShelf'),
                initialValue: selectedShelf,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Полка для ревизии',
                  border: OutlineInputBorder(),
                ),
                items: _revisionShelves.map((item) {
                  final shelf = _toIntValue(item['shelf_number'], 1);
                  final shelfLabel =
                      (item['shelf_label'] ??
                              item['revision_shelf_label'] ??
                              shelf.toString().padLeft(2, '0'))
                          .toString();
                  final count = _toIntValue(item['posts'], 0);
                  return DropdownMenuItem<int>(
                    value: shelf,
                    child: Text('Полка $shelfLabel · $count товаров'),
                  );
                }).toList(),
                onChanged: _runningRevision
                    ? null
                    : (value) {
                        if (value != null) {
                          unawaited(_selectRevisionShelf(value));
                        }
                      },
              ),
            ),
          const SizedBox(height: 8),
          AppSurfaceCard(
            compact: true,
            child: TextField(
              controller: _revisionProductIdSearchCtrl,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.search,
              enabled: !_runningRevision,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: 'Поиск по ID товара',
                hintText: 'Например 123',
                border: const OutlineInputBorder(),
                suffixIcon: revisionProductSearch.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить поиск',
                        icon: const Icon(Icons.close),
                        onPressed: _runningRevision
                            ? null
                            : () {
                                _revisionProductIdSearchCtrl.clear();
                                if (mounted) setState(() {});
                                unawaited(_loadRevisionPosts());
                              },
                      ),
              ),
              onChanged: (value) {
                if (mounted) setState(() {});
                _scheduleRevisionProductSearch(value);
              },
              onSubmitted: (_) => unawaited(_loadRevisionPosts()),
            ),
          ),
          const SizedBox(height: 8),
          _statChip(
            revisionProductSearch.isEmpty
                ? "Выбрана полка ${selectedShelf.toString().padLeft(2, '0')} · $selectedShelfPosts товаров"
                : "Выбрана полка ${selectedShelf.toString().padLeft(2, '0')} · найдено $revisionPostsCount из $selectedShelfPosts",
          ),
          const SizedBox(height: 14),
          AppSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _revisionPercentCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: false,
                        ),
                        onChanged: (_) {
                          if (mounted) setState(() {});
                        },
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText:
                                'Процент снижения (например: 10, 25, 50)',
                            border: OutlineInputBorder(),
                          ),
                          controller: _revisionPercentCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: _runningRevision ? null : _runAutoRevision,
                        icon: _runningRevision
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.auto_awesome_outlined),
                        label: const Text('Авто'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [10, 25, 50]
                      .map(
                        (value) => ActionChip(
                          label: Text('$value%'),
                          onPressed: _runningRevision
                              ? null
                              : () {
                                  _revisionPercentCtrl.text = '$value';
                                  _revisionPercentCtrl
                                      .selection = TextSelection.fromPosition(
                                    TextPosition(
                                      offset: _revisionPercentCtrl.text.length,
                                    ),
                                  );
                                  if (mounted) {
                                    setState(() {});
                                  }
                                },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _autoHideOldRevisionPosts,
                  onChanged: _runningRevision
                      ? null
                      : (v) => setState(() => _autoHideOldRevisionPosts = v),
                  title: const Text('Скрывать старые версии постов'),
                  subtitle: const Text(
                    'Оставлять только самый свежий вариант товара',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_loadingRevisionPosts)
            ...List.generate(
              3,
              (index) => const AppSkeletonCard(
                margin: EdgeInsets.only(bottom: 10),
                height: 188,
              ),
            )
          else if (_revisionPosts.isEmpty)
            AppEmptyState(
              badge: revisionProductSearch.isEmpty
                  ? 'Выбранная полка'
                  : 'Поиск',
              title: revisionProductSearch.isEmpty
                  ? 'Нет постов для выбранной полки'
                  : 'Товар с таким ID не найден',
              subtitle: revisionProductSearch.isEmpty
                  ? 'Либо подходящих товаров нет, либо они уже не участвуют в ревизии.'
                  : 'Проверьте ID товара или выберите другую полку.',
              icon: Icons.inventory_2_outlined,
            )
          else
            ..._revisionPosts.map((post) {
              final imageUrl = _coverImageOf(post);
              final mediaItems = _mediaItemsOf(post);
              final blocked = _isRevisionBlocked(post);
              final missingPhotoRecovery = _toBoolValue(
                post['creator_missing_photo_recovery'],
              );
              final blockedNote = _revisionBlockedNote(post);
              final revisionShelfNumber = _toIntValue(
                post['revision_shelf_number'] ?? post['shelf_number'],
                1,
              );
              final previewPrice = _previewRevisionPrice(post['price']);
              final productLabel = _formatProductLabel(
                post['product_code'],
                revisionShelfNumber,
              );
              final createdAt = (post['created_at'] ?? '').toString();
              final createdAtShort = createdAt.length >= 16
                  ? createdAt.substring(0, 16).replaceFirst('T', ' ')
                  : createdAt;
              return AppSurfaceCard(
                margin: const EdgeInsets.only(bottom: 12),
                compact: true,
                borderColor: blocked
                    ? theme.colorScheme.error.withValues(alpha: 0.20)
                    : null,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 118,
                      child: ProductMediaGallery(
                        coverImageUrl: imageUrl,
                        media: mediaItems,
                        height: 132,
                        borderRadius: 18,
                        heroLabel: 'Ревизия',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              AppStatusBadge.preset(
                                context,
                                blocked ? 'reserved' : 'revision-needed',
                                compact: true,
                              ),
                              if (createdAtShort.isNotEmpty)
                                _statChip(createdAtShort),
                              if (missingPhotoRecovery)
                                _statChip('Фото потеряно'),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            (post['title'] ?? 'Товар').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            (post['description'] ?? '').toString(),
                            maxLines: 2,
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
                              _statChip('ID $productLabel'),
                              _statChip(
                                'Полка ${revisionShelfNumber.toString().padLeft(2, '0')}',
                              ),
                              _statChip(
                                '${_toDoubleValue(post['price']).toStringAsFixed(0)} ₽',
                              ),
                              if (previewPrice != null)
                                _statChip('Будет: $previewPrice ₽'),
                              _statChip('x${_toIntValue(post['quantity'], 1)}'),
                            ],
                          ),
                          if (blockedNote.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            AppSurfaceCard(
                              compact: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              borderColor: theme.colorScheme.tertiary
                                  .withValues(alpha: 0.20),
                              child: Text(
                                blockedNote,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: missingPhotoRecovery
                              ? 'Восстановить фото через ручную ревизию'
                              : blocked
                              ? 'Товар уже купили, отнесите администратору'
                              : 'Ручная ревизия',
                          onPressed: _runningRevision || blocked
                              ? null
                              : () => _manualRevisionEdit(post),
                          icon: Icon(
                            missingPhotoRecovery
                                ? Icons.add_photo_alternate_outlined
                                : blocked
                                ? Icons.inventory_2_outlined
                                : Icons.edit_outlined,
                          ),
                        ),
                        if (_revisionDeleteApprovalEnabled)
                          IconButton(
                            tooltip: blocked
                                ? 'Купленный товар нельзя запросить на удаление'
                                : missingPhotoRecovery
                                ? 'Сначала восстановите фото через ручную ревизию'
                                : 'Запросить удаление',
                            onPressed:
                                _runningRevision ||
                                    blocked ||
                                    missingPhotoRecovery
                                ? null
                                : () => _requestRevisionDelete(post),
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  String _deliveryBatchStatusLabel(String raw) {
    switch (raw.trim()) {
      case 'calling':
        return 'Идет обзвон';
      case 'couriers_assigned':
        return 'Курьеры назначены';
      case 'handed_off':
        return 'Передано курьерам';
      case 'completed':
        return 'Завершено';
      case 'cancelled':
        return 'Отменено';
      default:
        return raw.trim().isEmpty ? '—' : raw.trim();
    }
  }

  String _deliveryCustomerStatusLabel(String raw) {
    switch (raw.trim()) {
      case 'accepted':
        return 'Согласился';
      case 'declined':
        return 'Отказался';
      case 'pending':
        return 'Ожидает ответа';
      case 'preparing_delivery':
        return 'Идет подготовка';
      case 'handing_to_courier':
        return 'Передается курьеру';
      case 'in_delivery':
        return 'В доставке';
      case 'delivered':
        return 'Доставлено';
      default:
        return raw.trim().isEmpty ? '—' : raw.trim();
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

  Future<void> _loadDeliveryDashboard({bool silent = true}) async {
    if (!_canViewDeliveryTab()) {
      if (mounted) {
        setState(() {
          _loadingDeliveryDashboard = false;
          _deliveryActiveBatch = null;
          _deliveryBatches = [];
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _loadingDeliveryDashboard = true);
    }
    try {
      final resp = await authService.dio.get('/api/admin/delivery/dashboard');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data'] as Map);
        if (!mounted) return;
        setState(() {
          _deliveryBatches = _asMapList(payload['batches']);
          _deliveryActiveBatch = payload['active_batch'] is Map
              ? Map<String, dynamic>.from(payload['active_batch'] as Map)
              : null;
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () =>
              _message = 'Ошибка загрузки доставки: ${_extractRequestError(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingDeliveryDashboard = false);
      } else {
        _loadingDeliveryDashboard = false;
      }
    }
  }

  Future<Map<String, dynamic>?> _askDeliveryAssemblyData(
    Map<String, dynamic> customer,
  ) async {
    final rawItems = _asMapList(customer['items']);
    final rows = rawItems.map((item) {
      final manualShelf = (item['manual_shelf_label'] ?? '').toString().trim();
      final shelfFloor = (item['shelf_floor'] ?? '').toString().trim();
      final productShelf = _toIntValue(
        item['product_shelf_number'] ?? item['shelf_number'],
        0,
      );
      final shelfLabel = _isAnnaUtevskayaTenantScope()
          ? [
              if (manualShelf.isNotEmpty) manualShelf,
              if (manualShelf.isEmpty && productShelf > 0)
                productShelf.toString().padLeft(2, '0'),
              if (shelfFloor.isNotEmpty)
                '$_placementBoxDisplayLabel $shelfFloor',
            ].join(' · ')
          : [
              if (manualShelf.isNotEmpty) manualShelf,
              if (manualShelf.isEmpty && productShelf > 0)
                'Полка ${productShelf.toString().padLeft(2, '0')}',
              if (shelfFloor.isNotEmpty)
                '$_placementBoxDisplayLabel $shelfFloor',
            ].join(' · ');
      final assemblyStatus = (item['assembly_status'] ?? 'pending')
          .toString()
          .trim();
      return <String, dynamic>{
        'id': (item['id'] ?? '').toString(),
        'title': (item['product_title'] ?? 'Товар').toString(),
        'description': (item['product_description'] ?? '').toString(),
        'image_url':
            _resolveImageUrl((item['product_image_url'] ?? '').toString()) ??
            '',
        'code': item['product_code'],
        'shelf_label': shelfLabel,
        'shelf_title': _placementShelfDisplayLabel,
        'quantity': _toIntValue(item['quantity'], 1),
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
                child: rows.isEmpty
                    ? const Center(child: Text('В корзине нет товаров'))
                    : ListView.separated(
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
                                            Text(
                                              '${row['shelf_title']}: $shelfLabel',
                                            ),
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
                                    'Товар найден и положен в пакет клиента',
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
                                    'Для товара будет напечатан габаритный стикер',
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
                                    'Товар будет убран из этой доставки',
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
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: rows.isEmpty
                      ? null
                      : () {
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
                                'removed_reason':
                                    reasonCtrls[id]?.text.trim() ?? '',
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
      text: _toIntValue(customer['package_places'], 1).toString(),
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
                helperText: 'Пакеты + габариты',
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
          () => _message = 'Ошибка старта сборки: ${_extractRequestError(e)}',
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
        setState(() => _message = 'Ошибка сборки: ${_extractRequestError(e)}');
      }
    } finally {
      if (mounted) setState(() => _deliverySaving = false);
    }
  }

  Future<void> _completeDeliveryAssembly(
    String batchId,
    Map<String, dynamic> customer,
  ) async {
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
          () =>
              _message = 'Ошибка завершения сборки: ${_extractRequestError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _deliverySaving = false);
    }
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
    final courierName = (customer['courier_name'] ?? '').toString().trim();
    final packagePlaces = _toIntValue(customer['package_places'], 1);
    final bulkyPlaces = _toIntValue(customer['bulky_places'], 0);
    final bulkyNote = (customer['bulky_note'] ?? '').toString().trim();
    final callStatus = (customer['call_status'] ?? '').toString().trim();
    final deliveryStatus = (customer['delivery_status'] ?? callStatus)
        .toString()
        .trim();
    final assemblyStatus = (customer['assembly_status'] ?? 'not_started')
        .toString()
        .trim();
    final items = _asMapList(customer['items']);
    final itemsCount = items.fold<int>(
      0,
      (sum, item) => sum + _toIntValue(item['quantity'], 0),
    );
    final canStartAssembly =
        callStatus == 'accepted' && assemblyStatus == 'not_started';
    final canEditAssembly =
        callStatus == 'accepted' && assemblyStatus != 'not_started';
    final canCompleteAssembly =
        callStatus == 'accepted' &&
        assemblyStatus != 'not_started' &&
        assemblyStatus != 'assembled';
    final normalStickers = _toIntValue(customer['normal_stickers_requested']);
    final bulkyStickers = _toIntValue(customer['bulky_stickers_requested']);
    final preferredAfter = _formatClockLabel(customer['preferred_time_from']);
    final preferredBefore = _formatClockLabel(customer['preferred_time_to']);
    final scheme = theme.colorScheme;
    final assemblyBadgeIcon = assemblyStatus == 'assembled'
        ? Icons.task_alt_outlined
        : assemblyStatus == 'issue'
        ? Icons.report_problem_outlined
        : Icons.inventory_2_outlined;
    final assemblyBadgeBackground = assemblyStatus == 'assembled'
        ? const Color(0xFF0E8F6A).withValues(alpha: 0.16)
        : assemblyStatus == 'issue'
        ? const Color(0xFFFFB648).withValues(alpha: 0.16)
        : scheme.surfaceContainerHigh;
    final assemblyBadgeForeground = assemblyStatus == 'assembled'
        ? const Color(0xFF67E0B6)
        : assemblyStatus == 'issue'
        ? const Color(0xFFFFD18A)
        : scheme.onSurface;
    final assemblyBadgeBorder = assemblyStatus == 'assembled'
        ? const Color(0xFF0E8F6A).withValues(alpha: 0.34)
        : assemblyStatus == 'issue'
        ? const Color(0xFFFFB648).withValues(alpha: 0.34)
        : scheme.outlineVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                AppStatusBadge(
                  label: _deliveryAssemblyStatusLabel(assemblyStatus),
                  icon: assemblyBadgeIcon,
                  background: assemblyBadgeBackground,
                  foreground: assemblyBadgeForeground,
                  border: assemblyBadgeBorder,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Телефон: $phone'),
            Text('Сумма в доставке: $sum'),
            Text('Полка: $shelf'),
            Text(
              'Статус доставки: ${_deliveryCustomerStatusLabel(deliveryStatus)}',
            ),
            Text(
              'Ответ после рассылки: ${_deliveryCustomerStatusLabel(callStatus)}',
            ),
            Text(
              'Стикеры: обычных $normalStickers · габаритных $bulkyStickers',
            ),
            if (address.isNotEmpty) Text('Адрес: $address'),
            if (preferredAfter.isNotEmpty || preferredBefore.isNotEmpty)
              Text(
                'Пожелание по времени: ${[if (preferredAfter.isNotEmpty) 'после $preferredAfter', if (preferredBefore.isNotEmpty) 'до $preferredBefore'].join(', ')}',
              ),
            if (courierName.isNotEmpty) Text('Курьер: $courierName'),
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
                  if (itemStatus == 'collected') 'положил',
                ];
                return Text(
                  '• ID ${item['product_code'] ?? '—'} · $itemTitle · ${_formatMoney(item['line_total'])}'
                  '${flags.isNotEmpty ? ' · ${flags.join(', ')}' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              }),
              if (items.length > 6) Text('Ещё товаров: ${items.length - 6}'),
            ],
            const SizedBox(height: 12),
            if (callStatus == 'accepted')
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
              )
            else
              Text(
                'Сборка откроется после согласия клиента на доставку.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
    final assembledAcceptedCount = customers
        .where(
          (customer) =>
              (customer['call_status'] ?? '').toString() == 'accepted' &&
              (customer['assembly_status'] ?? '').toString() == 'assembled',
        )
        .length;

    return RefreshIndicator(
      onRefresh: () => _loadDeliveryDashboard(silent: false),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loadingDeliveryDashboard && activeBatch == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (activeBatch == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Активного листа доставки пока нет.'),
              ),
            )
          else ...[
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
                        fontWeight: FontWeight.w800,
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
                    Text('Согласились: $acceptedCount'),
                    Text(
                      'Собрано корзин: $assembledAcceptedCount/$acceptedCount',
                    ),
                    if (((activeBatch['route_origin_address'] ?? '')
                            .toString()
                            .trim())
                        .isNotEmpty)
                      Text(
                        'Старт маршрута: ${(activeBatch['route_origin_address'] ?? '').toString()}',
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (customers.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('В активной доставке пока нет клиентов.'),
                ),
              )
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
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ..._deliveryBatches.take(5).map((batch) {
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

  Widget _buildNoAccessTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: AppEmptyState(
          badge: 'Worker',
          title: 'Нет прав для панели работника',
          subtitle:
              'Попросите арендатора или администратора выдать доступ к товарам.',
          icon: Icons.lock_outline_rounded,
        ),
      ),
    );
  }

  Widget _statChip(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
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
        appBar: AppBar(title: const Text('Панель работника')),
        body: SafeArea(child: _buildNoAccessTab()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель работника'),
        bottom: TabBar(
          controller: controller,
          tabs: tabs,
          isScrollable: compact,
          onTap: (_) => _dismissKeyboard(),
        ),
      ),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissKeyboard,
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
                    style: TextStyle(
                      color: _messageColor(Theme.of(context)),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(controller: controller, children: tabViews),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

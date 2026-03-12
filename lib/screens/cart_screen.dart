// lib/screens/cart_screen.dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../utils/date_time_utils.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/phoenix_loader.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  bool _loading = true;
  bool _cancelling = false;
  bool _reloading = false;
  bool _reloadQueued = false;
  String _error = '';
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _recentDeliveries = [];
  List<Map<String, dynamic>> _claims = [];
  Map<String, dynamic>? _cartRetentionWarning;
  double _total = 0;
  double _processed = 0;
  double _claimsTotal = 0;
  StreamSubscription? _eventsSub;
  Timer? _reloadDebounceTimer;
  bool _claimSubmitting = false;
  final Set<String> _claimDecisionBusyIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    _eventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if (type != 'cart:updated') return;
      final data = event['data'];
      if (data is! Map) return;
      final currentUserId = authService.currentUser?.id.trim() ?? '';
      final targetUserId = data['userId']?.toString().trim() ?? '';
      if (currentUserId.isEmpty || currentUserId != targetUserId) return;
      _scheduleReload();
    });
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _reloadDebounceTimer?.cancel();
    super.dispose();
  }

  void _applyPayload(Map<String, dynamic> payload) {
    _items = payload['items'] is List
        ? List<Map<String, dynamic>>.from(payload['items'])
        : [];
    _recentDeliveries = payload['recent_deliveries'] is List
        ? List<Map<String, dynamic>>.from(payload['recent_deliveries'])
        : [];
    _claims = payload['claims'] is List
        ? List<Map<String, dynamic>>.from(payload['claims'])
        : [];
    _cartRetentionWarning =
        payload['cart_retention_warning'] is Map
        ? Map<String, dynamic>.from(payload['cart_retention_warning'])
        : null;
    _total = (payload['total_sum'] is num)
        ? (payload['total_sum'] as num).toDouble()
        : double.tryParse('${payload['total_sum'] ?? 0}') ?? 0;
    _processed = (payload['processed_sum'] is num)
        ? (payload['processed_sum'] as num).toDouble()
        : double.tryParse('${payload['processed_sum'] ?? 0}') ?? 0;
    _claimsTotal = (payload['claims_total'] is num)
        ? (payload['claims_total'] as num).toDouble()
        : double.tryParse('${payload['claims_total'] ?? 0}') ?? 0;
  }

  void _scheduleReload({Duration delay = const Duration(milliseconds: 350)}) {
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = Timer(delay, () {
      unawaited(_load(showLoader: false));
    });
  }

  Future<void> _load({bool showLoader = true}) async {
    if (_reloading) {
      _reloadQueued = true;
      return;
    }
    _reloading = true;
    final shouldShowLoader = showLoader && _items.isEmpty;
    setState(() {
      if (shouldShowLoader) {
        _loading = true;
      }
      _error = '';
    });
    try {
      final resp = await authService.dio.get('/api/cart');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        setState(() {
          _applyPayload(payload);
        });
      } else {
        setState(() => _error = 'Неверный ответ сервера');
      }
    } catch (e) {
      setState(
        () => _error = 'Ошибка загрузки корзины: ${_extractDioError(e)}',
      );
    } finally {
      _reloading = false;
      if (mounted) {
        setState(() => _loading = false);
      }
      if (_reloadQueued) {
        _reloadQueued = false;
        _scheduleReload(delay: const Duration(milliseconds: 120));
      }
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

  String _statusText(String raw) {
    switch (raw) {
      case 'preparing_delivery':
        return 'Идет подготовка к отправке';
      case 'handing_to_courier':
        return 'Передается курьеру';
      case 'processed':
        return 'Обработан';
      case 'in_delivery':
        return 'В доставке';
      case 'delivered':
        return 'Доставлено';
      case 'pending_processing':
      default:
        return 'Ожидание обработки';
    }
  }

  Color _statusColor(String raw) {
    switch (raw) {
      case 'preparing_delivery':
        return const Color(0xFF7B5CFA);
      case 'handing_to_courier':
        return const Color(0xFF00897B);
      case 'processed':
        return const Color(0xFF2E7D32);
      case 'in_delivery':
        return const Color(0xFF1565C0);
      case 'delivered':
        return const Color(0xFF6D4C41);
      case 'pending_processing':
      default:
        return const Color(0xFFEF6C00);
    }
  }

  bool _canCancel(String status) {
    return status == 'pending_processing';
  }

  String _formatMoney(dynamic value) {
    final n = (value is num)
        ? value.toDouble()
        : double.tryParse('$value') ?? 0;
    final fixed = n.toStringAsFixed(2);
    return '$fixed ₽';
  }

  Map<String, dynamic>? _claimForCartItem(String cartItemId) {
    if (cartItemId.trim().isEmpty) return null;
    for (final claim in _claims) {
      final id = (claim['cart_item_id'] ?? '').toString();
      if (id == cartItemId) return claim;
    }
    return null;
  }

  String _claimDiscountDecision(Map<String, dynamic> claim) {
    return (claim['customer_discount_status'] ?? '').toString().trim();
  }

  bool _isDiscountDecisionPending(Map<String, dynamic>? claim) {
    if (claim == null) return false;
    final status = (claim['status'] ?? '').toString().trim();
    if (status != 'approved_discount') return false;
    return _claimDiscountDecision(claim) == 'pending';
  }

  String _claimStatusText(String status, {Map<String, dynamic>? claim}) {
    switch (status) {
      case 'pending':
        return 'Ожидает решения';
      case 'approved_return':
        return 'Подтвержден возврат';
      case 'approved_discount':
        if (_isDiscountDecisionPending(claim)) {
          return 'Скидка предложена (ожидает вас)';
        }
        return 'Подтверждена скидка';
      case 'settled':
        return 'Закрыта';
      case 'rejected':
      default:
        return 'Отклонена';
    }
  }

  Color _claimStatusColor(String status, ThemeData theme) {
    switch (status) {
      case 'pending':
        return theme.colorScheme.primary;
      case 'approved_return':
      case 'approved_discount':
        return Colors.green.shade700;
      case 'settled':
        return theme.colorScheme.secondary;
      case 'rejected':
      default:
        return theme.colorScheme.error;
    }
  }

  String _formatDeliveryEta(DateTime dateTime) {
    return formatDateTimeValue(dateTime);
  }

  DateTime? _extractDeliveryEta() {
    DateTime? best;
    for (final item in _items) {
      final etaRaw = (item['eta_from'] ?? '').toString().trim();
      final dateRaw = (item['delivery_date'] ?? '').toString().trim();
      DateTime? candidate = DateTime.tryParse(etaRaw);
      if (candidate == null && dateRaw.isNotEmpty) {
        candidate = DateTime.tryParse(dateRaw);
      }
      if (candidate == null) continue;
      if (best == null || candidate.isBefore(best)) {
        best = candidate;
      }
    }
    return best;
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) {
      return value;
    }
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  Future<String> _uploadClaimImageBytes(
    Uint8List bytes,
    String filename,
  ) async {
    final formData = FormData.fromMap({
      'image': MultipartFile.fromBytes(
        bytes,
        filename: filename.isEmpty ? 'claim-photo.jpg' : filename,
      ),
    });
    final resp = await authService.dio.post(
      '/api/cart/claims/upload-image',
      data: formData,
      options: Options(headers: const {'Content-Type': 'multipart/form-data'}),
    );
    final data = resp.data;
    if (data is! Map || data['ok'] != true || data['data'] is! Map) {
      throw Exception('Не удалось загрузить фото');
    }
    final payload = Map<String, dynamic>.from(data['data']);
    final imageUrl = (payload['image_url'] ?? '').toString().trim();
    if (imageUrl.isEmpty) {
      throw Exception('Сервер не вернул ссылку на фото');
    }
    return imageUrl;
  }

  Future<String?> _pickAndUploadClaimImage({required bool useCamera}) async {
    try {
      final reducedMode = performanceModeNotifier.value;
      final pickerQuality = reducedMode ? 72 : 88;
      final pickerMaxWidth = reducedMode ? 1440.0 : 2200.0;
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        final picked = await _imagePicker.pickImage(
          source: useCamera ? ImageSource.camera : ImageSource.gallery,
          imageQuality: pickerQuality,
          maxWidth: pickerMaxWidth,
        );
        if (picked == null) return null;
        final bytes = await picked.readAsBytes();
        return await _uploadClaimImageBytes(bytes, picked.name);
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      final file = result.files.first;
      final data = file.bytes;
      if (data == null) return null;
      return await _uploadClaimImageBytes(data, file.name);
    } catch (e) {
      if (!mounted) return null;
      showAppNotice(
        context,
        'Ошибка загрузки фото: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
      return null;
    }
  }

  Future<void> _cancelItem(Map<String, dynamic> item) async {
    final status = (item['status'] ?? '').toString();
    if (!_canCancel(status)) {
      showAppNotice(
        context,
        'Отказ невозможен: товар уже обработан',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    final itemId = (item['id'] ?? '').toString();
    if (itemId.isEmpty) return;
    final itemQtyRaw = int.tryParse('${item['quantity'] ?? 1}') ?? 1;
    final itemQty = itemQtyRaw > 0 ? itemQtyRaw : 1;
    int cancelQty = itemQty;

    if (itemQty > 1) {
      int selectedQty = 1;
      final pickedQty = await showDialog<int>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Количество для отказа'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Вы купили $itemQty шт. Сколько хотите отменить?'),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: selectedQty,
                  items: List.generate(
                    itemQty,
                    (i) => DropdownMenuItem<int>(
                      value: i + 1,
                      child: Text('${i + 1}'),
                    ),
                  ),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => selectedQty = value);
                  },
                  decoration: const InputDecoration(
                    labelText: 'Количество',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selectedQty),
                child: const Text('Далее'),
              ),
            ],
          ),
        ),
      );
      if (pickedQty == null) return;
      cancelQty = pickedQty;
    }
    if (!mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отказ от товара'),
        content: Text(
          cancelQty >= itemQty
              ? 'Вы уверены, что хотите отказаться от этого товара?\nТовар вернется в наличие.'
              : 'Вы уверены, что хотите отказаться от $cancelQty шт.?\nОстальная часть останется в корзине.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Отказаться'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _cancelling = true);
    try {
      final resp = await authService.dio.delete(
        '/api/cart/items/$itemId',
        data: {'quantity': cancelQty},
      );
      final payload = resp.data is Map && resp.data['data'] is Map
          ? Map<String, dynamic>.from(resp.data['data'])
          : <String, dynamic>{};
      final remaining =
          int.tryParse('${payload['remaining_quantity'] ?? 0}') ?? 0;
      if (!mounted) return;
      showAppNotice(
        context,
        remaining > 0
            ? 'Отказ оформлен: -$cancelQty шт. (в корзине осталось $remaining)'
            : 'Товар удален из корзины',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      _scheduleReload(delay: const Duration(milliseconds: 120));
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка отказа: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Future<void> _submitClaim({
    required String cartItemId,
    required String claimType,
    required String description,
    required double requestedAmount,
    String imageUrl = '',
  }) async {
    if (_claimSubmitting) return;
    setState(() => _claimSubmitting = true);
    try {
      await authService.dio.post(
        '/api/cart/claims',
        data: {
          'cart_item_id': cartItemId,
          'claim_type': claimType,
          'description': description.trim(),
          'requested_amount': requestedAmount,
          if (imageUrl.trim().isNotEmpty) 'image_url': imageUrl.trim(),
        },
      );
      if (!mounted) return;
      showAppNotice(
        context,
        'Заявка отправлена в обработку',
        tone: AppNoticeTone.success,
      );
      _scheduleReload(delay: const Duration(milliseconds: 100));
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка заявки: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _claimSubmitting = false);
    }
  }

  Future<void> _respondToDiscountClaim({
    required String claimId,
    required bool accept,
  }) async {
    final id = claimId.trim();
    if (id.isEmpty || _claimDecisionBusyIds.contains(id)) return;
    setState(() => _claimDecisionBusyIds.add(id));
    try {
      await authService.dio.post(
        '/api/cart/claims/$id/decision',
        data: {'action': accept ? 'accept_discount' : 'reject_discount'},
      );
      if (!mounted) return;
      showAppNotice(
        context,
        accept
            ? 'Скидка подтверждена'
            : 'Скидка отклонена. Возврат оформлен автоматически',
        tone: AppNoticeTone.success,
      );
      _scheduleReload(delay: const Duration(milliseconds: 120));
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _claimDecisionBusyIds.remove(id));
      } else {
        _claimDecisionBusyIds.remove(id);
      }
    }
  }

  Future<void> _openClaimDialog(Map<String, dynamic> item) async {
    final cartItemId = (item['id'] ?? '').toString().trim();
    if (cartItemId.isEmpty) return;
    final lineTotal = (item['line_total'] is num)
        ? (item['line_total'] as num).toDouble()
        : double.tryParse('${item['line_total'] ?? 0}') ?? 0;
    final amountCtrl = TextEditingController(
      text: lineTotal > 0 ? lineTotal.toStringAsFixed(2) : '',
    );
    final descriptionCtrl = TextEditingController();
    var claimType = 'return';
    var imageUrl = '';
    var imageUploading = false;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Сообщить о проблеме'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: claimType,
                    items: const [
                      DropdownMenuItem(value: 'return', child: Text('Возврат')),
                      DropdownMenuItem(
                        value: 'discount',
                        child: Text('Скидка'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => claimType = value);
                    },
                    decoration: const InputDecoration(labelText: 'Тип заявки'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descriptionCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Опишите проблему',
                      hintText: 'Например: треснутая крышка, брак упаковки...',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Сумма претензии (₽)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: imageUploading
                            ? null
                            : () async {
                                setDialogState(() => imageUploading = true);
                                final uploaded = await _pickAndUploadClaimImage(
                                  useCamera: true,
                                );
                                if (!mounted || !ctx.mounted) return;
                                setDialogState(() {
                                  imageUploading = false;
                                  if (uploaded != null && uploaded.isNotEmpty) {
                                    imageUrl = uploaded;
                                  }
                                });
                              },
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Сфоткать'),
                      ),
                      OutlinedButton.icon(
                        onPressed: imageUploading
                            ? null
                            : () async {
                                setDialogState(() => imageUploading = true);
                                final uploaded = await _pickAndUploadClaimImage(
                                  useCamera: false,
                                );
                                if (!mounted || !ctx.mounted) return;
                                setDialogState(() {
                                  imageUploading = false;
                                  if (uploaded != null && uploaded.isNotEmpty) {
                                    imageUrl = uploaded;
                                  }
                                });
                              },
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Из галереи'),
                      ),
                      if (imageUrl.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: imageUploading
                              ? null
                              : () => setDialogState(() => imageUrl = ''),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Убрать фото'),
                        ),
                    ],
                  ),
                  if (imageUploading) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (imageUrl.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Фото прикреплено',
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Отправить'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;

      final description = descriptionCtrl.text.trim();
      if (description.length < 5) {
        if (mounted) {
          showAppNotice(
            context,
            'Опишите проблему минимум в 5 символов',
            tone: AppNoticeTone.warning,
          );
        }
        return;
      }
      final requestedAmount =
          double.tryParse(amountCtrl.text.trim().replaceAll(',', '.')) ??
          lineTotal;

      await _submitClaim(
        cartItemId: cartItemId,
        claimType: claimType,
        description: description,
        requestedAmount: requestedAmount,
        imageUrl: imageUrl.trim(),
      );
    } finally {
      amountCtrl.dispose();
      descriptionCtrl.dispose();
    }
  }

  Widget _buildSummary() {
    final theme = Theme.of(context);
    final reducedVisuals =
        performanceModeNotifier.value ||
        (MediaQuery.maybeOf(context)?.disableAnimations == true);
    final eta = _extractDeliveryEta();
    final titleColor = reducedVisuals
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimary;
    final secondaryColor = reducedVisuals
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onPrimary.withValues(alpha: 0.82);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: reducedVisuals ? theme.colorScheme.surfaceContainerLow : null,
        gradient: reducedVisuals
            ? null
            : LinearGradient(
                colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(18),
        border: reducedVisuals
            ? Border.all(color: theme.colorScheme.outlineVariant)
            : null,
        boxShadow: reducedVisuals
            ? const []
            : [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.22),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Ваша корзина',
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (eta != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: reducedVisuals
                        ? theme.colorScheme.surface
                        : theme.colorScheme.onPrimary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: reducedVisuals
                          ? theme.colorScheme.outlineVariant
                          : theme.colorScheme.onPrimary.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Предварительное время доставки',
                        style: TextStyle(
                          color: secondaryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDeliveryEta(eta),
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Общая сумма: ${_formatMoney(_total)}',
            style: TextStyle(color: titleColor, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Обработано: ${_formatMoney(_processed)}',
            style: TextStyle(color: secondaryColor, fontSize: 14),
          ),
          if (_claimsTotal > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Сумма брака: ${_formatMoney(_claimsTotal)}',
              style: TextStyle(color: secondaryColor, fontSize: 13),
            ),
          ],
          if (_cartRetentionWarning != null &&
              _cartRetentionWarning!['active'] == true) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: reducedVisuals
                    ? theme.colorScheme.errorContainer.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: reducedVisuals
                      ? theme.colorScheme.error
                      : Colors.white.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                (_cartRetentionWarning!['message'] ??
                        'Корзина удерживается слишком долго и готовится к расформировке.')
                    .toString(),
                style: TextStyle(
                  color: reducedVisuals
                      ? theme.colorScheme.error
                      : theme.colorScheme.onPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImage(String? imageUrl) {
    final theme = Theme.of(context);
    if (imageUrl == null || imageUrl.isEmpty) {
      return Container(
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.image_not_supported_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 86,
        height: 86,
        child: AdaptiveNetworkImage(
          imageUrl,
          width: 86,
          height: 86,
          fit: BoxFit.cover,
          errorBuilder: (_, error, stackTrace) => Container(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.broken_image_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final theme = Theme.of(context);
    final title = (item['title'] ?? 'Товар').toString();
    final statusRaw = (item['status'] ?? '').toString();
    final quantity = (item['quantity'] is num)
        ? (item['quantity'] as num).toInt()
        : int.tryParse('${item['quantity']}') ?? 0;
    final unitPrice = (item['price'] is num)
        ? (item['price'] as num).toDouble()
        : double.tryParse('${item['price'] ?? 0}') ?? 0;
    final lineTotal = (item['line_total'] is num)
        ? (item['line_total'] as num).toDouble()
        : double.tryParse('${item['line_total'] ?? 0}') ?? 0;
    final imageUrl = _resolveImageUrl((item['image_url'] ?? '').toString());
    final statusColor = _statusColor(statusRaw);
    final canCancel = _canCancel(statusRaw);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImage(imageUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _infoChip('Цена 1 шт', _formatMoney(unitPrice)),
                          _infoChip('Количество', '$quantity'),
                          _infoChip('Сумма', _formatMoney(lineTotal)),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _statusText(statusRaw),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                if (canCancel)
                  TextButton.icon(
                    onPressed: _cancelling ? null : () => _cancelItem(item),
                    icon: const Icon(Icons.remove_shopping_cart_outlined),
                    label: Text(_cancelling ? 'Отмена...' : 'Отказаться'),
                  )
                else
                  Text(
                    'Отказ недоступен',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatShortDeliveryDate(dynamic raw) {
    return formatDateTimeValue(raw, fallback: 'Доставка');
  }

  Widget _buildRecentDeliveryCard(Map<String, dynamic> delivery) {
    final theme = Theme.of(context);
    final label = (delivery['delivery_label'] ?? 'Доставка').toString();
    final dateLabel = _formatShortDeliveryDate(delivery['delivery_date']);
    final total = _formatMoney(delivery['total_sum']);
    final itemsCount = (delivery['items_count'] is num)
        ? (delivery['items_count'] as num).toInt()
        : int.tryParse('${delivery['items_count'] ?? 0}') ?? 0;
    final items = delivery['items'] is List
        ? List<Map<String, dynamic>>.from(delivery['items'])
        : const <Map<String, dynamic>>[];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Text(
            '$label • $dateLabel',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text('Сумма: $total • Товаров: $itemsCount'),
          children: items.map((item) {
            final cartItemId = (item['id'] ?? '').toString().trim();
            final imageUrl = _resolveImageUrl(
              (item['image_url'] ?? '').toString(),
            );
            final quantity = (item['quantity'] is num)
                ? (item['quantity'] as num).toInt()
                : int.tryParse('${item['quantity']}') ?? 0;
            final lineTotal = (item['line_total'] is num)
                ? (item['line_total'] as num).toDouble()
                : double.tryParse('${item['line_total'] ?? 0}') ?? 0;
            final claim = _claimForCartItem(cartItemId);
            final claimStatus = (claim?['status'] ?? '').toString();
            final canCreateClaim = claim == null;
            final claimColor = _claimStatusColor(claimStatus, theme);
            final approvedAmount = (claim?['approved_amount'] is num)
                ? (claim?['approved_amount'] as num).toDouble()
                : double.tryParse('${claim?['approved_amount'] ?? 0}') ?? 0;
            final discountDecisionPending = _isDiscountDecisionPending(claim);
            final claimId = (claim?['id'] ?? '').toString().trim();
            final claimDecisionBusy =
                claimId.isNotEmpty && _claimDecisionBusyIds.contains(claimId);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildImage(imageUrl),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (item['title'] ?? 'Товар').toString(),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _infoChip('Количество', '$quantity'),
                                _infoChip('Сумма', _formatMoney(lineTotal)),
                                _infoChip('Статус', 'Доставлено'),
                                if (claim != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: claimColor.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      'Заявка: ${_claimStatusText(claimStatus, claim: claim)}',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: claimColor,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (claim != null && approvedAmount > 0)
                              Text(
                                'Подтверждено: ${_formatMoney(approvedAmount)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: (canCreateClaim && !_claimSubmitting)
                            ? () => _openClaimDialog(item)
                            : null,
                        icon: const Icon(Icons.report_problem_outlined),
                        label: Text(
                          canCreateClaim
                              ? 'Сообщить о проблеме'
                              : 'Повторная заявка недоступна',
                        ),
                      ),
                    ],
                  ),
                  if (discountDecisionPending && claimId.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: claimDecisionBusy
                                ? null
                                : () => _respondToDiscountClaim(
                                    claimId: claimId,
                                    accept: true,
                                  ),
                            icon: const Icon(Icons.check_circle_outline),
                            label: Text(
                              claimDecisionBusy
                                  ? 'Сохранение...'
                                  : 'Принять скидку',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: claimDecisionBusy
                                ? null
                                : () => _respondToDiscountClaim(
                                    claimId: claimId,
                                    accept: false,
                                  ),
                            icon: const Icon(Icons.restart_alt_outlined),
                            label: const Text('Отказаться → возврат'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inDeliveryItems = _items
        .where((item) => (item['status'] ?? '').toString() == 'in_delivery')
        .toList();
    final basketItems = _items
        .where((item) => (item['status'] ?? '').toString() != 'in_delivery')
        .toList();
    final hasVisibleCartContent =
        basketItems.isNotEmpty || inDeliveryItems.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Корзина')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(showLoader: false),
          child: _loading
              ? const PhoenixLoadingView(
                  title: 'Загружаем корзину',
                  subtitle: 'Собираем ваши товары и статусы',
                  size: 52,
                )
              : _error.isNotEmpty
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    AppEmptyState(
                      title: 'Не удалось загрузить корзину',
                      subtitle: _error,
                      icon: Icons.error_outline_rounded,
                      action: FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Повторить'),
                      ),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildSummary(),
                    const SizedBox(height: 14),
                    if (!hasVisibleCartContent)
                      const AppEmptyState(
                        title: 'Корзина пока пустая',
                        subtitle:
                            'Добавьте товар из канала, чтобы он появился здесь.',
                        icon: Icons.shopping_basket_outlined,
                      )
                    else ...[
                      if (basketItems.isNotEmpty) ...[
                        Text(
                          'Текущая корзина',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        ...basketItems.map(_buildItemCard),
                      ],
                      if (inDeliveryItems.isNotEmpty) ...[
                        if (basketItems.isNotEmpty) const SizedBox(height: 16),
                        Text(
                          'Сейчас в доставке',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        ...inDeliveryItems.map(_buildItemCard),
                      ],
                    ],
                    if (_recentDeliveries.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Две последние доставки',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      ..._recentDeliveries.map(_buildRecentDeliveryCard),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

// lib/screens/cart_screen.dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/phoenix_loader.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _loading = true;
  bool _cancelling = false;
  bool _reloading = false;
  bool _reloadQueued = false;
  String _error = '';
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _recentDeliveries = [];
  double _total = 0;
  double _processed = 0;
  StreamSubscription? _eventsSub;
  Timer? _reloadDebounceTimer;

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
    _total = (payload['total_sum'] is num)
        ? (payload['total_sum'] as num).toDouble()
        : double.tryParse('${payload['total_sum'] ?? 0}') ?? 0;
    _processed = (payload['processed_sum'] is num)
        ? (payload['processed_sum'] as num).toDouble()
        : double.tryParse('${payload['processed_sum'] ?? 0}') ?? 0;
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
    return '$fixed RUB';
  }

  String _formatDeliveryEta(DateTime dateTime) {
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = months[dateTime.month - 1];
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day $month, $hour:$minute';
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

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отказ от товара'),
        content: const Text(
          'Вы уверены, что хотите отказаться от этого товара?\n'
          'Товар вернется в наличие.',
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
      await authService.dio.delete('/api/cart/items/$itemId');
      if (!mounted) return;
      showAppNotice(
        context,
        'Товар удален из корзины',
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

  Widget _buildSummary() {
    final theme = Theme.of(context);
    final eta = _extractDeliveryEta();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
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
              const Expanded(
                child: Text(
                  'Ваша корзина',
                  style: TextStyle(
                    color: Colors.white,
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
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'Предварительное время доставки',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDeliveryEta(eta),
                        style: const TextStyle(
                          color: Colors.white,
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
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Обработано: ${_formatMoney(_processed)}',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
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
        child: Image.network(
          imageUrl,
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
    final parsed = DateTime.tryParse('${raw ?? ''}');
    if (parsed == null) return 'Доставка';
    return _formatDeliveryEta(parsed).split(',').first;
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
            final imageUrl = _resolveImageUrl(
              (item['image_url'] ?? '').toString(),
            );
            final quantity = (item['quantity'] is num)
                ? (item['quantity'] as num).toInt()
                : int.tryParse('${item['quantity']}') ?? 0;
            final lineTotal = (item['line_total'] is num)
                ? (item['line_total'] as num).toDouble()
                : double.tryParse('${item['line_total'] ?? 0}') ?? 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
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
                          ],
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
                    Text(
                      _error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _load,
                      child: const Text('Повторить'),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildSummary(),
                    const SizedBox(height: 14),
                    if (!hasVisibleCartContent)
                      Builder(
                        builder: (context) {
                          final theme = Theme.of(context);
                          return Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.shopping_basket_outlined,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Корзина пока пустая',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
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

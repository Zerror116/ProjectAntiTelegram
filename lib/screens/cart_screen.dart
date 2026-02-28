// lib/screens/cart_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _loading = true;
  bool _cancelling = false;
  String _error = '';
  List<Map<String, dynamic>> _items = [];
  double _total = 0;
  double _processed = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final resp = await authService.dio.get('/api/cart');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        setState(() {
          _items = payload['items'] is List
              ? List<Map<String, dynamic>>.from(payload['items'])
              : [];
          _total = (payload['total_sum'] is num)
              ? (payload['total_sum'] as num).toDouble()
              : 0;
          _processed = (payload['processed_sum'] is num)
              ? (payload['processed_sum'] as num).toDouble()
              : 0;
        });
      } else {
        setState(() => _error = 'Неверный ответ сервера');
      }
    } catch (e) {
      setState(
        () => _error = 'Ошибка загрузки корзины: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
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
      case 'processed':
        return 'Обработан';
      case 'in_delivery':
        return 'В доставке';
      case 'pending_processing':
      default:
        return 'Ожидание обработки';
    }
  }

  Color _statusColor(String raw) {
    switch (raw) {
      case 'processed':
        return const Color(0xFF2E7D32);
      case 'in_delivery':
        return const Color(0xFF1565C0);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отказ невозможен: товар уже обработан')),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Товар удален из корзины')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отказа: ${_extractDioError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Widget _buildSummary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blueGrey.shade700, Colors.blueGrey.shade500],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ваша корзина',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
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
    if (imageUrl == null || imageUrl.isEmpty) {
      return Container(
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.image_not_supported_outlined),
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
            color: Colors.grey.shade200,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final title = (item['title'] ?? 'Товар').toString();
    final statusRaw = (item['status'] ?? '').toString();
    final quantity = (item['quantity'] is num)
        ? (item['quantity'] as num).toInt()
        : int.tryParse('${item['quantity']}') ?? 0;
    final unitPrice = (item['price'] is num) ? item['price'] : 0;
    final lineTotal = (item['line_total'] is num) ? item['line_total'] : 0;
    final imageUrl = _resolveImageUrl((item['image_url'] ?? '').toString());
    final statusColor = _statusColor(statusRaw);
    final canCancel = _canCancel(statusRaw);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
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
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Корзина')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(_error, style: const TextStyle(color: Colors.red)),
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
                    if (_items.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text('Корзина пока пустая'),
                      )
                    else
                      ..._items.map(_buildItemCard),
                  ],
                ),
        ),
      ),
    );
  }
}

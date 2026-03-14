import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflinePurchaseQueueItem {
  final String id;
  final String userId;
  final String tenantCode;
  final String productId;
  final int quantity;
  final String queuedAtIso;
  final String? sourceChatId;

  const OfflinePurchaseQueueItem({
    required this.id,
    required this.userId,
    required this.tenantCode,
    required this.productId,
    required this.quantity,
    required this.queuedAtIso,
    required this.sourceChatId,
  });

  factory OfflinePurchaseQueueItem.fromMap(Map<String, dynamic> map) {
    final qtyRaw = int.tryParse('${map['quantity'] ?? 1}') ?? 1;
    return OfflinePurchaseQueueItem(
      id: (map['id'] ?? '').toString().trim(),
      userId: (map['user_id'] ?? '').toString().trim(),
      tenantCode: (map['tenant_code'] ?? '').toString().trim().toLowerCase(),
      productId: (map['product_id'] ?? '').toString().trim(),
      quantity: qtyRaw <= 0 ? 1 : qtyRaw,
      queuedAtIso: (map['queued_at'] ?? '').toString().trim(),
      sourceChatId: (map['source_chat_id'] ?? '').toString().trim().isEmpty
          ? null
          : (map['source_chat_id'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'user_id': userId,
      'tenant_code': tenantCode,
      'product_id': productId,
      'quantity': quantity,
      'queued_at': queuedAtIso,
      'source_chat_id': sourceChatId,
    };
  }
}

enum OfflinePurchaseSyncOutcome { confirmed, rejected }

class OfflinePurchaseSyncEvent {
  final OfflinePurchaseSyncOutcome outcome;
  final String productId;
  final int quantity;
  final String message;

  const OfflinePurchaseSyncEvent({
    required this.outcome,
    required this.productId,
    required this.quantity,
    required this.message,
  });
}

class OfflinePurchaseSyncResult {
  final int confirmed;
  final int rejected;
  final int remaining;
  final List<OfflinePurchaseSyncEvent> events;

  const OfflinePurchaseSyncResult({
    required this.confirmed,
    required this.rejected,
    required this.remaining,
    required this.events,
  });
}

class OfflinePurchaseQueueService {
  static const _storageKey = 'offline_purchase_queue_v1';
  final Random _random = Random();

  String _normalizeTenantCode(String? raw) {
    return (raw ?? '').trim().toLowerCase();
  }

  String _newQueueId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final tail = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$ts-$tail';
  }

  Future<List<OfflinePurchaseQueueItem>> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) return <OfflinePurchaseQueueItem>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return <OfflinePurchaseQueueItem>[];
    }
    if (decoded is! List) return <OfflinePurchaseQueueItem>[];

    final out = <OfflinePurchaseQueueItem>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final parsed = OfflinePurchaseQueueItem.fromMap(
        Map<String, dynamic>.from(item),
      );
      if (parsed.id.isEmpty ||
          parsed.userId.isEmpty ||
          parsed.productId.isEmpty ||
          parsed.quantity <= 0) {
        continue;
      }
      out.add(parsed);
    }
    return out;
  }

  Future<void> _saveQueue(List<OfflinePurchaseQueueItem> queue) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = queue.map((item) => item.toMap()).toList(growable: false);
    await prefs.setString(_storageKey, jsonEncode(payload));
  }

  Future<OfflinePurchaseQueueItem> enqueuePurchase({
    required String userId,
    required String productId,
    String? tenantCode,
    String? sourceChatId,
    int quantity = 1,
  }) async {
    final normalizedUserId = userId.trim();
    final normalizedProductId = productId.trim();
    final normalizedTenantCode = _normalizeTenantCode(tenantCode);
    final normalizedQty = quantity <= 0 ? 1 : quantity;

    if (normalizedUserId.isEmpty || normalizedProductId.isEmpty) {
      throw ArgumentError('userId/productId must be non-empty');
    }

    final queue = await _loadQueue();
    final existingIdx = queue.indexWhere((item) {
      return item.userId == normalizedUserId &&
          item.productId == normalizedProductId &&
          item.tenantCode == normalizedTenantCode;
    });

    final nowIso = DateTime.now().toIso8601String();
    if (existingIdx >= 0) {
      final existing = queue[existingIdx];
      final updated = OfflinePurchaseQueueItem(
        id: existing.id,
        userId: existing.userId,
        tenantCode: existing.tenantCode,
        productId: existing.productId,
        quantity: existing.quantity + normalizedQty,
        queuedAtIso: nowIso,
        sourceChatId: sourceChatId ?? existing.sourceChatId,
      );
      queue[existingIdx] = updated;
      await _saveQueue(queue);
      return updated;
    }

    final created = OfflinePurchaseQueueItem(
      id: _newQueueId(),
      userId: normalizedUserId,
      tenantCode: normalizedTenantCode,
      productId: normalizedProductId,
      quantity: normalizedQty,
      queuedAtIso: nowIso,
      sourceChatId: sourceChatId?.trim().isEmpty ?? true
          ? null
          : sourceChatId!.trim(),
    );
    queue.add(created);
    await _saveQueue(queue);
    return created;
  }

  Future<int> countForUser(String userId, {String? tenantCode}) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return 0;
    final normalizedTenant = _normalizeTenantCode(tenantCode);
    final queue = await _loadQueue();
    return queue
        .where(
          (item) =>
              item.userId == normalizedUserId &&
              (normalizedTenant.isEmpty || item.tenantCode == normalizedTenant),
        )
        .fold<int>(0, (sum, item) => sum + item.quantity);
  }

  bool _isConnectionError(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    final text = (e.message ?? '').toLowerCase();
    return text.contains('connection refused') ||
        text.contains('failed host lookup') ||
        text.contains('socketexception') ||
        text.contains('network is unreachable');
  }

  String _extractServerMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final message = (data['error'] ?? data['message'] ?? '').toString().trim();
      if (message.isNotEmpty) return message;
    }
    return (e.message ?? '').trim();
  }

  bool _isFinalRejectStatus(int? statusCode) {
    if (statusCode == null) return false;
    return statusCode == 400 || statusCode == 404 || statusCode == 409;
  }

  Future<OfflinePurchaseSyncResult> flushQueuedPurchases({
    required Dio dio,
    required String userId,
    String? tenantCode,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return const OfflinePurchaseSyncResult(
        confirmed: 0,
        rejected: 0,
        remaining: 0,
        events: <OfflinePurchaseSyncEvent>[],
      );
    }
    final normalizedTenant = _normalizeTenantCode(tenantCode);
    final queue = await _loadQueue();
    if (queue.isEmpty) {
      return const OfflinePurchaseSyncResult(
        confirmed: 0,
        rejected: 0,
        remaining: 0,
        events: <OfflinePurchaseSyncEvent>[],
      );
    }

    final target = <OfflinePurchaseQueueItem>[];
    final other = <OfflinePurchaseQueueItem>[];
    for (final item in queue) {
      final sameUser = item.userId == normalizedUserId;
      final sameTenant =
          normalizedTenant.isEmpty || item.tenantCode == normalizedTenant;
      if (sameUser && sameTenant) {
        target.add(item);
      } else {
        other.add(item);
      }
    }

    if (target.isEmpty) {
      return const OfflinePurchaseSyncResult(
        confirmed: 0,
        rejected: 0,
        remaining: 0,
        events: <OfflinePurchaseSyncEvent>[],
      );
    }

    var confirmed = 0;
    var rejected = 0;
    final events = <OfflinePurchaseSyncEvent>[];
    final remainingTarget = <OfflinePurchaseQueueItem>[];

    for (var idx = 0; idx < target.length; idx += 1) {
      final item = target[idx];
      try {
        final resp = await dio.post(
          '/api/cart/add',
          data: <String, dynamic>{
            'product_id': item.productId,
            'quantity': item.quantity,
          },
        );
        final ok = resp.statusCode == 200 || resp.statusCode == 201;
        if (!ok) {
          remainingTarget.add(item);
          remainingTarget.addAll(target.skip(idx + 1));
          break;
        }
        confirmed += 1;
        events.add(
          OfflinePurchaseSyncEvent(
            outcome: OfflinePurchaseSyncOutcome.confirmed,
            productId: item.productId,
            quantity: item.quantity,
            message: 'Покупка подтверждена и добавлена в корзину',
          ),
        );
      } on DioException catch (e) {
        if (_isConnectionError(e)) {
          remainingTarget.add(item);
          remainingTarget.addAll(target.skip(idx + 1));
          break;
        }
        final statusCode = e.response?.statusCode;
        final message = _extractServerMessage(e);
        if (_isFinalRejectStatus(statusCode)) {
          rejected += 1;
          events.add(
            OfflinePurchaseSyncEvent(
              outcome: OfflinePurchaseSyncOutcome.rejected,
              productId: item.productId,
              quantity: item.quantity,
              message: message.isEmpty
                  ? 'Не удалось купить товар: он недоступен'
                  : message,
            ),
          );
          continue;
        }
        remainingTarget.add(item);
        remainingTarget.addAll(target.skip(idx + 1));
        break;
      } catch (_) {
        remainingTarget.add(item);
        remainingTarget.addAll(target.skip(idx + 1));
        break;
      }
    }

    final nextQueue = <OfflinePurchaseQueueItem>[...other, ...remainingTarget];
    await _saveQueue(nextQueue);

    return OfflinePurchaseSyncResult(
      confirmed: confirmed,
      rejected: rejected,
      remaining: remainingTarget.fold<int>(0, (sum, item) => sum + item.quantity),
      events: events,
    );
  }
}

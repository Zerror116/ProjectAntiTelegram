import 'dart:async';
import 'dart:convert';

import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_browser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_outbox_service.dart';

class _IndexedDbChatOutboxService implements ChatOutboxService {
  static const String _dbName = 'fenix_chat_outbox_v2';
  static const String _storeName = 'items';
  static const String _legacyStorageKey = 'fenix_chat_outbox_v1';

  Future<idb.Database>? _dbFuture;
  bool _legacyMigrated = false;

  Future<idb.Database> _openDb() {
    return _dbFuture ??= idbFactoryBrowser.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, keyPath: 'id');
        }
      },
    );
  }

  Future<void> _ensureLegacyMigration() async {
    if (_legacyMigrated) return;
    _legacyMigrated = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyStorageKey);
    if ((raw ?? '').trim().isEmpty) return;
    try {
      final db = await _openDb();
      final tx = db.transaction(_storeName, idb.idbModeReadWrite);
      final store = tx.objectStore(_storeName);
      final decoded = jsonDecode(raw!);
      if (decoded is Map) {
        final parsed = Map<String, dynamic>.from(decoded);
        for (final entry in parsed.entries) {
          final value = entry.value;
          if (value is Map) {
            await store.put(Map<String, dynamic>.from(value));
          }
        }
      }
      await tx.completed;
      await prefs.remove(_legacyStorageKey);
    } catch (_) {
      // Keep app usable even if migration fails.
    }
  }

  Future<List<Map<String, dynamic>>> _readAllItems() async {
    await _ensureLegacyMigration();
    final db = await _openDb();
    final tx = db.transaction(_storeName, idb.idbModeReadOnly);
    final store = tx.objectStore(_storeName);
    final items = <Map<String, dynamic>>[];
    await for (final cursor in store.openCursor(autoAdvance: true)) {
      final value = cursor.value;
      if (value is Map) {
        items.add(Map<String, dynamic>.from(value));
      }
    }
    await tx.completed;
    return items;
  }

  Future<Map<String, dynamic>?> _readItem(String id) async {
    await _ensureLegacyMigration();
    final db = await _openDb();
    final tx = db.transaction(_storeName, idb.idbModeReadOnly);
    final store = tx.objectStore(_storeName);
    final value = await store.getObject(id);
    await tx.completed;
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  Future<void> _putItem(Map<String, dynamic> item) async {
    await _ensureLegacyMigration();
    final db = await _openDb();
    final tx = db.transaction(_storeName, idb.idbModeReadWrite);
    final store = tx.objectStore(_storeName);
    await store.put(item);
    await tx.completed;
  }

  Future<void> _deleteItem(String id) async {
    await _ensureLegacyMigration();
    final db = await _openDb();
    final tx = db.transaction(_storeName, idb.idbModeReadWrite);
    final store = tx.objectStore(_storeName);
    await store.delete(id);
    await tx.completed;
  }

  @override
  Future<List<ChatOutboxItem>> listForChat({
    required String chatId,
    required String tenantCode,
  }) async {
    final normalizedTenant = normalizeChatOutboxTenantCode(tenantCode);
    final list = (await _readAllItems())
        .map(ChatOutboxItem.fromMap)
        .where(
          (item) =>
              item.chatId == chatId && item.tenantCode == normalizedTenant,
        )
        .toList(growable: false)
      ..sort((a, b) => a.updatedAtIso.compareTo(b.updatedAtIso));
    return list;
  }

  @override
  Future<List<ChatOutboxItem>> listAll() async {
    final list = (await _readAllItems())
        .map(ChatOutboxItem.fromMap)
        .toList(growable: false)
      ..sort((a, b) => a.updatedAtIso.compareTo(b.updatedAtIso));
    return list;
  }

  @override
  Future<void> remove({
    required String chatId,
    required String tenantCode,
    required String clientMsgId,
  }) async {
    final id = buildChatOutboxItemId(
      chatId: chatId,
      tenantCode: tenantCode,
      clientMsgId: clientMsgId,
    );
    await _deleteItem(id);
  }

  @override
  Future<void> updateStatus({
    required String chatId,
    required String tenantCode,
    required String clientMsgId,
    required String status,
    String? errorMessage,
    bool clearError = false,
    int? retryCount,
    Map<String, dynamic>? message,
  }) async {
    final id = buildChatOutboxItemId(
      chatId: chatId,
      tenantCode: tenantCode,
      clientMsgId: clientMsgId,
    );
    final raw = await _readItem(id);
    if (raw == null) return;
    final current = ChatOutboxItem.fromMap(raw);
    await _putItem(
      current
          .copyWith(
            status: status,
            errorMessage: errorMessage,
            clearError: clearError,
            retryCount: retryCount,
            message: message,
            updatedAtIso: DateTime.now().toIso8601String(),
          )
          .toMap(),
    );
  }

  @override
  Future<void> upsert(ChatOutboxItem item) async {
    await _putItem(item.toMap());
  }

  @override
  Future<void> clearFailed() async {
    final items = await listAll();
    for (final item in items) {
      if (item.status == 'error' || item.status == 'failed_permanent') {
        await _deleteItem(item.id);
      }
    }
  }

  @override
  Future<void> clearAll() async {
    final db = await _openDb();
    final tx = db.transaction(_storeName, idb.idbModeReadWrite);
    await tx.objectStore(_storeName).clear();
    await tx.completed;
  }
}

ChatOutboxService createChatOutboxService() => _IndexedDbChatOutboxService();

import 'chat_outbox_service.dart';

class _MemoryChatOutboxService implements ChatOutboxService {
  final Map<String, ChatOutboxItem> _items = <String, ChatOutboxItem>{};

  @override
  Future<List<ChatOutboxItem>> listAll() async {
    final list = _items.values.toList(growable: false)
      ..sort((a, b) => a.updatedAtIso.compareTo(b.updatedAtIso));
    return list;
  }

  @override
  Future<List<ChatOutboxItem>> listForChat({
    required String chatId,
    required String tenantCode,
  }) async {
    final normalizedTenant = normalizeChatOutboxTenantCode(tenantCode);
    final list = _items.values
        .where(
          (item) => item.chatId == chatId && item.tenantCode == normalizedTenant,
        )
        .toList()
      ..sort((a, b) => a.updatedAtIso.compareTo(b.updatedAtIso));
    return list;
  }

  @override
  Future<void> remove({
    required String chatId,
    required String tenantCode,
    required String clientMsgId,
  }) async {
    _items.remove(
      buildChatOutboxItemId(
        chatId: chatId,
        tenantCode: tenantCode,
        clientMsgId: clientMsgId,
      ),
    );
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
    final current = _items[id];
    if (current == null) return;
    _items[id] = current.copyWith(
      status: status,
      errorMessage: errorMessage,
      clearError: clearError,
      retryCount: retryCount,
      message: message,
      updatedAtIso: DateTime.now().toIso8601String(),
    );
  }

  @override
  Future<void> upsert(ChatOutboxItem item) async {
    _items[item.id] = item;
  }

  @override
  Future<void> clearFailed() async {
    _items.removeWhere(
      (_, item) => item.status == 'error' || item.status == 'failed_permanent',
    );
  }

  @override
  Future<void> clearAll() async {
    _items.clear();
  }
}

ChatOutboxService createChatOutboxService() => _MemoryChatOutboxService();

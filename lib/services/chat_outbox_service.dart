import 'dart:convert';

import 'chat_outbox_service_stub.dart'
    if (dart.library.html) 'chat_outbox_service_web.dart' as impl;

class ChatOutboxItem {
  final String id;
  final String chatId;
  final String tenantCode;
  final String clientMsgId;
  final String userId;
  final String status;
  final Map<String, dynamic> message;
  final Map<String, dynamic> retryPayload;
  final String? errorMessage;
  final int retryCount;
  final String createdAtIso;
  final String updatedAtIso;

  const ChatOutboxItem({
    required this.id,
    required this.chatId,
    required this.tenantCode,
    required this.clientMsgId,
    required this.userId,
    required this.status,
    required this.message,
    required this.retryPayload,
    required this.errorMessage,
    required this.retryCount,
    required this.createdAtIso,
    required this.updatedAtIso,
  });

  factory ChatOutboxItem.fromMap(Map<String, dynamic> map) {
    return ChatOutboxItem(
      id: (map['id'] ?? '').toString().trim(),
      chatId: (map['chat_id'] ?? '').toString().trim(),
      tenantCode: (map['tenant_code'] ?? '').toString().trim().toLowerCase(),
      clientMsgId: (map['client_msg_id'] ?? '').toString().trim(),
      userId: (map['user_id'] ?? '').toString().trim(),
      status: (map['status'] ?? 'queued').toString().trim(),
      message: map['message'] is Map
          ? Map<String, dynamic>.from(map['message'] as Map)
          : <String, dynamic>{},
      retryPayload: map['retry_payload'] is Map
          ? Map<String, dynamic>.from(map['retry_payload'] as Map)
          : <String, dynamic>{},
      errorMessage: (map['error_message'] ?? '').toString().trim().isEmpty
          ? null
          : (map['error_message'] ?? '').toString().trim(),
      retryCount: map['retry_count'] is num
          ? (map['retry_count'] as num).toInt()
          : int.tryParse('${map['retry_count'] ?? 0}') ?? 0,
      createdAtIso: (map['created_at'] ?? '').toString().trim(),
      updatedAtIso: (map['updated_at'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'chat_id': chatId,
      'tenant_code': tenantCode,
      'client_msg_id': clientMsgId,
      'user_id': userId,
      'status': status,
      'message': message,
      'retry_payload': retryPayload,
      'error_message': errorMessage,
      'retry_count': retryCount,
      'created_at': createdAtIso,
      'updated_at': updatedAtIso,
    };
  }

  ChatOutboxItem copyWith({
    String? status,
    Map<String, dynamic>? message,
    Map<String, dynamic>? retryPayload,
    String? errorMessage,
    bool clearError = false,
    int? retryCount,
    String? updatedAtIso,
  }) {
    return ChatOutboxItem(
      id: id,
      chatId: chatId,
      tenantCode: tenantCode,
      clientMsgId: clientMsgId,
      userId: userId,
      status: status ?? this.status,
      message: message ?? this.message,
      retryPayload: retryPayload ?? this.retryPayload,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      retryCount: retryCount ?? this.retryCount,
      createdAtIso: createdAtIso,
      updatedAtIso: updatedAtIso ?? this.updatedAtIso,
    );
  }
}

abstract class ChatOutboxService {
  Future<void> upsert(ChatOutboxItem item);
  Future<List<ChatOutboxItem>> listAll();
  Future<void> remove({
    required String chatId,
    required String tenantCode,
    required String clientMsgId,
  });
  Future<List<ChatOutboxItem>> listForChat({
    required String chatId,
    required String tenantCode,
  });
  Future<void> updateStatus({
    required String chatId,
    required String tenantCode,
    required String clientMsgId,
    required String status,
    String? errorMessage,
    bool clearError,
    int? retryCount,
    Map<String, dynamic>? message,
  });
  Future<void> clearFailed();
  Future<void> clearAll();
}

String buildChatOutboxItemId({
  required String chatId,
  required String tenantCode,
  required String clientMsgId,
}) {
  return '${tenantCode.trim().toLowerCase()}::${chatId.trim()}::${clientMsgId.trim()}';
}

String normalizeChatOutboxTenantCode(String? raw) {
  return (raw ?? '').trim().toLowerCase();
}

Map<String, dynamic> sanitizeChatOutboxJson(Map<String, dynamic> value) {
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

final ChatOutboxService chatOutboxService = impl.createChatOutboxService();

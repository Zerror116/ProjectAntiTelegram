enum MessengerSupportStatusTone { primary, secondary, success, neutral }

enum MessengerReservedQuickFilter {
  all,
  waiting,
  processed,
  oversize,
  shelfless,
}

String messengerSupportStatusLabel(
  String raw, {
  bool hasAssignee = false,
}) {
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
      return '';
  }
}

MessengerSupportStatusTone messengerSupportStatusTone(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'waiting_customer':
      return MessengerSupportStatusTone.secondary;
    case 'resolved':
      return MessengerSupportStatusTone.success;
    case 'archived':
      return MessengerSupportStatusTone.neutral;
    case 'open':
    default:
      return MessengerSupportStatusTone.primary;
  }
}

String messengerSupportWaitingLabel({required bool waitingCustomer}) {
  return waitingCustomer
      ? 'Сейчас ждём ваш ответ'
      : 'Сейчас ход за поддержкой';
}

String messengerBuildLastMessagePreview({
  required String rawText,
  String? senderId,
  String? senderName,
  String? currentUserId,
}) {
  final text = rawText
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join(' ');
  final compact = text.isEmpty ? 'Пока без сообщений' : text;
  if (compact == 'Пока без сообщений') return compact;

  final trimmedSenderId = (senderId ?? '').trim();
  final trimmedSenderName = (senderName ?? '').trim();
  final trimmedCurrentUserId = (currentUserId ?? '').trim();
  if (trimmedSenderId.isEmpty || trimmedSenderName == 'Система') {
    return compact;
  }

  final prefix =
      trimmedSenderId.isNotEmpty && trimmedSenderId == trimmedCurrentUserId
      ? 'Вы'
      : trimmedSenderName;
  return '$prefix: $compact';
}

bool messengerMatchesReservedSearch({
  required String query,
  required bool reservedContext,
  String? text,
  String? title,
  String? description,
  String? clientName,
  String? productCode,
  String? clientPhone,
}) {
  final rawQuery = query.trim();
  if (rawQuery.isEmpty) return true;
  if (reservedContext && RegExp(r'^\d+$').hasMatch(rawQuery)) {
    final normalizedProductCode = (productCode ?? '').trim();
    return normalizedProductCode.isNotEmpty && normalizedProductCode == rawQuery;
  }

  final q = rawQuery.toLowerCase();
  final blobs = <String>[
    (text ?? '').toLowerCase(),
    (title ?? '').toLowerCase(),
    (description ?? '').toLowerCase(),
    (clientName ?? '').toLowerCase(),
    (productCode ?? '').toLowerCase(),
    (clientPhone ?? '').toLowerCase(),
  ];
  return blobs.any((value) => value.contains(q));
}

String messengerReservedQuickFilterLabel(MessengerReservedQuickFilter filter) {
  switch (filter) {
    case MessengerReservedQuickFilter.all:
      return 'Все';
    case MessengerReservedQuickFilter.waiting:
      return 'Ожидание';
    case MessengerReservedQuickFilter.processed:
      return 'Обработано';
    case MessengerReservedQuickFilter.oversize:
      return 'Габарит';
    case MessengerReservedQuickFilter.shelfless:
      return 'Без полки';
  }
}

bool messengerMatchesReservedQuickFilter({
  required MessengerReservedQuickFilter filter,
  required bool isPlaced,
  required bool isOversize,
  required String shelfNumber,
}) {
  final trimmedShelf = shelfNumber.trim();
  switch (filter) {
    case MessengerReservedQuickFilter.all:
      return true;
    case MessengerReservedQuickFilter.waiting:
      return !isPlaced;
    case MessengerReservedQuickFilter.processed:
      return isPlaced;
    case MessengerReservedQuickFilter.oversize:
      return isOversize;
    case MessengerReservedQuickFilter.shelfless:
      return !isOversize && trimmedShelf.isEmpty;
  }
}

String messengerLocalDeliveryLabel(
  String status, {
  double? progress,
  required bool retryable,
}) {
  final normalizedStatus = status.trim().toLowerCase();
  final normalizedProgress = progress?.clamp(0.0, 1.0);
  final progressPercent = normalizedProgress == null
      ? null
      : (normalizedProgress * 100).round().clamp(0, 100);
  switch (normalizedStatus) {
    case 'uploading':
      return progressPercent == null || progressPercent <= 0
          ? 'Загружается...'
          : 'Загружается $progressPercent%';
    case 'sending':
      return 'Отправляется...';
    case 'error':
      return retryable
          ? 'Не отправлено'
          : 'Не отправлено, прикрепите заново';
    default:
      return '';
  }
}

String messengerEditedBadgeText({
  String? editedByRole,
  String? editedByName,
  String? senderName,
}) {
  final role = (editedByRole ?? '').trim().toLowerCase();
  final editorName = (editedByName ?? '').trim();
  final originalSenderName = (senderName ?? '').trim();
  if ((role == 'admin' || role == 'creator') &&
      editorName.isNotEmpty &&
      editorName != originalSenderName) {
    return 'изменено • $editorName';
  }
  return 'изменено';
}

String messengerForwardedHeaderText(String forwardedBy) {
  final trimmed = forwardedBy.trim();
  return trimmed.isEmpty ? '' : 'Переслано от $trimmed';
}

String messengerReplyHeaderText(String senderName) {
  final trimmed = senderName.trim();
  return trimmed.isEmpty ? 'Ответ' : trimmed;
}

bool messengerShouldShowUnreadDivider({
  required String searchQuery,
  String? firstUnreadMessageId,
}) {
  return searchQuery.trim().isEmpty &&
      (firstUnreadMessageId ?? '').trim().isNotEmpty;
}

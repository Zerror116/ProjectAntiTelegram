import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/src/utils/messenger_ui_helpers.dart';

void main() {
  group('messengerMatchesReservedSearch', () {
    test('numeric reserved query matches only exact product code', () {
      expect(
        messengerMatchesReservedSearch(
          query: '1234',
          reservedContext: true,
          productCode: '1234',
          title: 'Товар',
        ),
        isTrue,
      );
      expect(
        messengerMatchesReservedSearch(
          query: '1234',
          reservedContext: true,
          productCode: '91234',
          title: 'Товар',
        ),
        isFalse,
      );
      expect(
        messengerMatchesReservedSearch(
          query: '1234',
          reservedContext: true,
          title: 'Товар 1234',
        ),
        isFalse,
      );
    });

    test('text query matches reserved title and description', () {
      expect(
        messengerMatchesReservedSearch(
          query: 'кроссовки',
          reservedContext: true,
          title: 'Белые кроссовки',
          description: 'Размер 42',
        ),
        isTrue,
      );
      expect(
        messengerMatchesReservedSearch(
          query: 'размер 42',
          reservedContext: true,
          title: 'Белые кроссовки',
          description: 'Размер 42',
        ),
        isTrue,
      );
    });
  });

  group('messengerSupport helpers', () {
    test('maps support statuses to user-facing labels', () {
      expect(messengerSupportStatusLabel('waiting_customer'), 'Ждём клиента');
      expect(messengerSupportStatusLabel('resolved'), 'Решён');
      expect(messengerSupportStatusLabel('archived'), 'Архив');
      expect(messengerSupportStatusLabel('open'), 'Открыт');
    });

    test('maps waiting side labels', () {
      expect(
        messengerSupportWaitingLabel(waitingCustomer: true),
        'Ждём клиента',
      );
      expect(
        messengerSupportWaitingLabel(waitingCustomer: false),
        'Ждём сотрудника',
      );
    });
  });

  group('messenger preview helpers', () {
    test('builds last message preview for current user', () {
      expect(
        messengerBuildLastMessagePreview(
          rawText: 'Привет\nмир',
          senderId: 'u1',
          senderName: 'Вазген',
          currentUserId: 'u1',
        ),
        'Вы: Привет мир',
      );
    });

    test('builds forwarded and reply labels', () {
      expect(messengerForwardedHeaderText('Анна'), 'Переслано от Анна');
      expect(messengerReplyHeaderText(''), 'Ответ');
      expect(messengerReplyHeaderText('Дима'), 'Дима');
    });
  });

  group('messenger delivery and edits', () {
    test('builds local delivery labels', () {
      expect(
        messengerLocalDeliveryLabel('uploading', progress: 0.42, retryable: true),
        'Загружается 42%',
      );
      expect(
        messengerLocalDeliveryLabel('sending', retryable: true),
        'Отправляется...',
      );
      expect(
        messengerLocalDeliveryLabel('error', retryable: true),
        'Не отправлено',
      );
      expect(
        messengerLocalDeliveryLabel('error', retryable: false),
        'Не отправлено, прикрепите заново',
      );
    });

    test('builds edited badge with admin attribution', () {
      expect(
        messengerEditedBadgeText(
          editedByRole: 'admin',
          editedByName: 'Админ',
          senderName: 'Клиент',
        ),
        'изменено • Админ',
      );
      expect(
        messengerEditedBadgeText(
          editedByRole: 'user',
          editedByName: 'Клиент',
          senderName: 'Клиент',
        ),
        'изменено',
      );
    });
  });

  group('messenger reserved filters and unread', () {
    test('matches reserved quick filters', () {
      expect(
        messengerMatchesReservedQuickFilter(
          filter: MessengerReservedQuickFilter.waiting,
          isPlaced: false,
          isOversize: false,
          shelfNumber: '',
        ),
        isTrue,
      );
      expect(
        messengerMatchesReservedQuickFilter(
          filter: MessengerReservedQuickFilter.processed,
          isPlaced: true,
          isOversize: false,
          shelfNumber: '12',
        ),
        isTrue,
      );
      expect(
        messengerMatchesReservedQuickFilter(
          filter: MessengerReservedQuickFilter.oversize,
          isPlaced: true,
          isOversize: true,
          shelfNumber: '',
        ),
        isTrue,
      );
      expect(
        messengerMatchesReservedQuickFilter(
          filter: MessengerReservedQuickFilter.shelfless,
          isPlaced: false,
          isOversize: false,
          shelfNumber: '',
        ),
        isTrue,
      );
    });

    test('shows unread divider only outside search mode', () {
      expect(
        messengerShouldShowUnreadDivider(
          searchQuery: '',
          firstUnreadMessageId: 'msg-1',
        ),
        isTrue,
      );
      expect(
        messengerShouldShowUnreadDivider(
          searchQuery: 'поиск',
          firstUnreadMessageId: 'msg-1',
        ),
        isFalse,
      );
      expect(
        messengerShouldShowUnreadDivider(
          searchQuery: '',
          firstUnreadMessageId: '',
        ),
        isFalse,
      );
    });
  });
}

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class NotificationOpenTrackerService {
  const NotificationOpenTrackerService._();

  static Future<void> reportOpened(Dio dio, String itemId) async {
    final normalizedId = itemId.trim();
    if (normalizedId.isEmpty) return;
    try {
      await dio.post('/api/notifications/inbox/$normalizedId/opened');
    } catch (e) {
      debugPrint('NotificationOpenTrackerService.reportOpened skipped: $e');
    }
  }
}

import 'chat_recent_gallery_models.dart';
import 'chat_recent_gallery_service_stub.dart'
    if (dart.library.io) 'chat_recent_gallery_service_io.dart'
    as impl;

export 'chat_recent_gallery_models.dart';

class ChatRecentGalleryService {
  const ChatRecentGalleryService._();

  static bool get isSupported => impl.isSupported;

  static Future<List<ChatRecentGalleryItem>> loadRecent({int limit = 72}) {
    return impl.loadRecent(limit: limit);
  }

  static Future<ChatRecentGalleryUpload?> loadUpload(
    ChatRecentGalleryItem item,
  ) {
    return impl.loadUpload(item);
  }
}

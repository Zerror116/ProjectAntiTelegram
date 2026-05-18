import 'chat_recent_gallery_models.dart';

bool get isSupported => false;

Future<List<ChatRecentGalleryItem>> loadRecent({int limit = 72}) async {
  return const <ChatRecentGalleryItem>[];
}

Future<ChatRecentGalleryUpload?> loadUpload(ChatRecentGalleryItem item) async {
  return null;
}

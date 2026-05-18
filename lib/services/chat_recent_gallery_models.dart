import 'dart:typed_data';

class ChatRecentGalleryItem {
  const ChatRecentGalleryItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.thumbnailBytes,
  });

  final String id;
  final String kind;
  final String title;
  final DateTime createdAt;
  final Uint8List? thumbnailBytes;
}

class ChatRecentGalleryUpload {
  const ChatRecentGalleryUpload({
    required this.kind,
    required this.filename,
    this.path,
    this.bytes,
    this.mimeType,
    this.fileSize,
  });

  final String kind;
  final String filename;
  final String? path;
  final Uint8List? bytes;
  final String? mimeType;
  final int? fileSize;
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'chat_recent_gallery_models.dart';

final Map<String, AssetEntity> _assetCache = <String, AssetEntity>{};

bool get isSupported {
  return !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
}

String _kindOf(AssetEntity asset) {
  return asset.type == AssetType.video ? 'video' : 'image';
}

String _extensionForKind(String kind) {
  return kind == 'video' ? 'mp4' : 'jpg';
}

String _mimeTypeFor(String filename, String kind) {
  final lower = filename.trim().toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.m4v')) return 'video/x-m4v';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  return kind == 'video' ? 'video/mp4' : 'image/jpeg';
}

Future<List<ChatRecentGalleryItem>> loadRecent({int limit = 72}) async {
  if (!isSupported) return const <ChatRecentGalleryItem>[];
  final permission = await PhotoManager.requestPermissionExtend();
  if (!permission.hasAccess) return const <ChatRecentGalleryItem>[];

  final paths = await PhotoManager.getAssetPathList(
    onlyAll: true,
    type: RequestType.common,
  );
  if (paths.isEmpty) return const <ChatRecentGalleryItem>[];

  final assets = await paths.first.getAssetListPaged(
    page: 0,
    size: limit.clamp(1, 120).toInt(),
  );
  final out = <ChatRecentGalleryItem>[];
  for (final asset in assets) {
    if (asset.type != AssetType.image && asset.type != AssetType.video) {
      continue;
    }
    final thumbnail = await asset.thumbnailDataWithSize(
      const ThumbnailSize.square(360),
      quality: 82,
    );
    _assetCache[asset.id] = asset;
    final fallbackTitle =
        'media-${asset.createDateTime.millisecondsSinceEpoch}.${_extensionForKind(_kindOf(asset))}';
    final title = (asset.title ?? '').trim().isNotEmpty
        ? asset.title!.trim()
        : (await asset.titleAsync).trim();
    out.add(
      ChatRecentGalleryItem(
        id: asset.id,
        kind: _kindOf(asset),
        title: title.isNotEmpty ? title : fallbackTitle,
        createdAt: asset.createDateTime,
        thumbnailBytes: thumbnail,
      ),
    );
  }
  return out;
}

Future<ChatRecentGalleryUpload?> loadUpload(ChatRecentGalleryItem item) async {
  if (!isSupported) return null;
  final cached = _assetCache[item.id];
  if (cached == null) return null;
  final kind = _kindOf(cached);
  final title = item.title.trim().isNotEmpty
      ? item.title.trim()
      : 'media-${DateTime.now().millisecondsSinceEpoch}.${_extensionForKind(kind)}';

  File? file;
  try {
    file = await cached.file;
  } catch (_) {
    file = null;
  }

  Uint8List? bytes;
  if (file == null) {
    try {
      bytes = await cached.originBytes;
    } catch (_) {
      bytes = null;
    }
  }

  final path = (file?.path ?? '').trim();
  if (path.isEmpty && (bytes == null || bytes.isEmpty)) return null;

  int? fileSize;
  if (bytes != null && bytes.isNotEmpty) {
    fileSize = bytes.length;
  } else if (file != null) {
    try {
      fileSize = await file.length();
    } catch (_) {}
  }

  return ChatRecentGalleryUpload(
    kind: kind,
    filename: title,
    path: path.isNotEmpty ? path : null,
    bytes: bytes == null || bytes.isEmpty ? null : bytes,
    mimeType: _mimeTypeFor(title, kind),
    fileSize: fileSize,
  );
}

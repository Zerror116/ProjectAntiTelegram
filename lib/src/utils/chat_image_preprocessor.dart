import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const int _defaultChatImageMaxSide = 1600;
const int _defaultChatImageJpegQuality = 88;

class ChatImagePreprocessResult {
  const ChatImagePreprocessResult({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.preprocessTag,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int width;
  final int height;
  final String preprocessTag;

  double get aspectRatio =>
      height <= 0 ? 1.0 : (width / height).clamp(0.1, 10.0).toDouble();

  factory ChatImagePreprocessResult.fromMap(Map<String, Object> raw) {
    return ChatImagePreprocessResult(
      bytes: raw['bytes'] as Uint8List,
      filename: raw['filename'] as String,
      mimeType: raw['mimeType'] as String,
      width: raw['width'] as int,
      height: raw['height'] as int,
      preprocessTag: raw['preprocessTag'] as String,
    );
  }
}

Future<ChatImagePreprocessResult> preprocessChatImageForMessage({
  required Uint8List bytes,
  required String filename,
  int maxSide = _defaultChatImageMaxSide,
  int jpegQuality = _defaultChatImageJpegQuality,
}) async {
  final payload = <String, Object>{
    'bytes': bytes,
    'filename': filename,
    'maxSide': maxSide,
    'jpegQuality': jpegQuality,
  };
  final result = kIsWeb
      ? _preprocessChatImagePayload(payload)
      : await compute(_preprocessChatImagePayload, payload);
  return ChatImagePreprocessResult.fromMap(result);
}

Map<String, Object> _preprocessChatImagePayload(Map<String, Object> payload) {
  final bytes = payload['bytes'] as Uint8List;
  final filename = payload['filename'] as String;
  final maxSide = payload['maxSide'] as int;
  final jpegQuality = payload['jpegQuality'] as int;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return <String, Object>{
      'bytes': bytes,
      'filename': _normalizeJpgFilename(filename),
      'mimeType': 'image/jpeg',
      'width': 0,
      'height': 0,
      'preprocessTag': 'chat_image_passthrough_v1',
    };
  }

  final baked = img.bakeOrientation(decoded);
  final resized = _resizeToMaxSide(baked, maxSide: maxSide);
  final encoded = Uint8List.fromList(
    img.encodeJpg(resized, quality: jpegQuality.clamp(60, 95)),
  );

  return <String, Object>{
    'bytes': encoded,
    'filename': _normalizeJpgFilename(filename),
    'mimeType': 'image/jpeg',
    'width': resized.width,
    'height': resized.height,
    'preprocessTag': 'chat_image_standardized_jpeg_v1',
  };
}

img.Image _resizeToMaxSide(img.Image image, {required int maxSide}) {
  final longestSide = math.max(image.width, image.height);
  if (longestSide <= maxSide) return image;

  final scale = maxSide / longestSide;
  final targetWidth = math.max(1, (image.width * scale).round());
  final targetHeight = math.max(1, (image.height * scale).round());
  return img.copyResize(
    image,
    width: targetWidth,
    height: targetHeight,
    interpolation: img.Interpolation.average,
  );
}

String _normalizeJpgFilename(String raw) {
  final trimmed = raw.trim();
  final safeBase = trimmed
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  final base = safeBase.isEmpty ? 'chat-image' : safeBase;
  return '$base.jpg';
}

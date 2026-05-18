import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'web_video_note_capture_service_stub.dart'
    if (dart.library.html) 'web_video_note_capture_service_web.dart'
    as impl;

class WebVideoNoteCaptureResult {
  const WebVideoNoteCaptureResult({
    required this.bytes,
    required this.filename,
    required this.durationMs,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final int durationMs;
  final String mimeType;

  factory WebVideoNoteCaptureResult.fromMap(Map<String, dynamic> map) {
    final rawBytes = map['bytes'];
    return WebVideoNoteCaptureResult(
      bytes: rawBytes is Uint8List ? rawBytes : Uint8List(0),
      filename: (map['filename'] ?? '').toString().trim(),
      durationMs: map['duration_ms'] is num
          ? (map['duration_ms'] as num).round()
          : int.tryParse('${map['duration_ms'] ?? 0}') ?? 0,
      mimeType: (map['mime_type'] ?? '').toString().trim(),
    );
  }
}

class WebVideoNoteCaptureService {
  const WebVideoNoteCaptureService._();

  static bool get isSupported => impl.isSupported();

  static Future<void> start() => impl.start();

  static Future<WebVideoNoteCaptureResult> stop() async {
    return WebVideoNoteCaptureResult.fromMap(await impl.stop());
  }

  static Future<void> cancel() => impl.cancel();

  static Widget previewWidget({Key? key}) => impl.previewWidget(key: key);
}

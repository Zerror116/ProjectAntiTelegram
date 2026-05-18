import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeVideoNoteCaptureResult {
  const NativeVideoNoteCaptureResult({
    required this.path,
    required this.filename,
    required this.durationMs,
    this.mimeType = 'video/quicktime',
  });

  final String path;
  final String filename;
  final int durationMs;
  final String mimeType;

  factory NativeVideoNoteCaptureResult.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoNoteCaptureResult(
      path: (map['path'] ?? '').toString().trim(),
      filename: (map['filename'] ?? '').toString().trim(),
      durationMs: map['duration_ms'] is num
          ? (map['duration_ms'] as num).round()
          : int.tryParse('${map['duration_ms'] ?? 0}') ?? 0,
      mimeType: (map['mime_type'] ?? '').toString().trim().isEmpty
          ? 'video/quicktime'
          : (map['mime_type'] ?? '').toString().trim(),
    );
  }
}

class NativeVideoNoteCaptureService {
  NativeVideoNoteCaptureService._();

  static const MethodChannel _channel = MethodChannel(
    'project_fenix/video_note_capture',
  );
  static const EventChannel _previewChannel = EventChannel(
    'project_fenix/video_note_preview',
  );
  static Stream<Uint8List>? _previewFrames;

  static bool get shouldUseNativeCapture {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  }

  static Future<bool> isSupported() async {
    if (!shouldUseNativeCapture) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> start() async {
    await _channel.invokeMethod<void>('start');
  }

  static Future<void> startPreview() async {
    await _channel.invokeMethod<void>('startPreview');
  }

  static Future<void> stopPreview() async {
    await _channel.invokeMethod<void>('stopPreview');
  }

  static Future<Uint8List?> capturePhoto() async {
    final data = await _channel.invokeMethod<Uint8List>('capturePhoto');
    if (data == null || data.isEmpty) return null;
    return data;
  }

  static Stream<Uint8List> get previewFrames {
    return _previewFrames ??= _previewChannel
        .receiveBroadcastStream()
        .where((event) => event is Uint8List)
        .cast<Uint8List>()
        .asBroadcastStream();
  }

  static Future<NativeVideoNoteCaptureResult> stop() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stop');
    if (result == null) {
      throw StateError('Native video capture did not return a file');
    }
    return NativeVideoNoteCaptureResult.fromMap(result);
  }

  static Future<void> cancel() async {
    await _channel.invokeMethod<void>('cancel');
  }
}

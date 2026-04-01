import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

const MethodChannel _androidUpdateInstallerChannel = MethodChannel(
  'com.garphoenix.projectphoenix/native_update_installer',
);

String _safeFileName(String raw, {required String fallback}) {
  final normalized = raw.trim().replaceAll('\\', '/').split('/').last.trim();
  final candidate = normalized.isEmpty ? fallback : normalized;
  final safe = candidate
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  return safe.isEmpty ? fallback : safe;
}

String suggestFileNameFromUrl(Uri url, {required String fallbackFileName}) {
  final fromUrl = url.pathSegments.isEmpty ? '' : url.pathSegments.last.trim();
  return _safeFileName(fromUrl, fallback: fallbackFileName);
}

int _toSafeInt(dynamic raw, {int fallback = -1}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse((raw ?? '').toString().trim()) ?? fallback;
}

Future<String?> _downloadPackageWithAndroidDownloadManager({
  required Uri url,
  required String fallbackFileName,
  Map<String, String>? headers,
  void Function(int received, int total)? onProgress,
}) async {
  final fileName = suggestFileNameFromUrl(
    url,
    fallbackFileName: fallbackFileName,
  );
  final downloadId = await _androidUpdateInstallerChannel.invokeMethod<String>(
    'enqueueDownload',
    <String, dynamic>{
      'url': url.toString(),
      'fileName': fileName,
      'headers': headers ?? const <String, String>{},
    },
  );
  if (downloadId == null || downloadId.trim().isEmpty) {
    return null;
  }

  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final rawStatus = await _androidUpdateInstallerChannel.invokeMethod<
      Map<Object?, Object?>
    >(
      'queryDownloadStatus',
      <String, dynamic>{'downloadId': downloadId},
    );
    if (rawStatus == null) return null;
    final status = rawStatus.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final downloadedBytes = _toSafeInt(status['downloadedBytes']);
    final totalBytes = _toSafeInt(status['totalBytes']);
    if (onProgress != null && downloadedBytes >= 0) {
      onProgress(downloadedBytes, totalBytes);
    }

    switch ((status['status'] ?? '').toString().trim()) {
      case 'successful':
        final uri = (status['uri'] ?? '').toString().trim();
        return uri.isEmpty ? null : uri;
      case 'failed':
        final reason = (status['reason'] ?? '').toString().trim();
        throw StateError(
          reason.isEmpty
              ? 'DownloadManager failed to download APK'
              : 'DownloadManager failed to download APK: $reason',
        );
      case 'missing':
        return null;
      case 'paused':
      case 'pending':
      case 'running':
      default:
        continue;
    }
  }
}

Future<String?> downloadPackage({
  required Uri url,
  required String fallbackFileName,
  Map<String, String>? headers,
  void Function(int received, int total)? onProgress,
}) async {
  final scheme = url.scheme.toLowerCase().trim();
  if (scheme != 'http' && scheme != 'https') {
    return null;
  }

  if (Platform.isAndroid) {
    return _downloadPackageWithAndroidDownloadManager(
      url: url,
      fallbackFileName: fallbackFileName,
      headers: headers,
      onProgress: onProgress,
    );
  }

  final appSupportDir = await getApplicationSupportDirectory();
  final updatesDir = Directory(
    '${appSupportDir.path}${Platform.pathSeparator}updates',
  );
  await updatesDir.create(recursive: true);

  final fileName = suggestFileNameFromUrl(
    url,
    fallbackFileName: fallbackFileName,
  );
  final targetFile = File(
    '${updatesDir.path}${Platform.pathSeparator}$fileName',
  );
  if (await targetFile.exists()) {
    await targetFile.delete();
  }

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 5,
    ),
  );

  await dio.downloadUri(
    url,
    targetFile.path,
    deleteOnError: true,
    options: Options(
      headers: headers,
      responseType: ResponseType.stream,
      receiveDataWhenStatusError: true,
    ),
    onReceiveProgress: onProgress,
  );

  if (!await targetFile.exists()) return null;
  final size = await targetFile.length();
  if (size <= 0) return null;
  return targetFile.path;
}

Future<bool> openDownloadedPackage(
  String filePath, {
  bool detached = false,
}) async {
  if (Platform.isAndroid) {
    final trimmed = filePath.trim();
    if (trimmed.startsWith('content://') || trimmed.startsWith('file://')) {
      final opened = await _androidUpdateInstallerChannel.invokeMethod<bool>(
        'openDownloadedUri',
        <String, dynamic>{'uri': trimmed},
      );
      return opened ?? false;
    }
  }

  final file = File(filePath);
  if (!await file.exists()) return false;
  if (detached &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    try {
      await Process.start(
        file.path,
        const [],
        workingDirectory: file.parent.path,
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return true;
    } catch (_) {
      // Fallback to open_filex below.
    }
  }
  final result = await OpenFilex.open(file.path);
  final typeName = result.type.toString().split('.').last.toLowerCase();
  return typeName == 'done' || typeName == 'success';
}

Future<bool> openDownloadsUi() async {
  if (!Platform.isAndroid) return false;
  final opened = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'openDownloadsUi',
  );
  return opened ?? false;
}

Future<void> exitCurrentAppForUpdate({
  Duration delay = const Duration(milliseconds: 1200),
}) async {
  await Future.delayed(delay);
  exit(0);
}

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
    return null;
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
  return false;
}

Future<bool> canPostNotifications() async {
  if (!Platform.isAndroid) return false;
  final allowed = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'canPostNotifications',
  );
  return allowed ?? false;
}

Future<bool> requestNotificationPermission() async {
  if (!Platform.isAndroid) return false;
  final allowed = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'requestNotificationPermission',
  );
  return allowed ?? false;
}

Future<bool> startManagedUpdateDownload({required String payloadJson}) async {
  if (!Platform.isAndroid) return false;
  final started = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'startManagedUpdateDownload',
    <String, dynamic>{'payloadJson': payloadJson},
  );
  return started ?? false;
}

Future<Map<String, dynamic>?> getManagedUpdateStatus() async {
  if (!Platform.isAndroid) return null;
  final raw = await _androidUpdateInstallerChannel
      .invokeMethod<Map<Object?, Object?>>('getManagedUpdateStatus');
  if (raw == null) return null;
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

Future<bool> installManagedUpdate() async {
  if (!Platform.isAndroid) return false;
  final started = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'installManagedUpdate',
  );
  return started ?? false;
}

Future<bool> clearManagedUpdateState() async {
  if (!Platform.isAndroid) return false;
  final cleared = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'clearManagedUpdateState',
  );
  return cleared ?? false;
}

Future<bool> canRequestPackageInstalls() async {
  if (!Platform.isAndroid) return false;
  final allowed = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'canRequestPackageInstalls',
  );
  return allowed ?? false;
}

Future<bool> openUnknownAppSourcesSettings() async {
  if (!Platform.isAndroid) return false;
  final opened = await _androidUpdateInstallerChannel.invokeMethod<bool>(
    'openUnknownAppSourcesSettings',
  );
  return opened ?? false;
}

Future<void> exitCurrentAppForUpdate({
  Duration delay = const Duration(milliseconds: 1200),
}) async {
  await Future.delayed(delay);
  exit(0);
}

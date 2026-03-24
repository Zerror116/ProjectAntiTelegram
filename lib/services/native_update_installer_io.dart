import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

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

Future<bool> openDownloadedPackage(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return false;
  final result = await OpenFilex.open(file.path);
  final typeName = result.type.toString().split('.').last.toLowerCase();
  return typeName == 'done' || typeName == 'success';
}

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';

const _lastRunPrefix = 'uploads_recovery_last_run_v1_';
const _lastSuccessPrefix = 'uploads_recovery_last_success_v1_';
const _defaultCooldown = Duration(minutes: 45);
const _maxTasksPerRun = 80;
const _maxGalleryAssetsToScan = 2500;
const _galleryPageSize = 200;
const _maxTempFilesToScan = 2500;
const _tempHeuristicWindow = Duration(minutes: 7);
const _scanExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
  '.avif',
  '.mp4',
  '.mov',
  '.m4v',
  '.webm',
  '.m4a',
  '.aac',
  '.wav',
  '.mp3',
  '.ogg',
  '.opus',
  '.bin',
};

bool isSupported() {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

class _RecoveryTask {
  const _RecoveryTask({
    required this.id,
    required this.kind,
    required this.relativeUploadPath,
    required this.expectedFilename,
    required this.expectedExtension,
    required this.matchMode,
    required this.originalFileName,
    required this.checksumSha256,
    required this.uploadedAtEpochMs,
  });

  final String id;
  final String kind;
  final String relativeUploadPath;
  final String expectedFilename;
  final String expectedExtension;
  final String matchMode;
  final String? originalFileName;
  final String? checksumSha256;
  final int? uploadedAtEpochMs;

  factory _RecoveryTask.fromMap(Map<String, dynamic> map) {
    int? parseEpoch(dynamic raw) {
      final value = int.tryParse('${raw ?? ''}'.trim());
      return value == null || value <= 0 ? null : value;
    }

    String? cleanNullable(dynamic raw) {
      final value = '${raw ?? ''}'.trim();
      return value.isEmpty ? null : value;
    }

    return _RecoveryTask(
      id: '${map['id'] ?? ''}'.trim(),
      kind: '${map['kind'] ?? ''}'.trim(),
      relativeUploadPath: '${map['relative_upload_path'] ?? ''}'.trim(),
      expectedFilename: '${map['expected_filename'] ?? ''}'.trim(),
      expectedExtension: '${map['expected_extension'] ?? ''}'
          .trim()
          .toLowerCase(),
      matchMode: '${map['match_mode'] ?? ''}'.trim(),
      originalFileName: cleanNullable(map['original_file_name']),
      checksumSha256: cleanNullable(map['checksum_sha256'])?.toLowerCase(),
      uploadedAtEpochMs: parseEpoch(map['uploaded_at_epoch_ms']),
    );
  }

  List<String> lookupNames() {
    final result = <String>{};
    if (originalFileName != null && originalFileName!.trim().isNotEmpty) {
      result.add(originalFileName!.trim().toLowerCase());
    }
    if (expectedFilename.trim().isNotEmpty) {
      result.add(expectedFilename.trim().toLowerCase());
    }
    return result.toList(growable: false);
  }
}

class _LocalFileCandidate {
  const _LocalFileCandidate({required this.file, required this.modifiedAt});

  final File file;
  final DateTime modifiedAt;
}

bool _allowRole(String role) {
  final normalized = role.trim().toLowerCase();
  return normalized == 'worker' ||
      normalized == 'admin' ||
      normalized == 'tenant' ||
      normalized == 'creator' ||
      normalized == 'client';
}

Future<void> maybeRun({
  required String userId,
  required String role,
  bool force = false,
}) async {
  if (!isSupported()) return;
  final normalizedUserId = userId.trim();
  if (normalizedUserId.isEmpty) return;
  if (!_allowRole(role)) return;
  final prefs = await SharedPreferences.getInstance();
  final lastRunKey = '$_lastRunPrefix$normalizedUserId';
  final lastRunRaw = prefs.getInt(lastRunKey);
  if (!force && lastRunRaw != null) {
    final lastRun = DateTime.fromMillisecondsSinceEpoch(lastRunRaw);
    if (DateTime.now().difference(lastRun) < _defaultCooldown) {
      return;
    }
  }
  await prefs.setInt(lastRunKey, DateTime.now().millisecondsSinceEpoch);

  try {
    final tasks = await _fetchTasks();
    if (tasks.isEmpty) return;

    final permissionState = await PhotoManager.requestPermissionExtend();
    final hasGalleryAccess = permissionState.hasAccess;
    final neededNames = <String>{};
    for (final task in tasks) {
      neededNames.addAll(task.lookupNames());
    }

    final tempIndex = await _buildLocalFileIndex(neededNames);
    final galleryIndex = hasGalleryAccess
        ? await _buildGalleryAssetIndex(neededNames)
        : const <String, List<AssetEntity>>{};

    var restored = 0;
    for (final task in tasks) {
      final candidate = await _resolveCandidate(
        task,
        tempIndex: tempIndex,
        galleryIndex: galleryIndex,
      );
      if (candidate == null) continue;
      final uploaded = await _uploadRecoveredFile(task, candidate.file);
      if (uploaded) restored += 1;
    }

    if (restored > 0) {
      await prefs.setInt(
        '$_lastSuccessPrefix$normalizedUserId',
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  } catch (err, stack) {
    debugPrint('[uploads-recovery] maybeRun failed: $err');
    debugPrint('$stack');
  }
}

Future<List<_RecoveryTask>> _fetchTasks() async {
  final response = await authService.dio.get(
    '/api/profile/uploads-recovery/tasks',
    queryParameters: {'limit': _maxTasksPerRun},
  );
  final root = response.data is Map<String, dynamic>
      ? response.data as Map<String, dynamic>
      : Map<String, dynamic>.from(response.data as Map);
  final data = root['data'];
  final rawTasks = data is Map && data['tasks'] is List
      ? data['tasks'] as List
      : const [];
  return rawTasks
      .map(
        (item) => item is Map<String, dynamic>
            ? item
            : Map<String, dynamic>.from(item as Map),
      )
      .map(_RecoveryTask.fromMap)
      .where(
        (task) =>
            task.id.isNotEmpty &&
            task.relativeUploadPath.isNotEmpty &&
            task.expectedFilename.isNotEmpty,
      )
      .toList(growable: false);
}

Future<Map<String, List<_LocalFileCandidate>>> _buildLocalFileIndex(
  Set<String> neededNames,
) async {
  final index = <String, List<_LocalFileCandidate>>{};
  final roots = <Directory?>[
    await getTemporaryDirectory(),
    await getApplicationSupportDirectory(),
    await getApplicationDocumentsDirectory(),
    (await getExternalStorageDirectory()),
  ];

  var scanned = 0;
  Future<void> walk(Directory dir, int depth) async {
    if (depth > 4 || scanned >= _maxTempFilesToScan) return;
    List<FileSystemEntity> children = const [];
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in children) {
      if (scanned >= _maxTempFilesToScan) return;
      if (entity is Directory) {
        await walk(entity, depth + 1);
        continue;
      }
      if (entity is! File) continue;
      scanned += 1;
      final lowerName = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last.toLowerCase()
          : entity.path.split(Platform.pathSeparator).last.toLowerCase();
      final ext = lowerName.contains('.')
          ? '.${lowerName.split('.').last}'
          : '';
      if (!_scanExtensions.contains(ext)) continue;
      final stat = await entity.stat();
      final candidate = _LocalFileCandidate(
        file: entity,
        modifiedAt: stat.modified,
      );
      if (neededNames.contains(lowerName)) {
        (index[lowerName] ??= <_LocalFileCandidate>[]).add(candidate);
      }
      (index['__all__'] ??= <_LocalFileCandidate>[]).add(candidate);
    }
  }

  for (final root in roots.whereType<Directory>()) {
    if (!await root.exists()) continue;
    await walk(root, 0);
  }

  for (final list in index.values) {
    list.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  }
  return index;
}

Future<Map<String, List<AssetEntity>>> _buildGalleryAssetIndex(
  Set<String> neededNames,
) async {
  final index = <String, List<AssetEntity>>{};
  if (neededNames.isEmpty) return index;
  final paths = await PhotoManager.getAssetPathList(
    onlyAll: true,
    type: RequestType.common,
  );
  if (paths.isEmpty) return index;
  final pathEntity = paths.first;
  var scanned = 0;
  var page = 0;
  while (scanned < _maxGalleryAssetsToScan) {
    final assets = await pathEntity.getAssetListPaged(
      page: page,
      size: _galleryPageSize,
    );
    if (assets.isEmpty) break;
    for (final asset in assets) {
      scanned += 1;
      final rawTitle = (asset.title ?? '').trim().isNotEmpty
          ? (asset.title ?? '')
          : await asset.titleAsync;
      final title = rawTitle.trim().toLowerCase();
      if (title.isEmpty || !neededNames.contains(title)) continue;
      (index[title] ??= <AssetEntity>[]).add(asset);
    }
    if (assets.length < _galleryPageSize) break;
    page += 1;
  }
  return index;
}

Future<_LocalFileCandidate?> _resolveCandidate(
  _RecoveryTask task, {
  required Map<String, List<_LocalFileCandidate>> tempIndex,
  required Map<String, List<AssetEntity>> galleryIndex,
}) async {
  final exactNames = task.lookupNames();

  for (final name in exactNames) {
    final tempCandidates = tempIndex[name] ?? const <_LocalFileCandidate>[];
    final matchedTemp = await _pickBestLocalCandidate(
      tempCandidates,
      checksumSha256: task.checksumSha256,
    );
    if (matchedTemp != null) return matchedTemp;

    final galleryCandidates = galleryIndex[name] ?? const <AssetEntity>[];
    final matchedGallery = await _pickBestGalleryCandidate(
      galleryCandidates,
      checksumSha256: task.checksumSha256,
    );
    if (matchedGallery != null) return matchedGallery;
  }

  if (task.matchMode == 'best_effort' && task.uploadedAtEpochMs != null) {
    final allCandidates = tempIndex['__all__'] ?? const <_LocalFileCandidate>[];
    final heuristic = _pickBestHeuristicTempCandidate(task, allCandidates);
    if (heuristic != null) return heuristic;
  }

  return null;
}

Future<_LocalFileCandidate?> _pickBestLocalCandidate(
  List<_LocalFileCandidate> candidates, {
  required String? checksumSha256,
}) async {
  if (candidates.isEmpty) return null;
  if (checksumSha256 == null || checksumSha256.isEmpty) {
    return candidates.length == 1 ? candidates.first : null;
  }
  for (final candidate in candidates) {
    final sha = await _sha256File(candidate.file);
    if (sha == checksumSha256) return candidate;
  }
  return null;
}

Future<_LocalFileCandidate?> _pickBestGalleryCandidate(
  List<AssetEntity> candidates, {
  required String? checksumSha256,
}) async {
  if (candidates.isEmpty) return null;
  final files = <_LocalFileCandidate>[];
  for (final candidate in candidates) {
    final file = await candidate.originFile;
    if (file == null) continue;
    final stat = await file.stat();
    files.add(_LocalFileCandidate(file: file, modifiedAt: stat.modified));
  }
  return _pickBestLocalCandidate(files, checksumSha256: checksumSha256);
}

_LocalFileCandidate? _pickBestHeuristicTempCandidate(
  _RecoveryTask task,
  List<_LocalFileCandidate> candidates,
) {
  if (task.uploadedAtEpochMs == null) return null;
  final expectedMoment = DateTime.fromMillisecondsSinceEpoch(
    task.uploadedAtEpochMs!,
  );
  final expectedExt = task.expectedExtension;
  final windowMatches = candidates
      .where((candidate) {
        final basename = candidate.file.uri.pathSegments.isNotEmpty
            ? candidate.file.uri.pathSegments.last.toLowerCase()
            : candidate.file.path
                  .split(Platform.pathSeparator)
                  .last
                  .toLowerCase();
        final ext = basename.contains('.')
            ? '.${basename.split('.').last}'
            : '';
        if (expectedExt.isNotEmpty && ext != expectedExt) return false;
        final diff = candidate.modifiedAt
            .difference(expectedMoment)
            .inMinutes
            .abs();
        return diff <= _tempHeuristicWindow.inMinutes;
      })
      .toList(growable: false);
  if (windowMatches.length == 1) return windowMatches.first;
  return null;
}

Future<String> _sha256File(File file) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<bool> _uploadRecoveredFile(_RecoveryTask task, File file) async {
  final form = FormData.fromMap({
    'task_id': task.id,
    'file': await MultipartFile.fromFile(
      file.path,
      filename: file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : file.path.split(Platform.pathSeparator).last,
    ),
  });
  try {
    await authService.dio.post(
      '/api/profile/uploads-recovery/upload',
      data: form,
      options: Options(headers: const {'Content-Type': 'multipart/form-data'}),
    );
    return true;
  } catch (err, stack) {
    debugPrint(
      '[uploads-recovery] upload failed for ${task.relativeUploadPath}: $err',
    );
    debugPrint('$stack');
    return false;
  }
}

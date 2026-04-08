import 'dart:convert';

import 'native_update_installer_stub.dart'
    if (dart.library.io) 'native_update_installer_io.dart'
    as impl;

typedef UpdateProgressCallback = void Function(int received, int total);

class ManagedAndroidUpdateState {
  final String status;
  final String stage;
  final String versionToken;
  final int receivedBytes;
  final int totalBytes;
  final int speedBytesPerSec;
  final int etaSeconds;
  final String filePath;
  final String errorCode;
  final String errorMessage;
  final bool required;
  final String packageName;
  final String keyId;
  final String payloadJson;
  final String sha256;
  final String downloadUrl;
  final String title;
  final int lastUpdatedAtMs;
  final bool readyToInstall;
  final bool canResume;

  const ManagedAndroidUpdateState({
    required this.status,
    required this.stage,
    required this.versionToken,
    required this.receivedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
    required this.filePath,
    required this.errorCode,
    required this.errorMessage,
    required this.required,
    required this.packageName,
    required this.keyId,
    required this.payloadJson,
    required this.sha256,
    required this.downloadUrl,
    required this.title,
    required this.lastUpdatedAtMs,
    required this.readyToInstall,
    required this.canResume,
  });

  const ManagedAndroidUpdateState.idle()
    : status = 'idle',
      stage = '',
      versionToken = '',
      receivedBytes = 0,
      totalBytes = 0,
      speedBytesPerSec = 0,
      etaSeconds = -1,
      filePath = '',
      errorCode = '',
      errorMessage = '',
      required = false,
      packageName = '',
      keyId = '',
      payloadJson = '',
      sha256 = '',
      downloadUrl = '',
      title = '',
      lastUpdatedAtMs = 0,
      readyToInstall = false,
      canResume = false;

  static int _toSafeInt(dynamic raw, {int fallback = 0}) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString().trim()) ?? fallback;
  }

  static bool _toSafeBool(dynamic raw, {bool fallback = false}) {
    if (raw is bool) return raw;
    final normalized = (raw ?? '').toString().trim().toLowerCase();
    if (normalized.isEmpty) return fallback;
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  factory ManagedAndroidUpdateState.fromMap(Map<String, dynamic> raw) {
    final status = (raw['status'] ?? '').toString().trim();
    return ManagedAndroidUpdateState(
      status: status.isEmpty ? 'idle' : status,
      stage: (raw['stage'] ?? '').toString().trim(),
      versionToken: (raw['versionToken'] ?? '').toString().trim(),
      receivedBytes: _toSafeInt(raw['receivedBytes']),
      totalBytes: _toSafeInt(raw['totalBytes']),
      speedBytesPerSec: _toSafeInt(raw['speedBytesPerSec']),
      etaSeconds: _toSafeInt(raw['etaSeconds'], fallback: -1),
      filePath: (raw['filePath'] ?? '').toString().trim(),
      errorCode: (raw['errorCode'] ?? '').toString().trim(),
      errorMessage: (raw['errorMessage'] ?? '').toString().trim(),
      required: _toSafeBool(raw['required']),
      packageName: (raw['packageName'] ?? '').toString().trim(),
      keyId: (raw['keyId'] ?? '').toString().trim(),
      payloadJson: (raw['payloadJson'] ?? '').toString().trim(),
      sha256: (raw['sha256'] ?? '').toString().trim(),
      downloadUrl: (raw['downloadUrl'] ?? '').toString().trim(),
      title: (raw['title'] ?? '').toString().trim(),
      lastUpdatedAtMs: _toSafeInt(raw['lastUpdatedAtMs']),
      readyToInstall: _toSafeBool(
        raw['readyToInstall'],
        fallback: status == 'ready_to_install',
      ),
      canResume: _toSafeBool(raw['canResume']),
    );
  }

  bool get isIdle => status == 'idle';
  bool get isDownloading => status == 'downloading';
  bool get isChecking => status == 'checking';
  bool get isVerifying => status == 'verifying';
  bool get isInstalling => status == 'installing';
  bool get isInstalledPendingRestart => status == 'installed_pending_restart';
  bool get isFailed => status == 'failed';

  double? get progress {
    if (totalBytes <= 0 || receivedBytes < 0) return null;
    return (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }
}

class NativeUpdateInstaller {
  const NativeUpdateInstaller._();

  static String suggestFileNameFromUrl(
    Uri url, {
    required String fallbackFileName,
  }) {
    return impl.suggestFileNameFromUrl(url, fallbackFileName: fallbackFileName);
  }

  static Future<String?> downloadPackage({
    required Uri url,
    required String fallbackFileName,
    Map<String, String>? headers,
    UpdateProgressCallback? onProgress,
  }) {
    return impl.downloadPackage(
      url: url,
      fallbackFileName: fallbackFileName,
      headers: headers,
      onProgress: onProgress,
    );
  }

  static Future<bool> openDownloadedPackage(
    String filePath, {
    bool detached = false,
  }) {
    return impl.openDownloadedPackage(filePath, detached: detached);
  }

  static Future<bool> openDownloadsUi() {
    return impl.openDownloadsUi();
  }

  static Future<bool> canPostNotifications() {
    return impl.canPostNotifications();
  }

  static Future<bool> requestNotificationPermission() {
    return impl.requestNotificationPermission();
  }

  static Future<bool> startManagedUpdateDownload(
    Map<String, dynamic> manifestEnvelope,
  ) {
    return impl.startManagedUpdateDownload(
      payloadJson: jsonEncode(manifestEnvelope),
    );
  }

  static Future<ManagedAndroidUpdateState> getManagedUpdateStatus() async {
    final raw = await impl.getManagedUpdateStatus();
    if (raw == null) return const ManagedAndroidUpdateState.idle();
    return ManagedAndroidUpdateState.fromMap(raw);
  }

  static Future<bool> installManagedUpdate() {
    return impl.installManagedUpdate();
  }

  static Future<bool> clearManagedUpdateState() {
    return impl.clearManagedUpdateState();
  }

  static Future<bool> canRequestPackageInstalls() {
    return impl.canRequestPackageInstalls();
  }

  static Future<bool> openUnknownAppSourcesSettings() {
    return impl.openUnknownAppSourcesSettings();
  }

  static Future<void> exitCurrentAppForUpdate({
    Duration delay = const Duration(milliseconds: 1200),
  }) {
    return impl.exitCurrentAppForUpdate(delay: delay);
  }
}

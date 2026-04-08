String suggestFileNameFromUrl(Uri url, {required String fallbackFileName}) {
  final last = url.pathSegments.isEmpty ? '' : url.pathSegments.last.trim();
  if (last.isEmpty) return fallbackFileName;
  return last;
}

Future<String?> downloadPackage({
  required Uri url,
  required String fallbackFileName,
  Map<String, String>? headers,
  void Function(int received, int total)? onProgress,
}) async {
  return null;
}

Future<bool> openDownloadedPackage(
  String filePath, {
  bool detached = false,
}) async {
  return false;
}

Future<bool> openDownloadsUi() async {
  return false;
}

Future<bool> canPostNotifications() async {
  return false;
}

Future<bool> requestNotificationPermission() async {
  return false;
}

Future<bool> startManagedUpdateDownload({required String payloadJson}) async {
  return false;
}

Future<Map<String, dynamic>?> getManagedUpdateStatus() async {
  return null;
}

Future<bool> installManagedUpdate() async {
  return false;
}

Future<bool> clearManagedUpdateState() async {
  return false;
}

Future<bool> canRequestPackageInstalls() async {
  return false;
}

Future<bool> openUnknownAppSourcesSettings() async {
  return false;
}

Future<void> exitCurrentAppForUpdate({
  Duration delay = const Duration(milliseconds: 1200),
}) async {}

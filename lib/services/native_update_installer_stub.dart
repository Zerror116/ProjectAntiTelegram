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

Future<bool> openDownloadedPackage(String filePath) async {
  return false;
}

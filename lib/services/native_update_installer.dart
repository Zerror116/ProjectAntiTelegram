import 'native_update_installer_stub.dart'
    if (dart.library.io) 'native_update_installer_io.dart'
    as impl;

typedef UpdateProgressCallback = void Function(int received, int total);

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

  static Future<bool> openDownloadedPackage(String filePath) {
    return impl.openDownloadedPackage(filePath);
  }
}

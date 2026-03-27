bool isSupported() => false;

Future<String> getPermissionState() async => 'unsupported';

Future<String> requestPreferredAccess({
  required bool includeVideo,
  bool allowAudioOnlyFallback = false,
}) async {
  return 'unsupported';
}

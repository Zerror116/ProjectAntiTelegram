bool isSupported() => false;

bool isDocumentHidden() => false;

bool isStandaloneDisplayMode() => false;

Future<String> getPermissionState() async => 'unsupported';

Future<String> requestPermission() async => 'unsupported';

Future<bool> showSystemNotification({
  required String title,
  String? body,
  String? tag,
  bool silent = false,
}) async {
  return false;
}

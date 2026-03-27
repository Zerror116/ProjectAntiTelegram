// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

bool isSupported() => html.Notification.supported;

bool isDocumentHidden() => html.document.hidden ?? false;

bool isStandaloneDisplayMode() {
  try {
    return html.window.matchMedia('(display-mode: standalone)').matches;
  } catch (_) {
    return false;
  }
}

Future<String> getPermissionState() async {
  if (!isSupported()) return 'unsupported';
  final normalized = (html.Notification.permission ?? 'default')
      .trim()
      .toLowerCase();
  if (normalized == 'granted' ||
      normalized == 'denied' ||
      normalized == 'default') {
    return normalized;
  }
  return 'default';
}

Future<String> requestPermission() async {
  if (!isSupported()) return 'unsupported';
  try {
    final normalized = (await html.Notification.requestPermission())
        .trim()
        .toLowerCase();
    if (normalized.isNotEmpty) return normalized;
  } catch (_) {
    // ignore
  }
  return await getPermissionState();
}

Future<bool> showSystemNotification({
  required String title,
  String? body,
  String? tag,
  bool silent = false,
}) async {
  if (!isSupported()) return false;
  final permission = await getPermissionState();
  if (permission != 'granted') return false;

  try {
    final notification = html.Notification(
      title,
      body: body ?? '',
      tag: tag,
      icon: 'icons/Icon-192.png',
    );
    notification.onClick.listen((_) {
      notification.close();
    });
    return true;
  } catch (_) {
    return false;
  }
}

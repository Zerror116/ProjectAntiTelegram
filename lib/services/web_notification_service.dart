import 'web_notification_service_stub.dart'
    if (dart.library.html) 'web_notification_service_web.dart'
    as impl;

enum WebNotificationPermissionState {
  unsupported,
  defaultState,
  granted,
  denied,
}

WebNotificationPermissionState _parsePermissionState(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'granted':
      return WebNotificationPermissionState.granted;
    case 'denied':
      return WebNotificationPermissionState.denied;
    case 'default':
      return WebNotificationPermissionState.defaultState;
    default:
      return WebNotificationPermissionState.unsupported;
  }
}

class WebNotificationService {
  const WebNotificationService._();

  static bool get isSupported => impl.isSupported();

  static bool get isDocumentHidden => impl.isDocumentHidden();

  static bool get isStandaloneDisplayMode => impl.isStandaloneDisplayMode();

  static Future<WebNotificationPermissionState> getPermissionState() async {
    return _parsePermissionState(await impl.getPermissionState());
  }

  static Future<WebNotificationPermissionState> requestPermission() async {
    return _parsePermissionState(await impl.requestPermission());
  }

  static Future<bool> showSystemNotification({
    required String title,
    String? body,
    String? tag,
    bool silent = false,
  }) {
    return impl.showSystemNotification(
      title: title,
      body: body,
      tag: tag,
      silent: silent,
    );
  }
}

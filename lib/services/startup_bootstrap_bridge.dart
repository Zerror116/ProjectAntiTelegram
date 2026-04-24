import 'startup_bootstrap_bridge_stub.dart'
    if (dart.library.html) 'startup_bootstrap_bridge_web.dart'
    as impl;

class StartupBootstrapBridge {
  const StartupBootstrapBridge._();

  static void setStatus(String message) => impl.setStatus(message);

  static void markReady() => impl.markReady();

  static void showError(String message) => impl.showError(message);
}

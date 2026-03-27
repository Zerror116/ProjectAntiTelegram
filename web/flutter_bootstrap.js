{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
    serviceWorkerUrl:
      "flutter_service_worker.js?v=" + {{flutter_service_worker_version}},
  },
  config: {
    // Force local CanvasKit files from /canvaskit to avoid CSP/CDN issues.
    canvasKitBaseUrl: "canvaskit/",
  },
});

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Force local CanvasKit files from /canvaskit to avoid CSP/CDN issues.
    canvasKitBaseUrl: "canvaskit/",
  },
});

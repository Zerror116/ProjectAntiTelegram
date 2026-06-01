{{flutter_js}}
{{flutter_build_config}}

(() => {
  const scriptUrl = (() => {
    try {
      return new URL(document.currentScript?.src || window.location.href);
    } catch (_) {
      return null;
    }
  })();
  const pageUrl = (() => {
    try {
      return new URL(window.location.href);
    } catch (_) {
      return null;
    }
  })();
  const versionToken =
    scriptUrl?.searchParams.get("v") ||
    pageUrl?.searchParams.get("v") ||
    Date.now().toString();
  const encodedToken = encodeURIComponent(versionToken);
  const builds = Array.isArray(_flutter?.buildConfig?.builds)
    ? _flutter.buildConfig.builds
    : [];
  for (const build of builds) {
    if (build && build.mainJsPath === "main.dart.js") {
      build.mainJsPath = `main.dart.js?v=${encodedToken}`;
    }
  }
})();

_flutter.loader.load({
  config: {
    // Force local CanvasKit files from /canvaskit to avoid CSP/CDN issues.
    canvasKitBaseUrl: "canvaskit/",
  },
});

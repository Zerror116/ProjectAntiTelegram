const phoenixWebBuildVersionStorageKey = 'projectphoenix-web-build-version';
const phoenixRootServiceWorkerUrl = '/flutter_service_worker.js';

String buildVersionedPhoenixServiceWorkerUrl(
  String? buildVersion, {
  String rootWorkerUrl = phoenixRootServiceWorkerUrl,
}) {
  final token = (buildVersion ?? '').trim();
  if (token.isEmpty) return rootWorkerUrl;
  return '$rootWorkerUrl?v=${Uri.encodeComponent(token)}';
}

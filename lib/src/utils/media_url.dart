String? resolveMediaUrl(String? raw, {required String apiBaseUrl}) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;

  final baseOrigin = _originFromApiBase(apiBaseUrl);
  final absolute = _tryParseUri(value);
  if (absolute != null && absolute.hasScheme) {
    final scheme = absolute.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      if (baseOrigin != null) {
        final baseHost = baseOrigin.host.toLowerCase();
        final targetHost = absolute.host.toLowerCase();
        final baseSecure = baseOrigin.scheme.toLowerCase() == 'https';

        if (baseSecure && scheme == 'http' && targetHost == baseHost) {
          return absolute
              .replace(
                scheme: 'https',
                port: absolute.hasPort && absolute.port != 80
                    ? absolute.port
                    : null,
              )
              .toString();
        }

        if (!_isLoopbackHost(baseHost) && _isLoopbackHost(targetHost)) {
          return absolute
              .replace(
                scheme: baseOrigin.scheme,
                host: baseOrigin.host,
                port: baseOrigin.hasPort ? baseOrigin.port : null,
              )
              .toString();
        }
      }
      return absolute.toString();
    }
    if (scheme == 'data' || scheme == 'blob') {
      return absolute.toString();
    }
    return value;
  }

  if (baseOrigin == null) return value;
  final relative = _tryParseUri(value);
  if (relative == null) return value;
  return baseOrigin.resolveUri(relative).toString();
}

Uri? _originFromApiBase(String rawBase) {
  final base = rawBase.trim();
  if (base.isEmpty) return null;
  final parsed = _tryParseUri(base);
  if (parsed == null) return null;
  final scheme = parsed.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || parsed.host.isEmpty) {
    return null;
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
  );
}

Uri? _tryParseUri(String raw) {
  try {
    return Uri.parse(raw);
  } catch (_) {
    try {
      return Uri.parse(Uri.encodeFull(raw));
    } catch (_) {
      return null;
    }
  }
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase().trim();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '0.0.0.0';
}

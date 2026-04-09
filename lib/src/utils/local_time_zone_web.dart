// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:js' as js;

String? _aliasTimeZone(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'самара, стандартное время':
    case 'samara standard time':
      return 'Europe/Samara';
    case 'азербайджан, стандартное время':
    case 'azerbaijan standard time':
      return 'Asia/Baku';
    default:
      return null;
  }
}

String? _timeZoneFromOffset(Duration offset) {
  if (offset.inMinutes == 0) return 'UTC';
  if (offset.inMinutes % 60 != 0) return null;
  final hours = offset.inHours.abs();
  if (hours == 0) return 'UTC';
  final sign = offset.isNegative ? '+' : '-';
  return 'Etc/GMT$sign$hours';
}

String? _normalizeTimeZone(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value == 'UTC' || value.startsWith('Etc/')) {
    return value;
  }
  if (value.contains('/')) {
    return value;
  }
  final alias = _aliasTimeZone(value);
  if (alias != null) {
    return alias;
  }
  final offsetMatch = RegExp(
    r'^(?:UTC|GMT)?([+-])(\d{1,2})(?::?(\d{2}))?$',
    caseSensitive: false,
  ).firstMatch(value.replaceAll(' ', ''));
  if (offsetMatch == null) return null;
  final sign = offsetMatch.group(1) == '+' ? 1 : -1;
  final hours = int.tryParse(offsetMatch.group(2) ?? '');
  final minutes = int.tryParse(offsetMatch.group(3) ?? '0');
  if (hours == null || minutes == null || minutes != 0) {
    return null;
  }
  return _timeZoneFromOffset(Duration(minutes: sign * (hours * 60 + minutes)));
}

String? _browserTimeZone() {
  try {
    final intl = js.context['Intl'];
    if (intl == null) return null;
    final intlObject = js.JsObject.fromBrowserObject(intl);
    final formatter = intlObject.callMethod('DateTimeFormat', const []);
    if (formatter == null) return null;
    final options = js.JsObject.fromBrowserObject(
      formatter.callMethod('resolvedOptions', const []),
    );
    return _normalizeTimeZone(options['timeZone']?.toString());
  } catch (_) {
    return null;
  }
}

Future<String?> resolveLocalTimeZoneId() async {
  return _browserTimeZone() ??
      _normalizeTimeZone(DateTime.now().timeZoneName) ??
      _timeZoneFromOffset(DateTime.now().timeZoneOffset) ??
      'UTC';
}

DateTime? parseDateTimeValue(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toLocal();
  final value = raw.toString().trim();
  if (value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String _pad2(int value) => value.toString().padLeft(2, '0');

String formatDateTimeValue(dynamic raw, {String fallback = ''}) {
  final parsed = parseDateTimeValue(raw);
  if (parsed == null) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? fallback : value;
  }
  return '${_pad2(parsed.day)}.${_pad2(parsed.month)}.${parsed.year} ${_pad2(parsed.hour)}:${_pad2(parsed.minute)}';
}

String formatDateValue(dynamic raw, {String fallback = ''}) {
  final parsed = parseDateTimeValue(raw);
  if (parsed == null) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? fallback : value;
  }
  return '${_pad2(parsed.day)}.${_pad2(parsed.month)}.${parsed.year}';
}

String formatTimeValue(dynamic raw, {String fallback = ''}) {
  final parsed = parseDateTimeValue(raw);
  if (parsed == null) return fallback;
  return '${_pad2(parsed.hour)}:${_pad2(parsed.minute)}';
}

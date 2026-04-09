import 'package:dio/dio.dart';

import '../../main.dart';

List<Map<String, dynamic>> _parseChatRows(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: true);
  }
  if (raw is Map && raw['ok'] == true && raw['data'] is List) {
    return (raw['data'] as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: true);
  }
  return <Map<String, dynamic>>[];
}

Future<List<Map<String, dynamic>>> loadChatsCollection() async {
  Future<List<Map<String, dynamic>>> attempt(String path) async {
    final response = await authService.dio.get(path);
    final rows = _parseChatRows(response.data);
    if (rows.isNotEmpty) {
      return rows;
    }
    if (response.data is Map && (response.data as Map)['ok'] == true) {
      return const <Map<String, dynamic>>[];
    }
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      error: 'Unexpected chats payload for $path',
      type: DioExceptionType.badResponse,
    );
  }

  try {
    return await attempt('/api/chats/list');
  } catch (firstError) {
    try {
      return await attempt('/api/chats');
    } catch (_) {
      throw firstError;
    }
  }
}

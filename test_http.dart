// test_http.dart
import 'dart:io';
import 'dart:convert';

void main() async {
  print('=== Socket test to 127.0.0.1:3000 ===');
  try {
    final socket = await Socket.connect('127.0.0.1', 3000, timeout: Duration(seconds: 3));
    print('Socket connected to ${socket.remoteAddress.address}:${socket.remotePort}');
    socket.destroy();
  } catch (e) {
    print('Socket connect failed: $e');
  }

  print('\n=== HTTP GET http://127.0.0.1:3000/ ===');
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:3000/'));
    final resp = await req.close();
    print('HTTP status: ${resp.statusCode}');
    final body = await resp.transform(utf8.decoder).join();
    print('Body: $body');
  } catch (e) {
    print('HTTP request failed: $e');
  }
}

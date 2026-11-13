import 'dart:convert';

import 'api_client.dart';
import 'logged_http.dart' as http;

class AgentService {
  final ApiClient api;
  final String origin;
  final int generation;
  AgentService(this.api)
      : origin = api.baseUrl,
        generation = ApiClient.sessionGeneration;

  void checkSession() {
    if (origin != api.baseUrl || generation != ApiClient.sessionGeneration) {
      throw AuthException('服务器或账号已切换，请重新打开智能体页面');
    }
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    checkSession();
    final client = http.Client();
    try {
      final req = http.Request(
          method, Uri.parse('${api.baseUrl}/api/agent$path'))
        ..followRedirects = false
        ..headers.addAll({'Content-Type': 'application/json', ...api.headers});
      if (body != null) req.body = jsonEncode(body);
      final response = await http.Response.fromStream(await http.sendLogged(
        client,
        req,
        label: 'agent $method',
      ))
          .timeout(const Duration(seconds: 320));
      final data = jsonDecode(response.body);
      checkSession();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data is Map && data['detail'] is String
            ? data['detail']
            : '智能体请求失败（${response.statusCode}）');
      }
      return data;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> settings() async =>
      Map<String, dynamic>.from(await request('GET', '/settings'));

  Future<void> save(Map<String, dynamic> settings) async {
    final data = Map<String, dynamic>.from(settings)
      ..remove('has_api_key')
      ..remove('has_proxy_password')
      ..remove('revision');
    await request('PUT', '/settings', data);
  }
}

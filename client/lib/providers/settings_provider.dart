/// Manages client settings: server connection, preferences.

import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

class SettingsProvider extends ChangeNotifier {
  String _serverHost = "";
  int _serverPort = 11451;
  bool _isLoading = false;
  String? _errorMessage;

  String get serverHost => _serverHost;
  int get serverPort => _serverPort;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _serverHost = prefs.getString("server_host") ?? "";
    _serverPort = prefs.getInt("server_port") ?? 11451;
    notifyListeners();
  }

  Future<bool> connect(String host, int port) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // Use dart:io HttpClient, bypass system proxy for direct LAN connection
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      client.findProxy = (url) => 'DIRECT';
      final request = await client.getUrl(Uri.parse("http://$host:$port/api/health"));
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _errorMessage = "服务器返回错误: ${response.statusCode}";
        _isLoading = false;
        notifyListeners();
        client.close();
        return false;
      }
      // Read response body to confirm full response
      await response.transform(utf8.decoder).join();
      client.close();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("server_host", host);
      await prefs.setInt("server_port", port);

      _serverHost = host;
      _serverPort = port;
      _isLoading = false;
      notifyListeners();
      return true;
    } on SocketException catch (e) {
      _errorMessage = "无法连接 $host:$port — ${e.message}";
      _isLoading = false;
      notifyListeners();
      return false;
    } on HandshakeException catch (e) {
      _errorMessage = "SSL/握手失败: ${e.message}";
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = "连接失败($host:$port): $e";
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}

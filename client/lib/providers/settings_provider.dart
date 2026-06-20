/// Manages client settings: server connection, preferences.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/logger_service.dart";

class SettingsProvider extends ChangeNotifier {
  String _serverHost = "";
  int _serverPort = 11451;
  bool _useHttps = false;
  bool _isLoading = false;
  String? _errorMessage;

  String get serverHost => _serverHost;
  int get serverPort => _serverPort;
  bool get useHttps => _useHttps;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _serverHost = prefs.getString("server_host") ?? "";
    _serverPort = prefs.getInt("server_port") ?? 11451;
    _useHttps = prefs.getBool("use_https") ?? false;
    notifyListeners();
  }

  Future<bool> connect(String host, int port, {bool useHttps = false}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    LoggerService().info("正在连接 $host:$port (${useHttps ? "HTTPS" : "HTTP"})");
    try {
      final scheme = useHttps ? "https" : "http";
      final uri = Uri.parse("$scheme://$host:$port/api/health");
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        _errorMessage = "服务器返回错误: ${resp.statusCode}";
        _isLoading = false;
        notifyListeners();
        LoggerService().warn("连接失败 $host:$port: HTTP ${resp.statusCode}");
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("server_host", host);
      await prefs.setInt("server_port", port);
      await prefs.setBool("use_https", useHttps);

      _serverHost = host;
      _serverPort = port;
      _useHttps = useHttps;
      _isLoading = false;
      notifyListeners();
      LoggerService().info("连接成功 $host:$port");
      return true;
    } on http.ClientException catch (e) {
      _errorMessage = "无法连接到服务器，请检查地址和端口";
      _isLoading = false;
      notifyListeners();
      LoggerService().error("连接失败 $host:$port", e);
      return false;
    } catch (e) {
      _errorMessage = "连接超时，请检查网络";
      _isLoading = false;
      notifyListeners();
      LoggerService().error("连接超时 $host:$port", e);
      return false;
    }
  }
}

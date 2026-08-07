/// Manages client settings: server connection, preferences.

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/api_response_utils.dart";
import "../services/logger_service.dart";

class SettingsProvider extends ChangeNotifier {
  String _serverHost = "";
  int _serverPort = 11451;
  bool _useHttps = false;
  bool _isLoading = false;
  String? _errorMessage;
  double _coverSize = Platform.isAndroid ? 160.0 : 200.0;
  bool _blurNsfwCovers = true;

  String get serverHost => _serverHost;
  int get serverPort => _serverPort;
  bool get useHttps => _useHttps;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  double get coverSize => _coverSize;
  bool get blurNsfwCovers => _blurNsfwCovers;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _serverHost = prefs.getString("server_host") ?? "";
    _serverPort = prefs.getInt("server_port") ?? 11451;
    _useHttps = prefs.getBool("use_https") ?? false;
    _coverSize = (prefs.getDouble("cover_size") ?? _coverSize)
        .clamp(100.0, 300.0)
        .toDouble();
    _blurNsfwCovers = prefs.getBool("blur_nsfw_covers") ?? true;
    notifyListeners();
  }

  Future<void> setBlurNsfwCovers(bool value) async {
    if (_blurNsfwCovers == value) return;
    _blurNsfwCovers = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("blur_nsfw_covers", value);
  }

  Future<void> setCoverSize(double value) async {
    final next = value.clamp(100.0, 300.0).toDouble();
    if (_coverSize == next) return;
    _coverSize = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble("cover_size", next);
  }

  Future<bool> connect(String host, int port, {bool useHttps = false}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    LoggerService().info("正在连接 $host:$port (${useHttps ? "HTTPS" : "HTTP"})");
    try {
      final scheme = useHttps ? "https" : "http";
      final uri = Uri.parse("$scheme://$host:$port/api/health");
      final resp = await _getHealthNoRedirect(uri);
      if (!isValidSenaHealthResponse(resp)) {
        _errorMessage = describeUnexpectedApiResponse(
          resp,
          expected: "Sena 健康检查",
          endpointPath: "/api/health",
        );
        _isLoading = false;
        notifyListeners();
        LoggerService().warn("连接失败 $host:$port: $_errorMessage");
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

  Future<http.Response> _getHealthNoRedirect(Uri uri) async {
    final client = http.Client();
    try {
      final request = http.Request("GET", uri)..followRedirects = false;
      final streamed = await client.send(request).timeout(
            const Duration(seconds: 5),
          );
      return http.Response.fromStream(streamed);
    } finally {
      client.close();
    }
  }
}

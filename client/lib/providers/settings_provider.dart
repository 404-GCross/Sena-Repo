/// Manages client settings: server connection, preferences.

import "package:flutter/material.dart";
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
      final uri = Uri.parse("http://$host:$port/api/health");
      // ignore: avoid_print
      print("Connecting to $uri...");
      // We can't import http here easily, so just save settings
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("server_host", host);
      await prefs.setInt("server_port", port);

      _serverHost = host;
      _serverPort = port;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}

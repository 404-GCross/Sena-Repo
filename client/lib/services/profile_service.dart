/// Multi-profile service — manage multiple server/user configurations.

import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

class UserProfile {
  String name;
  String host;
  int port;
  String authToken;
  String username;
  bool isAdmin;
  bool useHttps;

  UserProfile({
    required this.name,
    required this.host,
    this.port = 11451,
    this.authToken = "",
    this.username = "",
    this.isAdmin = false,
    this.useHttps = false,
  });

  String get scheme => useHttps ? "https" : "http";

  Map<String, dynamic> toJson() => {
    "name": name, "host": host, "port": port,
    "authToken": authToken, "username": username, "isAdmin": isAdmin,
    "useHttps": useHttps,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    name: json["name"] ?? "",
    host: json["host"] ?? "",
    port: json["port"] ?? 11451,
    authToken: json["authToken"] ?? "",
    username: json["username"] ?? "",
    isAdmin: json["isAdmin"] ?? false,
    useHttps: json["useHttps"] ?? false,
  );
}

class ProfileService {
  static final ProfileService _instance = ProfileService._();
  factory ProfileService() => _instance;
  ProfileService._();

  static const _keyProfiles = "user_profiles";
  static const _keyActiveIndex = "active_profile_index";

  Future<List<UserProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyProfiles);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list.map((j) => UserProfile.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<void> saveProfiles(List<UserProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProfiles, jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }

  Future<int> getActiveIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyActiveIndex) ?? 0;
  }

  Future<void> setActiveIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyActiveIndex, index);
  }

  /// Apply a profile as active: update current session values
  Future<void> applyProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    // Save as current
    await prefs.setString("server_host", profile.host);
    await prefs.setInt("server_port", profile.port);
    await prefs.setString("auth_token", profile.authToken);
    await prefs.setString("username", profile.username);
    await prefs.setBool("is_admin", profile.isAdmin);
    await prefs.setBool("use_https", profile.useHttps);
  }

  /// Save current session as a new or updated profile
  Future<void> saveCurrentAsProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString("server_host") ?? "";
    final port = prefs.getInt("server_port") ?? 11451;
    final token = prefs.getString("auth_token") ?? "";
    final username = prefs.getString("username") ?? "";
    final isAdmin = prefs.getBool("is_admin") ?? false;
    final useHttps = prefs.getBool("use_https") ?? false;

    final profiles = await loadProfiles();
    // Update existing or add new
    final existing = profiles.indexWhere((p) => p.name == name);
    final profile = UserProfile(name: name, host: host, port: port,
        authToken: token, username: username, isAdmin: isAdmin, useHttps: useHttps);
    if (existing >= 0) {
      profiles[existing] = profile;
      await setActiveIndex(existing);
    } else {
      profiles.add(profile);
      await setActiveIndex(profiles.length - 1);
    }
    await saveProfiles(profiles);
  }
}

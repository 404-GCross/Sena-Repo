/// Multi-profile service — manage multiple server/user configurations.

import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

import "../models/log_models.dart";
import "logger_service.dart";
import "secure_store.dart";
import "api_client.dart";
import "server_origin.dart";

int parseProfileUserId(Object? value) {
  final id = value is int ? value : int.tryParse(value?.toString() ?? "");
  return id != null && id > 0 ? id : 0;
}

class UserProfile {
  String name;
  String host;
  int port;
  String authToken;
  // String refreshToken; — removed
  int userId;
  String username;
  bool isAdmin;
  bool useHttps;

  UserProfile({
    required this.name,
    required this.host,
    this.port = 11451,
    this.authToken = "",
    // this.refreshToken = "",
    this.userId = 0,
    this.username = "",
    this.isAdmin = false,
    this.useHttps = false,
  });

  String get scheme => useHttps ? "https" : "http";
  String get baseUrl => serverEndpoint(host, port, useHttps);

  Map<String, dynamic> toJson() => {
    "name": name, "host": host, "port": port,
    "authToken": authToken,
    // "refreshToken": refreshToken,
    "userId": userId,
    "username": username, "isAdmin": isAdmin,
    "useHttps": useHttps,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    name: json["name"] ?? "",
    host: json["host"] ?? "",
    port: json["port"] ?? 11451,
    authToken: json["authToken"] ?? "",
    // refreshToken: json["refreshToken"] ?? "",
    userId: parseProfileUserId(json["userId"] ?? json["user_id"]),
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
    final raw = await SecureStore.getString(_keyProfiles);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    final profiles = list
        .map((j) => UserProfile.fromJson(j as Map<String, dynamic>))
        .toList();
    final owners = <String, Set<String>>{};
    for (final profile in profiles) {
      if (profile.authToken.isEmpty) continue;
      final origin = serverOrigin(profile.baseUrl);
      if (origin == null) {
        profile.authToken = "";
        continue;
      }
      owners.putIfAbsent(profile.authToken, () => <String>{}).add(origin);
    }
    for (final profile in profiles) {
      if ((owners[profile.authToken]?.length ?? 0) > 1) profile.authToken = "";
    }
    return profiles;
  }

  Future<void> saveProfiles(List<UserProfile> profiles) async {
    await SecureStore.setString(
      _keyProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<int> getActiveIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyActiveIndex) ?? -1;
  }

  Future<void> setActiveIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyActiveIndex, index);
  }

  /// Apply a profile as active: update current session values
  Future<int> applyProfile(UserProfile profile, {
    int? expectedGeneration, bool Function()? stillCurrent, String? logScope,
  }) async {
    final selected = UserProfile.fromJson(profile.toJson());
    if (expectedGeneration == null) await ApiClient.restoreToken();
    var generation = expectedGeneration ?? ApiClient.sessionGeneration;
    void ensureCurrent() {
      if (generation != ApiClient.sessionGeneration || stillCurrent?.call() == false) {
        throw AuthException("连接选择已变化，请重试");
      }
    }
    ensureCurrent();
    final prefs = await SharedPreferences.getInstance();
    ensureCurrent();
    final fresh = selected.userId > 0
        ? tokenForServer(selected.baseUrl, userId: selected.userId) : null;
    selected.authToken = fresh ?? selected.authToken;
    final promotion = selected.authToken.isEmpty
        ? ApiClient.clearTokens()
        : ApiClient.persistSessionInfo(accessToken: selected.authToken,
            serverBaseUrl: selected.baseUrl, userId: selected.userId,
            username: selected.username, isAdmin: selected.isAdmin,
            role: selected.isAdmin ? "admin" : "user", logScope: logScope,
            expectedGeneration: generation);
    generation = ApiClient.sessionGeneration;
    await promotion;
    ensureCurrent();
    await prefs.setString("server_host", selected.host);
    ensureCurrent();
    await prefs.setInt("server_port", selected.port);
    ensureCurrent();
    await prefs.setBool("use_https", selected.useHttps);
    ensureCurrent();
    if (serverOrigin(profile.baseUrl) == serverOrigin(selected.baseUrl) &&
        profile.userId == selected.userId) profile.authToken = selected.authToken;
    await LoggerService().record(LogLevel.info, "client.profile_applied",
        "已切换服务器配置", module: "连接");
    ensureCurrent();
    return generation;
  }

  /// Save current session as a new or updated profile
  Future<void> saveCurrentAsProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString("server_host") ?? "";
    final port = prefs.getInt("server_port") ?? 11451;
    final useHttps = prefs.getBool("use_https") ?? false;
    await ApiClient.restoreToken();
    final token = tokenForServer(serverEndpoint(host, port, useHttps)) ?? "";
    // final refreshToken = prefs.getString("refresh_token") ?? "";
    final userId = token.isEmpty ? 0 : (prefs.getInt("user_id") ?? 0);
    final username = token.isEmpty ? "" : (prefs.getString("username") ?? "");
    final isAdmin = token.isNotEmpty && (prefs.getBool("is_admin") ?? false);

    final profiles = await loadProfiles();
    // Update existing or add new. Keep different servers separate even when
    // they use the same profile name or username.
    final existing = profiles.indexWhere(
      (p) =>
          p.host == host &&
          p.port == port &&
          p.useHttps == useHttps &&
          ((userId > 0 && p.userId == userId) ||
              (userId <= 0 && p.username == username)),
    );
    final profile = UserProfile(
      name: name,
      host: host,
      port: port,
      authToken: token,
      /* refreshToken: refreshToken, */
      userId: userId,
      username: username,
      isAdmin: isAdmin,
      useHttps: useHttps,
    );
    if (existing >= 0) {
      profiles[existing] = profile;
      await setActiveIndex(existing);
    } else {
      profiles.add(profile);
      await setActiveIndex(profiles.length - 1);
    }
    await saveProfiles(profiles);
    await LoggerService().record(
      LogLevel.info,
      "client.profile_saved",
      "已保存连接配置",
      module: "连接",
      fields: {
        "name": name,
        "host": host,
        "port": port,
        "username": username,
      },
    );
  }
}

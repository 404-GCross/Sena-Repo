/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";
import "dart:async";

import "logged_http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";
import "api_response_utils.dart";
import "logger_service.dart";
import "secure_store.dart";

class ManagerInstallLink {
  final String target;
  final String installUrl;
  final int expiresAt;
  final String fileName;
  final String archiveFormat;
  final int size;
  final String checksumAlgo;
  final String checksum;

  ManagerInstallLink({
    required this.target,
    required this.installUrl,
    required this.expiresAt,
    required this.fileName,
    required this.archiveFormat,
    required this.size,
    required this.checksumAlgo,
    required this.checksum,
  });

  factory ManagerInstallLink.fromJson(Map<String, dynamic> json) {
    return ManagerInstallLink(
      target: json["target"] ?? "",
      installUrl: json["install_url"] ?? "",
      expiresAt: json["expires_at"] ?? 0,
      fileName: json["file_name"] ?? "",
      archiveFormat: json["archive_format"] ?? "",
      size: json["size"] ?? 0,
      checksumAlgo: json["checksum_algo"] ?? "",
      checksum: json["checksum"] ?? "",
    );
  }
}

class DownloadLink {
  final String url;
  final int expiresAt;

  DownloadLink({required this.url, required this.expiresAt});

  factory DownloadLink.fromJson(Map<String, dynamic> json) {
    return DownloadLink(
      url: json["url"]?.toString() ?? "",
      expiresAt: json["expires_at"] ?? 0,
    );
  }
}

/// Global access token — always accessible, survives Provider rebuilds.
String? _accessToken;

/// Cached user info from the last login.
String? _cachedUsername;
int? _cachedUserId;
bool? _cachedIsAdmin;
String? _cachedRole;

int? _parseUserId(Object? value) {
  final id = value is int ? value : int.tryParse(value?.toString() ?? "");
  return id != null && id > 0 ? id : null;
}

/// Shared accessor for DownloadService request headers.
String? get globalToken => _accessToken;

Map<String, String>? get mediaAuthHeaders {
  if (_accessToken == null || _accessToken!.isEmpty) return null;
  return {"Authorization": "Bearer $_accessToken"};
}

/// Hostname of the configured server — only bypasses TLS for this host.
String? trustedServerHost;

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  String? get accessToken => _accessToken;
  String? get cachedUsername => _cachedUsername;
  int? get cachedUserId => _cachedUserId;
  bool? get cachedIsAdmin => _cachedIsAdmin;
  String? get cachedRole => _cachedRole;

  Map<String, String> get headers {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      return {"Authorization": "Bearer $_accessToken"};
    }
    LoggerService().warn("auth headers requested without token");
    return {};
  }

  static Future<void> restoreToken() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = await SecureStore.getString("auth_token");
    _cachedUsername = prefs.getString("username");
    _cachedUserId = prefs.getInt("user_id");
    _cachedIsAdmin = prefs.getBool("is_admin");
    _cachedRole = prefs.getString("role");
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      LoggerService().info("auth token restored from secure storage");
    } else {
      LoggerService().info("auth token not found on disk");
    }
  }

  static Future<void> _persistTokens({
    String? accessToken,
    int? userId,
    String? username,
    bool? isAdmin,
    String? role,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (accessToken != null && accessToken.isNotEmpty) {
      await SecureStore.setString("auth_token", accessToken);
    }
    if (username != null) {
      await prefs.setString("username", username);
      _cachedUsername = username;
    }
    if (userId != null && userId > 0) {
      await prefs.setInt("user_id", userId);
      _cachedUserId = userId;
    }
    if (isAdmin != null) {
      await prefs.setBool("is_admin", isAdmin);
      _cachedIsAdmin = isAdmin;
    }
    if (role != null) {
      await prefs.setString("role", role);
      _cachedRole = role;
    }
  }

  static Future<void> persistSessionInfo({
    String? accessToken,
    int? userId,
    String? username,
    bool? isAdmin,
    String? role,
  }) async {
    if (accessToken != null && accessToken.isNotEmpty) {
      _accessToken = accessToken;
    }
    await _persistTokens(
      accessToken: accessToken,
      userId: userId,
      username: username,
      isAdmin: isAdmin,
      role: role,
    );
  }

  static Future<void> clearTokens() async {
    _accessToken = null;
    _cachedUsername = null;
    _cachedUserId = null;
    _cachedIsAdmin = null;
    _cachedRole = null;
    final prefs = await SharedPreferences.getInstance();
    await SecureStore.delete("auth_token");
    await prefs.remove("username");
    await prefs.remove("user_id");
    await prefs.remove("is_admin");
    await prefs.remove("role");
  }

  Future<void> connect(
    String host, {
    int port = 11451,
    bool useHttps = false,
  }) async {
    final scheme = useHttps ? "https" : "http";
    _baseUrl = "$scheme://$host:$port";
    trustedServerHost = host;
  }

  /// Execute an HTTP request.
  bool _isRetryableStatus(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  bool _isRetryableError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;

  Future<http.Response> _execute(
    Future<http.Response> Function() request, {
    bool allowRetry = true,
    String method = "HTTP",
    Uri? uri,
    String? label,
  }) async {
    const maxAttempts = 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final started = DateTime.now();
      try {
        final response = await request();
        final durationMs = DateTime.now().difference(started).inMilliseconds;
        final retrying = allowRetry &&
            attempt < maxAttempts - 1 &&
            _isRetryableStatus(response.statusCode);
        _logHttpResponse(
          method,
          uri,
          response.statusCode,
          durationMs,
          attempt + 1,
          retrying: retrying,
          label: label,
        );
        if (!allowRetry ||
            attempt == maxAttempts - 1 ||
            !_isRetryableStatus(response.statusCode)) {
          return response;
        }
      } catch (error, stackTrace) {
        final durationMs = DateTime.now().difference(started).inMilliseconds;
        final retrying = allowRetry &&
            attempt < maxAttempts - 1 &&
            _isRetryableError(error);
        _logHttpError(
          method,
          uri,
          error,
          stackTrace,
          durationMs,
          attempt + 1,
          retrying: retrying,
          label: label,
        );
        if (!allowRetry ||
            attempt == maxAttempts - 1 ||
            !_isRetryableError(error)) {
          rethrow;
        }
      }
      await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    throw StateError("HTTP retry loop exited unexpectedly");
  }

  String _uriForLog(Uri? uri) {
    if (uri == null) return "-";
    return LoggerService().redact(uri.toString());
  }

  void _logHttpResponse(
    String method,
    Uri? uri,
    int statusCode,
    int durationMs,
    int attempt, {
    bool retrying = false,
    String? label,
  }) {
    final target = label ?? "${method.toUpperCase()} ${_uriForLog(uri)}";
    final message =
        "HTTP ${retrying ? "retry" : "response"}: $target status=$statusCode attempt=$attempt durationMs=$durationMs";
    if (retrying || statusCode >= 400) {
      LoggerService().warn(message);
    } else {
      LoggerService().info(message);
    }
  }

  void _logHttpError(
    String method,
    Uri? uri,
    Object error,
    StackTrace stackTrace,
    int durationMs,
    int attempt, {
    bool retrying = false,
    String? label,
  }) {
    final target = label ?? "${method.toUpperCase()} ${_uriForLog(uri)}";
    final message =
        "HTTP ${retrying ? "retry" : "error"}: $target attempt=$attempt durationMs=$durationMs";
    if (retrying) {
      LoggerService().warn(message, error, stackTrace);
    } else {
      LoggerService().error(message, error, stackTrace);
    }
  }

  // --- Games ---

  Future<List<GameSummary>> getGames({
    int page = 1,
    int pageSize = 200,
    String? tag,
    String? platform,
    int? rootId,
  }) async {
    final params = <String, String>{
      "page": page.toString(),
      "page_size": pageSize.toString(),
    };
    if (tag != null) params["tag"] = tag;
    if (platform != null) params["platform"] = platform;
    if (rootId != null) params["root_id"] = rootId.toString();

    final uri = Uri.parse(
      "$baseUrl/api/games",
    ).replace(queryParameters: params);
    final resp = await _execute(
      () => _client.get(uri, headers: headers),
      method: "GET",
      uri: uri,
      label: "load games page=$page pageSize=$pageSize",
    );
    if (resp.statusCode != 200) throw HttpException("Failed to load games");

    final List<dynamic> data = jsonDecode(resp.body);
    return data
        .map((j) => GameSummary.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<GameDetail> getGame(int id) async {
    final uri = Uri.parse("$baseUrl/api/games/$id");
    final resp = await _execute(
      () => _client.get(uri, headers: headers),
      method: "GET",
      uri: uri,
      label: "load game detail id=$id",
    );
    if (resp.statusCode == 401) throw AuthException("登录已失效，请重新登录");
    if (resp.statusCode != 200) throw HttpException("Game not found");
    return GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<ManagerInstallLink> createManagerInstallLink({
    required int gameId,
    required int versionId,
    required String target,
  }) async {
    final uri = Uri.parse(
      "$baseUrl/api/download/$gameId/$versionId/manager-install-link",
    );
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"target": target}),
      ),
      allowRetry: false,
      method: "POST",
      uri: uri,
      label: "create manager install link gameId=$gameId versionId=$versionId target=$target",
    );
    checkResponse(resp, fallbackMessage: "生成管理器下载链接失败");
    return ManagerInstallLink.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  Future<DownloadLink> createDownloadLink({
    required int gameId,
    required int versionId,
  }) async {
    final uri = Uri.parse("$baseUrl/api/download/$gameId/$versionId/link");
    final resp = await _execute(
      () => _client.post(uri, headers: headers),
      allowRetry: false,
      method: "POST",
      uri: uri,
      label: "create download link gameId=$gameId versionId=$versionId",
    );
    checkResponse(resp, fallbackMessage: "生成下载链接失败");
    return DownloadLink.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteGame(int id) async {
    final uri = Uri.parse("$baseUrl/api/games/$id");
    final resp = await _execute(
      () => _client.delete(uri, headers: headers),
      method: "DELETE",
      uri: uri,
      label: "delete game id=$id",
    );
    if (resp.statusCode != 200) throw HttpException("Failed to delete game");
  }

  // --- Tags ---

  Future<List<Tag>> getTags() async {
    final uri = Uri.parse("$baseUrl/api/tags");
    final resp = await _execute(
      () => _client.get(uri, headers: headers),
      method: "GET",
      uri: uri,
      label: "load tags",
    );
    if (resp.statusCode != 200) throw HttpException("Failed to load tags");
    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => Tag.fromJson(j as Map<String, dynamic>)).toList();
  }

  // --- Roots ---

  Future<Map<String, dynamic>> refreshRoot(int id) async {
    final uri = Uri.parse("$baseUrl/api/roots/$id/refresh");
    final resp = await _execute(
      () => _client.post(uri, headers: headers),
      method: "POST",
      uri: uri,
      label: "refresh root id=$id",
    );
    if (resp.statusCode != 200) throw HttpException("Refresh failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshAllRoots() async {
    final uri = Uri.parse("$baseUrl/api/roots/refresh-all");
    final resp = await _execute(
      () => _client.post(uri, headers: headers),
      method: "POST",
      uri: uri,
      label: "refresh all roots",
    );
    if (resp.statusCode != 200) throw HttpException("Refresh all failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Setup ---

  Future<bool> checkSetupNeeded() async {
    try {
      final uri = Uri.parse("$baseUrl/api/setup/status");
      final resp = await _execute(
        () => _client.get(uri, headers: headers).timeout(
              const Duration(seconds: 5),
            ),
        allowRetry: false,
        method: "GET",
        uri: uri,
        label: "check setup status",
      );
      if (resp.statusCode == 200) {
        final data = tryDecodeJsonMap(resp.body);
        return data != null && data["needs_setup"] == true;
      }
    } catch (_) {}
    return false;
  }

  // --- Auth ---

  Future<Map<String, dynamic>> login(String username, String password) async {
    final loginUri = Uri.parse("$baseUrl/api/auth/login");
    final started = DateTime.now();
    try {
      LoggerService().info("auth login started: POST ${_uriForLog(loginUri)}");
      final resp = await _client
          .post(
            loginUri,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"username": username, "password": password}),
          )
          .timeout(const Duration(seconds: 10));
      _logHttpResponse(
        "POST",
        loginUri,
        resp.statusCode,
        DateTime.now().difference(started).inMilliseconds,
        1,
        label: "auth login",
      );
      if (resp.statusCode == 200) {
        final data = tryDecodeJsonMap(resp.body);
        if (data == null) {
          throw AuthException(
            describeUnexpectedApiResponse(
              resp,
              expected: "登录",
              endpointPath: "/api/auth/login",
            ),
          );
        }

        _accessToken = data["token"]?.toString();
        if (_accessToken == null || _accessToken!.isEmpty) {
          throw AuthException(
            "服务器返回 200，但登录响应缺少 token，域名可能没有把 /api/auth/login 转发到服务端",
          );
        }

        var username = data["username"]?.toString();
        var userId = _parseUserId(data["id"]);
        var isAdmin = data["is_admin"] == true;
        var role = data["role"]?.toString() ?? (isAdmin ? "admin" : "user");
        try {
          final meUri = Uri.parse("$baseUrl/api/auth/profile/me");
          final meStarted = DateTime.now();
          final meResp = await _client.get(
            meUri,
            headers: {"Authorization": "Bearer $_accessToken"},
          ).timeout(const Duration(seconds: 5));
          _logHttpResponse(
            "GET",
            meUri,
            meResp.statusCode,
            DateTime.now().difference(meStarted).inMilliseconds,
            1,
            label: "auth profile after login",
          );
          if (meResp.statusCode == 200) {
            final me = tryDecodeJsonMap(meResp.body);
            if (me == null || me["id"] == null) {
              throw AuthException(
                describeUnexpectedApiResponse(
                  meResp,
                  expected: "用户资料",
                  endpointPath: "/api/auth/profile/me",
                ),
              );
            }
            userId = _parseUserId(me["id"]) ?? userId;
            username = me["username"]?.toString() ?? username;
            isAdmin = me["is_admin"] == true;
            role = me["role"]?.toString() ?? role;
            if (userId != null) data["id"] = userId;
            data["username"] = username;
            data["is_admin"] = isAdmin;
            data["role"] = role;
          }
        } on AuthException {
          rethrow;
        } catch (e, stackTrace) {
          LoggerService().warn("auth profile sync after login failed", e, stackTrace);
        }
        await _persistTokens(
          accessToken: _accessToken,
          userId: userId,
          username: username,
          isAdmin: isAdmin,
          role: role,
        );
        LoggerService().info("auth login succeeded: role=$role isAdmin=$isAdmin");
        return data;
      }

      final body = tryDecodeJsonMap(resp.body);
      if (body != null && body["detail"] != null) {
        throw AuthException(body["detail"].toString());
      }
      throw AuthException(
        describeUnexpectedApiResponse(
          resp,
          expected: "登录",
          endpointPath: "/api/auth/login",
        ),
      );
    } on AuthException catch (e, stackTrace) {
      LoggerService().warn("auth login rejected", e, stackTrace);
      rethrow;
    } on SocketException catch (e, stackTrace) {
      LoggerService().error("auth login socket failure", e, stackTrace);
      throw AuthException("无法连接服务器: ${e.message}");
    } on TimeoutException catch (e, stackTrace) {
      LoggerService().error("auth login timeout", e, stackTrace);
      throw AuthException("连接服务器超时");
    }
  }

  Future<bool> logout() async {
    var success = true;
    try {
      if (_accessToken != null && _accessToken!.isNotEmpty) {
        final uri = Uri.parse("$baseUrl/api/auth/logout");
        final resp = await _execute(
          () => _client.post(uri, headers: headers),
          allowRetry: false,
          method: "POST",
          uri: uri,
          label: "auth logout",
        );
        success = resp.statusCode >= 200 && resp.statusCode < 300;
      }
    } catch (e, stackTrace) {
      success = false;
      LoggerService().warn("auth logout request failed", e, stackTrace);
    } finally {
      await clearTokens();
    }
    return success;
  }

  // --- Scraper ---

  Future<Map<String, dynamic>> scrapeGame(int gameId) async {
    final uri = Uri.parse("$baseUrl/api/games/$gameId/scrape");
    final resp = await _execute(
      () => _client.post(uri, headers: headers),
      method: "POST",
      uri: uri,
      label: "scrape game id=$gameId",
    );
    if (resp.statusCode != 200) throw HttpException("Scrape failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}

/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";
import "dart:async";

import "logged_http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";
import "../models/log_models.dart";
import "api_response_utils.dart";
import "logger_service.dart";
import "secure_store.dart";
import "server_origin.dart";

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
String? _tokenOrigin;
int _sessionGeneration = 0;
Future<void> _sessionWrites = Future<void>.value();

String? tokenForServer(String? url, {int? userId}) {
  final origin = serverOrigin(url);
  if (origin == null || origin != _tokenOrigin) return null;
  if (userId != null && userId != _cachedUserId) return null;
  return _accessToken;
}

int? userIdForServer(String? url) => tokenForServer(url) == null ? null : _cachedUserId;

Map<String, String>? mediaHeadersFor(String url) {
  final token = tokenForServer(url);
  return token == null || token.isEmpty ? null : {"Authorization": "Bearer $token"};
}

/// Cached user info from the last login.
String? _cachedUsername;
int? _cachedUserId;
bool? _cachedIsAdmin;
String? _cachedRole;
String _cachedLogScope = "";

int? _parseUserId(Object? value) {
  final id = value is int ? value : int.tryParse(value?.toString() ?? "");
  return id != null && id > 0 ? id : null;
}

/// Verified log ownership. Set only from an authenticated profile response.
String _logServerKey = "";
String _logAccountScope = "";
String _logSessionId = "";
bool _logManagement = false;

String stableLogKey(String value) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(value)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, "0");
}

Future<void> activateLogContext({
  required String baseUrl,
  required Map<String, dynamic> profile,
}) async {
  if (tokenForServer(baseUrl) == null ||
      (_cachedUserId != null && _cachedUserId != _parseUserId(profile["id"]))) return;
  final scope = profile["log_scope"]?.toString() ?? "";
  final userId = _parseUserId(profile["id"]) ?? 0;
  final role = profile["role"]?.toString() ?? "user";
  _logServerKey = stableLogKey(baseUrl);
  _logAccountScope =
      scope.isNotEmpty ? scope : stableLogKey("user:$userId");
  _logManagement = role == "admin";
  _logSessionId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  LoggerService().setContext(
    LogContext(
      serverKey: _logServerKey,
      accountScope: _logAccountScope,
      sessionId: _logSessionId,
    ),
  );
}

void clearLogContext() {
  _logServerKey = "";
  _logAccountScope = "";
  _logSessionId = "";
  _logManagement = false;
  LoggerService().setContext(null);
}

LogViewerAccess? get currentLogViewerAccess => _logAccountScope.isEmpty
    ? null
    : LogViewerAccess(
        serverKey: _logServerKey,
        accountScope: _logAccountScope,
        sessionId: _logSessionId,
        management: _logManagement,
      );

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;
  int? _oauthGeneration;
  String? _oauthOrigin;
  String? _oauthRequestId;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  String? get accessToken => tokenForServer(_baseUrl);
  String? get cachedUsername => accessToken == null ? null : _cachedUsername;
  int? get cachedUserId => accessToken == null ? null : _cachedUserId;
  bool? get cachedIsAdmin => accessToken == null ? null : _cachedIsAdmin;
  String? get cachedRole => accessToken == null ? null : _cachedRole;
  static int get sessionGeneration => _sessionGeneration;
  static void invalidatePendingSession() => _sessionGeneration++;

  /// Scope the log viewer may read for the current verified account.
  LogViewerAccess? get logViewerAccess => accessToken == null ? null : currentLogViewerAccess;

  Map<String, String> get headers {
    final token = accessToken;
    return token == null || token.isEmpty ? {} : {"Authorization": "Bearer $token"};
  }

  static Future<void> restoreToken() async {
    if (_accessToken != null) return;
    final generation = _sessionGeneration;
    await _sessionWrites;
    Map<String, dynamic>? session;
    try {
      final raw = await SecureStore.getString("auth_session");
      if (raw != null) {
        session = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } else {
        final legacy = await SecureStore.getString("auth_token");
        final profiles = jsonDecode(await SecureStore.getString("user_profiles") ?? "[]") as List;
        final matches = profiles.whereType<Map>().where((p) =>
            legacy != null && legacy.isNotEmpty && p["authToken"] == legacy).toList();
        final origins = matches.map((p) => serverOrigin(serverEndpoint(
            p["host"] as String, p["port"] as int? ?? 11451,
            p["useHttps"] == true))).whereType<String>().toSet();
        if (origins.length == 1) {
          final profile = matches.first;
          session = {"token": legacy, "origin": origins.single,
            "user_id": profile["userId"], "username": profile["username"],
            "is_admin": profile["isAdmin"],
            "role": profile["isAdmin"] == true ? "admin" : "user"};
        }
      }
    } catch (_) {
      LoggerService().warn("stored session ownership could not be verified");
      return;
    }
    if (generation != _sessionGeneration || session == null) return;
    final token = session["token"];
    final originValue = session["origin"];
    final origin = originValue is String ? serverOrigin(originValue) : null;
    if (token is! String || token.isEmpty || origin == null) return;
    await _persistTokens(accessToken: token, serverBaseUrl: origin,
      expectedGeneration: generation, userId: _parseUserId(session["user_id"]),
      username: session["username"] as String?, isAdmin: session["is_admin"] == true,
      role: session["role"] as String?, logScope: session["log_scope"] as String?);
  }

  static Future<void> _persistTokens({
    String? accessToken,
    String? serverBaseUrl,
    int? expectedGeneration,
    int? userId,
    String? username,
    bool? isAdmin,
    String? role,
    String? logScope,
  }) async {
    if (expectedGeneration != null && expectedGeneration != _sessionGeneration) {
      throw AuthException("连接已变化，请重新登录");
    }
    final origin = serverOrigin(serverBaseUrl);
    if (accessToken != null && accessToken.isNotEmpty) {
      if (origin == null) throw AuthException("缺少登录令牌所属的服务器地址");
      final sameAccount = _tokenOrigin == origin && userId != null &&
          userId > 0 && userId == _cachedUserId;
      if (!sameAccount) {
        clearLogContext();
        _cachedUserId = null;
        _cachedUsername = null;
        _cachedIsAdmin = null;
        _cachedRole = null;
        _cachedLogScope = "";
      }
      _accessToken = accessToken;
      _tokenOrigin = origin;
      _sessionGeneration++;
    } else if (origin == null || origin != _tokenOrigin) {
      return;
    }
    _cachedUserId = userId ?? _cachedUserId;
    _cachedUsername = username ?? _cachedUsername;
    _cachedIsAdmin = isAdmin ?? _cachedIsAdmin;
    _cachedRole = role ?? _cachedRole;
    _cachedLogScope = logScope ?? _cachedLogScope;
    final snapshot = {"token": _accessToken, "origin": _tokenOrigin,
      "user_id": _cachedUserId, "username": _cachedUsername,
      "is_admin": _cachedIsAdmin, "role": _cachedRole, "log_scope": _cachedLogScope};
    _sessionWrites = _sessionWrites.catchError((_) {}).then((_) async {
      await SecureStore.setString("auth_session", jsonEncode(snapshot));
      await SecureStore.setString("auth_token", snapshot["token"] as String);
      final prefs = await SharedPreferences.getInstance();
      for (final key in ["user_id", "username", "is_admin", "role", "log_scope"]) {
        final value = snapshot[key];
        if (value is String) { await prefs.setString(key, value); }
        else if (value is int) { await prefs.setInt(key, value); }
        else if (value is bool) { await prefs.setBool(key, value); }
        else { await prefs.remove(key); }
      }
    });
    await _sessionWrites;
  }

  static Future<void> persistSessionInfo({
    String? accessToken, String? serverBaseUrl, int? expectedGeneration,
    int? userId, String? username, bool? isAdmin, String? role, String? logScope,
  }) => _persistTokens(accessToken: accessToken, serverBaseUrl: serverBaseUrl,
    expectedGeneration: expectedGeneration, userId: userId, username: username,
    isAdmin: isAdmin, role: role, logScope: logScope);

  static Future<void> clearTokens() async {
    _sessionGeneration++;
    _accessToken = null;
    _tokenOrigin = null;
    _cachedUsername = null;
    _cachedUserId = null;
    _cachedIsAdmin = null;
    _cachedRole = null;
    _cachedLogScope = "";
    clearLogContext();
    _sessionWrites = _sessionWrites.catchError((_) {}).then((_) async {
      await SecureStore.setString("auth_session", "{}");
      await SecureStore.delete("auth_token");
      final prefs = await SharedPreferences.getInstance();
      for (final key in ["username", "user_id", "is_admin", "role", "log_scope"]) {
        await prefs.remove(key);
      }
    });
    await _sessionWrites;
  }

  Future<void> connect(
    String host, {
    int port = 11451,
    bool useHttps = false,
  }) async {
    _baseUrl = serverEndpoint(host, port, useHttps);
    await _restoreLogContextFromPrefs();
  }

  Future<void> _restoreLogContextFromPrefs() async {
    final base = _baseUrl;
    if (base == null || accessToken == null) return;
    final generation = _sessionGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (generation != _sessionGeneration || tokenForServer(base) == null) return;
    final scope = prefs.getString("log_scope") ?? "";
    if (scope.isEmpty) return;
    _logServerKey = stableLogKey(base);
    _logAccountScope = scope;
    _logManagement = (prefs.getString("role") ?? "user") != "user";
    _logSessionId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    LoggerService().setContext(
      LogContext(
        serverKey: _logServerKey,
        accountScope: _logAccountScope,
        sessionId: _logSessionId,
      ),
    );
  }

  /// Re-read the verified profile so log ownership follows role changes.
  Future<void> refreshLogContext() async {
    if (accessToken == null || _baseUrl == null) return;
    final origin = _baseUrl!;
    final generation = _sessionGeneration;
    try {
      final resp = await _client
          .get(
            Uri.parse("$baseUrl/api/auth/profile/me"),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return;
      final data = tryDecodeJsonMap(resp.body);
      if (data == null) return;
      if (generation != _sessionGeneration) return;
      await _persistTokens(
        serverBaseUrl: origin, expectedGeneration: generation,
        userId: _parseUserId(data["id"]),
        username: data["username"]?.toString(),
        isAdmin: data["is_admin"] == true,
        role: data["role"]?.toString(),
        logScope: data["log_scope"]?.toString(),
      );
      await activateLogContext(baseUrl: baseUrl, profile: data);
    } catch (e, stackTrace) {
      LoggerService().warn("log context refresh failed", e, stackTrace);
    }
  }

  /// Execute an HTTP request.
  static const Duration _requestTimeout = Duration(seconds: 120);

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
    if (_baseUrl == null) {
      LoggerService().warn(
        "ApiClient used before connect; request targets the localhost fallback"
        " (${label ?? method})",
      );
    }
    final initialBase = _baseUrl;
    final generation = _sessionGeneration;
    const maxAttempts = 2;
    final retryEnabled = allowRetry &&
        (method == "GET" ||
            method == "HEAD" ||
            method == "PUT" ||
            method == "OPTIONS");
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final started = DateTime.now();
      try {
        if (initialBase != _baseUrl || generation != _sessionGeneration ||
            (uri != null && _baseUrl != null && serverOrigin(uri.toString()) != serverOrigin(_baseUrl))) {
          throw AuthException("连接或账号已变化，请重试");
        }
        final pending = request();
        final response = (method == "GET" || method == "HEAD")
            ? await pending.timeout(_requestTimeout)
            : await pending;
        final durationMs = DateTime.now().difference(started).inMilliseconds;
        final retrying = retryEnabled &&
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
        if (!retryEnabled ||
            attempt == maxAttempts - 1 ||
            !_isRetryableStatus(response.statusCode)) {
          return response;
        }
      } catch (error, stackTrace) {
        final durationMs = DateTime.now().difference(started).inMilliseconds;
        final retrying = retryEnabled &&
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
        if (!retryEnabled ||
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

  static const String _enabledScrapersCachePrefix = "enabled_scrapers::";
  static String? _enabledScrapersCacheKey;
  static List<String>? _enabledScrapersCacheValue;

  String get _enabledScrapersKey => "$_enabledScrapersCachePrefix$baseUrl";

  /// Locally cached enabled scrapers, or null when this device never fetched
  /// them. Used to open the metadata dialog without waiting on the network.
  Future<List<String>?> cachedEnabledScraperSources() async {
    final key = _enabledScrapersKey;
    if (_enabledScrapersCacheKey == key && _enabledScrapersCacheValue != null) {
      return List<String>.from(_enabledScrapersCacheValue!);
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final values = decoded.map((value) => value.toString()).toList();
    _enabledScrapersCacheKey = key;
    _enabledScrapersCacheValue = values;
    return List<String>.from(values);
  }

  Future<void> rememberEnabledScraperSources(List<String> sources) async {
    final key = _enabledScrapersKey;
    final values = List<String>.from(sources);
    _enabledScrapersCacheKey = key;
    _enabledScrapersCacheValue = values;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(values));
  }

  /// Enabled scrapers for the current server. Cached values are returned
  /// immediately while a background refresh keeps them current.
  Future<List<String>> getEnabledScraperSources() async {
    final cached = await cachedEnabledScraperSources();
    if (cached != null) {
      unawaited(_fetchEnabledScraperSources());
      return cached;
    }
    final fetched = await _fetchEnabledScraperSources();
    return fetched ?? const [];
  }

  Future<List<String>?> _fetchEnabledScraperSources() async {
    final uri = Uri.parse("$baseUrl/api/settings/scraper");
    try {
      final resp = await _client.get(uri, headers: headers).timeout(
            const Duration(seconds: 10),
          );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final enabled = data["enabled_scrapers"];
      if (enabled is! List) return null;
      final sources = enabled.map((value) => value.toString()).toList();
      await rememberEnabledScraperSources(sources);
      return sources;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchMetadataCandidates({
    required String source,
    required String query,
  }) async {
    final uri = Uri.parse("$baseUrl/api/scrape/search").replace(
      queryParameters: {"q": query, "source": source},
    );
    final resp = await _execute(
      () => _client.get(uri, headers: headers),
      allowRetry: false,
      method: "GET",
      uri: uri,
      label: "search metadata source=$source",
    );
    checkResponse(resp, fallbackMessage: "搜索元数据失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return ((data["results"] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>> createGame(Map<String, dynamic> body) async {
    final uri = Uri.parse("$baseUrl/api/games");
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode(body),
      ),
      allowRetry: false,
      method: "POST",
      uri: uri,
      label: "create game entry",
    );
    checkResponse(resp, fallbackMessage: "创建游戏条目失败");
    return jsonDecode(resp.body) as Map<String, dynamic>;
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

  Future<bool> setGameMetadataLock(int id, bool locked) async {
    final uri = Uri.parse("$baseUrl/api/games/$id/metadata-lock");
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"locked": locked}),
      ),
      method: "PUT",
      uri: uri,
      label: "set game metadata lock id=$id locked=$locked",
    );
    checkResponse(resp, fallbackMessage: locked ? "锁定失败" : "解锁失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["metadata_locked"] == true;
  }

  Future<bool> setGameNameLock(int id, bool locked) async {
    final uri = Uri.parse("$baseUrl/api/games/$id/name-lock");
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"locked": locked}),
      ),
      method: "PUT",
      uri: uri,
      label: "set game name lock id=$id locked=$locked",
    );
    checkResponse(resp, fallbackMessage: locked ? "锁定名称失败" : "解锁名称失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["name_locked"] == true;
  }

  Future<String> batchSetGameMetadataLock(List<int> ids, bool locked) async {
    final uri = Uri.parse("$baseUrl/api/games/batch-metadata-lock");
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"game_ids": ids, "locked": locked}),
      ),
      method: "POST",
      uri: uri,
      label: "batch set metadata lock count=${ids.length} locked=$locked",
    );
    checkResponse(resp, fallbackMessage: locked ? "批量锁定失败" : "批量解锁失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["message"]?.toString() ?? (locked ? "已锁定" : "已解锁");
  }

  // --- Platform categories ---

  Future<List<PlatformCategory>> getPlatformCategories() async {
    final uri = Uri.parse("$baseUrl/api/platforms");
    final resp = await _execute(
      () => _client.get(uri, headers: headers),
      method: "GET",
      uri: uri,
      label: "load platform categories",
    );
    if (resp.statusCode != 200) {
      throw HttpException("Failed to load platform categories");
    }
    final List<dynamic> data = jsonDecode(resp.body);
    return data
        .map((item) => PlatformCategory.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<PlatformCategory> createPlatformCategory(String name) async {
    final uri = Uri.parse("$baseUrl/api/platforms");
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"name": name}),
      ),
      method: "POST",
      uri: uri,
      label: "create platform category name=$name",
    );
    checkResponse(resp, fallbackMessage: "创建分类失败");
    return PlatformCategory.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<PlatformCategory> updatePlatformCategory(
    int id, {
    String? name,
    int? sortOrder,
  }) async {
    final uri = Uri.parse("$baseUrl/api/platforms/$id");
    final body = <String, dynamic>{};
    if (name != null) body["name"] = name;
    if (sortOrder != null) body["sort_order"] = sortOrder;
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode(body),
      ),
      method: "PUT",
      uri: uri,
      label: "update platform category id=$id",
    );
    checkResponse(resp, fallbackMessage: "更新分类失败");
    return PlatformCategory.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> reorderPlatformCategories(List<int> ids) async {
    final uri = Uri.parse("$baseUrl/api/platforms/order");
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"ids": ids}),
      ),
      method: "PUT",
      uri: uri,
      label: "reorder platform categories",
    );
    checkResponse(resp, fallbackMessage: "保存分类顺序失败");
  }

  Future<String> deletePlatformCategory(int id, {int? reassignToId}) async {
    final query = reassignToId == null ? "" : "?reassign_to_id=$reassignToId";
    final uri = Uri.parse("$baseUrl/api/platforms/$id$query");
    final resp = await _execute(
      () => _client.delete(uri, headers: headers),
      method: "DELETE",
      uri: uri,
      label: "delete platform category id=$id",
    );
    checkResponse(resp, fallbackMessage: "删除分类失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["message"]?.toString() ?? "已删除";
  }

  Future<PlatformCategoryRule> createPlatformRule(
    int categoryId,
    String kind,
    String pattern,
  ) async {
    final uri = Uri.parse("$baseUrl/api/platforms/$categoryId/rules");
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"kind": kind, "pattern": pattern}),
      ),
      method: "POST",
      uri: uri,
      label: "create platform rule category=$categoryId kind=$kind",
    );
    checkResponse(resp, fallbackMessage: "添加规则失败");
    return PlatformCategoryRule.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<PlatformCategoryRule> updatePlatformRule(
    int categoryId,
    int ruleId, {
    String? kind,
    String? pattern,
  }) async {
    final uri = Uri.parse("$baseUrl/api/platforms/$categoryId/rules/$ruleId");
    final body = <String, dynamic>{};
    if (kind != null) body["kind"] = kind;
    if (pattern != null) body["pattern"] = pattern;
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode(body),
      ),
      method: "PUT",
      uri: uri,
      label: "update platform rule id=$ruleId",
    );
    checkResponse(resp, fallbackMessage: "更新规则失败");
    return PlatformCategoryRule.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deletePlatformRule(int categoryId, int ruleId) async {
    final uri = Uri.parse("$baseUrl/api/platforms/$categoryId/rules/$ruleId");
    final resp = await _execute(
      () => _client.delete(uri, headers: headers),
      method: "DELETE",
      uri: uri,
      label: "delete platform rule id=$ruleId",
    );
    checkResponse(resp, fallbackMessage: "删除规则失败");
  }

  Future<void> reorderPlatformRules(int categoryId, List<int> ids) async {
    final uri = Uri.parse("$baseUrl/api/platforms/$categoryId/rules/order");
    final resp = await _execute(
      () => _client.put(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"ids": ids}),
      ),
      method: "PUT",
      uri: uri,
      label: "reorder platform rules category=$categoryId",
    );
    checkResponse(resp, fallbackMessage: "保存规则顺序失败");
  }

  Future<String> testPlatformMatch(String filename) async {
    final uri = Uri.parse("$baseUrl/api/platforms/test-match");
    final resp = await _execute(
      () => _client.post(
        uri,
        headers: {...headers, "Content-Type": "application/json"},
        body: jsonEncode({"filename": filename}),
      ),
      method: "POST",
      uri: uri,
      label: "test platform match",
    );
    checkResponse(resp, fallbackMessage: "测试匹配失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["category"]?.toString() ?? "";
  }

  Future<String> reidentifyPlatformCategories() async {
    final uri = Uri.parse("$baseUrl/api/platforms/reidentify");
    final resp = await _execute(
      () => _client.post(uri, headers: headers),
      method: "POST",
      uri: uri,
      label: "reidentify platform categories",
    );
    checkResponse(resp, fallbackMessage: "重新识别失败");
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data["message"]?.toString() ?? "完成";
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
        () => _client.get(uri).timeout(
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
    final origin = serverOrigin(_baseUrl);
    if (origin == null) throw AuthException("请先连接服务器");
    final generation = ++_sessionGeneration;
    final loginUri = Uri.parse("$origin/api/auth/login");
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

        final token = data["token"]?.toString();
        if (token == null || token.isEmpty) {
          throw AuthException(
            "服务器返回 200，但登录响应缺少 token，域名可能没有把 /api/auth/login 转发到服务端",
          );
        }

        var username = data["username"]?.toString();
        var userId = _parseUserId(data["id"]);
        var isAdmin = data["is_admin"] == true;
        var role = data["role"]?.toString() ?? (isAdmin ? "admin" : "user");
        try {
          final meUri = Uri.parse("$origin/api/auth/profile/me");
          final meStarted = DateTime.now();
          final meResp = await _client.get(
            meUri,
            headers: {"Authorization": "Bearer $token"},
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
            data["log_scope"] = me["log_scope"]?.toString() ?? "";
          }
        } on AuthException {
          rethrow;
        } catch (e, stackTrace) {
          LoggerService().warn("auth profile sync after login failed", e, stackTrace);
        }
        if (serverOrigin(_baseUrl) != origin) throw AuthException("连接已变化，请重新登录");
        await _persistTokens(
          accessToken: token, serverBaseUrl: origin, expectedGeneration: generation,
          userId: userId,
          username: username,
          isAdmin: isAdmin,
          role: role,
          logScope: data["log_scope"]?.toString(),
        );
        await activateLogContext(baseUrl: baseUrl, profile: data);
        if (_sessionGeneration != generation + 1 || tokenForServer(origin) != token) {
          throw AuthException("连接或账号已变化，请重试");
        }
        data["_installed_generation"] = _sessionGeneration;
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

  // --- NextMoe OAuth ---

  Map<String, String> _jsonHeaders({bool withAuth = false}) {
    final headers = {"Content-Type": "application/json"};
    if (withAuth) headers.addAll(this.headers);
    return headers;
  }

  Future<Map<String, dynamic>?> getAuthProviders() async {
    final uri = Uri.parse("$baseUrl/api/auth/oauth/providers");
    try {
      final resp = await _execute(
        () => _client.get(uri).timeout(const Duration(seconds: 10)),
        allowRetry: false,
        method: "GET",
        uri: uri,
        label: "oauth providers",
      );
      if (resp.statusCode == 200) {
        return tryDecodeJsonMap(resp.body);
      }
    } catch (e, stackTrace) {
      LoggerService().warn("oauth providers failed", e, stackTrace);
    }
    return null;
  }

  Future<Map<String, dynamic>> oauthStart({
    required String provider,
    required String purpose,
    String redirectUri = "",
    int? redirectPort,
    bool withAuth = false,
  }) async {
    _oauthRequestId = null;
    _oauthGeneration = purpose == "login" ? ++_sessionGeneration : null;
    _oauthOrigin = serverOrigin(_baseUrl);
    final flowGeneration = _oauthGeneration;
    final flowOrigin = _oauthOrigin;
    if (flowOrigin == null) throw AuthException("请先连接服务器");
    final body = jsonEncode({
      "purpose": purpose,
      if (redirectUri.isNotEmpty) "redirect_uri": redirectUri,
      if (redirectPort != null) "redirect_port": redirectPort,
    });
    final uri = Uri.parse("$baseUrl/api/auth/oauth/$provider/start");
    var resp = await _execute(
      () => _client
          .post(
            uri,
            headers: _jsonHeaders(withAuth: withAuth),
            body: body,
          )
          .timeout(const Duration(seconds: 15)),
      allowRetry: false,
      method: "POST",
      uri: uri,
      label: "oauth start",
    );
    if (resp.statusCode == 404 && provider == "nextmoe") {
      final legacy = uri.replace(path: "/api/auth/oauth/start");
      resp = await _execute(
        () => _client
            .post(
              legacy,
              headers: _jsonHeaders(withAuth: withAuth),
              body: body,
            )
            .timeout(const Duration(seconds: 15)),
        allowRetry: false,
        method: "POST",
        uri: legacy,
        label: "oauth start legacy",
      );
    }
    final data = tryDecodeJsonMap(resp.body);
    if (resp.statusCode == 200 && data != null) {
      if (flowOrigin != serverOrigin(_baseUrl) || flowGeneration != _oauthGeneration ||
          (flowGeneration != null && flowGeneration != _sessionGeneration)) {
        throw AuthException("授权连接已变化，请重试");
      }
      _oauthRequestId = data["request_id"]?.toString();
      return data;
    }
    final detail = data?["detail"]?.toString() ?? "";
    throw AuthException(
      detail.isNotEmpty
          ? detail
          : "无法发起第三方账号授权（HTTP ${resp.statusCode}）",
    );
  }

  Future<Map<String, dynamic>> oauthComplete({
    required String provider,
    required String requestId,
    required String code,
    required String state,
    bool withAuth = false,
  }) async {
    final flowGeneration = _oauthGeneration;
    final flowOrigin = _oauthOrigin;
    if (requestId != _oauthRequestId || flowOrigin != serverOrigin(_baseUrl)) {
      throw AuthException("授权流程已变化，请重试");
    }
    final body = jsonEncode({
      "request_id": requestId,
      "code": code,
      "state": state,
    });
    final uri = Uri.parse("$baseUrl/api/auth/oauth/$provider/complete");
    var resp = await _execute(
      () => _client
          .post(
            uri,
            headers: _jsonHeaders(withAuth: withAuth),
            body: body,
          )
          .timeout(const Duration(seconds: 20)),
      allowRetry: false,
      method: "POST",
      uri: uri,
      label: "oauth complete",
    );
    if (resp.statusCode == 404 && provider == "nextmoe") {
      final legacy = uri.replace(path: "/api/auth/oauth/complete");
      resp = await _execute(
        () => _client
            .post(
              legacy,
              headers: _jsonHeaders(withAuth: withAuth),
              body: body,
            )
            .timeout(const Duration(seconds: 20)),
        allowRetry: false,
        method: "POST",
        uri: legacy,
        label: "oauth complete legacy",
      );
    }
    final data = tryDecodeJsonMap(resp.body);
    if (resp.statusCode == 200 && data != null) {
      if (data["token"] != null) {
        if (flowGeneration == null || flowGeneration != _sessionGeneration ||
            flowGeneration != _oauthGeneration || requestId != _oauthRequestId ||
            flowOrigin != serverOrigin(_baseUrl)) {
          throw AuthException("授权流程已变化，请重试");
        }
        data["_session_origin"] = flowOrigin;
        data["_session_generation"] = flowGeneration;
      }
      return data;
    }
    final detail = data?["detail"]?.toString() ?? "";
    throw AuthException(
      detail.isNotEmpty
          ? detail
          : "第三方账号授权失败（HTTP ${resp.statusCode}），请重试",
    );
  }

  Future<Map<String, dynamic>?> getOauthBindings() async {
    if (accessToken == null || accessToken!.isEmpty) return null;
    final uri = Uri.parse("$baseUrl/api/auth/oauth/bindings");
    try {
      final resp = await _execute(
        () => _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 10)),
        allowRetry: false,
        method: "GET",
        uri: uri,
        label: "oauth bindings",
      );
      if (resp.statusCode == 200) {
        return tryDecodeJsonMap(resp.body);
      }
    } catch (e, stackTrace) {
      LoggerService().warn("oauth bindings lookup failed", e, stackTrace);
    }
    return null;
  }

  Future<Map<String, dynamic>?> getOauthBinding() async {
    if (accessToken == null || accessToken!.isEmpty) return null;
    final uri = Uri.parse("$baseUrl/api/auth/oauth/binding");
    try {
      final resp = await _execute(
        () => _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 10)),
        allowRetry: false,
        method: "GET",
        uri: uri,
        label: "oauth binding",
      );
      if (resp.statusCode == 200) {
        return tryDecodeJsonMap(resp.body);
      }
    } catch (e, stackTrace) {
      LoggerService().warn("oauth binding lookup failed", e, stackTrace);
    }
    return null;
  }

  Future<void> unbindOauth({String provider = "nextmoe"}) async {
    final uri = Uri.parse("$baseUrl/api/auth/oauth/binding/$provider");
    var resp = await _execute(
      () => _client
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 10)),
      allowRetry: false,
      method: "DELETE",
      uri: uri,
      label: "oauth unbind",
    );
    if (resp.statusCode == 404 && provider == "nextmoe") {
      final legacy = Uri.parse("$baseUrl/api/auth/oauth/binding");
      resp = await _execute(
        () => _client
            .delete(legacy, headers: headers)
            .timeout(const Duration(seconds: 10)),
        allowRetry: false,
        method: "DELETE",
        uri: legacy,
        label: "oauth unbind legacy",
      );
    }
    if (resp.statusCode == 200) return;
    final data = tryDecodeJsonMap(resp.body);
    throw AuthException(data?["detail"]?.toString() ?? "解除绑定失败");
  }

  Future<Map<String, dynamic>> applyOAuthSession(
    Map<String, dynamic> data,
  ) async {
    final token = data["token"]?.toString() ?? "";
    if (token.isEmpty) {
      throw AuthException("登录响应缺少 token");
    }
    final origin = serverOrigin(data["_session_origin"] as String?);
    final generation = data["_session_generation"] as int?;
    if (origin == null || origin != _oauthOrigin || generation == null ||
        generation != _sessionGeneration) throw AuthException("授权连接已变化，请重试");
    final username = data["username"]?.toString() ?? "";
    final userId = _parseUserId(data["id"]);
    final isAdmin = data["is_admin"] == true;
    final role = data["role"]?.toString() ?? (isAdmin ? "admin" : "user");
    await _persistTokens(
      accessToken: token, serverBaseUrl: origin, expectedGeneration: generation,
      userId: userId,
      username: username,
      isAdmin: isAdmin,
      role: role,
    );
    await refreshLogContext();
    if (_sessionGeneration != generation + 1 || tokenForServer(origin) != token) {
      throw AuthException("连接或账号已变化，请重试");
    }
    data["_installed_generation"] = _sessionGeneration;
    LoggerService().info("oauth login succeeded: role=$role isAdmin=$isAdmin");
    return data;
  }

  Future<bool> logout() async {
    final token = accessToken;
    if (token == null) return true;
    final generation = _sessionGeneration;
    var success = true;
    try {
      if (token.isNotEmpty) {
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
      if (generation == _sessionGeneration) await clearTokens();
    }
    return success;
  }
}

/// OAuth login and binding helper: loopback callback + system browser + PKCE.

import "dart:async";
import "dart:io";

import "package:url_launcher/url_launcher.dart";

import "api_client.dart";
import "logger_service.dart";
import "oauth_token_store.dart";

enum OAuthAuthKind { session, bound, error }

class OAuthOutcome {
  final OAuthAuthKind kind;
  final Map<String, dynamic>? session;
  final String provider;
  final String boundName;
  final String boundUserId;
  final String requestId;
  final String error;
  final bool cancelled;

  const OAuthOutcome({
    required this.kind,
    this.session,
    this.provider = "",
    this.boundName = "",
    this.boundUserId = "",
    this.requestId = "",
    this.error = "",
    this.cancelled = false,
  });

  bool get isSession => kind == OAuthAuthKind.session;
  bool get isBound => kind == OAuthAuthKind.bound;

  static const cancelledOutcome = OAuthOutcome(
    kind: OAuthAuthKind.error,
    error: "已取消授权",
    cancelled: true,
  );
}

class OAuthProviderInfo {
  final String key;
  final String label;
  final String issuer;
  final String clientId;
  final String tokenUrl;
  final String fixedRedirectUri;
  final bool enabled;

  const OAuthProviderInfo({
    required this.key,
    required this.label,
    required this.issuer,
    required this.clientId,
    required this.tokenUrl,
    required this.fixedRedirectUri,
    required this.enabled,
  });

  factory OAuthProviderInfo.fromMap(String key, Map<dynamic, dynamic> map) {
    return OAuthProviderInfo(
      key: key,
      label: map["name"]?.toString() ?? key,
      issuer: map["issuer"]?.toString() ?? "",
      clientId: map["client_id"]?.toString() ?? "",
      tokenUrl: map["token_url"]?.toString() ?? "",
      fixedRedirectUri: map["fixed_redirect_uri"]?.toString() ?? "",
      enabled: map["enabled"] == true,
    );
  }

  String get asset => switch (key) {
        "nextmoe" => "assets/source_icons/nextmoe.png",
        "hikarinagi" => "assets/source_icons/hikarinagi.png",
        _ => "assets/icon.png",
      };

  String get shortLabel => switch (key) {
        "nextmoe" => "NextMoe·未萌",
        "hikarinagi" => "Hikarinagi",
        _ => label,
      };
}

class _CallbackOutcome {
  final String? code;
  final String error;

  const _CallbackOutcome({this.code, this.error = ""});
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return result == 0;
}

String _normalizeIssuer(String value) =>
    value.trim().replaceFirst(RegExp(r"/+$"), "");

class OAuthService {
  static const _authorizeTimeout = Duration(minutes: 5);
  static const _callbackPath = "/callback";

  static Future<Map<String, OAuthProviderInfo>> loadProviders(
    ApiClient api,
  ) async {
    final data = await api.getAuthProviders();
    if (data == null) return const {};
    final result = <String, OAuthProviderInfo>{};
    for (final entry in data.entries) {
      if (entry.value is Map) {
        result[entry.key] = OAuthProviderInfo.fromMap(
          entry.key,
          entry.value as Map,
        );
      }
    }
    return result;
  }

  /// Run a full loopback OAuth flow and return the outcome.
  ///
  /// [purpose] is one of `login`, `bind`, `setup`.
  static Future<OAuthOutcome> authorize(
    ApiClient api, {
    required String provider,
    required String purpose,
  }) async {
    final providers = await loadProviders(api);
    final info = providers[provider];
    if (info == null || !info.enabled) {
      return OAuthOutcome(
        kind: OAuthAuthKind.error,
        provider: provider,
        error: "${_label(provider)} 登录未启用",
      );
    }

    final fixedUri = info.fixedRedirectUri.trim();
    final fixed = fixedUri.isNotEmpty ? Uri.tryParse(fixedUri) : null;
    final port = fixed?.port ?? 0;
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e, stackTrace) {
      LoggerService().error("oauth loopback bind failed", e, stackTrace);
      return OAuthOutcome(
        kind: OAuthAuthKind.error,
        provider: provider,
        error: port > 0
            ? "无法在 $port 端口启动授权回调，请关闭占用该端口的程序后重试"
            : "无法在本机启动授权回调端口",
      );
    }

    final withAuth = purpose == "bind";
    final callbackPath =
        fixed != null && fixed.path.isNotEmpty ? fixed.path : _callbackPath;
    final redirectUri = fixed != null
        ? fixedUri
        : "http://127.0.0.1:${server.port}$_callbackPath";
    try {
      late final Map<String, dynamic> start;
      try {
        try {
          start = await api.oauthStart(
            provider: provider,
            purpose: purpose,
            redirectPort: fixed == null ? server.port : null,
            withAuth: withAuth,
          );
        } on AuthException {
          // Older servers only accept an explicit redirect_uri.
          if (fixed != null || provider != "nextmoe") rethrow;
          start = await api.oauthStart(
            provider: provider,
            purpose: purpose,
            redirectUri: redirectUri,
            withAuth: withAuth,
          );
        }
      } on AuthException catch (e) {
        return OAuthOutcome(
          kind: OAuthAuthKind.error,
          provider: provider,
          error: e.message,
        );
      } catch (e, stackTrace) {
        LoggerService().error("oauth start failed", e, stackTrace);
        return OAuthOutcome(
          kind: OAuthAuthKind.error,
          provider: provider,
          error: "无法发起 ${_label(provider)} 授权",
        );
      }

      final authorizeUrl = start["authorize_url"]?.toString() ?? "";
      final requestId = start["request_id"]?.toString() ?? "";
      final state = start["state"]?.toString() ?? "";
      if (authorizeUrl.isEmpty || requestId.isEmpty || state.isEmpty) {
        return OAuthOutcome(
          kind: OAuthAuthKind.error,
          provider: provider,
          error: "服务器返回了无效的授权信息",
        );
      }

      final codeCompleter = Completer<_CallbackOutcome>();
      final subscription = server.listen((request) async {
        if (request.uri.path != callbackPath) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final error = request.uri.queryParameters["error"];
        final errorDescription =
            request.uri.queryParameters["error_description"] ?? "";
        final code = request.uri.queryParameters["code"];
        final callbackState = request.uri.queryParameters["state"] ?? "";
        final callbackIssuer = request.uri.queryParameters["iss"] ?? "";
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
          "<title>Sena Repo</title></head><body style=\"font-family:sans-serif;"
          "display:flex;align-items:center;justify-content:center;height:100vh;"
          "background:#ECEFF5;color:#111827\"><div style=\"text-align:center\">"
          "<h2 style=\"font-size:18px\">已收到授权</h2>"
          "<p style=\"color:#6B7280;font-size:13px\">请返回 Sena Repo 客户端继续</p>"
          "</div></body></html>",
        );
        await request.response.close();
        if (codeCompleter.isCompleted) return;
        if (callbackState.isNotEmpty &&
            !_constantTimeEquals(callbackState, state)) {
          codeCompleter.complete(
            const _CallbackOutcome(error: "授权校验失败，请重试"),
          );
          return;
        }
        if (error != null) {
          if (error == "access_denied") {
            codeCompleter.complete(
              const _CallbackOutcome(error: "cancelled"),
            );
          } else {
            codeCompleter.complete(
              _CallbackOutcome(
                error: errorDescription.isNotEmpty
                    ? errorDescription
                    : "授权失败：$error",
              ),
            );
          }
          return;
        }
        if (callbackState.isEmpty) {
          codeCompleter.complete(
            const _CallbackOutcome(error: "授权校验失败，请重试"),
          );
          return;
        }
        if (callbackIssuer.isNotEmpty &&
            info.issuer.isNotEmpty &&
            _normalizeIssuer(callbackIssuer) != _normalizeIssuer(info.issuer)) {
          codeCompleter.complete(
            const _CallbackOutcome(error: "授权来源校验失败，请重试"),
          );
          return;
        }
        if (code == null || code.isEmpty) {
          codeCompleter.complete(const _CallbackOutcome(error: "缺少授权码"));
          return;
        }
        codeCompleter.complete(_CallbackOutcome(code: code));
      });

      try {
        bool launched;
        try {
          launched = await launchUrl(
            Uri.parse(authorizeUrl),
            mode: LaunchMode.externalApplication,
          );
        } catch (e, stackTrace) {
          LoggerService().error("oauth browser launch failed", e, stackTrace);
          launched = false;
        }
        if (!launched) {
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: "无法打开系统浏览器，请手动访问授权链接",
          );
        }

        final callback = await codeCompleter.future.timeout(
          _authorizeTimeout,
          onTimeout: () => const _CallbackOutcome(error: "timeout"),
        );
        if (callback.error == "timeout") {
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: "授权超时，请重试",
          );
        }
        if (callback.error == "cancelled") {
          return OAuthOutcome.cancelledOutcome;
        }
        if (callback.error.isNotEmpty) {
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: callback.error,
          );
        }
        final code = callback.code;
        if (code == null || code.isEmpty) {
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: "缺少授权码",
          );
        }

        final Map<String, dynamic> result;
        try {
          result = await api.oauthComplete(
            provider: provider,
            requestId: requestId,
            code: code,
            state: state,
            withAuth: withAuth,
          );
        } on AuthException catch (e) {
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: e.message,
          );
        } catch (e, stackTrace) {
          LoggerService().error("oauth complete failed", e, stackTrace);
          return OAuthOutcome(
            kind: OAuthAuthKind.error,
            provider: provider,
            error: "${_label(provider)} 授权失败，请重试",
          );
        }

        if (result["bound"] == true) {
          if (provider == "nextmoe") {
            await OAuthTokenStore.saveFromResponse(api, result);
          }
          return OAuthOutcome(
            kind: OAuthAuthKind.bound,
            provider: provider,
            boundName: result["name"]?.toString() ?? "",
            boundUserId: result["user_id"]?.toString() ?? "",
            requestId: requestId,
          );
        }
        if (result["token"] != null) {
          final session = await api.applyOAuthSession(result);
          if (provider == "nextmoe") {
            await OAuthTokenStore.saveFromResponse(api, session);
          }
          return OAuthOutcome(
            kind: OAuthAuthKind.session,
            provider: provider,
            session: session,
          );
        }
        return OAuthOutcome(
          kind: OAuthAuthKind.error,
          provider: provider,
          error: "服务器返回了未知的授权结果",
        );
      } finally {
        await subscription.cancel();
      }
    } finally {
      await server.close(force: true);
    }
  }

  static String _label(String provider) => switch (provider) {
        "nextmoe" => "NextMoe·未萌",
        "hikarinagi" => "Hikarinagi",
        _ => provider,
      };
}

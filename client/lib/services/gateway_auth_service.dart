import "dart:convert";

import "package:http/http.dart" as http;
import "package:url_launcher/url_launcher.dart";

class GatewayAuthChallenge {
  final Uri serverUri;
  final Uri authUri;
  final String provider;

  const GatewayAuthChallenge({
    required this.serverUri,
    required this.authUri,
    this.provider = "fn-knock",
  });
}

class GatewayAuthRequiredException implements Exception {
  final GatewayAuthChallenge challenge;

  const GatewayAuthRequiredException(this.challenge);

  @override
  String toString() => GatewayAuthService.protectedMessage;
}

class GatewayAuthService {
  static const protectedMessage = "该服务端受 fn-knock 保护，请认证后尝试重新登录";

  static Future<http.Response> getNoRedirect(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = http.Client();
    try {
      final request = http.Request("GET", uri)
        ..followRedirects = false
        ..headers.addAll(headers ?? const {});
      final streamed = await client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed);
    } finally {
      client.close();
    }
  }

  static Future<http.Response> postJsonNoRedirect(
    Uri uri, {
    required Object body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = http.Client();
    try {
      final request = http.Request("POST", uri)
        ..followRedirects = false
        ..headers.addAll({"Content-Type": "application/json", ...?headers})
        ..body = jsonEncode(body);
      final streamed = await client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed);
    } finally {
      client.close();
    }
  }

  static GatewayAuthChallenge? detect(Uri requestUri, http.Response response) {
    final headers = _normalizedHeaders(response.headers);
    final hasReauthHeader = headers.keys.any(
      (key) => key.startsWith("x-reauth-"),
    );
    final redirectValue =
        headers["x-reauth-redirect-location"] ?? headers["location"];
    final headerRedirectUri = _resolveRedirect(requestUri, redirectValue);
    final contentType = (headers["content-type"] ?? "").toLowerCase();
    final bodyHead = response.body.length > 4096
        ? response.body.substring(0, 4096)
        : response.body;
    final lowerBody = bodyHead.toLowerCase();
    final jsonRedirectUri = _resolveJsonRedirect(requestUri, bodyHead);
    final redirectUri = headerRedirectUri ?? jsonRedirectUri;
    final redirectLooksLikeKnock =
        redirectUri != null &&
        _looksLikeKnockAuth(redirectUri.toString().toLowerCase());
    // "fn-knock" is unique enough to match in any content-type.
    // Keep the text/html guard only for generic strings like "reauth".
    final bodyLooksLikeKnock =
        lowerBody.contains("fn-knock") ||
        (contentType.contains("text/html") &&
            (lowerBody.contains("reauth") || lowerBody.contains("#/login")));

    // /api/health never redirects on its own — any 3xx means a gateway intercepted.
    final isGatewayRedirect =
        response.statusCode >= 300 && response.statusCode < 400;

    if (!hasReauthHeader && !redirectLooksLikeKnock && !bodyLooksLikeKnock && !isGatewayRedirect) {
      return null;
    }

    final serverUri = requestUri.replace(path: "", query: "", fragment: "");
    return GatewayAuthChallenge(
      serverUri: serverUri,
      authUri: redirectUri ?? serverUri,
    );
  }

  static bool isValidSenaHealth(http.Response response) {
    if (response.statusCode != 200) return false;
    try {
      final data = jsonDecode(response.body);
      return data is Map && data["status"] == "ok";
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAuthPage(GatewayAuthChallenge challenge) {
    return launchUrl(challenge.authUri, mode: LaunchMode.externalApplication);
  }

  static Map<String, String> _normalizedHeaders(Map<String, String> headers) {
    return headers.map((key, value) => MapEntry(key.toLowerCase(), value));
  }

  static Uri? _resolveRedirect(Uri requestUri, String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      return requestUri.resolve(value.trim());
    } catch (_) {
      return null;
    }
  }

  static Uri? _resolveJsonRedirect(Uri requestUri, String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final redirectValue =
          decoded["redirect_to"] ??
          decoded["redirectTo"] ??
          decoded["location"];
      if (redirectValue is! String) return null;
      final redirectUri = _resolveRedirect(requestUri, redirectValue);
      if (redirectUri == null ||
          !_looksLikeKnockAuth(redirectUri.toString().toLowerCase())) {
        return null;
      }
      return redirectUri;
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeKnockAuth(String value) {
    return value.contains("fn-knock") ||
        value.contains("reauth") ||
        value.contains("/__auth__/") ||
        value.contains("/auth/api/auth/") ||
        (value.contains("/auth/") && !value.contains("/api/auth/")) ||
        value.contains("#/login");
  }
}


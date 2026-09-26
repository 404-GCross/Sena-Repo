/// NextMoe OAuth login helper: loopback callback + system browser + PKCE.

import "dart:async";
import "dart:io";

import "package:url_launcher/url_launcher.dart";

import "api_client.dart";
import "logger_service.dart";
import "nextmoe_token_store.dart";

enum NextmoeAuthKind { session, pending, rejected, bound, registerRequired, error }

class NextmoeAuthOutcome {
  final NextmoeAuthKind kind;
  final Map<String, dynamic>? session;
  final String username;
  final String boundName;
  final String boundUserId;
  final String requestId;
  final String nextmoeName;
  final String suggestedUsername;
  final String error;
  final bool cancelled;

  const NextmoeAuthOutcome({
    required this.kind,
    this.session,
    this.username = "",
    this.boundName = "",
    this.boundUserId = "",
    this.requestId = "",
    this.nextmoeName = "",
    this.suggestedUsername = "",
    this.error = "",
    this.cancelled = false,
  });

  bool get isSession => kind == NextmoeAuthKind.session;
  bool get isPending => kind == NextmoeAuthKind.pending;
  bool get isRejected => kind == NextmoeAuthKind.rejected;
  bool get isBound => kind == NextmoeAuthKind.bound;

  static const cancelledOutcome = NextmoeAuthOutcome(
    kind: NextmoeAuthKind.error,
    error: "已取消授权",
    cancelled: true,
  );
}

class NextmoeOAuth {
  static const _authorizeTimeout = Duration(minutes: 5);
  static const _callbackPath = "/callback";

  /// Run a full loopback OAuth flow and return the outcome.
  ///
  /// [purpose] is one of `login`, `bind`, `setup`.
  static Future<NextmoeAuthOutcome> authorize(
    ApiClient api, {
    required String purpose,
  }) async {
    HttpServer? bound;
    try {
      bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e, stackTrace) {
      LoggerService().error("oauth loopback bind failed", e, stackTrace);
      return const NextmoeAuthOutcome(
        kind: NextmoeAuthKind.error,
        error: "无法在本机启动授权回调端口",
      );
    }
    final server = bound;
    if (server == null) {
      return const NextmoeAuthOutcome(
        kind: NextmoeAuthKind.error,
        error: "无法在本机启动授权回调端口",
      );
    }

    final withAuth = purpose == "bind";
    try {
      final Map<String, dynamic> start;
      try {
        start = await api.oauthStart(
          purpose: purpose,
          redirectUri: "http://127.0.0.1:${server.port}$_callbackPath",
          withAuth: withAuth,
        );
      } on AuthException catch (e) {
        return NextmoeAuthOutcome(kind: NextmoeAuthKind.error, error: e.message);
      } catch (e, stackTrace) {
        LoggerService().error("oauth start failed", e, stackTrace);
        return const NextmoeAuthOutcome(
          kind: NextmoeAuthKind.error,
          error: "无法发起 鲲Galgame 授权",
        );
      }

      final authorizeUrl = start["authorize_url"]?.toString() ?? "";
      final requestId = start["request_id"]?.toString() ?? "";
      final state = start["state"]?.toString() ?? "";
      if (authorizeUrl.isEmpty || requestId.isEmpty || state.isEmpty) {
        return const NextmoeAuthOutcome(
          kind: NextmoeAuthKind.error,
          error: "服务器返回了无效的授权信息",
        );
      }

      final codeCompleter = Completer<String?>();
      final subscription = server.listen((request) async {
        if (request.uri.path != _callbackPath) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final error = request.uri.queryParameters["error"];
        final code = request.uri.queryParameters["code"];
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
        if (!codeCompleter.isCompleted) {
          codeCompleter.complete(error != null ? "" : code);
        }
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
          return const NextmoeAuthOutcome(
            kind: NextmoeAuthKind.error,
            error: "无法打开系统浏览器，请手动访问授权链接",
          );
        }

        final code = await codeCompleter.future.timeout(
          _authorizeTimeout,
          onTimeout: () => null,
        );
        if (code == null) {
          return const NextmoeAuthOutcome(
            kind: NextmoeAuthKind.error,
            error: "授权超时，请重试",
          );
        }
        if (code.isEmpty) {
          return NextmoeAuthOutcome.cancelledOutcome;
        }

        final Map<String, dynamic> result;
        try {
          result = await api.oauthComplete(
            requestId: requestId,
            code: code,
            state: state,
            withAuth: withAuth,
            expectUsername: purpose == "login",
          );
        } on AuthException catch (e) {
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.error,
            error: e.message,
          );
        } catch (e, stackTrace) {
          LoggerService().error("oauth complete failed", e, stackTrace);
          return const NextmoeAuthOutcome(
            kind: NextmoeAuthKind.error,
            error: "鲲Galgame 授权失败，请重试",
          );
        }

        if (result["register_required"] == true) {
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.registerRequired,
            requestId: result["request_id"]?.toString() ?? requestId,
            nextmoeName: result["name"]?.toString() ?? "",
            suggestedUsername: result["suggested_username"]?.toString() ?? "",
          );
        }
        if (result["pending"] == true) {
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.pending,
            username: result["username"]?.toString() ?? "",
          );
        }
        if (result["rejected"] == true) {
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.rejected,
            username: result["username"]?.toString() ?? "",
          );
        }
        if (result["bound"] == true) {
          await NextmoeTokenStore.saveFromResponse(api, result);
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.bound,
            boundName: result["name"]?.toString() ?? "",
            boundUserId: result["user_id"]?.toString() ?? "",
            requestId: requestId,
          );
        }
        if (result["token"] != null) {
          final session = await api.applyOAuthSession(result);
          await NextmoeTokenStore.saveFromResponse(api, session);
          return NextmoeAuthOutcome(
            kind: NextmoeAuthKind.session,
            session: session,
          );
        }
        return const NextmoeAuthOutcome(
          kind: NextmoeAuthKind.error,
          error: "服务器返回了未知的授权结果",
        );
      } finally {
        await subscription.cancel();
      }
    } finally {
      await server.close(force: true);
    }
  }
}

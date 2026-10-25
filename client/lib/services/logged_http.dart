/// Logging wrapper for package:http top-level helpers.

import "dart:convert";

import "package:http/http.dart" as base;

import "../models/log_models.dart";
import "logger_service.dart";

export "package:http/http.dart"
    show
        BaseRequest,
        ByteStream,
        Client,
        ClientException,
        MultipartFile,
        MultipartRequest,
        Request,
        Response,
        StreamedResponse;

Future<base.Response> get(Uri url, {Map<String, String>? headers}) =>
    _send("GET", url, () => base.get(url, headers: headers));

Future<base.Response> head(Uri url, {Map<String, String>? headers}) =>
    _send("HEAD", url, () => base.head(url, headers: headers));

Future<base.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _send(
      "POST",
      url,
      () => base.post(url, headers: headers, body: body, encoding: encoding),
    );

Future<base.Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _send(
      "PUT",
      url,
      () => base.put(url, headers: headers, body: body, encoding: encoding),
    );

Future<base.Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _send(
      "PATCH",
      url,
      () => base.patch(url, headers: headers, body: body, encoding: encoding),
    );

Future<base.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _send(
      "DELETE",
      url,
      () => base.delete(url, headers: headers, body: body, encoding: encoding),
    );

Future<base.StreamedResponse> sendLogged(
  base.Client client,
  base.BaseRequest request, {
  required String label,
  LogVisibility visibility = LogVisibility.personal,
}) async {
  final started = DateTime.now();
  final target = LoggerService().redact("${request.method} ${request.url}");
  LoggerService().record(
    LogLevel.info,
    "http.request",
    "$label $target",
    module: "network",
    visibility: visibility,
  );
  try {
    final response = await client.send(request);
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    final failed = response.statusCode >= 400;
    LoggerService().record(
      failed ? LogLevel.warning : LogLevel.info,
      failed ? "http.response_error" : "http.response",
      "$label status=${response.statusCode} durationMs=$durationMs",
      module: "network",
      visibility: visibility,
      fields: {"status": response.statusCode, "duration_ms": durationMs},
    );
    return response;
  } catch (error, stackTrace) {
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    LoggerService().record(
      LogLevel.error,
      "http.error",
      "$label failed durationMs=$durationMs",
      module: "network",
      visibility: visibility,
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

/// Logs a multipart (or any self-sending) request around [BaseRequest.send].
Future<base.StreamedResponse> sendMultipart(
  base.BaseRequest request, {
  required String label,
  LogVisibility visibility = LogVisibility.personal,
}) async {
  final started = DateTime.now();
  final target = LoggerService().redact("${request.method} ${request.url}");
  LoggerService().record(
    LogLevel.info,
    "http.request",
    "$label $target",
    module: "network",
    visibility: visibility,
  );
  try {
    final response = await request.send();
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    final failed = response.statusCode >= 400;
    LoggerService().record(
      failed ? LogLevel.warning : LogLevel.info,
      failed ? "http.response_error" : "http.response",
      "$label status=${response.statusCode} durationMs=$durationMs",
      module: "network",
      visibility: visibility,
      fields: {"status": response.statusCode, "duration_ms": durationMs},
    );
    return response;
  } catch (error, stackTrace) {
    LoggerService().record(
      LogLevel.error,
      "http.error",
      "$label failed",
      module: "network",
      visibility: visibility,
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

Future<base.Response> _send(
  String method,
  Uri url,
  Future<base.Response> Function() request,
) async {
  final started = DateTime.now();
  final safeUrl = LoggerService().redact(url.toString());
  try {
    final response = await request();
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    final message =
        "HTTP response: $method $safeUrl status=${response.statusCode} durationMs=$durationMs";
    if (response.statusCode >= 400) {
      LoggerService().warn(message);
    } else {
      LoggerService().info(message);
    }
    return response;
  } catch (e, stackTrace) {
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    LoggerService().error(
      "HTTP error: $method $safeUrl durationMs=$durationMs",
      e,
      stackTrace,
    );
    rethrow;
  }
}

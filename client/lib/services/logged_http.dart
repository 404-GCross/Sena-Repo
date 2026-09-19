/// Logging wrapper for package:http top-level helpers.

import "dart:convert";

import "package:http/http.dart" as base;

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

import "dart:convert";

import "logged_http.dart" as http;

class ApiResponseException implements Exception {
  final String message;

  const ApiResponseException(this.message);

  @override
  String toString() => message;
}

Map<String, dynamic>? tryDecodeJsonMap(String body) {
  try {
    final data = jsonDecode(body);
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
  } catch (_) {
    return null;
  }
  return null;
}

String apiResponsePreview(String body, {int maxLength = 80}) {
  final compact = body.trim().replaceAll(RegExp(r"\s+"), " ");
  if (compact.length <= maxLength) return compact;
  return "${compact.substring(0, maxLength)}...";
}

bool isValidSenaHealthResponse(http.Response response) {
  if (response.statusCode != 200) return false;
  final data = tryDecodeJsonMap(response.body);
  return data != null && data["status"] == "ok";
}

String describeUnexpectedApiResponse(
  http.Response response, {
  required String expected,
  String endpointPath = "/api",
}) {
  if (response.statusCode >= 300 && response.statusCode < 400) {
    final location = response.headers["location"];
    return location == null || location.isEmpty
        ? "服务器返回重定向 ${response.statusCode}，未到达 Sena 服务端"
        : "服务器返回重定向 ${response.statusCode}：$location";
  }
  if (response.statusCode != 200) {
    return "服务器返回错误: ${response.statusCode}";
  }

  final body = response.body.trim();
  if (body.isEmpty) {
    return "服务器返回 200，但 $expected 响应为空";
  }

  final data = tryDecodeJsonMap(response.body);
  if (data == null) {
    final preview = apiResponsePreview(response.body);
    return "服务器返回 200，但内容不是 Sena API JSON，域名可能没有把 $endpointPath 转发到服务端：$preview";
  }

  final preview = apiResponsePreview(response.body);
  return "服务器返回 200，但不是 $expected 响应：$preview";
}

void checkResponse(
  http.Response response, {
  String fallbackMessage = "请求失败",
}) {
  if (response.statusCode >= 200 && response.statusCode < 300) return;

  final data = tryDecodeJsonMap(response.body);
  final detail = data?["detail"];
  if (detail != null && detail.toString().trim().isNotEmpty) {
    throw ApiResponseException(detail.toString());
  }

  throw ApiResponseException(
    "$fallbackMessage：" +
        describeUnexpectedApiResponse(
          response,
          expected: fallbackMessage,
        ),
  );
}

String? serverOrigin(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final uri = Uri.parse(value);
    if ((uri.scheme != "http" && uri.scheme != "https") ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port < 1 ||
        uri.port > 65535) return null;
    return Uri(scheme: uri.scheme, host: uri.host.toLowerCase(), port: uri.port)
        .toString();
  } on FormatException {
    return null;
  }
}

String serverEndpoint(String host, int port, bool useHttps) =>
    Uri(scheme: useHttps ? "https" : "http", host: host, port: port).toString();

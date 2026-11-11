import "dart:async";
import "dart:convert";
import "dart:io";

class CredentialSafeHttpClient implements HttpClient {
  final HttpClient _inner;
  CredentialSafeHttpClient(this._inner);

  Future<HttpClientRequest> _wrap(Future<HttpClientRequest> request) async =>
      _CredentialRequest(await request);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _wrap(_inner.open(method, host, port, path));
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(_inner.openUrl(method, url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrap(_inner.get(host, port, path));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _wrap(_inner.getUrl(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrap(_inner.post(host, port, path));
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _wrap(_inner.postUrl(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrap(_inner.put(host, port, path));
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _wrap(_inner.putUrl(url));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrap(_inner.delete(host, port, path));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _wrap(_inner.deleteUrl(url));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrap(_inner.patch(host, port, path));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _wrap(_inner.patchUrl(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrap(_inner.head(host, port, path));
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _wrap(_inner.headUrl(url));
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? callback) =>
      _inner.authenticate = callback;
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(Uri, String?, int?)?
              callback) =>
      _inner.connectionFactory = callback;
  @override
  set findProxy(String Function(Uri)? callback) => _inner.findProxy = callback;
  @override
  set authenticateProxy(
          Future<bool> Function(String, int, String, String?)? callback) =>
      _inner.authenticateProxy = callback;
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
          bool Function(X509Certificate, String, int)? callback) =>
      _inner.badCertificateCallback = (_, __, ___) => false;
  @override
  set keyLog(void Function(String)? callback) => _inner.keyLog = callback;
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _CredentialRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  bool _prepared = false;
  _CredentialRequest(this._inner);

  bool get _hasCredentials =>
      (_inner.headers[HttpHeaders.authorizationHeader]?.isNotEmpty ?? false) ||
      (_inner.headers[HttpHeaders.proxyAuthorizationHeader]?.isNotEmpty ??
          false);

  void _prepare() {
    if (_prepared) return;
    // Dart otherwise forwards Authorization to some different-origin subdomains.
    if (_hasCredentials) _inner.followRedirects = false;
    _prepared = true;
  }

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) =>
      _inner.followRedirects = _hasCredentials ? false : value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  Future<HttpClientResponse> get done {
    _prepare();
    return _inner.done;
  }

  @override
  Future<HttpClientResponse> close() {
    _prepare();
    return _inner.close();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) {
    _prepare();
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _prepare();
    return _inner.addStream(stream);
  }

  @override
  Future<void> flush() {
    _prepare();
    return _inner.flush();
  }

  @override
  void write(Object? object) {
    _prepare();
    _inner.write(object);
  }

  @override
  void writeAll(Iterable objects, [String separator = ""]) {
    _prepare();
    _inner.writeAll(objects, separator);
  }

  @override
  void writeln([Object? object = ""]) {
    _prepare();
    _inner.writeln(object);
  }

  @override
  void writeCharCode(int charCode) {
    _prepare();
    _inner.writeCharCode(charCode);
  }
}

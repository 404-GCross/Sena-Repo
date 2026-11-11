import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:http/io_client.dart";
import "package:sena_repo/services/tls_policy.dart";

void main() {
  Directory? temporary;
  File? certificate;
  File? key;
  var opensslAvailable = false;

  setUpAll(() async {
    try {
      opensslAvailable =
          (await Process.run("openssl", ["version"])).exitCode == 0;
    } on ProcessException {
      return;
    }
    if (!opensslAvailable) return;
    temporary = await Directory.systemTemp.createTemp("sena-tls-test-");
    certificate = File("${temporary!.path}/localhost.pem");
    key = File("${temporary!.path}/localhost-key.pem");
    final result = await Process.run("openssl", [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=localhost",
      "-addext",
      "subjectAltName=DNS:localhost",
      "-keyout",
      key!.path,
      "-out",
      certificate!.path,
    ]);
    expect(result.exitCode, 0,
        reason: "Could not create ephemeral local TLS fixture");
  });

  tearDownAll(() async {
    final dir = temporary;
    if (dir != null) {
      expect(await dir.resolveSymbolicLinks(), dir.absolute.path);
      expect(dir.uri.pathSegments.where((part) => part.isNotEmpty).last,
          startsWith("sena-tls-test-"));
      await dir.delete(recursive: true);
    }
  });

  Future<HttpServer> server() async {
    final context = SecurityContext()
      ..useCertificateChain(certificate!.path)
      ..usePrivateKey(key!.path);
    final instance =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    instance.listen((request) {
      request.response.write("ok");
      request.response.close();
    }, onError: (Object _) {});
    addTearDown(() => instance.close(force: true));
    return instance;
  }

  test("untrusted self-signed certificate is rejected", () async {
    if (!opensslAvailable) {
      markTestSkipped("openssl is required for an ephemeral TLS fixture");
      return;
    }
    final endpoint = await server();
    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      try {
        await expectLater(
            client.getUrl(Uri.parse("https://localhost:${endpoint.port}")),
            throwsA(isA<HandshakeException>()));
      } finally {
        client.close(force: true);
      }
    }, StrictCertificatePolicy());
  });

  test("explicitly trusted valid certificate remains usable", () async {
    if (!opensslAvailable) {
      markTestSkipped("openssl is required for an ephemeral TLS fixture");
      return;
    }
    final endpoint = await server();
    await HttpOverrides.runWithHttpOverrides(() async {
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(certificate!.path);
      final client = HttpClient(context: context);
      try {
        final request = await client
            .getUrl(Uri.parse("https://localhost:${endpoint.port}"));
        final response = await request.close();
        expect(await utf8.decodeStream(response), "ok");
      } finally {
        client.close(force: true);
      }
    }, StrictCertificatePolicy());
  });

  test("even a trusted certificate must match the requested hostname",
      () async {
    if (!opensslAvailable) {
      markTestSkipped("openssl is required for an ephemeral TLS fixture");
      return;
    }
    final endpoint = await server();
    await HttpOverrides.runWithHttpOverrides(() async {
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(certificate!.path);
      final client = HttpClient(context: context);
      try {
        await expectLater(
            client.getUrl(Uri.parse("https://127.0.0.1:${endpoint.port}")),
            throwsA(isA<HandshakeException>()));
      } finally {
        client.close(force: true);
      }
    }, StrictCertificatePolicy());
  });

  test("authenticated API and media requests never auto-forward to a subdomain",
      () async {
    var targets = 0;
    final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == "/start") {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader,
            "http://cdn.parent.test:${endpoint.port}/target");
      } else {
        targets++;
        expect(request.headers[HttpHeaders.authorizationHeader], isNull);
        request.response.write("ok");
      }
      await request.response.close();
    });
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        final native = HttpClient()
          ..connectionFactory = (uri, host, port) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, endpoint.port);
        final client = IOClient(native);
        final uri = Uri.parse("http://parent.test:${endpoint.port}/start");
        try {
          final response = await client
              .get(uri, headers: {"Authorization": "Bearer test-token"});
          expect(response.statusCode, HttpStatus.found);
          expect(targets, 0);
          final media = await native.getUrl(uri);
          media.headers
              .set(HttpHeaders.authorizationHeader, "Bearer test-token");
          final mediaResponse = await media.close();
          await mediaResponse.drain<void>();
          expect(mediaResponse.statusCode, HttpStatus.found);
          expect(targets, 0);
          final public = await client.get(uri);
          expect(public.statusCode, 200);
          expect(targets, 1);
        } finally {
          client.close();
        }
      }, StrictCertificatePolicy());
    } finally {
      await endpoint.close(force: true);
    }
  });

  test("aria2 never disables verification when its CA bundle is missing", () {
    expect(aria2CertificateArguments(null), ["--check-certificate=true"]);
    expect(aria2CertificateArguments("test-ca.pem"),
        ["--check-certificate=true", "--ca-certificate=test-ca.pem"]);
  });
}

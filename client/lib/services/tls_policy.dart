import "dart:io";
import "credential_http_client.dart";

class StrictCertificatePolicy extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      CredentialSafeHttpClient(super.createHttpClient(context)
        ..badCertificateCallback = (_, __, ___) => false);
}

List<String> aria2CertificateArguments(String? caCertificate) => [
      "--check-certificate=true",
      if (caCertificate != null) "--ca-certificate=$caCertificate",
    ];

import "dart:async";

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._();
  factory DeepLinkService() => _instance;
  DeepLinkService._();

  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  final List<Uri> _pending = [];

  Stream<Uri> get uriStream => _controller.stream;

  void publish(Uri uri) {
    if (!isSupportedUri(uri)) return;
    if (!_controller.hasListener) {
      _pending.add(uri);
    }
    _controller.add(uri);
  }

  List<Uri> takePending() {
    final values = List<Uri>.from(_pending);
    _pending.clear();
    return values;
  }

  static Uri? firstSupportedUri(Iterable<String> args) {
    for (final arg in args) {
      final uri = Uri.tryParse(arg);
      if (uri != null && isSupportedUri(uri)) {
        return uri;
      }
    }
    return null;
  }

  static bool isSupportedUri(Uri uri) =>
      uri.scheme == "com.github.senarepo" &&
      uri.path == "/oauth/hikarinagi";
}

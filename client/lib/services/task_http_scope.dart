import 'package:http/http.dart' as http;

/// Top-level HTTP helpers close their temporary client after every request.
/// The search dialog owns the actual transport until the operation ends.
class TaskHttpScope extends http.BaseClient {
  final _transport = http.Client();
  bool _stopped = false;

  Future<T> run<T>(Future<T> Function() work) =>
      http.runWithClient(work, () => this);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_stopped) throw http.ClientException('任务已停止');
    return _transport.send(request);
  }

  void stop() {
    _stopped = true;
    _transport.close();
  }
}

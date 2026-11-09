import "dart:async";
import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:sena_repo/services/api_client.dart";
import "package:sena_repo/services/steam_service.dart";

List<String> requestIds(http.Request request) =>
    List<String>.from((jsonDecode(request.body) as Map)["appids"] as List);

http.Response namesResponse(List<String> ids) => http.Response(
      jsonEncode({for (final id in ids) id: "Game $id"}),
      200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("250 IDs are sent sequentially in batches of 100, 100 and 50", () async {
    final batches = <List<String>>[];
    var active = 0;
    var peak = 0;
    final ids = List.generate(250, (index) => "${index + 1}");
    final result = await http.runWithClient(
      () => SteamService.resolveGameNames(ApiClient(), ids),
      () => MockClient((request) async {
        active++;
        if (active > peak) peak = active;
        expect(request.method, "POST");
        expect(request.url.path, "/api/steam/game-names");
        final batch = requestIds(request);
        batches.add(batch);
        await Future<void>.value();
        active--;
        return namesResponse(batch);
      }),
    );
    expect(batches.map((batch) => batch.length), [100, 100, 50]);
    expect(batches.expand((batch) => batch), ids);
    expect(peak, 1);
    expect(result.length, 250);
    expect(result["250"], "Game 250");
  });

  test("invalid IDs are filtered and duplicates preserve first-seen order", () async {
    final result = await http.runWithClient(
      () => SteamService.resolveGameNames(ApiClient(), [
        "2", "1", "2", "0", "01", "-1", " 1", "1 ", "1\n", "１２",
        "1&l=english", "", "4294967296", "12345678901", "4294967295",
      ]),
      () => MockClient((request) async {
        final ids = requestIds(request);
        expect(ids, ["2", "1", "4294967295"]);
        return namesResponse(ids);
      }),
    );
    expect(result.keys, ["2", "1", "4294967295"]);
  });

  test("empty or entirely invalid lists make no request", () async {
    for (final ids in <List<String>>[[], ["0", "invalid"]]) {
      final result = await http.runWithClient(
        () => SteamService.resolveGameNames(ApiClient(), ids),
        () => MockClient((request) async => throw StateError("unexpected HTTP request")),
      );
      expect(result, isEmpty);
    }
  });

  for (final status in [401, 403, 422, 429, 502]) {
    test("HTTP $status stops further batches without discarding prior names", () async {
      var calls = 0;
      final result = await http.runWithClient(
        () => SteamService.resolveGameNames(
          ApiClient(), List.generate(250, (index) => "${index + 1}"),
        ),
        () => MockClient((request) async {
          calls++;
          return calls == 1
              ? namesResponse(requestIds(request))
              : http.Response("failure", status, headers: {"Retry-After": "60"});
        }),
      );
      expect(calls, 2);
      expect(result.length, 100);
      expect(result["100"], "Game 100");
      expect(result.containsKey("101"), isFalse);
    });
  }

  test("network failures preserve prior results and stop remaining batches", () async {
    var calls = 0;
    final result = await http.runWithClient(
      () => SteamService.resolveGameNames(
        ApiClient(), List.generate(250, (index) => "${index + 1}"),
      ),
      () => MockClient((request) async {
        calls++;
        if (calls == 2) throw http.ClientException("simulated network failure");
        return namesResponse(requestIds(request));
      }),
    );
    expect(calls, 2);
    expect(result.length, 100);
  });

  test("invalid response values cannot partially corrupt the merged result", () async {
    var calls = 0;
    final result = await http.runWithClient(
      () => SteamService.resolveGameNames(
        ApiClient(), List.generate(250, (index) => "${index + 1}"),
      ),
      () => MockClient((request) async {
        calls++;
        return calls == 1
            ? namesResponse(requestIds(request))
            : http.Response('{"101":"valid","102":123}', 200);
      }),
    );
    expect(calls, 2);
    expect(result.length, 100);
  });

  test("missing, empty and unsolicited names do not overwrite game names", () async {
    final result = await http.runWithClient(
      () => SteamService.resolveGameNames(ApiClient(), ["1", "2", "3"]),
      () => MockClient((request) async => http.Response(
        '{"1":"Name","2":"  ","999":"Unsolicited"}', 200,
      )),
    );
    expect(result, {"1": "Name"});
  });

  testWidgets("65 second timeout preserves earlier batch without a real wait", (tester) async {
    final delayed = Completer<http.Response>();
    var calls = 0;
    var completed = false;
    final future = http.runWithClient(
      () => SteamService.resolveGameNames(
        ApiClient(), List.generate(250, (index) => "${index + 1}"),
      ),
      () => MockClient((request) async {
        calls++;
        if (calls == 2) return delayed.future;
        return namesResponse(requestIds(request));
      }),
    );
    future.then((_) => completed = true);
    await tester.pump();
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 64));
    expect(completed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, isTrue);
    expect((await future).length, 100);
    expect(calls, 2);
    delayed.complete(http.Response("{}", 200));
    await tester.pump();
  });
}

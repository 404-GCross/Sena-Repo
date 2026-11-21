import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/models/game.dart';
import 'package:sena_repo/providers/settings_provider.dart';
import 'package:sena_repo/services/api_client.dart';
import 'package:sena_repo/services/tls_policy.dart';
import 'package:sena_repo/widgets/game_grid.dart';
import 'package:sena_repo/widgets/game_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late HttpClient client;
  late String origin;
  final requests = <Uri>[];
  final bytes = base64Decode(
    'UklGRhwAAABXRUJQVlA4TA8AAAAvB8ACAAcQ0f/+ByKi/wEA',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = StrictCertificatePolicy().createHttpClient(null);
    origin = 'http://127.0.0.1:${server.port}';
    await ApiClient.persistSessionInfo(
      serverBaseUrl: origin,
      accessToken: 'fixture',
    );
    requests.clear();
    server.listen((request) async {
      requests.add(request.uri);
      request.response.persistentConnection = false;
      if (request.headers.value('authorization') != 'Bearer fixture') {
        request.response.statusCode = 401;
      } else {
        // Older servers serve upstream WebP bytes under a .jpg filename.
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(bytes);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await ApiClient.clearTokens();
  });

  for (final grid in [true, false]) {
    testWidgets(
      'Android ${grid ? 'grid' : 'list'} displays a protected thumbnail without disk cache',
      (tester) async {
        final games = List.generate(
          287,
          (id) => GameSummary.fromJson({
            'id': id,
            'name': 'Game $id',
            'imported_at': 'before',
            'cover_revision': 'after',
            if (id == 0) 'cover_path': r'C:\covers\海报 #1.jpg',
          }),
        );
        debugNetworkImageHttpClientProvider = () => client;
        try {
          await tester.pumpWidget(
            ChangeNotifierProvider(
              create: (_) => SettingsProvider(),
              child: MaterialApp(
                home: Scaffold(
                  body: grid
                      ? GameGrid(
                          games: games,
                          coverBaseUrl: origin,
                          onTap: (_) {},
                        )
                      : GameList(
                          games: games,
                          coverBaseUrl: origin,
                          onTap: (_) {},
                        ),
                ),
              ),
            ),
          );
          expect(find.text('Game 286', skipOffstage: false), findsNothing);
          for (
            var i = 0;
            i < 200 && find.byType(RawImage).evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
          expect(requests.single.pathSegments, [
            'api',
            'files',
            'covers',
            '海报 #1.jpg',
          ]);
          expect(requests.single.queryParameters['t'], 'after');
        } finally {
          debugNetworkImageHttpClientProvider = null;
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}

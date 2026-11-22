import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/models/game.dart';
import 'package:sena_repo/providers/game_provider.dart';
import 'package:sena_repo/providers/settings_provider.dart';
import 'package:sena_repo/providers/theme_provider.dart';
import 'package:sena_repo/screens/game_edit_screen.dart';
import 'package:sena_repo/screens/home_screen.dart';
import 'package:sena_repo/services/api_client.dart';
import 'package:sena_repo/widgets/new_game_dialog.dart';

const origin = 'https://metadata.test';
http.Response mode(List<String> enabled) =>
    http.Response(jsonEncode({'enabled_scrapers': enabled}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'enabled_scrapers::$origin': '["steam"]',
    });
    FlutterSecureStorage.setMockInitialValues({});
    await ApiClient.clearTokens();
    await ApiClient.persistSessionInfo(
      accessToken: 'fixture',
      serverBaseUrl: origin,
    );
  });
  tearDown(ApiClient.clearTokens);

  Future<GameProvider> editor(
    WidgetTester tester,
    MockClientHandler handle,
  ) async {
    final provider = http.runWithClient(
      GameProvider.new,
      () => MockClient(handle),
    );
    await provider.api.connect('metadata.test', port: 443, useHttps: true);
    tester.view.physicalSize = const Size(450, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          home: GameEditScreen(
            game: GameDetail.fromJson({'id': 1, 'name': ''}),
          ),
        ),
      ),
    );
    return provider;
  }

  testWidgets(
    'first tap after login waits for current mode; next opening sees reverse switch',
    (tester) async {
      final reply = Completer<http.Response>();
      var calls = 0;
      await editor(tester, (req) async {
        expect(req.url.path, '/api/settings/scraper');
        expect(req.headers['authorization'], 'Bearer fixture');
        return ++calls == 1 ? reply.future : mode(['steam']);
      });
      await tester.tap(find.text('下载元数据'));
      await tester.pump();
      await tester.tap(find.text('正在读取…'));
      expect(calls, 1);
      expect(find.text('选择元数据来源'), findsNothing);
      reply.complete(mode(['nextmoe']));
      await tester.pumpAndSettle();
      expect(find.text('搜索 NextMoe'), findsOneWidget);
      expect(find.text('选择元数据来源'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载元数据'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('4 个来源'), findsOneWidget);
    },
  );

  for (final error in ['network', 'timeout', 'invalid', 'unauthorized']) {
    testWidgets('editor rejects $error and allows a fresh retry', (
      tester,
    ) async {
      var calls = 0;
      await editor(tester, (_) async {
        if (++calls > 1) return mode(['nextmoe']);
        return switch (error) {
          'unauthorized' => http.Response('{}', 401),
          'invalid' => http.Response('{"enabled_scrapers":[null]}', 200),
          'timeout' => Completer<http.Response>().future,
          _ => throw http.ClientException('offline'),
        };
      });
      await tester.tap(find.text('下载元数据'));
      await tester.pump();
      if (error == 'timeout') await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(error == 'unauthorized' ? '登录已失效，请重新登录' : '无法读取刮削模式，请重试'),
        findsOneWidget,
      );
      expect(find.text('选择元数据来源'), findsNothing);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载元数据'));
      await tester.pumpAndSettle();
      expect(find.text('搜索 NextMoe'), findsOneWidget);
    });
  }

  for (final change in ['server', 'session']) {
    testWidgets('discard scraper reply for previous $change', (tester) async {
      final reply = Completer<http.Response>();
      final provider = await editor(tester, (_) => reply.future);
      await tester.tap(find.text('下载元数据'));
      await tester.pump();
      if (change == 'server') {
        await provider.api.connect('other.test');
      } else {
        await tester.runAsync(ApiClient.clearTokens);
      }
      reply.complete(mode(['nextmoe']));
      await tester.pumpAndSettle();
      expect(find.text('搜索 NextMoe'), findsNothing);
      expect(find.text('选择元数据来源'), findsNothing);
      expect(find.text('下载元数据'), findsOneWidget);
    });
  }

  testWidgets('new entry auto-search waits for mode and uses only NextMoe', (
    tester,
  ) async {
    final reply = Completer<http.Response>();
    final searches = <String?>[];
    final api = http.runWithClient(
      ApiClient.new,
      () => MockClient((req) async {
        if (req.url.path == '/api/settings/scraper') return reply.future;
        expect(req.url.path, '/api/scrape/search');
        searches.add(req.url.queryParameters['source']);
        return http.Response('{"results":[]}', 200);
      }),
    );
    await api.connect('metadata.test', port: 443, useHttps: true);
    await tester.pumpWidget(
      MaterialApp(
        home: NewGameDialog(api: api, initialQuery: 'Fixture', title: '新建条目'),
      ),
    );
    await tester.pump();
    expect(searches, isEmpty);
    expect(find.text('Hikarinagi'), findsNothing);
    reply.complete(mode(['nextmoe']));
    await tester.pumpAndSettle();
    expect(searches, ['nextmoe']);
  });

  testWidgets('batch submits only NextMoe from the live mode', (tester) async {
    final reply = Completer<http.Response>();
    Map<String, dynamic>? submitted;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_admin', true);
    await http.runWithClient(
      () async {
        final provider = GameProvider();
        await provider.api.connect('metadata.test', port: 443, useHttps: true);
        await provider.loadGames();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: provider),
              ChangeNotifierProvider(create: (_) => ThemeProvider()),
              ChangeNotifierProvider(create: (_) => SettingsProvider()),
            ],
            child: const MaterialApp(home: HomeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('多选'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fixture').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('刮削'));
        await tester.pump();
        expect(find.text('批量刮削'), findsNothing);
        reply.complete(mode(['nextmoe']));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsOneWidget);
        expect(find.text('NextMoe'), findsOneWidget);
        await tester.tap(find.text('开始刮削'));
        await tester.pumpAndSettle();
        expect(submitted?['sources'], ['nextmoe']);
        expect(submitted?['game_ids'], [1]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
      },
      () => MockClient((req) async {
        if (req.url.path == '/api/games' &&
            req.url.queryParameters['page'] == '1') {
          return http.Response('[{"id":1,"name":"Fixture"}]', 200);
        }
        if (req.url.path == '/api/settings/scraper') return reply.future;
        if (req.url.path == '/api/agent/settings') {
          return http.Response('{"game_ask":false}', 200);
        }
        if (req.url.path == '/api/scrape/batch') {
          submitted = jsonDecode(req.body);
          return http.Response('{"job_id":1}', 200);
        }
        return http.Response('[]', 200);
      }),
    );
  });
}

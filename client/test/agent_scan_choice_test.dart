import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/screens/agent_screen.dart';
import 'package:sena_repo/services/api_client.dart';
import 'package:sena_repo/services/agent_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('agent settings cannot cross a server switch', () async {
    final api = ApiClient();
    await api.connect('server-a.invalid');
    final service = AgentService(api);
    await api.connect('server-b.invalid');
    var requests = 0;
    await http.runWithClient(() async {
      await expectLater(service.settings(), throwsA(isA<AuthException>()));
      expect(requests, 0);
    },
        () => MockClient((_) async {
              requests++;
              return http.Response('{}', 200);
            }));
  });

  testWidgets(
      'manual scan asks once and persists choice separately for patches',
      (tester) async {
    final api = ApiClient();
    await api.connect('localhost');
    final config = <String, dynamic>{
      'enabled': true,
      'model': 'test',
      'patch_ask': true,
      'patch_default': 'regular',
      'game_ask': true,
      'game_default': 'regular'
    };
    String? chosen;
    final mock = MockClient((request) async {
      if (request.method == 'PUT') {
        config.addAll(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return http.Response(jsonEncode(config), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        chosen = await chooseScanMode(context, api, 'patch');
                      },
                      child: const Text('Scan'))))));
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      expect(find.text('选择补丁扫描方式'), findsOneWidget);
      await tester.tap(find.text('智能体扫描'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记住此选择，下次不再询问'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始扫描'));
      await tester.pumpAndSettle();
      expect(chosen, 'agent');
      expect(config['patch_ask'], false);
      expect(config['game_ask'], true);
      chosen = null;
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      expect(find.text('选择补丁扫描方式'), findsNothing);
      expect(chosen, 'agent');
    }, () => mock);
  });

  testWidgets('disabled agent falls back without turning itself on',
      (tester) async {
    final api = ApiClient();
    await api.connect('localhost');
    String? chosen;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        chosen = await chooseScanMode(context, api, 'game');
                      },
                      child: const Text('Scan'))))));
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      expect(chosen, 'regular');
      expect(find.text('智能体已关闭或未配置，本次使用常规扫描'), findsOneWidget);
    },
        () => MockClient((_) async => http.Response(
            jsonEncode({
              'enabled': false,
              'model': 'test',
              'game_ask': false,
              'game_default': 'agent'
            }),
            200)));
  });

  testWidgets('cancel does not persist a scan preference', (tester) async {
    final api = ApiClient();
    await api.connect('localhost');
    final methods = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => chooseScanMode(context, api, 'game'),
                      child: const Text('Scan'))))));
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(methods, ['GET']);
    },
        () => MockClient((r) async {
              methods.add(r.method);
              return http.Response(
                  jsonEncode({
                    'enabled': false,
                    'game_ask': true,
                    'game_default': 'regular'
                  }),
                  200);
            }));
  });
}

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/services/api_client.dart';
import 'package:sena_repo/widgets/agent_scan_progress.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [370.0, 900.0]) {
    testWidgets(
      'stop from the progress card at width $width targets one job and waits for acknowledgement',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final api = ApiClient();
        await api.connect('localhost');
        final reply = Completer<void>();
        final posted = <String>[];
        var status = 'running';
        Map<String, dynamic> job() => {
          'id': 58,
          'kind': 'game',
          'status': status,
          'message': '处理中',
          'calls': 1,
          'tokens': 2,
        };
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(body: AgentScanProgress(api: api)),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tap(find.text('停止任务'));
            await tester.pump();
            expect(find.text('正在停止…'), findsOneWidget);
            await tester.tap(find.text('正在停止…'));
            await tester.pump();
            status = 'stopping';
            reply.complete();
            await tester.pump();
            expect(posted, ['/api/agent/jobs/58/cancel']);
            status = 'cancelled';
            await tester.pump(const Duration(seconds: 3));
            await tester.pump();
            expect(find.text('智能体游戏扫描 · 已停止'), findsOneWidget);
            expect(find.text('停止任务'), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          () => MockClient((request) async {
            if (request.method == 'POST') {
              posted.add(request.url.path);
              await reply.future;
            }
            return http.Response(
              jsonEncode(request.method == 'POST' ? job() : [job()]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
      },
    );
  }

  testWidgets('scan progress reopens an existing job without starting a scan', (
    tester,
  ) async {
    final api = ApiClient();
    await api.connect('localhost');
    final requests = <String>[];
    final job = {
      'id': 37,
      'kind': 'game',
      'status': 'running',
      'calls': 3,
      'tokens': 1200,
      'message': '正在列举目录，发现 20 个候选文件',
    };
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AgentScanProgress(api: api)),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('智能体游戏扫描 · 进行中'), findsOneWidget);
        expect(find.text('正在列举目录，发现 20 个候选文件'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          isNull,
        );
        await tester.tap(find.text('查看详情'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('分析结果'), findsOneWidget);
        expect(requests, contains('GET /api/agent/jobs/37'));
        expect(requests.every((request) => request.startsWith('GET ')), true);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      () => MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        final Object result = request.url.path.endsWith('/37')
            ? {...job, 'results': [], 'counts': {}}
            : [job];
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });

  testWidgets(
    'active task state refreshes and restores after leaving the page',
    (tester) async {
      final api = ApiClient();
      await api.connect('localhost');
      var status = 'running';
      final activity = <bool>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: AgentScanProgress(
                  api: api,
                  onActivityChanged: activity.add,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(activity, [true]);
          status = 'completed';
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          expect(activity, [true, false]);
          expect(find.text('智能体补丁扫描 · 已完成'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: AgentScanProgress(api: api)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('智能体补丁扫描 · 已完成'), findsOneWidget);
          expect(find.text('查看详情'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'id': 8,
                'kind': 'patch',
                'status': status,
                'calls': 4,
                'tokens': 500,
                'message': '补丁分析',
              },
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
    },
  );
}

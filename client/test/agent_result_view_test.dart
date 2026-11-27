import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/screens/agent_screen.dart';
import 'package:sena_repo/services/api_client.dart';

void main() {
  testWidgets(
    'result filters survive refresh and follow the final failed bucket',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient();
      await api.connect('localhost');
      var active = true;
      final requested = <String>[];
      final mock = MockClient((req) async {
        final filter = req.url.queryParameters['bucket'] ?? 'all';
        requested.add(filter);
        final bucket = !active && filter == 'scanning' ? 'failed' : filter;
        final rows = [
          if (active)
            {
              'key': '2',
              'name': '正在分析的游戏',
              'state': 'scanning',
              'brief': '校验封面',
              'records': [],
            },
          {
            'key': '3',
            'name': '缺图游戏',
            'state': 'failed',
            'brief': '未找到匹配封面',
            'records': [],
          },
          {
            'key': '1',
            'name': '横封游戏',
            'state': 'success',
            'brief': '已用横版封面',
            'records': [],
          },
        ];
        return http.Response(
          jsonEncode({
            'id': 7,
            'kind': 'scrape',
            'status': active ? 'running' : 'completed',
            'calls': 8,
            'tokens': 120,
            'message': '模型依据',
            'offset': 0,
            'page_size': 30,
            'has_more': false,
            'bucket': bucket,
            'item_total': active ? 3 : 2,
            'plan_known': true,
            'preparation_count': 0,
            'current_item': active
                ? {'kind': 'game', 'key': '2', 'name': '正在分析的游戏'}
                : null,
            'item_counts': {
              'success': 1,
              'failed': 1,
              if (active) 'scanning': 1,
            },
            'items': rows
                .where((r) => bucket == 'all' || r['state'] == bucket)
                .toList(),
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(home: AgentJobsScreen(api: api, jobId: 7)),
        );
        await tester.pumpAndSettle();
        expect(find.text('正在扫描：正在分析的游戏'), findsOneWidget);
        expect(find.text('已成功 1 项'), findsOneWidget);
        expect(find.textContaining('120 Token'), findsNothing);
        await tester.tap(find.text('成功 1'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        expect(requested.last, 'success');
        expect(find.text('横封游戏'), findsOneWidget);
        expect(find.text('缺图游戏'), findsNothing);
        await tester.tap(find.text('任务详情'));
        await tester.pumpAndSettle();
        expect(find.textContaining('120 Token'), findsOneWidget);
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('扫描中'));
        await tester.pumpAndSettle();
        active = false;
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('扫描中'), findsNothing);
        expect(find.text('缺图游戏'), findsOneWidget);
        expect(find.text('横封游戏'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => mock);
    },
  );
}

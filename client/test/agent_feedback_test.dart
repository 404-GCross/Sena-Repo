import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/screens/agent_screen.dart';
import 'package:sena_repo/services/api_client.dart';

const settings = {
  'enabled': true,
  'provider': 'openai',
  'protocol': 'responses',
  'base_url': 'http://127.0.0.1:7863/v1',
  'model': 'test-model',
  'proxy_mode': 'direct',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('previous successful discoveries are not labelled as failures',
      (tester) async {
    final api = ApiClient();
    await api.connect('localhost');
    final payload = {
      'status': 'completed', 'calls': 3, 'tokens': 500, 'message': '任务完成',
      'counts': {'identified': 1},
      'results': [{
        'id': 1, 'key': 'sample', 'status': 'identified',
        'summary': '智能识别 1 组；未确定内容交给常规扫描',
        'data': {'groups': [{'name': '示例游戏', 'source': 'steam', 'evidence': '资料已匹配'}]},
      }],
    };
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: AgentJobsScreen(api: api, jobId: 1)));
      await tester.pumpAndSettle();
      expect(find.text('已识别 1 组游戏'), findsOneWidget);
      expect(find.text('智能识别 1 组；未确定内容交给常规扫描'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => MockClient((_) async => http.Response(jsonEncode(payload), 200,
        headers: {'content-type': 'application/json; charset=utf-8'})));
  });

  testWidgets('model failure uses a dismissible dialog instead of a snackbar',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient();
    await api.connect('localhost');
    const detail = '模型服务请求失败（HTTP 404），请检查协议、凭据与模型 ID';
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: AgentScreen(api: api)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存并测试连接与工具调用'));
      await tester.tap(find.text('保存并测试连接与工具调用'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('操作失败'), findsOneWidget);
      expect(find.text(detail), findsOneWidget);
      expect(find.text('Exception: $detail'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final button = tester.widget<TextButton>(find.widgetWithText(
          TextButton, '保存并测试连接与工具调用'));
      expect(button.onPressed, isNotNull);
    }, () => MockClient((request) async {
          if (request.url.path.endsWith('/test')) {
            return http.Response(jsonEncode({'detail': detail}), 502,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return http.Response(jsonEncode(settings), 200);
        }));
  });

  testWidgets('setup waits for save feedback before leaving configuration',
      (tester) async {
    final api = ApiClient();
    await api.connect('localhost');
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
              builder: (_) => AgentScreen(api: api, setup: true),
            )),
            child: const Text('进入配置'),
          ),
        )),
      ));
      await tester.tap(find.text('进入配置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('保存并完成'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('保存并完成'));
      await tester.pumpAndSettle();
      expect(find.text('保存成功'), findsOneWidget);
      expect(find.byType(AgentScreen), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentScreen), findsNothing);
      expect(find.text('进入配置'), findsOneWidget);
    }, () => MockClient((_) async => http.Response(jsonEncode(settings), 200)));
  });
}

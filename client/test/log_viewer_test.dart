import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sena_repo/models/log_models.dart';
import 'package:sena_repo/providers/game_provider.dart';
import 'package:sena_repo/providers/theme_provider.dart';
import 'package:sena_repo/screens/log_screen.dart';
import 'package:sena_repo/services/api_client.dart';
import 'package:sena_repo/services/logger_service.dart';

const origin = 'https://logs.test';

LogViewerAccess access(
  String server,
  String account,
  String session, {
  bool admin = false,
}) => LogViewerAccess(
  serverKey: server,
  accountScope: account,
  sessionId: session,
  management: admin,
);

LogContext writer(LogViewerAccess a) => LogContext(
  serverKey: a.serverKey,
  accountScope: a.accountScope,
  sessionId: a.sessionId,
);

class MemoryLogs extends Fake implements LoggerService {
  static const file = LogFileInfo(
    path: 'fixture/2026-01-01.jsonl',
    name: '2026-01-01.jsonl',
    day: null,
    size: 100,
  );
  @override
  final storageStatus = ValueNotifier<String?>(null);
  final reads = <LogViewerAccess>[];
  Completer<void>? delayed;
  bool fail = false;

  @override
  Future<List<LogFileInfo>> listFiles(LogViewerAccess a) async => [file];
  @override
  Future<List<LogRecord>> readEntries(
    LogViewerAccess a,
    LogFileInfo file, {
    int limit = 500,
    DateTime? before,
  }) async {
    reads.add(a);
    final pending = delayed;
    delayed = null;
    if (pending != null) await pending.future;
    if (fail) throw const LogReadException('无法读取日志文件：应用存储不可用');
    return [
      LogRecord(
        timestamp: DateTime(2026),
        level: LogLevel.info,
        context: writer(a),
        visibility: LogVisibility.personal,
        module: 'fixture',
        event: 'read',
        message: 'personal-${a.accountScope}',
      ),
      if (a.management)
        LogRecord(
          timestamp: DateTime(2026),
          level: LogLevel.info,
          context: writer(a),
          visibility: LogVisibility.management,
          module: 'fixture',
          event: 'read',
          message: 'management detail',
        ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await ApiClient.clearTokens();
  });
  tearDown(ApiClient.clearTokens);

  test(
    'normal account sees pending and previous-session records but not management or other accounts/servers',
    () async {
      final root = await Directory.systemTemp.createTemp('sena-personal-logs-');
      addTearDown(() => root.delete(recursive: true));
      final logger = LoggerService.inDirectory(root);
      final current = access('serverA', 'accountA', 'new');
      for (final (a, message, visibility) in [
        (
          access('serverA', 'accountA', 'old'),
          'previous login',
          LogVisibility.personal,
        ),
        (
          access('serverA', 'accountB', 'old'),
          'other user',
          LogVisibility.personal,
        ),
        (
          access('serverB', 'accountA', 'old'),
          'other server',
          LogVisibility.personal,
        ),
        (current, 'admin only', LogVisibility.management),
        (
          access('serverA', 'accountA', 'old'),
          'old device session',
          LogVisibility.device,
        ),
        (current, 'new session', LogVisibility.personal),
      ]) {
        logger.setContext(writer(a));
        unawaited(
          logger.record(
            LogLevel.info,
            'operation',
            message,
            visibility: visibility,
          ),
        );
      }
      final files = await logger.listFiles(current);
      expect(files, hasLength(1));
      final records = await logger.readEntries(current, files.single);
      expect(
        records.map((r) => r.message),
        unorderedEquals(['previous login', 'new session']),
      );
      final exported = await logger.exportEntries(current);
      expect(exported, contains('previous login'));
      expect(exported, isNot(contains('admin only')));
      expect(
        (await logger.exportEntries(
          access('serverA', 'accountA', 'new', admin: true),
        )),
        contains('admin only'),
      );
    },
  );

  test(
    'missing account directory is empty; failed file reads are distinct and do not disclose its path',
    () async {
      final root = await Directory.systemTemp.createTemp('sena-read-failure-');
      addTearDown(() => root.delete(recursive: true));
      final logger = LoggerService.inDirectory(root),
          a = access('server', 'account', 'session');
      expect(await logger.listFiles(a), isEmpty);
      logger.setContext(writer(a));
      await logger.record(LogLevel.info, 'test', 'fixture');
      final file = (await logger.listFiles(a)).single;
      await File(file.path).delete();
      await expectLater(
        logger.readEntries(a, file),
        throwsA(
          isA<LogReadException>().having(
            (e) => e.message,
            'message',
            isNot(contains(root.path)),
          ),
        ),
      );
      final accountDir = Directory(file.path).parent;
      await accountDir.delete();
      await File(accountDir.path).writeAsString('not a directory');
      await expectLater(logger.listFiles(a), throwsA(isA<LogReadException>()));
    },
  );

  Future<void> signIn(int id, String account, bool admin) =>
      ApiClient.persistSessionInfo(
        serverBaseUrl: origin,
        accessToken: 'fixture-$id',
        userId: id,
        role: admin ? 'admin' : 'user',
        logScope: account,
      );

  test(
    'profile refresh restores missing scope and rejects a late reply from another server',
    () async {
      await ApiClient.persistSessionInfo(
        serverBaseUrl: origin,
        accessToken: 'fixture',
        userId: 1,
      );
      final reply = Completer<http.Response>();
      var calls = 0;
      final api = http.runWithClient(
        ApiClient.new,
        () => MockClient((req) async {
          expect(req.headers['authorization'], 'Bearer fixture');
          if (++calls == 2) return reply.future;
          return http.Response(
            '{"id":1,"role":"user","log_scope":"accountA"}',
            200,
          );
        }),
      );
      await api.connect('logs.test', port: 443, useHttps: true);
      expect(api.logViewerAccess, isNull);
      await api.refreshLogContext();
      final access = api.logViewerAccess!;
      expect(access.accountScope, 'accountA');
      final pending = api.refreshLogContext();
      await api.connect('other.test');
      reply.complete(
        http.Response('{"id":1,"role":"admin","log_scope":"old"}', 200),
      );
      await pending;
      expect(api.logViewerAccess, isNull);
      await api.connect('logs.test', port: 443, useHttps: true);
      expect(api.logViewerAccess, same(access));
    },
  );

  Future<GameProvider> screen(
    WidgetTester tester,
    MemoryLogs store,
    MockClientHandler handler,
  ) async {
    final provider = http.runWithClient(
      GameProvider.new,
      () => MockClient(handler),
    );
    await provider.api.connect('logs.test', port: 443, useHttps: true);
    tester.view.physicalSize = const Size(430, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(home: LogScreen(logger: store)),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets(
    'profile restoration wakes log page; refresh failure and no filter matches are distinct',
    (tester) async {
      await tester.runAsync(
        () => ApiClient.persistSessionInfo(
          serverBaseUrl: origin,
          accessToken: 'fixture',
          userId: 1,
        ),
      );
      var requests = 0;
      final response = Completer<http.Response>();
      final store = MemoryLogs()..fail = true;
      await screen(tester, store, (req) async {
        requests++;
        expect(req.url.path, '/api/auth/profile/me');
        return response.future;
      });
      expect(find.text('正在确认账号'), findsOneWidget);
      await activateLogContext(
        baseUrl: origin,
        profile: {'id': 1, 'role': 'user', 'log_scope': 'accountA'},
      );
      response.complete(http.Response('', 503));
      await tester.pumpAndSettle();
      expect(find.text('日志读取失败'), findsOneWidget);
      expect(find.text('当前账号暂无日志'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(requests, 1);
      store.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('personal-accountA'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'no such record');
      await tester.pumpAndSettle();
      expect(find.text('没有符合筛选条件的日志'), findsOneWidget);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(find.text('personal-accountA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'switching accounts discards delayed reads and closes old details; demotion removes management entries',
    (tester) async {
      await tester.runAsync(() => signIn(1, 'accountA', true));
      final store = MemoryLogs();
      await screen(
        tester,
        store,
        (_) => throw StateError('periodic reads must be local'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('management detail'));
      await tester.pumpAndSettle();
      expect(find.text('复制这条日志'), findsOneWidget);
      final delayed = Completer<void>();
      store.delayed = delayed;
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      await tester.runAsync(
        () => ApiClient.persistSessionInfo(
          serverBaseUrl: origin,
          userId: 1,
          role: 'user',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('management detail'), findsNothing);
      expect(find.text('复制这条日志'), findsNothing);
      await tester.runAsync(() => signIn(2, 'accountB', false));
      await tester.pumpAndSettle();
      delayed.complete();
      await tester.pump();
      expect(find.text('personal-accountA'), findsNothing);
      expect(find.text('personal-accountB'), findsOneWidget);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, contains('personal-accountB'));
      expect(copied, isNot(contains('accountA')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

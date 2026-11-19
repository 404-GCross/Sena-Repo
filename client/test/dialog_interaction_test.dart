import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sena_repo/widgets/app_dialog.dart';
import 'package:sena_repo/widgets/dialog_picker.dart';
import 'package:sena_repo/widgets/dialog_text_input.dart';
import 'package:sena_repo/widgets/patch_configuration_dialog.dart';

void main() {
  testWidgets('long executable paths stay distinct after filtering', (t) async {
    final paths = [
      '/game/play.exe',
      '/game/tools/play.exe',
      '/game/prefs.exe',
      '/game/update.exe',
    ];
    String? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await chooseExecutable(ctx, paths, '/game');
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'MISSING');
    await t.pump();
    expect(find.text('没有匹配的选项'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'TOOLS');
    await t.pump();
    expect(find.text('/game/tools/play.exe'), findsNothing);
    await t.tap(find.text('tools/play.exe'));
    await t.pumpAndSettle();
    expect(result, '/game/tools/play.exe');
  });

  testWidgets(
    'pending smart choice checks local source and cancel stays reachable in a short dark window',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(340, 320);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final state = Completer<String?>();
      PatchConfigurationMode? picked;
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                picked = await showDialog<PatchConfigurationMode>(
                  context: ctx,
                  builder: (_) => PatchConfigurationDialog(
                    game: 'DRACU-RIOT!',
                    appId: '1340140',
                    filename: List.filled(8, 'long-name_').join(),
                    unavailableReason: state.future,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(
        t.widget<DialogActionCard>(find.byType(DialogActionCard).first).onTap,
        isNull,
      );
      expect(find.text('检查中'), findsOneWidget);
      state.complete(null);
      await t.pumpAndSettle();
      expect(
        t.widget<DialogActionCard>(find.byType(DialogActionCard).first).onTap,
        isNotNull,
      );
      expect(find.textContaining('服务端读取本地补丁'), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(picked, isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Enter on an untouched destructive dialog cancels', (t) async {
    bool? confirmed;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              confirmed = await confirmDestructiveAction(
                ctx,
                section: '备份与恢复',
                title: '删除备份？',
                message: '不可撤销',
                item: 'archive.zip',
                action: '删除备份',
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(confirmed, isFalse);
  });

  testWidgets(
    'editing may save an empty label but cancelling never submits it',
    (t) async {
      String? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                result = await showDialogTextInput(
                  ctx,
                  section: '游戏编辑',
                  title: '编辑标签',
                  label: '标签名称',
                  hint: '留空可删除',
                  initial: '原标签',
                  allowEmpty: true,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextFormField), '');
      await t.pump();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(result, isNull);
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextFormField), '');
      await t.pump();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(result, '');
    },
  );
}

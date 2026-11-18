import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sena_repo/widgets/patch_configuration_dialog.dart';
import 'package:sena_repo/widgets/steam_patch_layout.dart';

void main() {
  testWidgets('short narrow window scrolls from library to last patch', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SteamPatchLayout(
            controls: const SizedBox(height: 380, child: Text('library')),
            results: (stacked) => Column(
              children: [
                Text('$stacked'),
                const SizedBox(height: 400),
                const Text('last'),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('last').hitTestable(), findsNothing);
    await tester.dragFrom(const Offset(120, 180), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('last').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing local directory disables smart only, manual keeps current game',
    (tester) async {
      PatchConfigurationMode? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('规则待配置'),
              onPressed: () async {
                selected = await showDialog<PatchConfigurationMode>(
                  context: context,
                  builder: (_) => PatchConfigurationDialog(
                    game: 'DRACU-RIOT!',
                    appId: '1340140',
                    filename: 'sample.zip',
                    unavailableReason: Future.value('本地目录不可读'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('规则待配置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1340140'), findsOneWidget);
      await tester.tap(find.text('智能配置'));
      await tester.pumpAndSettle();
      expect(find.text('手动配置'), findsOneWidget);
      await tester.tap(find.text('手动配置'));
      await tester.pumpAndSettle();
      expect(selected, PatchConfigurationMode.manual);
    },
  );
}

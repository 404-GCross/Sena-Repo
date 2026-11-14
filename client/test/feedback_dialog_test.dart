import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sena_repo/widgets/feedback_dialog.dart';

void main() {
  testWidgets('long feedback remains readable and waits for dismissal', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final message = List.generate(80, (i) => '第 $i 项处理失败，请检查服务连接。').join('\n');
    var finished = false;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        await showFeedbackDialog(context, 'Exception: $message', error: true);
        finished = true;
      }, child: const Text('执行')),
    ))));
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('操作失败'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(finished, false);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(finished, true);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('feedback from a disposed screen is ignored', (tester) async {
    late BuildContext oldContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      oldContext = context;
      return const SizedBox();
    })));
    await tester.pumpWidget(const SizedBox());
    await showFeedbackDialog(oldContext, '已完成');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });
}

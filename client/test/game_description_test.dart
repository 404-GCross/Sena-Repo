import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:sena_repo/utils/description_markdown.dart";
import "package:sena_repo/widgets/game_description.dart";

String renderedDescription(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((widget) => widget.data ?? widget.textSpan!.toPlainText())
    .join("\n");

void main() {
  test(
    "previews preserve words and remove formatting without joining paragraphs",
    () {
      expect(
        descriptionPreview(
          "# 简介\n\n**新的春天**<br />校园故事\\\n开始。\n\n"
          "<BR/>\n\n- 第一章\n- [第二章](https://example.com)\n\nA &amp; B",
        ),
        "简介 新的春天 校园故事 开始。 第一章 第二章 A & B",
      );
      expect(descriptionPreview("**你好🌸世界**", maxLength: 3), "你好🌸...");
    },
  );

  test("literal markup in code and escaped text remains literal", () {
    expect(
      descriptionPreview("`<br />`\n\n```text\n<br>\n```\n\n\\<br />"),
      "<br /> <br> <br />",
    );
    expect(
      descriptionPreview(r"文件在 C:\Games\story.zip"),
      r"文件在 C:\Games\story.zip",
    );
  });

  for (final width in [360.0, 1024.0]) {
    testWidgets("mixed source descriptions render at width $width", (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: GameDescription(
                description:
                    "# 故事介绍\n\n**国见洸太郎**就读于御影之丘学园。\n\n"
                    "<br />\n\n他在文艺部进行活动。\\\n他有一个写不出来的故事。\n\n"
                    "<BR/>\n\n新的春天。<br>新的相遇。\n下一行。\n\n- 校园\n- 恋爱",
                style: TextStyle(
                  fontSize: 15,
                  height: 1.7,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      final text = renderedDescription(tester);
      expect(text, contains("故事介绍"));
      expect(text, contains("国见洸太郎就读于御影之丘学园。"));
      expect(text, contains("活动。\n他有一个"));
      expect(text, contains("新的春天。\n新的相遇。\n下一行。"));
      expect(text, contains("校园"));
      expect(text, isNot(contains("<br")));
      expect(text, isNot(contains("<BR")));
      expect(text, isNot(contains("\\")));
      expect(text, isNot(contains("**")));
      final spans = <TextSpan>[];
      for (final widget in tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      )) {
        widget.textSpan!.visitChildren((span) {
          if (span is TextSpan) spans.add(span);
          return true;
        });
      }
      expect(
        spans.any(
          (span) =>
              span.text == "国见洸太郎" && span.style?.fontWeight == FontWeight.bold,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("literal code and empty descriptions render correctly", (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              GameDescription(description: "`<br />`\n\n```text\n<br>\n```"),
              GameDescription(description: " \n "),
              GameDescription(description: null, emptyText: "(空)"),
            ],
          ),
        ),
      ),
    );
    expect(renderedDescription(tester), contains("<br />"));
    expect(renderedDescription(tester), contains("<br>"));
    expect(find.text("暂无简介"), findsOneWidget);
    expect(find.text("(空)"), findsOneWidget);
  });

  testWidgets("description images use their text instead of loading resources", (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GameDescription(
            description:
                "![插图](https://example.com/cover.jpg)\n\n![本地图片](file:///private/image.png)",
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text("插图"), findsOneWidget);
    expect(find.text("本地图片"), findsOneWidget);
  });

  testWidgets("web links open externally and unsupported schemes show a dialog", (
    tester,
  ) async {
    const channel = MethodChannel("plugins.flutter.io/url_launcher");
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GameDescription(
            description:
                "[官网](https://example.com/story)\n\n[本地链接](file:///private/image.png)",
          ),
        ),
      ),
    );
    await tester.tap(find.text("官网", findRichText: true));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.arguments["url"], "https://example.com/story");
    await tester.tap(find.text("本地链接", findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text("此链接暂不支持打开"), findsOneWidget);
    expect(calls, hasLength(1));
    await tester.tap(find.text("确定"));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}

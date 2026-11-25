import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sena_repo/providers/game_provider.dart";
import "package:sena_repo/providers/theme_provider.dart";
import "package:sena_repo/screens/platform_categories_screen.dart";
import "package:sena_repo/services/api_client.dart";

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test("fallback platform list uses PC and omits the legacy category", () {
    final provider = GameProvider();
    addTearDown(provider.dispose);
    expect(provider.platforms.map((item) => item.name), [
      "PC",
      "手机模拟器",
      "安卓直装",
      "iOS",
    ]);
    expect(provider.platforms.first.isSystem, isTrue);
  });

  testWidgets(
    "default PC keeps its rule editor without rename or delete actions",
    (tester) async {
      const categories = [
        {
          "id": 1,
          "name": "PC",
          "is_system": true,
          "sort_order": 0,
          "version_count": 2,
          "rules": [
            {
              "id": 10,
              "kind": "keyword",
              "pattern": "desktop",
              "sort_order": 0,
            },
          ],
        },
        {
          "id": 2,
          "name": "手机模拟器",
          "is_system": false,
          "sort_order": 1,
          "version_count": 1,
          "rules": [],
        },
      ];
      await http.runWithClient(
        () async {
          final api = ApiClient();
          await api.connect("localhost");
          await tester.pumpWidget(
            ChangeNotifierProvider(
              create: (_) => ThemeProvider(),
              child: MaterialApp(home: PlatformCategoriesScreen(api: api)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text("未分类"), findsNothing);
          expect(find.textContaining("未命中规则时默认归入 PC"), findsOneWidget);
          final pcTile = find.ancestor(
            of: find.text("PC"),
            matching: find.byType(ListTile),
          );
          await tester.tap(
            find.descendant(
              of: pcTile,
              matching: find.byType(PopupMenuButton<String>),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text("匹配规则"), findsOneWidget);
          expect(find.text("重命名"), findsNothing);
          expect(find.text("删除"), findsNothing);
          await tester.tap(find.text("匹配规则"));
          await tester.pumpAndSettle();
          expect(find.byType(PlatformRulesScreen), findsOneWidget);
          expect(find.text("desktop"), findsOneWidget);
          expect(find.byType(FloatingActionButton), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode(categories),
            200,
            headers: {"content-type": "application/json; charset=utf-8"},
          ),
        ),
      );
    },
  );
}

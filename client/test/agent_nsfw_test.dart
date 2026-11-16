import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sena_repo/models/game.dart";
import "package:sena_repo/providers/game_provider.dart";
import "package:sena_repo/providers/settings_provider.dart";
import "package:sena_repo/providers/theme_provider.dart";
import "package:sena_repo/screens/agent_screen.dart";
import "package:sena_repo/screens/game_edit_screen.dart";
import "package:sena_repo/services/api_client.dart";

Finder switchFor(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets("image NSFW setting requires vision and turns off with vision", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var settings = <String, dynamic>{
      "enabled": true,
      "provider": "openai",
      "protocol": "chat",
      "base_url": "https://model.example/v1",
      "model": "vision-test",
      "proxy_mode": "direct",
      "vision": false,
    };
    await http.runWithClient(
      () async {
        final api = ApiClient();
        await api.connect("localhost");
        await tester.pumpWidget(MaterialApp(home: AgentScreen(api: api)));
        await tester.pumpAndSettle();
        await tester.tap(find.text("游戏偏好"));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(switchFor("自动识别图片 NSFW")).onChanged,
          isNull,
        );
        await tester.tap(find.text("模型与代理"));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text("允许图片分析"));
        await tester.tap(find.text("允许图片分析"));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text("游戏偏好"));
        await tester.tap(find.text("游戏偏好"));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text("自动识别图片 NSFW"));
        await tester.tap(find.text("自动识别图片 NSFW"));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(switchFor("自动识别图片 NSFW")).value,
          isTrue,
        );
        await tester.ensureVisible(find.text("模型与代理"));
        await tester.tap(find.text("模型与代理"));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text("允许图片分析"));
        await tester.tap(find.text("允许图片分析"));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text("游戏偏好"));
        await tester.tap(find.text("游戏偏好"));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(switchFor("自动识别图片 NSFW")).value,
          isFalse,
        );
        await tester.ensureVisible(find.text("保存设置"));
        await tester.tap(find.text("保存设置"));
        await tester.pumpAndSettle();
        expect(settings["image_nsfw"], isFalse);
        expect(settings["vision"], isFalse);
        await tester.tap(find.text("确定"));
        await tester.pumpAndSettle();
      },
      () => MockClient((request) async {
        if (request.method == "PUT") {
          settings = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        }
        return http.Response(
          jsonEncode(settings),
          200,
          headers: {"content-type": "application/json; charset=utf-8"},
        );
      }),
    );
  });

  for (final action in ["unchanged", "manual_off", "allow_auto"]) {
    testWidgets("game editor saves NSFW intent correctly: $action", (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      await http.runWithClient(
        () async {
          final provider = GameProvider();
          await provider.api.connect("localhost");
          final game = GameDetail.fromJson({
            "id": 1,
            "name": "Test Game",
            "nsfw_manual": action == "allow_auto",
            "description": "Original description",
          });
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => provider),
                ChangeNotifierProvider(create: (_) => ThemeProvider()),
                ChangeNotifierProvider(create: (_) => SettingsProvider()),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => GameEditScreen(game: game),
                        ),
                      ),
                      child: const Text("编辑"),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text("编辑"));
          await tester.pumpAndSettle();
          if (action == "manual_off") {
            await tester.ensureVisible(find.text("NSFW 内容"));
            await tester.tap(find.text("NSFW 内容"));
            await tester.pumpAndSettle();
            await tester.tap(find.text("NSFW 内容"));
            await tester.pumpAndSettle();
            expect(
              tester.widget<SwitchListTile>(switchFor("允许智能体自动标记")).value,
              isFalse,
            );
          } else if (action == "allow_auto") {
            await tester.ensureVisible(find.text("允许智能体自动标记"));
            await tester.tap(find.text("允许智能体自动标记"));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text("保存"));
          await tester.pumpAndSettle();
          expect(saved, isNotNull);
          if (action == "unchanged") {
            expect(saved!.containsKey("is_nsfw"), isFalse);
            expect(saved!.containsKey("nsfw_manual"), isFalse);
          } else if (action == "manual_off") {
            expect(saved!["is_nsfw"], isFalse);
            expect(saved!["nsfw_manual"], isTrue);
          } else {
            expect(saved!.containsKey("is_nsfw"), isFalse);
            expect(saved!["nsfw_manual"], isFalse);
          }
          expect(find.byType(GameEditScreen), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => MockClient((request) async {
          if (request.method == "PUT") {
            saved = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          }
          return http.Response(
            '{"message":"ok"}',
            200,
            headers: {"content-type": "application/json; charset=utf-8"},
          );
        }),
      );
    });
  }
}

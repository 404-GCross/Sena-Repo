import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:provider/provider.dart";

import "package:sena_repo/providers/settings_provider.dart";
import "package:sena_repo/widgets/nsfw_image.dart";

void main() {
  late SettingsProvider settings;

  setUp(() {
    settings = SettingsProvider();
  });

  tearDown(() {
    settings.dispose();
  });

  testWidgets("touch reveal button does not trigger the parent card tap",
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      var cardTaps = 0;

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: GestureDetector(
                  onTap: () => cardTaps++,
                  child: const SizedBox(
                    width: 200,
                    height: 280,
                    child: NsfwImage(
                      isNsfw: true,
                      child: ColoredBox(color: Colors.pink),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(ImageFiltered), findsOneWidget);

      final imageTopLeft = tester.getTopLeft(find.byType(NsfwImage));
      await tester.tapAt(imageTopLeft + const Offset(12, 12));
      await tester.pump();

      expect(cardTaps, 1);
      expect(find.byType(ImageFiltered), findsOneWidget);

      cardTaps = 0;
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pump();

      expect(cardTaps, 0);
      expect(find.byType(ImageFiltered), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(ImageFiltered), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

import 'package:flutter/material.dart';
import '../utils/theme_utils.dart';

class SteamPatchLayout extends StatelessWidget {
  final Widget controls;
  final Widget Function(bool stacked) results;
  const SteamPatchLayout({
    super.key,
    required this.controls,
    required this.results,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: LayoutBuilder(
      builder: (_, box) {
        if (box.maxWidth < 860) {
          return ListView(
            children: [
              controls,
              const SizedBox(height: AppGap.lg),
              results(true),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 320,
              child: SingleChildScrollView(primary: false, child: controls),
            ),
            const SizedBox(width: AppGap.lg),
            Expanded(child: results(false)),
          ],
        );
      },
    ),
  );
}

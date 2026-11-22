import 'package:flutter/widgets.dart';

import '../models/scraper_sources.dart';
import '../services/api_client.dart';
import 'feedback_dialog.dart';

Future<ScraperSources?> readScraperSources(
  BuildContext context,
  ApiClient api,
) async {
  final scope = api.sessionScope;
  final route = ModalRoute.of(context);
  bool current() => scope == api.sessionScope && route?.isCurrent != false;
  try {
    final sources = await api.getScraperSources();
    return context.mounted && current() ? sources : null;
  } catch (error) {
    if (context.mounted && current()) {
      await showFeedbackDialog(
        context,
        error is AuthException ? error.message : '无法读取刮削模式，请重试',
        error: true,
      );
    }
    return null;
  }
}

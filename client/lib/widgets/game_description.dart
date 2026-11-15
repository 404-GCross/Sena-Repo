import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:url_launcher/url_launcher.dart";

import "../services/logger_service.dart";
import "../utils/description_markdown.dart";
import "../utils/theme_utils.dart";
import "feedback_dialog.dart";

class GameDescription extends StatelessWidget {
  final String? description;
  final TextStyle? style;
  final String emptyText;

  const GameDescription({
    super.key,
    required this.description,
    this.style,
    this.emptyText = "暂无简介",
  });

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? "");
    if (uri == null ||
        !{"http", "https"}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      await showFeedbackDialog(context, "此链接暂不支持打开", error: true);
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      LoggerService().warn("Description link could not be opened");
      if (context.mounted) {
        await showFeedbackDialog(context, "无法打开简介中的链接", error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = description?.trim() ?? "";
    final body = DefaultTextStyle.of(
      context,
    ).style.merge(style ?? AppText.body.copyWith(height: 1.7));
    if (text.isEmpty) return Text(emptyText, style: body);
    final heading = body.copyWith(fontWeight: FontWeight.w700);
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      fitContent: false,
      extensionSet: descriptionMarkdownExtensions,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: body,
        h1: heading.copyWith(fontSize: (body.fontSize ?? 15) + 6),
        h2: heading.copyWith(fontSize: (body.fontSize ?? 15) + 4),
        h3: heading.copyWith(fontSize: (body.fontSize ?? 15) + 2),
        h4: heading,
        h5: heading,
        h6: heading,
        a: TextStyle(color: Theme.of(context).colorScheme.primary),
        blockquote: body,
        listBullet: body,
        tableBody: body,
        tableHead: heading,
        blockSpacing: 12,
      ),
      imageBuilder: (uri, title, alt) => Text(alt ?? "", style: body),
      onTapLink: (text, href, title) => _openLink(context, href),
    );
  }
}

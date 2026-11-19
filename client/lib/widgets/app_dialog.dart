import 'package:flutter/material.dart';

import '../utils/theme_utils.dart';

/// Short dialogs size to their content; the action bar stays outside the scroll area.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.section,
    required this.title,
    required this.child,
    this.actions = const [],
    this.footnote,
    this.width = 480,
    this.showClose = true,
    this.scrollBody = true,
    this.tone,
  });

  final String section, title;
  final Widget child;
  final List<Widget> actions;
  final String? footnote;
  final double width;
  final bool showClose, scrollBody;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = tone ?? cs.primary;
    return Dialog(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: SizedBox(
        width: width,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final inset = bounds.maxWidth < 430 ? 16.0 : 22.0;
            final heading = Padding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset - 4, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                section,
                                style: AppText.label.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Semantics(
                          namesRoute: true,
                          header: true,
                          child: Text(
                            title,
                            style: AppText.headline.copyWith(
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showClose)
                    IconButton(
                      tooltip: '关闭弹窗',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                ],
              ),
            );
            final body = Padding(
              padding: EdgeInsets.fromLTRB(inset, 2, inset, 16),
              child: child,
            );
            final buttonShape = RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            );
            final footer = Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(top: BorderSide(color: cs.outlineVariant)),
              ),
              padding: EdgeInsets.symmetric(horizontal: inset, vertical: 8),
              child: Theme(
                data: Theme.of(context).copyWith(
                  filledButtonTheme: FilledButtonThemeData(
                    style: FilledButton.styleFrom(shape: buttonShape),
                  ),
                  outlinedButtonTheme: OutlinedButtonThemeData(
                    style: OutlinedButton.styleFrom(shape: buttonShape),
                  ),
                ),
                child: OverflowBar(
                  alignment: footnote == null
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 8,
                  overflowSpacing: 4,
                  children: [
                    if (footnote != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              footnote!,
                              style: AppText.label.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ...actions,
                  ],
                ),
              ),
            );
            final compactHeight = bounds.maxHeight < 360;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (compactHeight && scrollBody)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [heading, body],
                      ),
                    ),
                  )
                else ...[
                  heading,
                  Flexible(
                    child: scrollBody
                        ? SingleChildScrollView(child: body)
                        : body,
                  ),
                ],
                if (actions.isNotEmpty || footnote != null) footer,
              ],
            );
          },
        ),
      ),
    );
  }
}

class DialogActionCard extends StatelessWidget {
  const DialogActionCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.onTap,
    this.highlight = false,
    this.badge,
  });
  final String title, description;
  final String? badge;
  final IconData icon;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = onTap != null && highlight;
    final foreground = active ? cs.primary : cs.onSurfaceVariant;
    return CustomPaint(
      foregroundPainter: onTap == null
          ? _UnavailableOutline(cs.outlineVariant)
          : null,
      child: Material(
        color: active
            ? Color.alphaBlend(cs.primary.withValues(alpha: .06), cs.surface)
            : onTap == null
            ? cs.surfaceContainerLow
            : cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: onTap == null
              ? BorderSide.none
              : BorderSide(
                  color: active
                      ? cs.primary.withValues(alpha: .46)
                      : cs.outlineVariant,
                ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          enabled: onTap != null,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: active
                          ? cs.primaryContainer
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, color: foreground, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            Text(
                              title,
                              style: AppText.body.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (badge != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  badge!,
                                  style: AppText.caption.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          description,
                          style: AppText.bodySmall.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    onTap == null ? Icons.lock_outline : Icons.chevron_right,
                    color: foreground,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnavailableOutline extends CustomPainter {
  const _UnavailableOutline(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(12),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(metric.extractPath(start, start + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_UnavailableOutline old) => color != old.color;
}

class DialogRadioCard<T> extends StatelessWidget {
  const DialogRadioCard({
    super.key,
    required this.value,
    required this.selected,
    required this.title,
    required this.description,
    this.enabled = true,
    this.danger = false,
  });
  final T value;
  final String title, description;
  final bool selected, enabled, danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = danger ? cs.error : cs.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? Color.alphaBlend(accent.withValues(alpha: .07), cs.surface)
            : cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? accent.withValues(alpha: .5) : cs.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: RadioListTile<T>(
          value: value,
          enabled: enabled,
          activeColor: accent,
          title: Text(
            title,
            style: AppText.body.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(description, style: AppText.bodySmall),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 3,
          ),
        ),
      ),
    );
  }
}

Future<bool?> confirmDestructiveAction(
  BuildContext context, {
  required String section,
  required String title,
  required String message,
  required String action,
  String? item,
}) => confirmAppAction(
  context,
  section: section,
  title: title,
  message: message,
  action: action,
  item: item,
  destructive: true,
);

Future<bool?> confirmAppAction(
  BuildContext context, {
  required String section,
  required String title,
  required String message,
  required String action,
  String? item,
  bool destructive = false,
}) {
  final cs = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      section: section,
      title: title,
      width: 440,
      tone: destructive ? cs.error : null,
      showClose: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                destructive ? Icons.warning_amber_rounded : Icons.info_outline,
                color: destructive ? cs.error : cs.primary,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          if (item != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(item),
            ),
        ],
      ),
      actions: [
        OutlinedButton(
          autofocus: true,
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
}

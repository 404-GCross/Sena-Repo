import 'package:flutter/material.dart';
import '../utils/theme_utils.dart';
import 'app_dialog.dart';

Future<String?> showStringPicker(
  BuildContext context, {
  required String title,
  required String section,
  required List<String> items,
  String? selected,
  String? root,
}) {
  var query = '';
  final base = root?.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
  String path(String value) {
    final normalized = value.replaceAll('\\', '/');
    return base != null && normalized.startsWith('$base/')
        ? normalized.substring(base.length + 1)
        : normalized;
  }

  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (_, update) {
        final visible = query.isEmpty
            ? items
            : items
                  .where(
                    (s) => (base == null ? s : path(s)).toLowerCase().contains(
                      query,
                    ),
                  )
                  .toList();
        return AppDialog(
          title: title,
          section: section,
          scrollBody: false,
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              if (items.length > 3)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: base == null ? '筛选模型' : '按名称或路径筛选',
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (v) =>
                          update(() => query = v.trim().toLowerCase()),
                    ),
                  ),
                ),
              SliverList.builder(
                itemCount: visible.isEmpty ? 1 : visible.length,
                itemBuilder: (_, i) {
                  if (visible.isEmpty)
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('没有匹配的选项'),
                    );
                  final value = visible[i];
                  return ListTile(
                    leading: Icon(base == null ? Icons.memory : Icons.terminal),
                    title: Text(
                      base == null ? value : path(value).split('/').last,
                      style: AppText.body,
                    ),
                    subtitle: base == null
                        ? null
                        : Text(path(value), style: AppText.label),
                    trailing: Icon(
                      value == selected ? Icons.check : Icons.chevron_right,
                    ),
                    selected: value == selected,
                    onTap: () => Navigator.pop(ctx, value),
                  );
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<String?> chooseExecutable(
  BuildContext context,
  List<String> paths,
  String root,
) => showStringPicker(
  context,
  title: '选择启动程序',
  section: '游戏启动',
  items: paths,
  root: root,
);

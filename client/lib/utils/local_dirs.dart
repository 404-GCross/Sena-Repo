/// On-demand checks for the client's local directories.

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../services/download_service.dart";

class LocalDirs {
  /// Return the game download directory, asking the user to pick one when unset.
  static Future<String?> ensureDownloadDir(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString("local_download_dir") ?? "";
    if (dir.isNotEmpty) return dir;
    if (!context.mounted) return null;
    final confirmed = await _showPrompt(
      context,
      title: "需要先设置游戏下载目录",
      message: "下载游戏前需要选择保存位置，稍后也可以在「本地设置」中修改。",
    );
    if (confirmed != true || !context.mounted) return null;
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "选择游戏下载目录",
    );
    if (picked == null || picked.isEmpty) return null;
    await DownloadService().setDownloadDir(picked);
    return picked;
  }

  /// Return the Steam steamapps directory, asking the user to pick one when unset.
  static Future<String?> ensureSteamappsDir(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString("steamapps_dir") ??
        prefs.getString("steam_common_dir") ??
        "";
    if (dir.isNotEmpty) return dir;
    if (!context.mounted) return null;
    final confirmed = await _showPrompt(
      context,
      title: "需要先设置 Steam 库目录",
      message: "请选择 Steam 的 steamapps 目录，导入 Steam 与补丁注入都会使用它。",
    );
    if (confirmed != true || !context.mounted) return null;
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "选择 Steam steamapps 目录",
    );
    if (picked == null || picked.isEmpty) return null;
    await prefs.setString("steamapps_dir", picked);
    return picked;
  }

  static Future<bool?> _showPrompt(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("选择目录"),
          ),
        ],
      ),
    );
  }
}

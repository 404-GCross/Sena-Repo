/// Android download progress notification via flutter_local_notifications.

import "dart:io" show Platform;

import "package:flutter_local_notifications/flutter_local_notifications.dart";

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings("@mipmap/ic_launcher");
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
    _initialized = true;
  }

  /// Show a download progress notification. Call with progress 0-1.
  /// Returns the notification ID so you can update/cancel it.
  Future<int> showDownloadProgress({
    required int id,
    required String gameName,
    required double progress,
    required int receivedBytes,
    required int totalBytes,
  }) async {
    if (!Platform.isAndroid || !_initialized) return id;

    final indeterminate = totalBytes <= 0;
    final maxProgress = totalBytes > 0 ? totalBytes : 100;
    final currentProgress = totalBytes > 0 ? receivedBytes : (progress * 100).round();

    await _plugin.show(
      id,
      "正在下载: $gameName",
      totalBytes > 0
          ? "${(progress * 100).toStringAsFixed(0)}% · ${_fmtSize(receivedBytes)} / ${_fmtSize(totalBytes)}"
          : "下载中...",
      NotificationDetails(
        android: AndroidNotificationDetails(
          "download_progress",
          "下载进度",
          channelDescription: "游戏下载进度通知",
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: maxProgress,
          progress: currentProgress,
          ongoing: true,
          autoCancel: false,
        ),
      ),
    );
    return id;
  }

  /// Show completion notification.
  Future<void> showCompleted({
    required int id,
    required String gameName,
  }) async {
    if (!Platform.isAndroid || !_initialized) return;

    // Cancel the progress notification
    await _plugin.cancel(id);

    await _plugin.show(
      id + 10000, // different ID so it doesn't replace
      "下载完成",
      gameName,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          "download_complete",
          "下载完成",
          channelDescription: "游戏下载完成通知",
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }

  /// Cancel a notification.
  Future<void> cancel(int id) async {
    if (!Platform.isAndroid) return;
    await _plugin.cancel(id);
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }
}

/// Sena Repo Client — GalGame Private Library Manager
///
/// Cross-platform client for Windows, Android, and Linux.

import "dart:async";
import "dart:io" show HttpClient, HttpOverrides, InternetAddress, Platform, Process, SecurityContext, ServerSocket, Socket, exit;

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:window_manager/window_manager.dart";

import "providers/settings_provider.dart";
import "providers/game_provider.dart";
import "providers/theme_provider.dart";
import "screens/connect_screen.dart";
import "services/tray_service.dart";
import "services/logger_service.dart";
import "services/notification_service.dart";
import "services/download_service.dart";

Future<bool> _check7zAvailable() async {
  try {
    final exe = Platform.isWindows ? "7z" : "7z";
    final result = await Process.run(exe, ["--help"]);
    return result.exitCode == 0 || result.exitCode == 7;
  } catch (_) {
    return false;
  }
}

final trayService = TrayService();

ServerSocket? _lockServer;
const _instancePort = 11452;

/// Acquire single-instance lock. If already running, signal the existing
/// instance to show itself and return false.
Future<bool> _acquireSingleInstanceLock() async {
  try {
    _lockServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
    return true;
  } catch (_) {
    // Another instance is already running — tell it to come to front
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4, _instancePort,
        timeout: const Duration(milliseconds: 500),
      );
      await s.close();
    } catch (_) {}
    return false;
  }
}

/// Start listening for "show" signals from subsequent launches.
/// Must be called AFTER windowManager.ensureInitialized().
void _startInstanceListener() {
  _lockServer?.listen((Socket s) {
    s.destroy();
    windowManager.show();
    windowManager.focus();
  });
}

class _AllowAllCertificates extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, __, ___) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowAllCertificates();
  NotificationService().init();
  DownloadService().initLifecycle();
  LoggerService().cleanOldLogs();

  if (Platform.isWindows || Platform.isLinux) {
    if (!await _acquireSingleInstanceLock()) {
      exit(0);
    }
    await windowManager.ensureInitialized();
    windowManager.setTitle("Sena Repo");
    _startInstanceListener();
  }

  // Disclaimer / EULA check
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool("disclaimer_agreed") != true) {
    final agreed = await _showDisclaimer();
    if (agreed != true) exit(0);
    await prefs.setBool("disclaimer_agreed", true);
  }

  runApp(const SenaRepoApp());
}

Future<bool?> _showDisclaimer() async {
  final result = Completer<bool?>();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Builder(
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Row(children: [
                Icon(Icons.warning_amber, color: Colors.orange, size: 24),
                SizedBox(width: 8),
                Text("免责声明"),
              ]),
              content: const SingleChildScrollView(
                child: Text(
                  "Sena Repo 是一款 GalGame 私有库管理工具。\n\n"
                  "1. 本项目仅供个人合法使用，不提供游戏本体、破解资源或任何违规内容。\n\n"
                  "2. 用户应遵守所在地法律法规，仅管理和下载有权使用的游戏资源。\n\n"
                  "3. 本项目由 AI 辅助开发，可能存在未知缺陷，使用过程中造成的任何数据损失或系统问题，开发者不承担责任。\n\n"
                  "4. 本软件按\"现状\"提供，不提供任何明示或暗示的担保。\n\n"
                  "点击\"同意\"即表示您已阅读并接受以上条款。",
                  style: TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text("不同意"),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("同意"),
                ),
              ],
            ),
          ).then((value) {
            result.complete(value);
          });
        });
        return const Scaffold(body: SizedBox.shrink());
      },
    ),
  ));
  return result.future;
}

class SenaRepoApp extends StatefulWidget {
  const SenaRepoApp({super.key});

  @override
  State<SenaRepoApp> createState() => _SenaRepoAppState();
}

class _SenaRepoAppState extends State<SenaRepoApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux) {
      windowManager.addListener(this);
      _initTray();
    }
  }

  Future<void> _initTray() async {
    // Delay to ensure window is fully created before setting preventClose
    await Future.delayed(const Duration(milliseconds: 500));
    await windowManager.setPreventClose(true);
    try {
      await trayService.init(onQuit: () {
        exit(0);
      });
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool("minimize_to_tray") ?? false;
    await trayService.setEnabled(enabled);
  }

  @override
  void onWindowClose() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool("minimize_to_tray") ?? false;
    if (enabled) {
      await windowManager.hide();
    } else {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => GameProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) => MaterialApp(
          title: "Sena Repo",
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: theme.accentColor,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            chipTheme: ChipThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          home: const ConnectScreen(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }
}

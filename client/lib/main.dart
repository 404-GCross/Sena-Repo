/// Sena Repo Client — GalGame Private Library Manager
///
/// Cross-platform client for Windows, Android, and Linux.

import "dart:async";
import "dart:io" show HttpClient, HttpOverrides, InternetAddress, Platform, Process, SecurityContext, ServerSocket, Socket, X509Certificate, exit;
import "services/api_client.dart" show trustedServerHost;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
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
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return host == trustedServerHost;
      };
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowAllCertificates();
  // Prevent Android system bars from overlapping the app
  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Column(children: [
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.asset("assets/icon.png", width: 72, height: 72, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF7C3AED), Color(0xFFA855F7)],
                        ),
                      ),
                      child: const Icon(Icons.videogame_asset, size: 36, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text("欢迎使用 Sena Repo", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text("免责声明", style: TextStyle(fontSize: 13, color: Colors.grey)),
              ]),
              content: const SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(children: [
                    Divider(height: 1),
                    SizedBox(height: 12),
                    _DisclaimerItem(icon: Icons.folder_special, text: "本项目为开源项目，仅用于合法用途，管理您有权使用的游戏与应用。"),
                    _DisclaimerItem(icon: Icons.shield, text: "您需要自行确认资源与第三方组件的合法性。"),
                    _DisclaimerItem(icon: Icons.block, text: "本项目不提供游戏本体、破解资源、绕过授权的能力或任何违规用途的支持。"),
                    _DisclaimerItem(icon: Icons.warning_amber, text: "本项目由 AI 辅助开发，安全性未经审计，服务端部署至公网前请自行加固。"),
                  ]),
                ),
              ),
              actions: const [
                _DisclaimerActions(),
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

class _DisclaimerItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _DisclaimerItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: const Color(0xFF7C3AED).withValues(alpha: 0.7)),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.5))),
      ]),
    );
  }
}

class _DisclaimerActions extends StatelessWidget {
  const _DisclaimerActions();

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("不同意")),
      const SizedBox(width: 8),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("同意")),
    ]);
  }
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

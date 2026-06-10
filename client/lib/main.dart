/// Sena Repo Client — GalGame Private Library Manager
///
/// Cross-platform client for Windows, Android, and Linux.

import "dart:io" show InternetAddress, Platform, ServerSocket, exit;

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

final trayService = TrayService();

ServerSocket? _lockServer;

Future<bool> _acquireSingleInstanceLock() async {
  try {
    _lockServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 11452);
    return true; // First instance
  } catch (_) {
    return false; // Port in use = another instance already running
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LoggerService().cleanOldLogs();

  if (Platform.isWindows || Platform.isLinux) {
    if (!await _acquireSingleInstanceLock()) {
      exit(0);
    }
    await windowManager.ensureInitialized();
    windowManager.setTitle("Sena Repo");
  }

  runApp(const SenaRepoApp());
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
        builder: (context, theme, _) {
          final base = ThemeData(useMaterial3: true);
          return MaterialApp(
            title: "Sena Repo",
            debugShowCheckedModeBanner: false,
            themeMode: theme.themeMode,
            darkTheme: base.copyWith(
              colorScheme: ColorScheme.fromSeed(
                seedColor: theme.accentColor,
                brightness: Brightness.dark,
              ),
            ),
            theme: base.copyWith(
              colorScheme: ColorScheme.fromSeed(
                seedColor: theme.accentColor,
                brightness: Brightness.light,
              ),
            ),
            home: const ConnectScreen(),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }
}

/// Sena Repo Client — GalGame Private Library Manager
///
/// Cross-platform client for Windows, Android, and Linux.

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:window_manager/window_manager.dart";

import "providers/settings_provider.dart";
import "providers/game_provider.dart";
import "providers/theme_provider.dart";
import "screens/connect_screen.dart";
import "services/tray_service.dart";

final trayService = TrayService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
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
    // Must call setPreventClose FIRST so onWindowClose always fires
    await windowManager.setPreventClose(true);
    try {
      await trayService.init(onQuit: () async {
        await windowManager.destroy();
      });
    } catch (_) {
      // Tray icon init failed, but close-to-tray still works via onWindowClose
    }
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
      await trayService.dispose();
      await windowManager.destroy();
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
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
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

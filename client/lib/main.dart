/// Sena Repo Client — GalGame Private Library Manager
///
/// Cross-platform client for Windows, Android, and Linux.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "providers/settings_provider.dart";
import "providers/game_provider.dart";
import "screens/connect_screen.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SenaRepoApp());
}

class SenaRepoApp extends StatelessWidget {
  const SenaRepoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => GameProvider()),
      ],
      child: MaterialApp(
        title: "Sena Repo",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C3AED),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const ConnectScreen(),
      ),
    );
  }
}

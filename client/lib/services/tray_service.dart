/// System tray service — minimize to tray on close.
/// Windows / Linux desktop only. Window close handling is in main.dart.

import "dart:io" show Directory, File, Platform;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:path_provider/path_provider.dart";
import "package:system_tray/system_tray.dart";
import "package:window_manager/window_manager.dart";

class TrayService {
  final SystemTray _tray = SystemTray();
  bool _enabled = false;
  bool _initialized = false;
  void Function()? _onQuit;

  bool get isEnabled => _enabled;

  Future<void> init({required void Function() onQuit}) async {
    if (_initialized) return;
    _onQuit = onQuit;

    if (!Platform.isWindows && !Platform.isLinux) return;

    // Generate a simple tray icon — Windows needs .ico format
    String iconPath = "";
    try {
      final dir = await getTemporaryDirectory();
      final ext = Platform.isWindows ? ".ico" : ".png";
      final iconFile = File("${dir.path}/sena_tray_icon$ext");
      if (!await iconFile.exists()) {
        final pngBytes = await _generateIconPng();
        final bytes = Platform.isWindows ? _pngToIco(pngBytes, 32) : pngBytes;
        await iconFile.writeAsBytes(bytes);
      }
      iconPath = iconFile.path;
    } catch (_) {}

    await _tray.initSystemTray(
      title: "Sena Repo",
      iconPath: iconPath,
    );

    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: "显示窗口", onClicked: (_) => windowManager.show()),
      MenuItemLabel(label: "退出", onClicked: (_) => _onQuit?.call()),
    ]);
    await _tray.setContextMenu(menu);

    // Handle tray icon events
    _tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick || eventName == kSystemTrayEventDoubleClick) {
        windowManager.show();
      } else if (eventName == "SystemTray.rightClick") {
        _tray.popUpContextMenu();
      }
    });

    _initialized = true;
  }

  /// Generate a 32x32 purple PNG icon programmatically.
  Future<Uint8List> _generateIconPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const size = 32.0;

    final paint = ui.Paint()..color = const ui.Color(0xFF7C3AED);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(0, 0, size, size),
        const ui.Radius.circular(6),
      ),
      paint,
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Wrap PNG data in an ICO container for Windows.
  Uint8List _pngToIco(Uint8List png, int size) {
    final builder = BytesBuilder();
    // ICO header: reserved(2) + type(2=ICO) + count(2)
    builder.add(_u16le(0)); // reserved
    builder.add(_u16le(1)); // type: ICO
    builder.add(_u16le(1)); // image count
    // Directory entry: w,h,colors,reserved,planes,bpp,size,offset
    builder.add([size > 255 ? 0 : size]); // width (0 = 256px)
    builder.add([size > 255 ? 0 : size]); // height
    builder.add([0]); // color palette
    builder.add([0]); // reserved
    builder.add(_u16le(1)); // color planes
    builder.add(_u16le(32)); // bits per pixel
    builder.add(_u32le(png.length)); // image size
    builder.add(_u32le(22)); // offset (6 header + 16 entry)
    // PNG data
    builder.add(png);
    return builder.toBytes();
  }

  Uint8List _u16le(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  Uint8List _u32le(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
  }

  void showWindow() => windowManager.show();

  Future<void> dispose() async {
    await windowManager.setPreventClose(false);
  }
}

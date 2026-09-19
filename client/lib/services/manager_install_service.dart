/// Open external manager install protocol URLs.

import "dart:io";

class ManagerInstallService {
  ManagerInstallService._();

  static bool get isSupportedDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<void> openInstallUrl(String url) async {
    final uri = Uri.tryParse(url);
    final scheme = uri?.scheme.toLowerCase();
    final host = uri?.host.toLowerCase();
    final isAllowed =
        (scheme == "lunabox" || scheme == "reinamanager") && host == "install";
    if (!isAllowed) {
      throw ArgumentError("不支持的管理器安装链接");
    }

    if (Platform.isWindows) {
      await Process.start(
        "rundll32",
        ["url.dll,FileProtocolHandler", url],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (Platform.isMacOS) {
      await Process.start("open", [url], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isLinux) {
      await Process.start("xdg-open", [url], mode: ProcessStartMode.detached);
      return;
    }
    throw UnsupportedError("当前平台暂不支持推送到外部管理器");
  }
}

/// About page — versions, environment, links, attribution and licenses.

import "dart:convert";
import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:font_awesome_flutter/font_awesome_flutter.dart";
import "package:provider/provider.dart";
import "package:url_launcher/url_launcher.dart";

import "../providers/game_provider.dart";
import "../services/logged_http.dart" as http;
import "../utils/source_icons.dart";
import "../utils/theme_utils.dart";
import "../utils/version.dart";
import "../widgets/app_shell.dart";

const _repoUrl = "https://github.com/404-GCross/Sena-Repo";
const _docsUrl = "https://sena-repo.github.io/";
const _issuesUrl = "https://github.com/404-GCross/Sena-Repo/issues/new";
const _releasesUrl = "https://github.com/404-GCross/Sena-Repo/releases";
const _thanksUrl =
    "https://github.com/404-GCross/Sena-Repo/blob/main/README_zh-CN.md#特别鸣谢";
const _thanksProjects = <({String name, String repo})>[
  (name: "mcmilk/7-Zip-zstd", repo: "https://github.com/mcmilk/7-Zip-zstd"),
  (
    name: "OpenListTeam/OpenList",
    repo: "https://github.com/OpenListTeam/OpenList",
  ),
  (
    name: "KunMoe/kun-galgame-forum",
    repo: "https://github.com/KunMoe/kun-galgame-forum",
  ),
  (name: "Ringyuki/shionlib", repo: "https://github.com/Ringyuki/shionlib"),
  (name: "xm486/YukiHub", repo: "https://github.com/xm486/YukiHub"),
  (name: "INK666/myGal", repo: "https://github.com/INK666/myGal"),
  (
    name: "JosefNemec/Playnite",
    repo: "https://github.com/JosefNemec/Playnite",
  ),
  (
    name: "huoshen80/ReinaManager",
    repo: "https://github.com/huoshen80/ReinaManager",
  ),
  (
    name: "Saramanda9988/LunaBox",
    repo: "https://github.com/Saramanda9988/LunaBox",
  ),
  (
    name: "bggRGjQaUbCoE/PiliPlus",
    repo: "https://github.com/bggRGjQaUbCoE/PiliPlus",
  ),
  (
    name: "moraroy/NonSteamLaunchers-On-Steam-Deck",
    repo: "https://github.com/moraroy/NonSteamLaunchers-On-Steam-Deck",
  ),
];
const _sevenZipRepo = "https://github.com/mcmilk/7-Zip-zstd";
const _aria2Repo = "https://github.com/aria2/aria2";
const _disclaimerUrl =
    "https://github.com/404-GCross/Sena-Repo/blob/main/README_zh-CN.md#免责声明";
const _upstreamSources = "VNDB · Bangumi · DLsite · ErogameScape · Ci-en · Getchu";
const _disclaimerText = "本项目为开源项目，仅用于合法用途，管理您有权使用的游戏/应用，"
    "如有侵权请告知。\n\n"
    "您需要自行确认资源与第三方组件的合法性。\n\n"
    "本项目不提供游戏本体、破解资源、绕过授权的能力或任何违规用途的支持。\n\n"
    "本项目由 AI 辅助开发，安全性未经审计，服务端部署至公网前请自行加固。";

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _serverVersion = "";
  bool _loadingServer = false;

  String get _serverLabel =>
      _serverVersion.isEmpty ? "未获取" : versionLabel(_serverVersion);

  String get _serverAddress => context.read<GameProvider>().api.baseUrl;

  @override
  void initState() {
    super.initState();
    _loadServerVersion();
  }

  Future<void> _loadServerVersion() async {
    if (_loadingServer) return;
    setState(() => _loadingServer = true);
    try {
      final api = context.read<GameProvider>().api;
      final resp = await http
          .get(Uri.parse("${api.baseUrl}/api/health"))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted) {
          setState(() => _serverVersion = data["version"]?.toString() ?? "");
        }
      }
    } catch (_) {
      // Keep the previous value; the badge falls back to 未获取.
    } finally {
      if (mounted) setState(() => _loadingServer = false);
    }
  }

  Future<void> _openUrl(String url) async {
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!launched && mounted) {
      _toast("无法打开链接：$url");
    }
  }

  Future<void> _copyText(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _toast("$label 已复制");
  }

  Future<void> _copyDiagnostics() async {
    final text = [
      "Sena Repo $appVersionLabel",
      "客户端: $appVersionLabel",
      "服务端: $_serverLabel",
      "平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}"
          .trim(),
      "服务器: $_serverAddress",
      "时间: ${DateTime.now().toIso8601String()}",
    ].join("\n");
    await _copyText("诊断信息", text);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showLicenses() {
    showLicensePage(
      context: context,
      applicationName: "Sena Repo",
      applicationVersion: appVersionLabel,
      applicationIcon: Padding(
        padding: const EdgeInsets.all(8),
        child: Image.asset("assets/icon.png", width: 48, height: 48),
      ),
    );
  }

  Future<void> _showComponents() {
    return _showListDialog(
      title: "开源组件",
      intro: "本客户端随包分发以下开源可执行文件，点击条目可在浏览器打开对应仓库。",
      rows: [
        _dialogEntry(
          leading: Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: sectionIconColor(context),
          ),
          title: "7-Zip（7-Zip-zstd 构建）",
          subtitle: "压缩包解压 / 压缩（含 RAR、Zstd）",
          license: "GNU LGPL-2.1（RAR 部分含 unRAR 限制；另含 BSD-2/BSD-3/public domain 组件）",
          actionLabel: "许可全文",
          onAction: () => _showBundledLicense(
            title: "7-Zip 许可",
            assetPath: "assets/binaries/LICENSE-7z.txt",
            fallbackUrl: _sevenZipRepo,
          ),
          url: _sevenZipRepo,
        ),
        _dialogEntry(
          leading: Icon(
            Icons.download_rounded,
            size: 20,
            color: sectionIconColor(context),
          ),
          title: "aria2",
          subtitle: "多线程下载（HTTP/BT，失败时回退内置下载）",
          license: "GNU GPL-2.0（含 OpenSSL 链接例外）",
          actionLabel: "许可全文",
          onAction: () => _showBundledLicense(
            title: "aria2 许可",
            assetPath: "assets/binaries/COPYING-aria2.txt",
            fallbackUrl: _aria2Repo,
          ),
          url: _aria2Repo,
        ),
      ],
      footer: _dialogFooterRow(
        icon: Icons.article_outlined,
        label: "查看全部 Dart/Flutter 组件许可",
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          _showLicenses();
        },
      ),
    );
  }

  Future<void> _showThanks() {
    return _showListDialog(
      title: "特别鸣谢",
      intro: "开发过程中参考与学习了以下开源项目（排名不分先后），点击条目可在浏览器打开对应仓库。",
      rows: [
        for (final project in _thanksProjects)
          _dialogEntry(
            leading: FaIcon(
              FontAwesomeIcons.github,
              size: 16,
              color: sectionIconColor(context),
            ),
            title: project.name,
            subtitle: project.repo.replaceFirst("https://", ""),
            url: project.repo,
          ),
      ],
      footer: _dialogFooterRow(
        icon: Icons.link_rounded,
        label: "在浏览器查看完整名单",
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          _openUrl(_thanksUrl);
        },
      ),
    );
  }

  Future<void> _showListDialog({
    required String title,
    required String intro,
    required List<Widget> rows,
    Widget? footer,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(title),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 440,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  intro,
                  style: AppText.bodySmall.copyWith(
                    color: subTextColor(ctx),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppGap.md),
                ...rows,
                if (footer != null) ...[
                  const SizedBox(height: AppGap.sm),
                  Divider(height: 1, color: cardBorder(ctx)),
                  const SizedBox(height: 2),
                  footer,
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("关闭"),
          ),
        ],
      ),
    );
  }

  Widget _dialogEntry({
    required Widget leading,
    required String title,
    required String subtitle,
    String? license,
    String? actionLabel,
    VoidCallback? onAction,
    String? url,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: url == null ? null : () => _openUrl(url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Center(child: leading),
            ),
            const SizedBox(width: AppGap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.bodyMedium.copyWith(
                      color: sectionTextColor(context),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.label.copyWith(color: hintColor(context)),
                  ),
                  if (license != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      license,
                      style: AppText.caption.copyWith(
                        color: hintColor(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppGap.sm),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  actionLabel,
                  style: AppText.label.copyWith(fontWeight: FontWeight.w700),
                ),
              )
            else
              Icon(
                Icons.open_in_new_rounded,
                size: 15,
                color: hintColor(context),
              ),
          ],
        ),
      ),
    );
  }

  Widget _dialogFooterRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: hintColor(context)),
            const SizedBox(width: AppGap.sm),
            Expanded(
              child: Text(
                label,
                style: AppText.label.copyWith(color: subTextColor(context)),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: hintColor(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBundledLicense({
    required String title,
    required String assetPath,
    required String fallbackUrl,
  }) async {
    String content;
    try {
      content = await rootBundle.loadString(assetPath);
    } catch (_) {
      content = "";
    }
    if (!mounted) return;
    if (content.trim().isEmpty) {
      _toast("应用内未随包该许可文本，已改为浏览器打开");
      await _openUrl(fallbackUrl);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(title),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("关闭"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openUrl(fallbackUrl);
            },
            child: const Text("在浏览器查看"),
          ),
        ],
      ),
    );
  }

  void _showDisclaimer() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text("免责声明"),
        content: const SingleChildScrollView(
          child: Text(
            _disclaimerText,
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("关闭"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openUrl(_disclaimerUrl);
            },
            child: const Text("在浏览器查看"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return AppScaffold(
      title: "关于",
      maxWidth: 760,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      actions: [
        AppActionButton(
          icon: Icons.refresh_rounded,
          label: "刷新",
          busy: _loadingServer,
          onPressed: _loadingServer ? null : _loadServerVersion,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headerCard(compact),
          const SizedBox(height: AppGap.lg),
          _section(
            icon: Icons.memory_rounded,
            title: "运行环境",
            children: [
              _infoRow("服务器", _serverAddress),
              _infoRow(
                "平台",
                "${Platform.operatingSystem} ${Platform.operatingSystemVersion}"
                    .trim(),
              ),
              _infoRow("客户端", appVersionLabel),
              _infoRow("服务端", _serverLabel),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          _section(
            icon: Icons.link_rounded,
            title: "链接",
            children: [
              _linkRow(
                icon: Icons.code_rounded,
                title: "GitHub 仓库",
                subtitle: "github.com/404-GCross/Sena-Repo",
                url: _repoUrl,
              ),
              _linkRow(
                icon: Icons.menu_book_rounded,
                title: "使用文档",
                subtitle: "sena-repo.github.io",
                url: _docsUrl,
              ),
              _linkRow(
                icon: Icons.bug_report_outlined,
                title: "问题反馈",
                url: _issuesUrl,
              ),
              _linkRow(
                icon: Icons.new_releases_outlined,
                title: "更新日志",
                subtitle: "GitHub Releases",
                url: _releasesUrl,
              ),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          _sourceCard(),
          const SizedBox(height: AppGap.lg),
          _section(
            icon: Icons.more_horiz_rounded,
            title: "其他",
            children: [
              _linkRow(
                icon: Icons.gavel_rounded,
                title: "开源组件",
                subtitle: "7-Zip · aria2",
                onTap: _showComponents,
              ),
              _linkRow(
                icon: Icons.favorite_outline_rounded,
                title: "特别鸣谢",
                subtitle: "参考与学习的开源项目",
                onTap: _showThanks,
              ),
              _linkRow(
                icon: Icons.warning_amber_rounded,
                title: "免责声明",
                onTap: _showDisclaimer,
              ),
            ],
          ),
          const SizedBox(height: AppGap.xl),
          Center(
            child: AppActionButton(
              icon: Icons.copy_all_rounded,
              label: "复制诊断信息",
              filled: true,
              onPressed: _copyDiagnostics,
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(bool compact) {
    final clientColor = versionChannelColor(context, appVersion);
    final serverColor = versionChannelColor(context, _serverVersion);
    final details = Column(
      crossAxisAlignment:
          compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          "Sena Repo",
          style: AppText.headline.copyWith(color: sectionTextColor(context)),
        ),
        const SizedBox(height: 4),
        Text(
          "GalGame 私有库管理器",
          style: AppText.bodySmall.copyWith(color: hintColor(context)),
        ),
        const SizedBox(height: AppGap.md),
        Wrap(
          spacing: AppGap.sm,
          runSpacing: AppGap.sm,
          alignment: compact ? WrapAlignment.center : WrapAlignment.start,
          children: [
            _VersionBadge(
              icon: Icons.phone_iphone_rounded,
              label: "客户端 $appVersionLabel",
              color: clientColor,
            ),
            _VersionBadge(
              icon: Icons.dns_rounded,
              label: "服务端 $_serverLabel",
              color: serverColor,
            ),
          ],
        ),
      ],
    );
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Image.asset("assets/icon.png", width: 72, height: 72),
    );
    return AppSurface(
      padding: const EdgeInsets.all(AppGap.lg),
      child: compact
          ? Column(
              children: [
                logo,
                const SizedBox(height: AppGap.md),
                details,
              ],
            )
          : Row(
              children: [
                logo,
                const SizedBox(width: AppGap.lg),
                Expanded(child: details),
              ],
            ),
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return AppSurface(
      padding: const EdgeInsets.all(AppGap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionTitle(icon: icon, title: title),
          const SizedBox(height: AppGap.sm),
          ...children,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: AppText.bodySmall.copyWith(color: subTextColor(context)),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? "-" : value,
              style: AppText.bodyMedium.copyWith(
                color: sectionTextColor(context),
              ),
            ),
          ),
          IconButton(
            tooltip: "复制$label",
            icon: const Icon(Icons.copy_rounded, size: 16),
            color: hintColor(context),
            visualDensity: VisualDensity.compact,
            onPressed: value.trim().isEmpty
                ? null
                : () => _copyText(label, value),
          ),
        ],
      ),
    );
  }

  Widget _linkRow({
    required IconData icon,
    required String title,
    String? subtitle,
    String? url,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap ?? (url == null ? null : () => _openUrl(url)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: sectionIconColor(context)),
            const SizedBox(width: AppGap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.bodyMedium.copyWith(
                      color: sectionTextColor(context),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppText.label.copyWith(color: hintColor(context)),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: hintColor(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceCard() {
    return AppSurface(
      padding: const EdgeInsets.all(AppGap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionTitle(icon: Icons.auto_awesome_rounded, title: "数据来源"),
          const SizedBox(height: AppGap.md),
          Text(
            "支持的来源",
            style: AppText.label.copyWith(
              color: subTextColor(context),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppGap.sm),
          _sourceRow(nextmoeSourceIcon, "NextMoe·未萌 开放 API",
              badge: "NextMoe 模式"),
          _sourceRow(vndbSourceIcon, "VNDB"),
          _sourceRow(bangumiSourceIcon, "Bangumi"),
          _sourceRow(steamSourceIcon, "Steam"),
          _sourceRow(hikarinagiSourceIcon, "Hikarinagi"),
          const SizedBox(height: AppGap.md),
          Divider(height: 1, color: cardBorder(context)),
          const SizedBox(height: AppGap.md),
          Text(
            "NextMoe 模式署名",
            style: AppText.label.copyWith(
              color: subTextColor(context),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "NextMoe 模式下，元数据来自 NextMoe·未萌 开放 API（聚合上游六源）；"
            "数据标注为「鲲 Galgame 论坛」。",
            style: AppText.bodySmall.copyWith(
              color: subTextColor(context),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "上游六源：$_upstreamSources",
            style: AppText.label.copyWith(color: hintColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _sourceRow(String iconAsset, String label, {String? badge}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.asset(
              iconAsset,
              width: 26,
              height: 26,
              errorBuilder: (_, __, ___) =>
                  const SizedBox(width: 26, height: 26),
            ),
          ),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Text(
              label,
              style: AppText.bodyMedium.copyWith(
                color: sectionTextColor(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.primary.withValues(alpha: 0.28)),
              ),
              child: Text(
                badge,
                style: AppText.caption.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _VersionBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppText.label.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

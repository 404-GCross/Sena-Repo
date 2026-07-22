/// Multi-step setup wizard for first-time server initialization.

import "dart:convert";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";

class SetupWizardScreen extends StatefulWidget {
  final ApiClient api;
  const SetupWizardScreen({super.key, required this.api});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  int _step = 0;
  bool _loading = false;
  String? _error;

  final _userCtrl = TextEditingController(text: "admin");
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  final List<Map<String, dynamic>> _gameLibraries = [
    {"source_type": "local", "path": "/games"},
  ];
  final List<Map<String, dynamic>> _patchLibraries = [
    {"source_type": "local", "path": "/steam_patch"},
  ];
  final List<Map<String, dynamic>> _openListSources = [];

  String _structure = "company_game";
  bool _autoScan = false;
  int _scanInterval = 24;

  bool _useBangumi = true;
  bool _useVndbKana = true;
  bool _useSteam = true;
  bool _useYmgal = true;
  final _vndbCtrl = TextEditingController();

  static const _titles = [
    "\u521b\u5efa\u7ba1\u7406\u5458",
    "\u76ee\u5f55\u4e0e\u626b\u63cf",
    "\u522e\u524a\u6e90",
  ];

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    _vndbCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step == 0 && _passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "\u4e24\u6b21\u5bc6\u7801\u4e0d\u4e00\u81f4");
      return;
    }
    setState(() {
      _step++;
      _error = null;
    });
  }

  void _prev() => setState(() {
    _step--;
    _error = null;
  });

  Future<void> _addDirectory(
    List<Map<String, dynamic>> target,
    String label,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SetupDirectoryDialog(
        label: label,
        openListSources: _openListSources,
      ),
    );
    if (payload == null) return;
    setState(() => target.add(payload));
  }

  Future<void> _editDirectory(
    List<Map<String, dynamic>> target,
    int index,
    String label,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SetupDirectoryDialog(
        label: label,
        openListSources: _openListSources,
        initial: target[index],
      ),
    );
    if (payload == null) return;
    setState(() => target[index] = payload);
  }

  Future<void> _addOpenListSource() async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => const _SetupOpenListSourceDialog(),
    );
    if (payload == null) return;
    setState(() => _openListSources.add(payload));
  }

  Future<void> _editOpenListSource(int index) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) =>
          _SetupOpenListSourceDialog(initial: _openListSources[index]),
    );
    if (payload == null) return;
    setState(() => _openListSources[index] = payload);
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/setup/initialize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "admin_username": _userCtrl.text.trim(),
          "admin_password": _passCtrl.text,
          "game_libraries": _gameLibraries,
          "steam_patch_libraries": _patchLibraries,
          "auto_scan": _autoScan,
          "scan_interval": _scanInterval,
          "scan_structure": _structure,
        }),
      );
      if (resp.statusCode != 200) {
        final body = jsonDecode(resp.body);
        setState(() {
          _error =
              body["detail"]?.toString() ?? "\u521d\u59cb\u5316\u5931\u8d25";
          _loading = false;
        });
        return;
      }

      await _saveScraperPrefs();
      if (mounted) {
        Navigator.pop(context, {
          "username": _userCtrl.text.trim(),
          "password": _passCtrl.text,
        });
      }
    } catch (e) {
      setState(() {
        _error = "$e";
        _loading = false;
      });
    }
  }

  Future<void> _saveScraperPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("scrape_src_vndb_kana", _useVndbKana);
    await prefs.setBool("scrape_src_bangumi", _useBangumi);
    await prefs.setBool("scrape_src_steam", _useSteam);
    await prefs.setBool("scrape_src_ymgal", _useYmgal);
    await prefs.setString("scan_structure", _structure);
    await prefs.setBool("auto_scan", _autoScan);
    if (_autoScan) await prefs.setInt("scan_interval", _scanInterval);

    if (_vndbCtrl.text.trim().isNotEmpty) {
      await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"vndb_token": _vndbCtrl.text.trim()}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("\u521d\u59cb\u8bbe\u7f6e (${_step + 1}/3)")),
      body: Center(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 520,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: List.generate(
                        3,
                        (i) => Expanded(
                          child: Container(
                            height: 4,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: i <= _step
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey[700],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _titles[_step],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_step == 0) ..._buildAdminStep(),
                    if (_step == 1) ..._buildDirectoryStep(),
                    if (_step == 2) ..._buildScraperStep(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        if (_step > 0)
                          OutlinedButton(
                            onPressed: _prev,
                            child: const Text("\u4e0a\u4e00\u6b65"),
                          ),
                        const Spacer(),
                        if (_step < 2)
                          FilledButton(
                            onPressed: _next,
                            child: const Text("\u4e0b\u4e00\u6b65"),
                          ),
                        if (_step == 2)
                          FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text("\u5b8c\u6210"),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildAdminStep() => [
    TextField(
      controller: _userCtrl,
      decoration: const InputDecoration(
        labelText: "\u7528\u6237\u540d",
        prefixIcon: Icon(Icons.person),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passCtrl,
      decoration: const InputDecoration(
        labelText: "\u5bc6\u7801",
        prefixIcon: Icon(Icons.lock),
      ),
      obscureText: true,
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passConfirmCtrl,
      decoration: const InputDecoration(
        labelText: "\u786e\u8ba4\u5bc6\u7801",
        prefixIcon: Icon(Icons.lock),
      ),
      obscureText: true,
    ),
  ];

  List<Widget> _buildDirectoryStep() => [
    _openListSourceSection(),
    const SizedBox(height: 16),
    _librarySection(
      "\u6e38\u620f\u5e93",
      _gameLibraries,
      () => _addDirectory(_gameLibraries, "\u6e38\u620f\u5e93"),
      (index) => _editDirectory(_gameLibraries, index, "\u6e38\u620f\u5e93"),
    ),
    const SizedBox(height: 16),
    _librarySection(
      "Steam \u8865\u4e01\u5e93",
      _patchLibraries,
      () => _addDirectory(_patchLibraries, "Steam \u8865\u4e01\u5e93"),
      (index) =>
          _editDirectory(_patchLibraries, index, "Steam \u8865\u4e01\u5e93"),
    ),
    const SizedBox(height: 16),
    const Text(
      "\u626b\u63cf\u9009\u9879",
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    DropdownButtonFormField<String>(
      value: _structure,
      decoration: const InputDecoration(labelText: "\u76ee\u5f55\u7ed3\u6784"),
      items: const [
        DropdownMenuItem(
          value: "company_game",
          child: Text("\u4f1a\u793e / \u6e38\u620f"),
        ),
        DropdownMenuItem(value: "game_only", child: Text("\u4ec5\u6e38\u620f")),
        DropdownMenuItem(value: "flat", child: Text("\u6241\u5e73")),
      ],
      onChanged: (v) => setState(() => _structure = v ?? "company_game"),
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text("\u81ea\u52a8\u626b\u63cf"),
      subtitle: Text(
        _autoScan ? "\u6bcf $_scanInterval \u5c0f\u65f6" : "\u5173\u95ed",
      ),
      value: _autoScan,
      onChanged: (v) => setState(() => _autoScan = v),
    ),
    if (_autoScan)
      TextField(
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: "\u626b\u63cf\u95f4\u9694\uff08\u5c0f\u65f6\uff09",
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n > 0) setState(() => _scanInterval = n);
        },
      ),
  ];

  Widget _librarySection(
    String title,
    List<Map<String, dynamic>> items,
    VoidCallback onAdd,
    void Function(int index) onEdit,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text("\u6dfb\u52a0\u76ee\u5f55"),
            ),
          ],
        ),
        if (items.isEmpty)
          Text(
            "\u6682\u65e0\u76ee\u5f55",
            style: AppText.label.copyWith(color: hintColor(context)),
          )
        else
          ...items.asMap().entries.map(
            (entry) => ListTile(
              dense: true,
              leading: Icon(
                entry.value["source_type"] == "openlist"
                    ? Icons.cloud_outlined
                    : Icons.folder_outlined,
              ),
              title: Text(
                entry.value["source_type"] == "openlist"
                    ? "OpenList \u6e90"
                    : "\u672c\u5730\u6587\u4ef6\u6e90",
              ),
              subtitle: Text(
                entry.value["source_type"] == "openlist"
                    ? "${entry.value["source_name"] ?? "OpenList"} - ${entry.value["path"] ?? ""}"
                    : entry.value["path"]?.toString() ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: "\u7f16\u8f91",
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => onEdit(entry.key),
                  ),
                  IconButton(
                    tooltip: "\u5220\u9664",
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => items.removeAt(entry.key)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _openListSourceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                "OpenList \u670d\u52a1\u5668",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: _addOpenListSource,
              icon: const Icon(Icons.add),
              label: const Text("\u6dfb\u52a0\u670d\u52a1\u5668"),
            ),
          ],
        ),
        if (_openListSources.isEmpty)
          Text(
            "\u9700\u8981\u4f7f\u7528 OpenList \u76ee\u5f55\u65f6\u5148\u6dfb\u52a0\u670d\u52a1\u5668",
            style: AppText.label.copyWith(color: hintColor(context)),
          )
        else
          ..._openListSources.asMap().entries.map(
            (entry) => ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_outlined),
              title: Text(
                entry.value["source_name"]?.toString().isNotEmpty == true
                    ? entry.value["source_name"].toString()
                    : "OpenList",
              ),
              subtitle: Text(
                entry.value["base_url"]?.toString() ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: "\u7f16\u8f91",
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editOpenListSource(entry.key),
                  ),
                  IconButton(
                    tooltip: "\u5220\u9664",
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () =>
                        setState(() => _openListSources.removeAt(entry.key)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildScraperStep() => [
    _scraperSwitch(
      "VNDB Kana v2",
      _useVndbKana,
      (v) => setState(() => _useVndbKana = v),
    ),
    _scraperSwitch(
      "Bangumi",
      _useBangumi,
      (v) => setState(() => _useBangumi = v),
    ),
    _scraperSwitch("Steam", _useSteam, (v) => setState(() => _useSteam = v)),
    _scraperSwitch("YMGal", _useYmgal, (v) => setState(() => _useYmgal = v)),
    const SizedBox(height: 12),
    TextField(
      controller: _vndbCtrl,
      decoration: const InputDecoration(
        labelText: "VNDB Token\uff08\u53ef\u9009\uff09",
      ),
    ),
  ];

  Widget _scraperSwitch(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SetupDirectoryDialog extends StatefulWidget {
  final String label;
  final List<Map<String, dynamic>> openListSources;
  final Map<String, dynamic>? initial;
  const _SetupDirectoryDialog({
    required this.label,
    required this.openListSources,
    this.initial,
  });

  @override
  State<_SetupDirectoryDialog> createState() => _SetupDirectoryDialogState();
}

class _SetupDirectoryDialogState extends State<_SetupDirectoryDialog> {
  String _sourceType = "local";
  int? _sourceIndex;
  final _pathCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _sourceType = initial["source_type"]?.toString() == "openlist"
          ? "openlist"
          : "local";
      _pathCtrl.text = initial["path"]?.toString() ?? "";
      if (_sourceType == "openlist") {
        final idx = widget.openListSources.indexWhere(
          (s) =>
              s["base_url"] == initial["base_url"] &&
              s["username"] == initial["username"],
        );
        _sourceIndex = idx >= 0 ? idx : null;
      }
    }
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedSourceIndex =
        _sourceIndex != null &&
            _sourceIndex! >= 0 &&
            _sourceIndex! < widget.openListSources.length
        ? _sourceIndex
        : null;
    return AlertDialog(
      title: Text("\u6dfb\u52a0${widget.label}\u76ee\u5f55"),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: "local",
                      icon: Icon(Icons.folder_outlined),
                      label: Text("\u672c\u5730\u6587\u4ef6\u6e90"),
                    ),
                    ButtonSegment(
                      value: "openlist",
                      icon: Icon(Icons.cloud_outlined),
                      label: Text("OpenList"),
                    ),
                  ],
                  selected: {_sourceType},
                  onSelectionChanged: (v) => setState(() {
                    _sourceType = v.first;
                    if (_sourceType == "openlist" &&
                        _sourceIndex == null &&
                        widget.openListSources.isNotEmpty) {
                      _sourceIndex = 0;
                    }
                  }),
                ),
              ),
              const SizedBox(height: 20),
              if (_sourceType == "openlist") ...[
                if (widget.openListSources.isEmpty)
                  Text(
                    "\u8bf7\u5148\u5728\u4e0a\u65b9\u6dfb\u52a0 OpenList \u670d\u52a1\u5668",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else
                  DropdownButtonFormField<int>(
                    value: selectedSourceIndex,
                    decoration: const InputDecoration(
                      labelText: "OpenList \u670d\u52a1\u5668",
                    ),
                    items: widget.openListSources.asMap().entries.map((entry) {
                      final source = entry.value;
                      return DropdownMenuItem<int>(
                        value: entry.key,
                        child: Text(
                          (source["source_name"] ??
                                  source["base_url"] ??
                                  "OpenList")
                              .toString(),
                        ),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _sourceIndex = v),
                  ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _pathCtrl,
                decoration: InputDecoration(
                  labelText: _sourceType == "openlist"
                      ? "\u8fdc\u7a0b\u76ee\u5f55"
                      : "\u670d\u52a1\u7aef\u672c\u5730\u76ee\u5f55",
                  hintText: _sourceType == "openlist"
                      ? "/Games"
                      : "/data/games",
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("\u53d6\u6d88"),
        ),
        FilledButton(
          onPressed: () {
            final path = _pathCtrl.text.trim();
            if (path.isEmpty) return;
            final payload = <String, dynamic>{
              "source_type": _sourceType,
              "path": path,
            };
            if (_sourceType == "openlist") {
              if (_sourceIndex == null ||
                  _sourceIndex! < 0 ||
                  _sourceIndex! >= widget.openListSources.length) {
                return;
              }
              final source = widget.openListSources[_sourceIndex!];
              payload["source_name"] = source["source_name"];
              payload["base_url"] = source["base_url"];
              payload["username"] = source["username"];
              payload["password"] = source["password"];
            }
            Navigator.pop(context, payload);
          },
          child: const Text("\u4fdd\u5b58"),
        ),
      ],
    );
  }
}

class _SetupOpenListSourceDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _SetupOpenListSourceDialog({this.initial});

  @override
  State<_SetupOpenListSourceDialog> createState() =>
      _SetupOpenListSourceDialogState();
}

class _SetupOpenListSourceDialogState
    extends State<_SetupOpenListSourceDialog> {
  final _nameCtrl = TextEditingController(text: "OpenList");
  final _baseUrlCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _nameCtrl.text = initial["source_name"]?.toString() ?? "OpenList";
      _baseUrlCtrl.text = initial["base_url"]?.toString() ?? "";
      _usernameCtrl.text = initial["username"]?.toString() ?? "";
      _passwordCtrl.text = initial["password"]?.toString() ?? "";
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? "\u6dfb\u52a0 OpenList \u670d\u52a1\u5668"
            : "\u7f16\u8f91 OpenList \u670d\u52a1\u5668",
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: "\u540d\u79f0"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlCtrl,
                decoration: const InputDecoration(
                  labelText: "OpenList \u5730\u5740",
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: "\u7528\u6237\u540d",
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(labelText: "\u5bc6\u7801"),
                obscureText: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("\u53d6\u6d88"),
        ),
        FilledButton(
          onPressed: () {
            final baseUrl = _baseUrlCtrl.text.trim();
            final username = _usernameCtrl.text.trim();
            if (baseUrl.isEmpty || username.isEmpty) return;
            Navigator.pop(context, {
              "source_name": _nameCtrl.text.trim().isEmpty
                  ? "OpenList"
                  : _nameCtrl.text.trim(),
              "base_url": baseUrl,
              "username": username,
              "password": _passwordCtrl.text,
            });
          },
          child: const Text("\u4fdd\u5b58"),
        ),
      ],
    );
  }
}

# Sena Repo 技术文档（本技术文档由ai生成）


## 架构概览

```
客户端（Flutter）                    服务端（FastAPI）
─────────────                    ─────────────
Windows / Android / Linux        Docker 或 Python 直接部署
    │                                    │
    ├─ Provider 层（状态管理）            ├─ API Router 层
    ├─ Service 层（业务逻辑）             ├─ Service 层（刮削/扫描）
    ├─ Screen 层（UI）                    ├─ Model 层（ORM）
    └─ HTTP ────────────────────────────→└─ SQLite 数据库
```

客户端通过 HTTP/HTTPS 连接服务端，认证使用 Bearer Token（随机十六进制字符串）。服务端默认端口 11451。

## 技术栈

### 服务端

| 组件 | 技术 | 说明 |
|------|------|------|
| Web 框架 | FastAPI + Uvicorn | 异步 Python Web 框架 |
| ORM | SQLAlchemy 2.0 (async) | 异步数据库操作 |
| 数据库 | SQLite (aiosqlite) | 嵌入式数据库，数据文件在 `/data` |
| 密码 | bcrypt | 密码哈希与验证 |
| HTTP 客户端 | httpx | 异步刮削请求 |
| 配置 | YAML + 环境变量 | 优先级：CLI > 环境变量 > config.yaml |
| 容器化 | Docker (python:3.11-slim) | 支持 AMD64 / ARM64 |

### 客户端

| 组件 | 技术 | 说明 |
|------|------|------|
| 框架 | Flutter 3.29 | 跨平台 UI |
| 状态管理 | Provider (ChangeNotifier) | 游戏库、主题、设置 |
| 网络 | package:http | HTTP 请求 |
| 解压 | 7z (内嵌二进制) | Windows/Linux/Android |
| 桌面 | window_manager + tray_manager | Windows 托盘、窗口管理 |
| 通知 | flutter_local_notifications | Android 下载进度通知 |
| 存储 | shared_preferences + path_provider | 本地配置、路径管理 |
| 权限 | permission_handler | Android MANAGE_EXTERNAL_STORAGE |

## 服务端详解

### 入口点

`server/main.py` — FastAPI 应用入口。注册所有 API 路由器，配置 CORS（`allow_origins=["*"]`），设置 lifespan 事件初始化数据库并启动自动扫描后台任务。

### API 路由

```
/api/auth/*         — 登录、注册、用户管理、通知、头像上传
/api/games/*        — 游戏 CRUD、搜索、版本移动
/api/tags/*         — 标签 CRUD
/api/roots/*        — 根目录管理、扫描触发
/api/download/*     — 游戏文件下载
/api/files/*        — 封面/背景/头像静态文件服务
/api/scraper/*      — 刮削搜索、元数据应用、封面管理
/api/settings/*     — 扫描设置、刮削配置、回收站
/api/setup/*        — 初始化向导（首次设置）
/api/steam/*        — Steam 补丁匹配、索引、下载
```

除 `/api/auth/login` 和 `/api/auth/register` 外，所有端点需要 `Authorization: Bearer <token>` 认证。

### 数据模型

```
User ──→ Notification          Game ──→ GameVersion
  │         │                    │         │
  │         └── target_user_id   │         └── platform, filename, file_size
  │                              │
  ├── username                   ├── Company (多对一)
  ├── password_hash + salt       ├── GameTag ──→ Tag
  ├── token (随机 hex)           ├── RootDirectory (多对一)
  ├── is_admin                   ├── cover_path, bg_path
  ├── status (active/pending)    ├── developer, description
  └── avatar_path                └── vndb_id, steam_id, bangumi_id
```

### 扫描与导入流程

1. `POST /api/roots/refresh-all` 触发全量扫描
2. `services/scanner.py` 遍历根目录 → 识别会社/游戏/版本层级
3. 文件名清洗：正则提取平台标识 `[PC]` `[KRKR]` 等
4. 导入数据库：创建 Company/Game/GameVersion 记录
5. 刮削：按游戏名 + 会社搜索元数据源

### 刮削架构

**单游戏刮削（编辑页）— 客户端直连：**

```
客户端 scrape_service.dart → 直连外部 API
    ├── VNDB   → api.vndb.org/kana/vn
    ├── Bangumi → api.bgm.tv
    ├── Steam  → store.steampowered.com
    ├── DLsite → dlsite.com
    └── 月幕   → api.ymgal.games
```

**批量刮削（游戏库多选）— 服务端处理：**

```
客户端 POST /api/scrape/batch → orchestrator.py 分发
    ├── vndb_kana.py → api.vndb.org/kana/vn
    ├── bangumi.py   → api.bgm.tv
    ├── steam.py     → Steam 商店搜索
    ├── dlsite.py    → dlsite.com
    └── ymgal.py     → ymgal.games
```

单游戏刮削走客户端直连减少一次 HTTP 往返，元数据填充到编辑表单后由用户手动保存。批量刮削走服务端后台任务，支持全量 / 缺失填充 / 覆盖模式。

### Steam 补丁

- `scan_patches.py` — 扫描补丁目录，自动识别类型（关键词匹配）和 AppID（文件名提取/Steam API 搜索）
- `api/steam_patch.py` — API 层：扫描、列表、下载、编辑、索引
- `patch_type_keywords.json` — 可自定义的关键词→类型映射

### 配置系统

`config.py` 定义 `Config` dataclass。加载优先级：

1. CLI 参数 (`--host`, `--port`, `--games-path`, `--data-path`)
2. 环境变量 (`SENA_GAMES_PATH`, `SENA_DATA_PATH`, `SENA_PROXY` 等)
3. `config.yaml` 文件
4. 代码默认值

## 客户端详解

### 应用入口

`client/lib/main.dart` — Flutter 应用入口。

- 平台初始化（窗口管理、单实例锁）
- 免责声明弹窗（首次启动）
- HTTP 证书忽略（自签名 HTTPS）
- 通知和下载服务初始化
- Provider 注入（SettingsProvider / GameProvider / ThemeProvider）

### 状态管理（Provider 层）

| Provider | 职责 |
|----------|------|
| `GameProvider` | 游戏列表、搜索、排序、过滤、加载 |
| `SettingsProvider` | 服务端连接状态、地址端口 |
| `ThemeProvider` | 主题色、背景相关 |

### 服务层

| Service | 职责 |
|---------|------|
| `ApiClient` | HTTP 客户端封装，管理 baseUrl 和 Token |
| `SteamService` | Steam 本地库扫描、补丁匹配、注入 |
| `DownloadService` | 游戏下载、解压、进度管理、暂停/恢复 |
| `NotificationService` | Android 通知权限和下载进度通知 |
| `ProfileService` | 用户配置切换 |
| `LoggerService` | 文件日志（7天轮转） |
| `TrayService` | Windows 系统托盘 |
| `SteamIntegrationService` | Steam 快捷方式创建 |

### 下载管线

```
startDownload(gameId, versionId, fileName, downloadUrl)
    → DownloadTask（状态管理）
        → _download() → stream 写入临时文件（支持 Range 续传）
        → _extract() → 7z 解压到目标目录
        → _fixLayout() → 修正目录结构
        → 临时文件清理
```

- 暂停：关闭 HTTP Client，保留已下载字节
- 恢复：检查临时文件大小，Range 头续传
- 取消：关闭 Client + 杀 7z 进程 + 清理临时文件

### Steam 补丁注入（PC）

```
客户端 Tab                          服务端 Tab
─────────                          ─────────
扫 steamapps 目录                    GET /api/steam/patches
POST /api/steam/scan                 POST /api/steam/scan-patches
匹配补丁列表                         编辑补丁参数（PUT）
点击注入 → DownloadService 下载解压   关键词快捷匹配（GET/PUT）
```

### 屏幕导航（home_screen.dart）

底部/侧边导航使用 `IndexedStack` 保活所有页面：

```
游戏库 (GameProvider 驱动)
    → 搜索/排序/过滤
    → GameDetailScreen
    → GameEditScreen

Steam 补丁 (SteamPatchScreen)
    → 客户端 Tab + 服务端 Tab

我的 (ProfileScreen)
    → 设置 (SettingsScreen)
    → 个人信息编辑 (ProfileEditScreen)
```

### 跨平台适配

| 平台 | 特殊处理 |
|------|---------|
| Windows | 单实例锁（端口绑定）；窗口管理 + 托盘；7z.exe + 7z.dll；安装包（fastforge + Inno Setup） |
| Android | 存储权限（MANAGE_EXTERNAL_STORAGE）；7z ELF 通过 linker64 执行；通知权限；APK 直装 |
| Linux | AppImage 打包；7zz 独立二进制；触摸屏环境变量 |

### Linux runner 触控补丁

仓库不提交 `client/linux` 目录。GitHub Actions 在 Linux 构建阶段执行 `flutter create .` 生成 runner，然后调用：

```bash
python3 ../.github/scripts/patch_linux_runner_touch.py
```

该脚本会修改生成后的 `linux/runner/main.cc` 和 `linux/runner/my_application.cc`：

- 强制优先 `GDK_BACKEND=wayland,x11`
- 输出 Linux 输入诊断日志到 stderr
- 递归启用 GTK touch/button/motion 事件
- 将单指 touch begin/update/end 桥接为鼠标左键 press/motion/release

如果需要调整 Linux 触控兼容逻辑，应优先修改 `.github/scripts/patch_linux_runner_touch.py`，不要手动维护生成目录。

## CI/CD

三个 GitHub Actions 工作流（`.github/workflows/`）：

| 文件 | 触发 | 构建 | 发布 |
|------|------|------|------|
| `build.yml` | push dev/main | Android APK + Windows + Linux AppImage + Server Tarball | — |
| `build_Release.yml` | 手动 | 同上 | 正式 Release + GHCR |
| `build_PreRelease.yml` | 手动 | 同上 | Pre-Release |

Windows 安装包使用 fastforge + Inno Setup，中文安装界面、开始菜单快捷方式、卸载支持。

## 关键数据流

### 游戏下载

```
客户端选择版本
  → GET /api/download/{gameId}/{versionId}
  → 服务端 FileResponse 返回文件
  → 客户端 stream 写入临时文件
  → 7z 解压到本地下载目录
```

### 元数据刮削

```
客户端点击"下载元数据"
  → 选择刮削源 → 输入搜索关键词
  → GET /api/scrape/search?q=xxx&source=vndb_kana
  → 服务端调用对应刮削器
  → 返回结果列表 → 客户端选择 → 对比逐字段
  → POST /api/scrape/apply → 服务端写入数据库
```

### Steam 补丁匹配

```
客户端扫 steamapps → 提取 appmanifest_*.acf → 获取 app_id
  → POST /api/steam/scan {games: [{app_id, name, install_dir}]}
  → 服务端读 patches.json → 按 app_id 匹配
  → 返回匹配结果 → 客户端显示 → 点击注入 → 下载解压到游戏目录
```

## 安全

- 密码使用 bcrypt 哈希
- Token 为 32 字节随机十六进制字符串
- 所有 API 端点（除 login/register）需要 Bearer Token 认证
- 自签名 HTTPS 支持（客户端允许所有证书）
- 文件服务仅允许图片扩展名（`.jpg/.png/.gif/.webp/.bmp`）
- 外部 URL 下载前校验 IP 地址（防止 SSRF）

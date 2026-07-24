# Sena Repo 技术文档

## 架构概览

```
客户端（Flutter）                    服务端（FastAPI）
─────────────────                    ─────────────────
Windows / Android / Linux            Docker 或 Python 直接部署
    │                                    │
    ├─ Provider 层（状态管理）             ├─ API Router 层
    ├─ Service 层（业务逻辑）             ├─ Service 层（刮削/扫描）
    ├─ Screen 层（UI）                   ├─ Model 层（ORM）
    └─ HTTP ──────────────────────────► └─ SQLite 数据库
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
| 解压 | 7zip-zstd（内嵌二进制） | Windows/Linux/Android |
| 桌面 | window_manager + tray_manager | Windows 托盘、窗口管理 |
| 通知 | flutter_local_notifications | Android 下载进度通知 |
| 存储 | shared_preferences + flutter_secure_storage | 本地配置、Token 安全存储 |
| 权限 | permission_handler | Android MANAGE_EXTERNAL_STORAGE |

## 服务端详解

### 入口点

`server/main.py` — FastAPI 应用入口。注册所有 API 路由，配置 CORS（`allow_origins=["*"]`），设置 lifespan 事件初始化数据库并启动自动扫描后台任务。

### API 路由

```
/api/auth/*         — 登录、注册、用户管理、通知、头像上传
/api/games/*        — 游戏 CRUD、搜索、版本移动
/api/tags/*         — 标签 CRUD
/api/roots/*        — 根目录管理、扫描触发
/api/file-sources/* — OpenList 服务器管理
/api/download/*     — 游戏文件下载（本地/OpenList 302 重定向）
/api/files/*        — 封面/背景/头像静态文件服务
/api/scrape/*       — 刮削搜索、元数据应用、封面管理
/api/settings/*     — 扫描设置、刮削配置、回收站
/api/setup/*        — 初始化向导（首次设置）
/api/steam/*        — Steam 补丁匹配、索引、下载
```

除 `/api/auth/login`、`/api/auth/register`、`/api/setup/*` 和健康检查外，所有端点需要 `Authorization: Bearer <token>` 认证。游戏列表、详情、搜索等只读端点也需要认证。

### 数据模型

```
User ──► Notification
  │         └─ target_user_id
  ├─ username
  ├─ password_hash + salt
  ├─ token（随机 hex，64 字符）
  ├─ is_admin
  ├─ status（active / pending）
  └─ avatar_path

Game ──► GameVersion
  │         └─ platform, filename, file_size, extract_password
  ├─ Company（多对一）
  ├─ GameTag ──► Tag
  ├─ RootDirectory（多对一）
  ├─ cover_path, bg_path
  ├─ developer, description
  └─ vndb_id, steam_id, bangumi_id

RootDirectory
  ├─ type（local / openlist）
  ├─ path
  ├─ structure（company_game / game_only / flat）
  └─ file_source_id（OpenList 源 ID，可为空）

FileSource（OpenList 服务器）
  ├─ url
  ├─ username
  └─ password
```

### 扫描与导入流程

1. `POST /api/roots/refresh-all` 触发全量扫描
2. `services/file_source.py` 根据根目录类型选择本地文件或 OpenList 适配器
3. `services/scanner.py` 遍历根目录，识别会社/游戏/版本层级
4. 文件名清洗：正则提取平台标识 `[PC]` `[KRKR]` `[RPG]` 等
5. 支持的压缩格式：`.zip` `.rar` `.7z` `.tar` `.gz` `.xz` `.apk`
6. `services/importer.py` 将扫描结果写入数据库，新增/更新/标记孤立记录

### 下载流程

**本地文件源：**

```
客户端 GET /api/download/{gameId}/{versionId}
  → 服务端 FileResponse 返回文件流
  → 客户端 stream 写入临时文件
  → 7zip-zstd 解压到本地下载目录
```

**OpenList 文件源：**

```
客户端 GET /api/download/{gameId}/{versionId}
  → 服务端获取 OpenList token → 调用 /api/fs/get 获取签名 URL
  → 服务端返回 302 重定向至 OpenList /d/... 签名 URL
  → 客户端跟随 → OpenList 返回 302 至网盘/CDN
  → 客户端直连 CDN 下载（绕过服务端带宽限制）
```

下载器只将 Sena Token 发给 Sena 服务端，后续跳转不携带认证头，确保令牌不泄露给第三方。

客户端下载进度 UI 约每 250ms 刷新一次，任务状态约每 2 秒持久化一次，避免每个网络分片都写 SharedPreferences。

### 刮削流程

```
客户端选择刮削源 → 输入搜索关键词
  → GET /api/scrape/search?q=xxx&source=vndb_kana
  → 服务端调用对应刮削器（VNDB / Steam / Bangumi / Kungal 等）
  → 返回结果列表 → 客户端选择 → 逐字段对比
  → POST /api/scrape/apply → 服务端写入数据库，封面/背景异步下载
```

### Steam 补丁注入（PC）

```
客户端扫描 steamapps 目录 → 提取 appmanifest_*.acf → 获取 app_id
  → POST /api/steam/scan {games: [{app_id, name, install_dir}]}
  → 服务端用 patches.json 按 app_id 匹配
  → 返回匹配结果 → 客户端显示 → 点击注入 → 下载解压到游戏目录
```

### 页面导航（home_screen.dart）

底部/侧边导航使用 `IndexedStack` 保活所有页面：

```
游戏库（GameProvider 驱动）
  → 搜索/排序/过滤 → GameDetailScreen → GameEditScreen

Steam 补丁（SteamPatchScreen）
  → 客户端 Tab + 服务端 Tab

我的（ProfileScreen）
  → 设置（SettingsScreen）→ 下载设置 / 扫描设置 / 刮削配置
  → 个人信息编辑（ProfileEditScreen）
```

## 跨平台适配

| 平台 | 特殊处理 |
|------|---------|
| Windows | 单实例锁（窗口绑定）；窗口管理 + 托盘；7z.exe + 7z.dll；安装包（fastforge + Inno Setup） |
| Android | 存储权限（MANAGE_EXTERNAL_STORAGE）；7z ELF 通过 linker64 执行；通知权限；APK 直装 |
| Linux | AppImage 打包；7zz 独立二进制；触摸屏环境变量 `GDK_BACKEND=wayland,x11` |

### Linux Runner 触控补丁

仓库不提交 `client/linux` 目录。GitHub Actions 在 Linux 构建阶段执行 `flutter create .` 生成 runner，然后调用：

```bash
python3 ../.github/scripts/patch_linux_runner_touch.py
```

该脚本修改生成后的 `linux/runner/main.cc` 和 `linux/runner/my_application.cc`：

- 强制优先 `GDK_BACKEND=wayland,x11`
- 输出 Linux 输入诊断日志到 stderr
- 递归启用 GTK touch/button/motion 事件
- 将单指 touch begin/update/end 桥接为鼠标左键 press/motion/release

如需调整 Linux 触控兼容逻辑，应优先修改 `.github/scripts/patch_linux_runner_touch.py`，不要手动维护生成目录。

## CI/CD

三个 GitHub Actions 工作流（`.github/workflows/`）：

| 文件 | 触发 | 构建产物 | 发布 |
|------|------|---------|------|
| `build.yml` | push dev/main | Android APK + Windows + Linux AppImage + Server Tarball；版本号显示为 `0.0.0` / `test` | 无 |
| `build_Release.yml` | 手动 | 同上；版本号为正式版本号 | GitHub Release + GHCR `:latest` + DockerHub `:latest` |
| `build_PreRelease.yml` | 手动 | 同上 | GitHub Pre-Release + DockerHub `:pre-release` |

发布正式 Release 时会自动删除所有旧的 Pre-Release。Windows 安装包使用 fastforge + Inno Setup，支持中文安装界面、开始菜单快捷方式和卸载支持。

## 安全设计

- 密码使用 bcrypt 哈希，不存储明文
- Token 为 32 字节随机十六进制字符串（64 字符），改密后立即重置，客户端同步更新会话
- 所有 API 端点（除 login/register/setup/health）需要 Bearer Token 认证
- 注册接口不允许申请管理员权限，需管理员单独授权
- 自签 HTTPS 支持（客户端允许所有证书）
- 文件服务仅允许图片扩展名（`.jpg` `.png` `.gif` `.webp` `.bmp`）
- 外部 URL 下载前校验协议格式，防止 SSRF
- OpenList 下载 302 跳转链中不携带 Sena Token，避免令牌泄露给第三方
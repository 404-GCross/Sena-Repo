# 贡献指南

欢迎为 **Sena Repo** 做出贡献。Sena Repo 是一个由 FastAPI 服务端和 Flutter 多平台客户端组成的视觉小说私有库管理器，当前主要面向 Windows、Android、Linux 客户端和 Docker 服务端。

如果你只是反馈问题、补充文档或提出功能建议，也同样是有价值的贡献。

## 开始之前

- 请先搜索 [Issues](https://github.com/404-GCross/Sena-Repo/issues)，确认是否已有相同问题或建议。
- 较大的功能改动建议先开 Issue 讨论，尤其是会影响数据库结构、客户端/服务端 API、下载协议、Steam 补丁流程或发布工作流的改动。
- 当前主要开发分支是 `dev`，Pull Request 请默认提交到 `dev`。
- 本项目包含游戏库扫描、OpenList 文件源、元数据刮削、Steam 补丁注入、LunaBox / ReinaManager 推送下载等功能。改动其中任一流程时，请同时检查客户端、服务端和文档是否需要同步。

## 仓库结构

| 路径 | 说明 |
|------|------|
| `server/` | FastAPI 服务端、SQLite 数据库模型、扫描/刮削/下载 API |
| `client/` | Flutter 客户端，支持 Windows / Android / Linux |
| `Documentation/zh-CN/` | 中文用户文档、技术文档、排障文档和测试清单 |
| `.github/workflows/` | CI、开发版预发布、正式 Release 和 7-Zip-zstd 构建流程 |
| `7zip-zstd/` | 构建产物期望存在的 7-Zip-zstd 平台二进制目录 |
| `.codex/skills/` | 本仓库的 Codex 项目规则与提交规范 |

> `client/linux` 不提交到仓库。Linux runner 由 CI 中的 `flutter create .` 生成，并通过 `.github/scripts/patch_linux_runner_touch.py` 自动补丁。

## 报告 Bug

请尽量提供：

1. 问题现象、期望行为和复现步骤
2. 客户端平台与版本（Windows / Android / Linux，安装包类型）
3. 服务端部署方式（Docker / 直接运行）、版本、系统架构
4. 相关日志截图或文本
5. 是否使用 OpenList、网盘、代理、Steam 补丁库或外部管理器推送下载

请不要公开粘贴密码、Token、OpenList 登录信息、签名下载 URL、Authorization Header 或任何可直接访问私有资源的链接。

## 本地开发

### 服务端

建议使用 Python 3.11+；CI 使用 Python 3.12 做语法检查。

```bash
cd server
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements.txt
python main.py
```

服务端默认监听 `11451`。常用环境变量可参考 `server/config.example.yaml` 和 `Documentation/zh-CN/server-guide.md`：

- `SENA_GAMES_PATH`：游戏库路径
- `SENA_DATA_PATH`：数据库、图片和配置数据路径
- `SENA_PATCH_DIR`：Steam 补丁库路径
- `SENA_PROXY`：刮削代理
- `SENA_BANGUMI_TOKEN` / `SENA_VNDB_TOKEN`：可选刮削 Token
- `SENA_HIKARINAGI_CLIENT_ID` / `SENA_HIKARINAGI_CLIENT_SECRET`：Hikarinagi Client Credentials 配置
- `SENA_HIKARINAGI_SCOPE`：Hikarinagi API 权限范围，默认 `catalog:full`

### 客户端

CI 使用 Flutter `3.44.8` stable。建议本地使用同版本，避免平台工程和 analyzer 结果不一致。

```bash
cd client
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter run
```

桌面端功能会依赖平台能力：

- Windows / Linux：下载、解压、托盘、窗口管理、Steam 导入与补丁注入
- Android：下载、解压、安装 APK；不显示 Steam 相关功能
- Linux：触屏兼容补丁在 CI 生成 runner 后注入，修改时请改 `.github/scripts/patch_linux_runner_touch.py`

## 提交代码

1. 从 `dev` 创建功能分支。
2. 保持改动聚焦，不要把无关格式化、实验文件或本地设计稿一起提交。
3. 同步修改客户端、服务端、Schema、文档和测试清单中受影响的部分。
4. 提交信息使用英文 Conventional Commits，例如：

```text
fix: update Hikarinagi metadata scraping
feat: add manual Steam patch rule mode
docs: refresh contribution guide
```

5. Pull Request 描述中说明：
   - 改动了什么
   - 为什么这样改
   - 已经跑过哪些检查
   - 是否影响数据库、配置、下载协议或客户端/服务端 API

## 检查与测试

按改动范围运行尽可能窄且可靠的检查。

### 服务端改动

```bash
cd server
python -m compileall .
```

如果只改了少量文件，也可以使用：

```bash
python -m py_compile path/to/file.py
```

涉及数据库模型、Pydantic Schema、API 返回字段或导入流程时，请同时检查：

- SQLAlchemy 模型
- Pydantic Schema
- 数据库初始化 / 迁移兼容逻辑
- Flutter 客户端解析字段
- 文档和测试清单

### 客户端改动

```bash
cd client
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
```

涉及下载、解压、日志、Steam、Android 权限、Linux 触屏或外部管理器协议时，建议至少做一次目标平台实机验证。

### 文档改动

请确认：

- README、`Documentation/zh-CN/` 和 `CONTRIBUTING.md` 的功能描述一致
- 工作流名称、Flutter 版本、Docker 镜像标签和平台产物没有过期
- 示例命令不包含真实路径、Token 或私有 URL

## CI 与发布

当前主要工作流：

| 工作流 | 触发 | 作用 |
|--------|------|------|
| `.github/workflows/build.yml` | push / PR 到 `dev`、`main`、`master`，也支持手动触发 | 服务端 `compileall`、Flutter analyze、构建 Android / Windows / Linux / Server，并在非 PR 时发布 `dev-release` 预发布 |
| `.github/workflows/build_Release.yml` | 手动触发 | 构建正式 Release 产物，发布 GitHub Release，并推送 Docker 镜像 |
| `.github/workflows/build-7zz-zstd.yml` | 手动或维护触发 | 构建各平台 7-Zip-zstd 二进制 |

`build.yml` 中的关键检查是：

- `Server checks`：安装服务端依赖并执行 `python -m compileall .`
- `Flutter analyze`：安装 Flutter `3.44.8` 并执行 `flutter analyze --no-fatal-infos --no-fatal-warnings`

不要把完整打包成功当成 analyzer 的替代信号；客户端改动应明确确认 `Flutter analyze` 通过。

## 开发注意事项

### 客户端 / 服务端协议

新增、重命名或删除 API 字段时，请同时检查：

- 服务端请求/响应模型
- Flutter `ApiClient`、数据模型和 UI 调用点
- 现有数据库数据的默认值与兼容逻辑
- 相关文档和错误提示

### 下载与外部管理器

下载链路可能涉及本地文件、OpenList 302、网盘/CDN、Range 请求、签名 URL、校验值和第三方管理器协议。修改时请特别注意：

- 不要让 OpenList 大文件默认走 Sena 服务端代理，除非功能明确要求
- 不要把 Sena Token、OpenList 凭据或签名下载 URL 写入日志
- LunaBox 推送下载当前需要 `size`、`expires_at`；`checksum_algo` / `checksum` 有值时必须成对传递，无值时两者都不要传
- ReinaManager 与 LunaBox 协议不同，不要把两个目标的字段假设为完全一致

### Steam 补丁

Steam 补丁功能分为客户端本机扫描/注入和服务端补丁库管理/匹配。改动时请确认：

- Android 不显示 Steam 补丁功能
- OpenList 补丁库需要区分本地映射与网盘
- 网盘模式不应为了探测压缩包目录树而下载整包
- `patches.json`、手写规则、压缩包目录树和客户端注入行为保持一致

### 安全与隐私

- 不提交真实配置、Token、密码、Cookie、OpenList 凭据或私有下载链接
- 日志中避免输出 Authorization Header、签名 URL、账号标识和外部服务密钥
- 服务端公网部署前请自行加固；本项目更推荐在内网、VPN 或受控环境中使用

## 文档同步

如果改动影响用户可见行为，请同步更新至少一个相关文档：

- `README.md` / `README_zh_CN.md`
- `Documentation/zh-CN/server-guide.md`
- `Documentation/zh-CN/client-guide.md`
- `Documentation/zh-CN/technical.md`
- `Documentation/zh-CN/troubleshooting.md`
- `Documentation/zh-CN/test-checklist.md`

## 许可证

贡献的代码将采用本项目相同的 [AGPL-3.0 许可证](https://github.com/404-GCross/Sena-Repo/blob/dev/LICENSE)。

如果你分发修改版，或将修改版作为网络服务提供给他人使用，请遵守 AGPL-3.0 的源代码公开要求。

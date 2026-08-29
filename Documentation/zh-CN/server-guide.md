# Sena Repo 服务端部署说明书

> [!CAUTION]
>
> Sena Repo 由 AI 辅助开发，安全性未经过专业审计。**强烈建议仅在 VPN 或家庭内网环境中使用，不建议直接暴露到公网。**

## 目录

- [部署前准备](#部署前准备)
- [服务端部署](#服务端部署)
- [配置参考](#配置参考)
- [OpenList 文件源](#openlist-文件源)
- [Steam 补丁](#steam-补丁)
- [附录](#附录)

---

## 部署前准备

### 目录结构

Sena Repo 按固定层级扫描游戏文件，部署前请先整理好文件：

```
游戏目录/
  ├── 会社A/
  │   ├── 游戏1/
  │   │   ├── [PC]游戏1.rar
  │   │   └── [KRKR]游戏1_v2.zip
  │   └── 游戏2/
  │       └── [Ty]游戏2.7z
  └── 会社B/
      └── 游戏3/
          └── 直装_游戏3.apk
```

| 层级 | 内容 |
|------|------|
| 第一级 | 会社文件夹（文件夹名即会社名） |
| 第二级 | 游戏文件夹（文件夹名即游戏名） |
| 第三级 | 压缩包（`.rar` `.zip` `.7z` `.tar` `.gz` `.xz` `.apk`） |

- 平台标记：`[PC]` `[KRKR]` `[Ty]` `[ONS]` `直装_`，无标记默认 PC
- 压缩包直接放在会社目录下也可以，自动视为独立游戏

> 文件不按规则整理则扫不出来。也可以在设置中调整目录结构为"仅游戏"或"扁平"模式。

如果游戏库和 Steam 补丁库都使用 OpenList 作为文件来源，服务端本地无需挂载 `/games` 和 `/steam_patch`。

### Steam 补丁目录结构

```
steam_patch/
├── patches.json               ← 自动生成，记录所有补丁
├── patch_type_keywords.json   ← 类型识别关键词配置
├── 游戏1_Steam_Chinese_Patch.7z
└── 游戏2_Steam_Voice_Patch.rar
```

---

## 服务端部署

### 方式一：Docker 拉取（推荐）

Release 发布时镜像自动推送到 DockerHub 和 GHCR，同时支持 amd64 和 arm64。

```bash
# DockerHub（推荐）
docker pull 404gcross/sena-repo:latest

# GHCR（备用）
docker pull ghcr.io/404-gcross/sena-repo:latest

# Pre-release 测试版
docker pull 404gcross/sena-repo:pre-release
```

**基础启动：**

```bash
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  --restart unless-stopped \
  404gcross/sena-repo:latest
```

**纯 OpenList 启动（游戏文件全在 OpenList 上）：**

```bash
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/data:/data \
  --restart unless-stopped \
  404gcross/sena-repo:latest
```

**完整启动（含刮削 API Key 与代理）：**

```bash
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  -e SENA_BANGUMI_TOKEN="your_token" \
  -e SENA_VNDB_TOKEN="your_token" \
  -e SENA_PROXY="http://127.0.0.1:7890" \
  --restart unless-stopped \
  404gcross/sena-repo:latest
```

**Docker Compose：**

```yaml
services:
  sena-repo:
    image: 404gcross/sena-repo:latest
    container_name: sena-repo
    ports:
      - "11451:11451"
    volumes:
      - /path/to/games:/games
      - /path/to/data:/data
      - /path/to/steam_patches:/steam_patch
    environment:
      - SENA_BANGUMI_TOKEN=your_token      # 可选
      - SENA_VNDB_TOKEN=your_token         # 可选
      - SENA_PROXY=http://127.0.0.1:7890   # 可选，刮削代理
    restart: unless-stopped
```

**纯 OpenList Docker Compose：**

```yaml
services:
  sena-repo:
    image: 404gcross/sena-repo:latest
    container_name: sena-repo
    ports:
      - "11451:11451"
    volumes:
      - /path/to/data:/data
    restart: unless-stopped
```

### 方式二：Tarball 加载

从 [Releases](https://github.com/404-GCross/Sena-Repo/releases) 下载对应架构的 `Sena-Repo_Server_*.tar.gz`：

| 架构 | 文件名 |
|------|--------|
| x86_64 / amd64 | `Sena-Repo_Server_amd64_v*.tar.gz` |
| ARM64 | `Sena-Repo_Server_arm64_v*.tar.gz` |

```bash
docker load < Sena-Repo_Server_amd64_v0.1.0.tar.gz
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  sena-repo:latest
```

### 方式三：安装脚本直接部署

> 适合没有 Docker 的设备，例如部分 arm32 NAS、盒子或 Armbian 设备。amd64 / arm64 仍建议优先使用 Docker。

```bash
git clone -b dev https://github.com/404-GCross/Sena-Repo.git
cd Sena-Repo/server
sudo bash install.sh
```

脚本当前支持 Debian / Ubuntu / Armbian 一类带 `apt` 与 `systemd` 的系统，会自动安装 Python 编译依赖、创建 venv、写入 systemd 服务并启动服务。

默认路径：

| 路径 | 说明 |
|------|------|
| `/opt/sena-repo/server` | 服务端程序 |
| `/opt/sena-repo/venv` | Python 虚拟环境 |
| `/etc/sena-repo/sena-repo.env` | 服务端环境变量 |
| `/var/lib/sena-repo` | 数据库、封面、配置数据 |
| `/srv/sena-repo/games` | 本地游戏库目录 |
| `/srv/sena-repo/steam_patch` | Steam 补丁目录 |

更新：

```bash
cd Sena-Repo/server
sudo bash install.sh --update
```

卸载程序文件：

```bash
sudo bash /opt/sena-repo/server/install.sh --uninstall
```

卸载会保留 `/var/lib/sena-repo` 和 `/etc/sena-repo/sena-repo.env`，避免误删数据库和配置。

---

## 配置参考

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SENA_GAMES_PATH` | 游戏文件目录 | `/games` |
| `SENA_DATA_PATH` | 数据目录（数据库、封面等） | `/data` |
| `SENA_PATCH_DIR` | Steam 补丁目录 | `/steam_patch` |
| `SENA_HOST` | 监听地址 | `0.0.0.0` |
| `SENA_PORT` | 监听端口 | `11451` |
| `SENA_PROXY` | 刮削代理（http/socks5） | 空 |
| `SENA_BANGUMI_TOKEN` | Bangumi API Token | 空 |
| `SENA_VNDB_TOKEN` | VNDB API Token | 空 |

### config.yaml（可选）

`/data/config.yaml` 可覆盖部分配置（环境变量优先级更高）：

```yaml
server:
  host: 0.0.0.0
  port: 11451

games_path: /games
data_path: /data
patch_dir: /steam_patch
steam_dir: ""
proxy: ""

scrapers:
  bangumi_token: ""
  vndb_token: ""
```

### 数据目录结构

```
/data/
├── sena_repo.db          ← SQLite 数据库
├── covers/               ← 游戏封面图
├── backgrounds/          ← 游戏背景图
├── avatars/              ← 用户头像
├── scan_settings.json    ← 扫描配置持久化
└── scraper_config.json   ← 刮削配置持久化
```

### 刮削源

| 刮削源 | 认证要求 | 说明 |
|--------|---------|------|
| VNDB Kana v2 | 可选 Token | 含游戏时长数据 |
| Bangumi | 可选 Token | 中文元数据丰富 |
| Steam | 免认证 | 封面、背景、简介 |

---

## OpenList 文件源

Sena Repo 支持将 OpenList 作为游戏库或 Steam 补丁库的文件来源，添加分两步：

**第一步：添加 OpenList 服务器**

在「扫描设置」→「OpenList 服务器」中添加，填写：
- OpenList 地址（客户端和服务端都能访问的地址，如 `http://192.168.1.100:5244`）
- 用户名和密码（留空则使用 OpenList 访客模式）

**第二步：添加目录**

在「游戏库目录」或「Steam 补丁目录」中选择该 OpenList 服务器，填写 OpenList 内部路径，例如 `/115/Games/GalGame/Library`。目录内仍需遵守 Sena Repo 的目录结构规则。

**下载链路：**

```
客户端 → Sena /api/download/{id}
  → 302 → OpenList /d/文件路径?sign=...
  → 302 → 网盘/CDN 直链
  → 客户端直接从网盘/CDN 下载
```

Sena 服务端只生成跳转，不代理大文件流量。OpenList 地址必须从客户端设备可访问。

---

## Steam 补丁

### 工作原理

```
补丁文件（.7z/.rar/.zip 等）
    │
扫描 → patches.json（记录 AppID、文件路径、类型等）
    │
客户端扫描本地 steamapps → 匹配 AppID → 下载注入
```

### AppID 识别规则（优先级从高到低）

1. 文件名中的纯数字（`123456.zip` → 123456）
2. 父目录名中的纯数字（`123456/patch.zip` → 123456）
3. 从文件名提取游戏名 → Steam Store API 搜索
4. 都失败则 `app_id: null`，可手动在客户端填写

### 补丁类型识别关键词

| 类型 | 默认关键词 |
|------|-----------|
| `translation`（汉化） | `_Steam_Chinese_Patch` |
| `voice`（音声） | `_Steam_Voice_Patch` |
| `story`（剧情） | `_Steam_Story_Patch` |
| `extra`（额外） | `_Steam_Extra_Patch` |
| `misc`（其他） | 无关键词匹配时 |

关键词可在客户端 Steam 补丁页编辑，或直接修改 `patch_type_keywords.json`。

### patches.json 字段说明

| 字段 | 说明 |
|------|------|
| `app_id` | Steam AppID |
| `file` | 压缩包相对补丁目录的路径 |
| `patch_dir` | 解压后取哪个子目录的内容（空=自动选） |
| `target_dir` | 复制到游戏目录的哪个子路径（空=根目录） |
| `label` | 界面显示名称 |
| `type` | 补丁类型 |
| `game_name` | Steam 游戏中文名 |

---

## 附录

### 支持的压缩格式

`.zip` `.rar` `.7z` `.tar` `.gz` `.xz` `.apk`

### 平台标识

| 标识 | 平台 |
|------|------|
| `[PC]` | Windows PC |
| `[KRKR]` | Kirikiri |
| `[Ty]` | Tyranor |
| `[ONS]` | ONScripter |
| `直装_` / `.apk` | Android 直装 |

### 默认端口

`11451` — 服务端 HTTP API

### 相关文档

- [客户端使用说明书](client-guide.md)
- [技术文档](technical.md)
- [疑难杂症](troubleshooting.md)

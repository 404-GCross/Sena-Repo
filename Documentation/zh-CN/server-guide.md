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

如果游戏库和 Steam 补丁库都使用 OpenList 作为文件来源，服务端本地无需挂载实际的 `/games` 和补丁文件目录。补丁索引与关键词配置都写在数据目录下的 `steam_patch_index/`，只要 `/data` 是持久化挂载即可。

### Steam 补丁目录结构

```
steam_patch/                      ← 补丁压缩包目录（本地类型的补丁库）
├── 游戏1_Steam_Chinese_Patch.7z
└── 游戏2_Steam_Voice_Patch.rar

data/steam_patch_index/           ← 索引目录，位于数据目录内
├── patches.json                  ← 自动生成，记录所有补丁与匹配规则
└── patch_type_keywords.json      ← 补丁类型识别关键词配置
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
  -e SENA_PATCH_DIR=/data/steam_patch \
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
    environment:
      - SENA_PATCH_DIR=/data/steam_patch
    restart: unless-stopped
```

Docker 镜像内置 `senacli`，可以直接在容器里执行本地维护命令：

```bash
docker exec -it sena-repo senacli status
docker exec -it sena-repo senacli scan --scrape missing
docker exec -it sena-repo senacli useradd
```

Docker 部署的升级和卸载仍应在宿主机通过重新拉取镜像、停止旧容器、重建容器完成；容器内的 `senacli update` / `senacli uninstall` 只会给出操作提示，不会尝试修改宿主机。

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

一键下载安装稳定版（默认安装 `main` 分支）：

```bash
curl -fsSL https://raw.githubusercontent.com/404-GCross/Sena-Repo/main/server/install.sh | sudo bash
```

安装开发版 / `dev` 分支：

```bash
curl -fsSL https://raw.githubusercontent.com/404-GCross/Sena-Repo/dev/server/install.sh | sudo SENA_REPO_REF=dev bash
```

如果需要指定端口、数据目录或 Python 路径，可以把环境变量放到 `sudo` 后面：

```bash
curl -fsSL https://raw.githubusercontent.com/404-GCross/Sena-Repo/main/server/install.sh | sudo SENA_PORT=11451 SENA_DATA_PATH=/var/lib/sena-repo bash
```

如果希望先查看脚本内容再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/404-GCross/Sena-Repo/main/server/install.sh
sudo bash install.sh
```

也可以手动 clone 稳定版源码后运行本地脚本：

```bash
git clone https://github.com/404-GCross/Sena-Repo.git
cd Sena-Repo/server
sudo bash install.sh
```

如果需要开发版源码：

```bash
git clone -b dev https://github.com/404-GCross/Sena-Repo.git Sena-Repo-dev
cd Sena-Repo-dev/server
sudo SENA_REPO_REF=dev bash install.sh
```

脚本当前支持带 `systemd` 的常见 Linux 发行版，会自动识别 `apt-get`、`dnf`、`yum`、`zypper` 或 `pacman` 安装 Python 编译依赖、创建 venv、写入 systemd 服务并启动服务。已覆盖 Debian / Ubuntu / Armbian、Fedora / RHEL / Rocky / AlmaLinux / openEuler、openSUSE、Arch / Manjaro 等发行版。

如果发行版不在上述包管理器范围内，脚本不会立即退出；只要系统已经手动准备好依赖，仍会继续尝试创建 venv 和安装服务。

如果系统默认 `python3` 低于 3.10，可以通过环境变量指定 Python：

```bash
sudo SENA_PYTHON_BIN=/usr/bin/python3.11 bash install.sh
```

Steam 补丁压缩包探测需要 `7z` / `7zz` / `7za`。RPM 系发行版如果没有直接安装到 7z，通常需要先启用 EPEL 或手动安装 `7zip` / `p7zip`。

如果服务端已经安装，再次直接运行安装脚本时会先检查远程提交版本：已是最新则不重复安装；检测到新提交才会更新依赖并重启服务。需要强制更新可使用 `--update`，只检查而不更新可使用 `--check`。

安装完成后会注册本地维护命令 `senacli`，常用命令如下：

```bash
senacli status --roots
senacli scan
senacli scan --scrape missing
senacli clear
senacli backup
senacli backup /path/to/backup-dir
senacli backup -o /path/to/backup.json
senacli restore sena-steam-patch-rules-20260909-153000.json
senacli restore sena-steam-patch-rules-20260909-153000.json --skip-keywords
senacli update --channel dev
senacli update --channel release
senacli uninstall
```

用户管理命令：

```bash
senacli users
senacli useradd
senacli username
senacli passwd
senacli useradmin
senacli userdel
```

`useradd` 在数据库没有任何用户时会创建首个服主；已有用户后默认创建普通用户，加 `--admin` 可创建管理员。`username`、`passwd`、`useradmin` 会让目标用户现有登录态失效，用户需要重新登录。`clear` 只清空游戏、版本和游戏标签关联，目录配置、用户、OpenList 与刮削配置会保留，然后重新扫描。

### 备份与恢复 Steam 补丁

`senacli backup` / `senacli restore` 用于导出和恢复 Steam 补丁的匹配规则与补丁类型识别关键词，导出的是两份东西：

| 内容 | 来源文件 | 说明 |
|------|----------|------|
| 匹配规则 | `steam_patch_index/patches.json` | AppID、游戏名、标签、类型、`patch_dir`、`target_dir`、清单确认状态 |
| 类型关键词 | `steam_patch_index/patch_type_keywords.json` | 按文件名自动识别补丁类型的词表 |

只导出真正配置过的条目：没有任何规则（AppID、标签、目录、已确认清单、非 `misc` 类型全为空）的补丁不会进备份。

```bash
# 备份到数据目录下的 backups/steam-patch-rules/
senacli backup

# 备份到指定目录或指定文件
senacli backup /path/to/backup-dir
senacli backup -o /path/to/backup.json

# 恢复（默认同时覆盖匹配规则和类型关键词）
senacli restore sena-steam-patch-rules-20260909-153000.json

# 只恢复匹配规则，保留服务器上现有的类型关键词
senacli restore sena-steam-patch-rules-20260909-153000.json --skip-keywords

# 先清空当前规则再恢复，脚本化恢复时加 -y 跳过确认
senacli restore sena-steam-patch-rules-20260909-153000.json --replace -y
```

恢复前会打印预览（可恢复、会变更、无效条目、冲突、未匹配、关键词），并分别备份当前的 `patches.json` 和 `patch_type_keywords.json` 到 `backups/steam-patch-rules/`。恢复是覆盖式的：`--replace` 会把现有规则清空再写入，关键词则总是整体覆盖（除非加 `--skip-keywords`）。

匹配靠补丁的路径和文件身份（`source_type` / `source_id` / `file` / `source_path` / 文件名加大小），所以本地重扫、目录改名或网盘换路径都可能导致条目对不上，此时会记在预览的"未匹配"里，不会被写坏。没有 `keywords` 字段的旧版备份只恢复规则，不报错。

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
sudo bash /opt/sena-repo/install.sh --update
```

更新会从配置的远程仓库和分支拉取最新服务端代码，不使用当前目录中的旧代码；数据库、游戏目录、补丁目录和环境配置会保留。

只检查是否有更新、不执行安装：

```bash
sudo bash /opt/sena-repo/install.sh --check
```

安装脚本会记录上次使用的仓库地址和分支；未显式设置 `SENA_REPO_URL` / `SENA_REPO_REF` 时，后续检查会继续使用该记录。

卸载程序文件：

```bash
sudo bash /opt/sena-repo/uninstall.sh
```

默认卸载会保留 `/var/lib/sena-repo` 和 `/etc/sena-repo/sena-repo.env`，避免误删数据库和配置。需要连数据库与配置一起清除时：

```bash
sudo bash /opt/sena-repo/uninstall.sh --purge-data
```

也可以明确保留数据：

```bash
sudo bash /opt/sena-repo/uninstall.sh --keep-data
```

不带选项且在交互终端执行时，脚本会询问是否删除；如果程序目录已经被删除但数据库或配置仍在，也会先询问。非交互执行默认保留数据，并提示使用 `--purge-data`。

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
| `SENA_NEXTMOE_API_KEY` | NextMoe 应用密钥（`nmk_live_…`） | 空 |

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
  hikarinagi_client_id: ""
  hikarinagi_client_secret: ""
  nextmoe_api_key: ""
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
| Hikarinagi | Client ID / Secret | 中文 Galgame 资料站 |
| NextMoe | 应用密钥 | 聚合六源；独立模式，开启后禁用其他刮削源 |

> NextMoe 是独立的刮削模式：在客户端「扫描设置 → 刮削源」中开启 NextMoe 后，其余刮削源会自动关闭并禁用，单条目和批量刮削都只走 NextMoe。密钥在 https://developer.nextmoe.dev 控制台自助创建应用并勾选 `catalog:read`，免费额度为每分钟 60 次、每天 50000 次。关闭 NextMoe 后其余刮削源恢复可选。

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

关键词文件位于数据目录的 `steam_patch_index/patch_type_keywords.json`，可在客户端 Steam 补丁页的"关键词快捷匹配"里编辑，也可以直接改这个文件。文件名（统一转小写）包含任一关键词即归为该类型，按类型顺序取第一个命中的；`misc` 不参与匹配。

这份文件只在不存在时才会写入上面的默认值，之后以文件内容为准——也就是说修改过关键词后，升级服务端不会覆盖你改过的词。它会被 `senacli backup` 一起导出，`senacli restore` 默认一起恢复（加 `--skip-keywords` 可保留服务器上的现有词表）。

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

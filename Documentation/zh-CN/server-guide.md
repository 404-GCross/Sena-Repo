# Sena-Repo 服务端部署说明书

## 目录

- [概述](#概述)
- [服务端部署](#服务端部署)
- [配置参考](#配置参考)
- [导入及清洗逻辑](#导入及清洗逻辑)
- [Steam 补丁](#steam-补丁)
- [附录](#附录)

---

> [!CAUTION]
>
> Sena-Repo 为社区开发，安全性无法切实保证。**强烈建议仅在 VPN 或家庭内网环境中使用，不要直接暴露到公网。**

---




### 部署前准备

Sena-Repo 按固定目录结构扫描游戏，**部署前请先整理好文件**：

```
游戏目录/
  ├── 会社A/
  │   ├── 游戏1/
  │   │   ├── [PC]游戏1.rar       ← 带平台标记的压缩包
  │   │   └── [KRKR]游戏1_v2.zip
  │   └── 游戏2/
  │       └── [Ty]游戏2.7z
  └── 会社B/
      └── 游戏3/
          └── 直装_游戏3.apk
```

- **第一级** → 会社（文件夹名即会社名）
- **第二级** → 游戏（文件夹名即游戏名）
- **第三级** → 压缩包（`.rar` `.zip` `.7z` `.tar` `.gz` `.xz` `.apk`）
- 平台标记：`[PC]` `[KRKR]` `[Ty]` `[ONS]` `直装_`，无标记默认 PC
- 压缩包直接放在会社目录下也可以（自动视为独立游戏）

> **文件不按规则整理 → 扫不出来。** 安排好了再部署容器进行扫描。

## 方式一：GHCR 拉取（推荐）

每次 Release 发布时，Docker 镜像会自动推送到 GitHub Container Registry。本仓库公开，镜像可直接拉取，无需登录。镜像同时包含 **amd64** 和 **arm64** 架构，Docker 会自动拉取匹配的版本。

```bash
# 拉取最新版本
docker pull ghcr.io/404-gcross/sena-repo:latest

# 或拉取指定版本
docker pull ghcr.io/404-gcross/sena-repo:v0.1.0
```

**基础启动：**

```bash
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  ghcr.io/404-gcross/sena-repo:latest
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
  -e SENA_PROXY="http://127.0.0.1:7890" \
  ghcr.io/404-gcross/sena-repo:latest
```

**Docker Compose：**

```yaml
services:
  sena-repo:
    image: ghcr.io/404-gcross/sena-repo:latest
    container_name: sena-repo
    ports:
      - "11451:11451"
    volumes:
      - /path/to/games:/games
      - /path/to/data:/data
      - /path/to/steam_patches:/steam_patch
    environment:
      - SENA_BANGUMI_TOKEN=your_token      # 可选
      - SENA_PROXY=http://127.0.0.1:7890   # 可选，刮削代理
    restart: unless-stopped
```

## 方式二：Tarball 加载

从 [Releases](https://github.com/404-GCross/Sena-Repo/releases) 下载 `Sena-Repo_Server_v*.tar.gz` 后手动加载。

```bash
docker load < Sena-Repo_Server_v0.1.0.tar.gz  # 改成对应版本号

docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  sena-repo:latest
```

从 [Releases](https://github.com/404-GCross/Sena-Repo/releases) 下载时注意选择对应架构的包：

| 架构 | 文件名 |
|------|--------|
| x86_64 / amd64 | `Sena-Repo_Server_amd64_v*.tar.gz` |
| ARM64（树莓派 / NAS） | `Sena-Repo_Server_arm64_v*.tar.gz` |


## 方式三：直接部署

>[!TIPS]
>
> 此方式未经过充分测试，不推荐。建议优先使用 Docker。

```bash
git clone https://github.com/404-GCross/Sena-Repo.git
cd Sena-Repo/server
pip install -r requirements.txt
python main.py --host 0.0.0.0 --port 11451 \
  --games-path /path/to/games \
  --data-path /path/to/data
```

## 服务端更新

```bash
# ── GHCR ──
docker pull ghcr.io/404-gcross/sena-repo:latest
docker stop sena-repo && docker rm sena-repo
# 执行完以上命令后，重新执行服务端部署（挂载目录不变，数据不丢失）

# ── docker-compose ──
docker pull ghcr.io/404-gcross/sena-repo:latest
docker-compose down && docker-compose up -d

# ── Tarball ──
docker load < Sena-Repo_Server_v新版本.tar.gz
docker stop sena-repo && docker rm sena-repo
# 执行完以上命令后，重新执行服务端部署（挂载目录不变，数据不丢失）

# ── 直接部署 ──
cd Sena-Repo && git pull && cd server && pip install -r requirements.txt
pkill -f "python main.py" && python main.py ...
```

---

## 配置参考

### 挂载 / 环境变量

| 目录 / 变量 | 作用 | 必须 |
|-------------|------|------|
| `/games` | 游戏文件存放目录 | 是 |
| `/data` | 数据库、封面、背景、配置 | 是 |
| `/steam_patch` | Steam 补丁压缩包目录 | Steam 补丁功能需要 |
| `SENA_BANGUMI_TOKEN` | Bangumi API Token | 可选 |
| `SENA_PROXY` | 刮削 HTTP 代理 | 可选 |

### 刮削 API Key 获取地址

| 刮削源 | 获取地址 |
|--------|---------|
| Bangumi | [bgm.tv/dev/app](https://bgm.tv/dev/app) |
| VNDB | —（免认证） |

---

## 导入及清洗逻辑

### 文件结构

>[!IMPORTANT]
> 
> - 当前 Sena-Repo 仅测试通过会社/游戏的文件结构，其他文件结构仍未测试，未确保可用。
> - Sena-Repo 严格按照所选择的文件目录模式来扫描，建议先整理好服务端内的资源文件再进行部署扫描。

会社/游戏模式里，服务端按三级目录扫描，每一级都有特定含义：

```
根目录/                         ← --games-path
  ├── 会社A/                    ← 第一级：会社
  │   ├── 游戏1/                ← 第二级：游戏
  │   │   ├── [PC]游戏1.rar     ← 第三级：版本文件
  │   │   └── [Ty]游戏1.zip
  │   └── 游戏2/
  │       ├── [PC]游戏2.zip
  │       └── [KRKR]游戏2.zip
  └── 会社B/
      └── 游戏3/
          └── 直装_游戏3.apk
```

**第一级 · 会社** — 文件夹名自动填入游戏的**开发商**字段（不覆盖手动修改的值），同时作为标签附加。

**第二级 · 游戏** — 每个子文件夹视为一个独立游戏项目，文件夹名即为游戏名。

**第三级 · 版本文件** — 同一游戏下的每个压缩包各生成一个可下载版本，非压缩包文件自动过滤。文件名按规则解析：

| 格式 | 示例 | 解析结果 |
|------|------|---------|
| `[平台]游戏名.rar` | `[PC]游戏1.rar` | 平台=PC，游戏名=游戏1 |
| `[平台]游戏名.zip` | `[KRKR]游戏2.zip` | 平台=KRKR，游戏名=游戏2 |
| `直装_游戏名.apk` | `直装_游戏5.apk` | 平台=安卓直装，游戏名=游戏5 |

支持的平台标识：`PC`、`KRKR`、`Ty`、`ONS`、`直装`，`.apk` 后缀或含"安卓""直装"字样自动归类为安卓直装。

### 刮削源

| 刮削源 | 说明 |
|--------|------|
| VNDB Kana v2 | 免认证，含游戏时长数据 |
| Bangumi | 免认证 |
| Steam | 免认证 |
| DLsite | 免认证 |
| 月幕 GalGame | 免认证 |

---

## Steam 补丁

### 工作原理

```
补丁目录（.zip/.rar/.7z 等）
    │
scan_patches.py ──→ patches.json
    │                   ↓             客户端: 扫 steamapps → 匹配 → 注入
    │              ┌─ 服务端Tab: 查看/编辑/扫描索引
    └─ Steam API ─┘  (根据文件名搜索 AppID)
```

补丁文件放在服务端，客户端扫描本地 Steam 库后自动匹配并注入。

### 补丁目录结构

```
steam_patches/
├── patches.json               ← 自动生成
├── patch_type_keywords.json   ← 类型识别关键词
├── 游戏1_Steam_extra_Patch.7z
└── 游戏2_Steam_Chinese_Patch.rar
```

直接把补丁压缩包放在补丁目录下即可，`scan_patches.py` 会递归扫描所有子目录。

### AppID 自动识别

1. 文件名中的纯数字（如 `123456.zip` → 123456）
2. 父目录名中的纯数字（如 `123456/v2.zip` → 123456）
3. 从文件名提取游戏名 → 调 Steam Store API 搜索 → 获取 AppID
4. 都失败则 `app_id: null`，可手动填写

> 游戏名提取规则：去掉文件扩展名 → 去掉类型关键词后缀 → 下划线替换空格。

### 补丁类型自动分类

根据文件名中的关键词（大小写不敏感）：

| 类型 | 默认关键词 |
|------|-----------|
| `translation`（汉化） | `_Steam_Chinese_Patch` |
| `voice`（音声） | `_Steam_Voice_Patch` |
| `story`（剧情） | `_Steam_Story_Patch` |
| `extra`（额外） | `_Steam_Extra_Patch` |
| `misc`（其他） | 默认（无关键词匹配时） |

关键词可通过客户端 Steam 补丁页右上角 🔍 编辑，或直接修改 `patch_type_keywords.json`。

### patches.json 格式

```json
{
  "patches": [
    {
      "app_id": 123456,
      "file": "想要传达给你的爱恋_Steam_extra_Patch.7z",
      "patch_dir": "",
      "target_dir": "",
      "label": "",
      "type": "extra",
      "game_name": "游戏中文名"
    }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `app_id` | Steam AppID，可自动识别或手动填写 |
| `file` | 压缩包相对补丁目录的路径 |
| `patch_dir` | 解压后取哪个子目录的内容（空=自动选） |
| `target_dir` | 复制到游戏目录的哪个子路径（空=根目录） |
| `label` | 界面显示名称 |
| `type` | 补丁类型：`translation` / `voice` / `story` / `extra` / `misc` |
| `game_name` | Steam 游戏中文名，扫描时自动获取 |

### patch_dir / target_dir 规则

**简单路径**（两者都为空）：压缩包直接解压到游戏根目录。适用于压缩包内部已按游戏目录结构组织的场景。

**复杂路径**（任一非空）：
1. 解压到临时目录
2. 定位源目录（`patch_dir`）：从 `临时目录/patch_dir/` 取文件；若为空且临时目录只有一个文件夹则自动选择
3. 合并到目标目录（`target_dir`）：文件复制到 `游戏目录/target_dir/`

举例：压缩包内结构为 `汉化v2/data/patch.xp3`，配置 `patch_dir="汉化v2"` `target_dir=""` → 文件提取到游戏根目录。

---

## 附录

### 支持的压缩格式

`.zip` `.rar` `.7z` `.tar` `.gz` `.xz` `.apk`

### 支持的平台标识

| 标识 | 平台 |
|------|------|
| `[PC]` | Windows |
| `[KRKR]` | Kirikiri |
| `[Ty]` | Tyranor |
| `[ONS]` | ONScripter |
| `直装_` / `.apk` | 安卓直装 |

### 默认端口

| 端口 | 用途 |
|------|------|
| 11451 | 服务端 HTTP/HTTPS API |

### 相关文档

- [客户端使用说明书](client-guide.md)
- [技术文档](technical.md)
- [疑难杂症](troubleshooting.md)

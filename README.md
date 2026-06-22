# Sena Repo - GalGame 私有库管理器

**Sena Repo** 是一款面向多平台的视觉小说仓库管理工具，适合管理部署在远程服务器（如 NAS）上的游戏库，让使用者能方便地浏览、搜索、下载与安装自己的游戏收藏。

服务端（Docker / Python）负责扫描目录、清洗文件名、刮削元数据；客户端（Windows / Android / Linux）通过 HTTP/HTTPS 连接服务端，提供一体化的游戏库浏览和下载安装体验。

---

## 导入及清洗逻辑

### 目录结构 （当前仅会社/游戏目录测试通过，其他目录结构支持仍在测试与调整中）

```
根目录/
  ├── 会社A/                    ← 第一级：会社文件夹
  │   ├── 游戏1/                ← 第二级：游戏文件夹
  │   │   ├── [PC]游戏1.rar
  │   │   └── [Ty]游戏1.zip
  │   ├── 游戏2/
  │   │   ├── [PC]游戏2.zip
  │   │   └── [KRKR]游戏2.zip
  │   └── 游戏3/
  │       └── 直装_游戏3.apk
  └── 会社B/
      └── 游戏4/
          └── 游戏4安卓直装版.apk
```

### 处理流程

**扫描 → 清洗 → 导入 → 刮削**

1. **第一级** → 识别为**会社**，自动作为标签附加，并填入**开发商**字段
2. **第二级** → 识别为**游戏项目**
3. **第三级** → 识别为游戏对应的**压缩包文件**，同一游戏可包含多平台版本

### 清洗规则

| 文件名 | 游戏名 | 平台 |
|-------|-------|------|
| `[PC]游戏1.rar` | 游戏1 | PC |
| `[KRKR]游戏2.zip` | 游戏2 | KRKR |
| `[Ty]游戏4.zip` | 游戏4 | Tyranor |
| `直装_游戏5.apk` | 游戏5 | 安卓直装 |

支持的平台标识：`PC`、`KRKR`、`Ty`、`ONS`、`直装`，末尾 `.apk` 或含"安卓""直装"字样自动归类。

### 导入规则

- 会社名自动填入**开发商**字段（不覆盖手动修改）
- 同一游戏多平台压缩包各生成独立版本
- 非压缩包文件自动过滤
- 会社名自动作为标签

### 刮削

| 刮削源 | 说明 |
|--------|------|
| VNDB Kana v2 | 免认证，含游戏时长 |
| Bangumi | 免认证 |
| Steam | 免认证 |
| DLsite | 免认证 |
| 月幕 GalGame | 免认证 |

---

## 主要功能

- **游戏库浏览** — 网格/列表双视图，搜索、排序、游戏时长显示
- **元数据编辑** — 下载元数据逐字段对比勾选，封面上传即时生效
- **用户系统** — 登录/注册，管理员审批，头像上传
- **游戏下载** — 暂停/取消/断点续传，Android 外部存储解压
- **初始化向导** — 首次连接自动创建管理员 + 配置目录
- **Steam 补丁注入**（PC）— 双 Tab 客户端/服务端管理，关键词快捷匹配类型，注入进度条
- **Windows 安装包** — 便携 zip + 安装包 exe，开始菜单 + 卸载入口
- **个性化** — 主题色，最小化托盘，双击拉起已运行实例

---

## 服务端部署

### 方式一：GHCR 拉取（推荐）

每次 Release 发布时，Docker 镜像会自动推送到 GitHub Container Registry。本仓库公开，镜像可直接拉取，无需登录。

```bash
# 拉取最新版本
docker pull ghcr.io/404-gcross/sena-repo:latest

# 或拉取指定版本
docker pull ghcr.io/404-gcross/sena-repo:v0.1.0
```

**启动容器：**

```bash
# 基础启动
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  ghcr.io/404-gcross/sena-repo:latest

# 完整启动（含刮削 API Key）
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  -e SENA_BANGUMI_TOKEN="your_token" \
  -e SENA_VNDB_TOKEN="your_token" \
  -e SENA_IGDB_CLIENT_ID="your_id" \
  -e SENA_IGDB_CLIENT_SECRET="your_secret" \
  -e SENA_PROXY="http://127.0.0.1:7890" \
  ghcr.io/404-gcross/sena-repo:latest
```

**Docker Compose（GHCR）：**

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
      - SENA_VNDB_TOKEN=your_token         # 可选
      - SENA_IGDB_CLIENT_ID=your_id        # 可选
      - SENA_IGDB_CLIENT_SECRET=your_secret # 可选
      - SENA_PROXY=http://127.0.0.1:7890   # 可选，刮削代理
    restart: unless-stopped
```

### 方式二：Tarball 加载

从 [Releases](https://github.com/404-GCross/Sena-Repo/releases) 下载 `Sena-Repo_Server_v*.tar.gz` 后手动加载。

```bash
docker load < Sena-Repo_Server_v0.1.0.tar.gz

docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /path/to/games:/games \
  -v /path/to/data:/data \
  -v /path/to/steam_patches:/steam_patch \
  sena-repo:latest
```

### 挂载说明

| 目录 | 作用 | 是否必须 |
|------|------|---------|
| `/games` | 游戏文件存放目录 | 是 |
| `/data` | 数据库、封面、背景、配置 | 是 |
| `/steam_patch` | Steam 补丁压缩包目录 | Steam 补丁功能需要 |

### 刮削 API Key（可选，通过环境变量传入）

| 环境变量 | 对应刮削源 | 获取地址 |
|---|---|---|
| `SENA_BANGUMI_TOKEN` | Bangumi | [bgm.tv/dev/app](https://bgm.tv/dev/app) |
| `SENA_VNDB_TOKEN` | VNDB | — |
| `SENA_IGDB_CLIENT_ID` | IGDB | [dev.twitch.tv](https://dev.twitch.tv/console/apps) |
| `SENA_IGDB_CLIENT_SECRET` | IGDB | 同上 |
| `SENA_PROXY` | 代理 | 刮削走代理，如 `http://127.0.0.1:7890` |

### 直接部署

> ⚠️ 此方式未经过充分测试，不推荐使用。建议优先使用 Docker 部署。

```bash
git clone https://github.com/404-GCross/Sena-Repo.git
cd Sena-Repo/server
pip install -r requirements.txt
python main.py --host 0.0.0.0 --port 11451 \
  --games-path /path/to/games \
  --data-path /path/to/data
```

### 服务端更新方法

```bash
# ── GHCR（推荐）──
# docker run 方式
docker pull ghcr.io/404-gcross/sena-repo:latest
docker stop sena-repo && docker rm sena-repo
# 重新 docker run（挂载目录不变，数据不丢失）

# docker-compose 方式
docker pull ghcr.io/404-gcross/sena-repo:latest
docker-compose down && docker-compose up -d

# ── Tarball ──
# docker run 方式
docker load < Sena-Repo_Server_v新版本.tar.gz
docker stop sena-repo && docker rm sena-repo
# 重新 docker run（挂载目录不变，数据不丢失）

# docker-compose 方式（需先将 compose 中的 image 改为 sena-repo:latest）
docker load < Sena-Repo_Server_v新版本.tar.gz
docker-compose down && docker-compose up -d

# ── 直接部署 ──
cd Sena-Repo && git pull && cd server && pip install -r requirements.txt
pkill -f "python main.py" && python main.py ...
```


## 客户端安装

从 [Releases](https://github.com/404-GCross/Sena-Repo/releases) 下载：

- **Windows**：安装包 `.exe`（含卸载）或便携版 `.zip`
- **Android**：`.apk`
- **Linux**：`.AppImage`



## 使用方法

### 首次设置

连接服务端 → 同意免责声明 → 初始化向导创建管理员 → 配置游戏目录 → 自动扫描

### 游戏库

底部导航切换 → 搜索/排序 → 详情页 → 下载或编辑

### Steam 补丁

打开 Steam 补丁页 → 选择 steamapps 目录 → 自动匹配 → 点击注入

---

## 免责声明

- 本项目为开源项目，仅用于合法用途，管理您有权使用的游戏/应用。
- 您需要自行确认资源与第三方组件的合法性。
- 本项目不提供游戏本体、破解资源、绕过授权的能力或任何违规用途的支持。
- 本项目由 AI 辅助开发，安全性未经审计，服务端部署至公网前请自行加固。
- 本项目在后续更新中可能涉及服务端变动，可能存在无法保数据更新的可能。
---

## 开源协议

本项目采用 **GNU Affero General Public License v3.0 (AGPL-3.0)**。

**你可以：**
- 自由使用、复制、修改、分发本项目
- 将本项目用于商业或非商业用途
- 将修改后的版本作为网络服务运行

**你需要：**
- 分发或公开部署修改后的版本时，开源你的修改
- 即使只通过网络提供服务（不分发二进制），也要提供源代码
- 保留原始版权声明和许可声明
- 使用相同的 AGPL-3.0 许可证

**简单来说：** 自己用随便改；如果把修改版给别人用或部署成公共服务，代码也要开源。

# Sena-Repo 服务端部署说明书

Sena-Repo 服务端负责扫描游戏库目录、维护数据库、提供下载接口、处理批量刮削任务和 Steam 补丁索引。客户端只需要连接服务端地址即可浏览、下载和管理自己的视觉小说库。

> [!CAUTION]
> Sena-Repo 面向私有库使用，建议只部署在家庭内网、NAS、VPN 或可信网络中。不要在没有反向代理鉴权、防火墙和 HTTPS 的情况下直接暴露到公网。

## 目录

- [部署前准备](#部署前准备)
- [Docker 部署](#docker-部署)
- [更新服务端](#更新服务端)
- [首次初始化](#首次初始化)
- [游戏库目录](#游戏库目录)
- [OpenList 文件来源](#openlist-文件来源)
- [扫描与刮削](#扫描与刮削)
- [Steam 补丁库](#steam-补丁库)
- [配置参考](#配置参考)
- [维护与排障](#维护与排障)

## 部署前准备

### 推荐目录

```text
/docker/Sena-Repo/
  data/          # 数据库、封面、背景、配置文件
  games/         # 本地游戏库，可选
  steam_patch/   # Steam 补丁库，默认路径
```

容器内默认路径：

| 容器路径 | 用途 | 是否建议挂载 |
| --- | --- | --- |
| `/data` | SQLite 数据库、封面、背景、设置文件 | 必须 |
| `/games` | 默认本地游戏库目录 | 可选，但推荐 |
| `/steam_patch` | 默认 Steam 补丁目录 | 使用补丁功能时推荐 |

### 安全建议

- 使用强密码创建首个管理员。
- 新注册用户默认应保持普通用户，管理员审核后再授予权限。
- 服务端数据库位于 `/data/sena_repo.db`，更新容器前不要删除 `/data`。
- 如果需要公网访问，建议放在 HTTPS 反向代理后，并限制来源 IP 或配合 VPN。

## Docker 部署

### GHCR 镜像

```bash
docker pull ghcr.io/404-gcross/sena-repo:latest

docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /docker/Sena-Repo/data:/data \
  -v /docker/Sena-Repo/games:/games \
  -v /docker/Sena-Repo/steam_patch:/steam_patch \
  --restart unless-stopped \
  ghcr.io/404-gcross/sena-repo:latest
```

### DockerHub 镜像

```bash
docker pull 404gcross/sena-repo:latest
docker pull 404gcross/sena-repo:pre-release
```

测试预发布版本时可以使用：

```bash
docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /docker/Sena-Repo/data:/data \
  -v /docker/Sena-Repo/games:/games \
  -v /docker/Sena-Repo/steam_patch:/steam_patch \
  --restart unless-stopped \
  404gcross/sena-repo:pre-release
```

### Docker Compose

```yaml
services:
  sena-repo:
    image: ghcr.io/404-gcross/sena-repo:latest
    container_name: sena-repo
    ports:
      - "11451:11451"
    volumes:
      - /docker/Sena-Repo/data:/data
      - /docker/Sena-Repo/games:/games
      - /docker/Sena-Repo/steam_patch:/steam_patch
    environment:
      - SENA_GAMES_PATH=/games
      - SENA_DATA_PATH=/data
      - SENA_PATCH_DIR=/steam_patch
      # 可选：刮削代理
      # - SENA_PROXY=http://127.0.0.1:7890
      # 可选：API Token
      # - SENA_BANGUMI_TOKEN=your_token
      # - SENA_VNDB_TOKEN=your_token
    restart: unless-stopped
```

启动：

```bash
docker compose up -d
docker logs -f sena-repo
```

健康检查：

```bash
curl http://127.0.0.1:11451/api/health
```

## 更新服务端

### Docker / Compose

```bash
docker compose pull
docker compose up -d
```

如果使用 `docker run`：

```bash
docker pull ghcr.io/404-gcross/sena-repo:latest
docker stop sena-repo
docker rm sena-repo
# 使用原来的 -v 参数重新 docker run
```

只要 `/data` 挂载路径不变，数据库、封面、背景和设置不会丢失。

### 查看版本

客户端“关于”页会显示服务端版本。容器日志中也会输出启动信息和数据库路径。

## 首次初始化

首次连接一个未初始化的服务端时，客户端会进入初始化向导。服务端初始化会完成：

1. 创建管理员账号。
2. 添加游戏库目录。
3. 添加 Steam 补丁库目录。
4. 保存扫描设置和自动扫描间隔。
5. 保存批量自动刮削字段来源规则。
6. 启动后台扫描。

如果服务端被重置，客户端使用旧配置连接时会重新进入初始化流程。

## 游戏库目录

Sena-Repo 支持三种扫描结构，推荐使用“会社 / 游戏”。

### 会社 / 游戏

```text
/games/
  SAGA PLANETS/
    金辉恋曲四重奏/
      [PC]金辉恋曲四重奏.rar
      [KRKR]金辉恋曲四重奏.7z
  ALcot/
    Clover Day's/
      Clover Day's Plus.rar
```

含义：

- 第一级目录：会社 / 开发商。
- 第二级目录：游戏条目。
- 第三级文件：游戏版本压缩包。

### 仅游戏

```text
/games/
  金辉恋曲四重奏/
    [PC]金辉恋曲四重奏.rar
```

适合没有按会社整理的游戏库。

### 扁平

```text
/games/
  [PC]游戏A.rar
  [KRKR]游戏B.7z
```

适合简单目录，但元数据整理效果通常不如前两种。

### 平台识别

常见平台标记：

| 标记 | 平台 |
| --- | --- |
| `[PC]` | PC |
| `[KRKR]` | KRKR |
| `[Ty]` | Tyranor |
| `[ONS]` | ONScripter |
| `直装` / `.apk` | Android 直装 |

支持的常见压缩格式包括 `.zip`、`.rar`、`.7z`、`.tar`、`.gz`、`.xz`、`.apk`。当前项目内置 7zip-zstd，用于提升压缩格式兼容性。

## OpenList 文件来源

Sena-Repo 可以把 OpenList 作为游戏库或 Steam 补丁库来源。OpenList 添加逻辑分两步：

1. 先在“扫描设置”中添加 OpenList 服务器。
2. 再添加游戏库目录或 Steam 补丁库目录，并选择对应 OpenList 服务器。

### 地址填写原则

OpenList 地址是服务端和客户端都需要能访问的地址。因为下载时会经过 302 跳转，最终由客户端直接访问 OpenList 和网盘 CDN。

推荐填写：

```text
http://192.168.1.100:5244
```

目录路径填写 OpenList 内部路径，例如：

```text
/115/Games/GalGame/Library
/115/Games/GalGame/Steam_Patch
```

### 下载链路

```text
客户端请求 Sena /api/download/{game_id}/{version_id}
  -> Sena 返回 302 到 OpenList /d/...?...sign=...
  -> OpenList 返回 302 到网盘 / CDN 直链
  -> 客户端直接下载文件
```

Sena-Repo 不转发大文件流量，因此 OpenList 地址必须对客户端可达；否则扫描可能成功，但客户端下载会失败或卡住。

### OpenList 排障

在 Sena 容器内测试：

```bash
docker exec -i sena-repo python - <<'PY'
import urllib.request
url = "http://192.168.1.100:5244/api/public/settings"
with urllib.request.urlopen(url, timeout=10) as r:
    print(r.status)
    print(r.read(200).decode("utf-8", "ignore"))
PY
```

测试 OpenList 登录和列目录时，优先使用 `/api/auth/login`；部分 OpenList 配置下 `/api/auth/login/hash` 可能返回用户名或密码错误。

## 扫描与刮削

### 扫描设置

客户端“设置 -> 扫描设置”中可以管理：

- OpenList 服务器。
- 游戏库目录。
- Steam 补丁库目录。
- 目录结构。
- 自动扫描开关和间隔。
- 立即扫描。
- 清空游戏库并重新扫描。
- 批量刮削任务。
- 刮削源和批量自动刮削字段来源。

### 清空游戏库并重新扫描

“清空并重扫”会删除数据库中的游戏条目、版本、标签关联和已刮削元数据，然后重新扫描所有游戏库目录。

不会删除：

- 本地游戏文件。
- OpenList / 网盘文件。
- 游戏库目录设置。
- Steam 补丁库目录设置。
- 用户账号。

如果当前已经有扫描任务运行，服务端会拒绝清空重扫，避免边扫边删导致数据错乱。

### 刮削源

当前支持：

| 来源 | 说明 |
| --- | --- |
| VNDB Kana v2 | 支持中文标题、时长等信息，可使用 VNDB Token |
| Bangumi | 支持关键词或 ID 刮削 |
| Steam | 使用 Steam Store 信息，背景图优先使用 `header_image` |
| YMGal | 月幕 GalGame 元数据 |

### 批量自动刮削字段来源

批量和自动刮削可以按字段指定来源，例如：

- 名称：Steam。
- 封面：VNDB Kana。
- 背景图：Steam。
- 简介：Bangumi。
- 平均游戏时长：VNDB Kana。

选择“跟随刮削源顺序”的字段会保持旧逻辑：按启用来源顺序填充缺失字段。单个游戏手动刮削不受这套批量规则影响。

## Steam 补丁库

Steam 补丁库用于管理汉化、语音、剧情、额外内容等补丁压缩包，客户端可将补丁注入到本地 Steam 游戏目录。

### 默认目录

服务端默认补丁目录为：

```text
/steam_patch
```

Docker 建议挂载：

```bash
-v /docker/Sena-Repo/steam_patch:/steam_patch
```

也可以通过环境变量修改：

```bash
SENA_PATCH_DIR=/steam_patch
```

### 补丁文件

直接把补丁压缩包放入补丁库即可，可以使用子目录：

```text
/steam_patch/
  金辉恋曲四重奏_Steam_Chinese_Patch.rar
  ATRI_Steam_Extra_Patch.7z
```

扫描补丁后，服务端会生成或更新补丁索引。客户端 Steam 补丁页可以：

- 扫描服务端补丁库。
- 自动识别 Steam AppID。
- 编辑补丁类型、AppID、目标目录等参数。
- 下载并注入补丁。
- 打开对应游戏目录。

### 补丁路径规则

- `patch_dir`：从压缩包内哪个目录取文件。
- `target_dir`：复制到游戏目录下哪个子目录。
- 两者为空时，默认把压缩包内容解到游戏根目录。

Windows 和 Linux 的配置路径建议统一使用 `/` 风格路径，服务端会按平台处理，不需要在配置里强制写 `\`。

## 配置参考

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SENA_GAMES_PATH` | `/games` | 默认本地游戏库目录 |
| `SENA_DATA_PATH` | `/data` | 数据库和资源目录 |
| `SENA_PATCH_DIR` | `/steam_patch` | Steam 补丁目录 |
| `SENA_HOST` | `0.0.0.0` | 监听地址 |
| `SENA_PORT` | `11451` | 监听端口 |
| `SENA_PROXY` | 空 | 刮削请求代理 |
| `SENA_BANGUMI_TOKEN` | 空 | Bangumi Token |
| `SENA_VNDB_TOKEN` | 空 | VNDB Token |
| `SENA_YMGAL_CLIENT_ID` | `ymgal` | YMGal Client ID |
| `SENA_YMGAL_CLIENT_SECRET` | `luna0327` | YMGal Client Secret |

### 数据目录内容

```text
/data/
  sena_repo.db
  covers/
  backgrounds/
  scan_settings.json
  scraper_config.json
```

升级、迁移和备份时优先备份整个 `/data`。

## 维护与排障

### 查看日志

```bash
docker logs -f sena-repo
```

关注关键词：

- `Database initialized at`：数据库路径。
- `Scanning root`：正在扫描的目录。
- `Scan discovered`：扫描到的会社、游戏、压缩包数量。
- `OpenList login request failed`：OpenList 登录失败。
- `Request URL is missing an 'http://' or 'https://' protocol`：OpenList 地址缺少协议或未正常保存。

### 扫描不到游戏

按顺序检查：

1. 游戏库目录是否已添加到“扫描设置”。
2. 目录结构是否选对。
3. 压缩包是否放在对应层级。
4. OpenList 路径是否能列出下级目录和压缩包。
5. 服务端日志中 `Scan discovered` 的数量是否为 0。

### OpenList 下载慢或卡住

1. 在客户端浏览器直接打开 OpenList 文件下载，确认网盘本身速度正常。
2. 检查客户端日志中的 302 链路是否跳到 OpenList，再跳到网盘 CDN。
3. 确认客户端能访问 OpenList 地址，而不仅是 Sena 服务端能访问。
4. 检查客户端是否设置了下载限速。

### 相关文档

- [客户端使用说明书](client-guide.md)
- [技术文档](technical.md)
- [疑难杂症](troubleshooting.md)

# 疑难杂症

## 服务端

### Docker 容器启动后立即退出

`docker ps` 看不到容器，`docker ps -a` 显示 `Exited`。

```bash
docker logs sena-repo 2>&1 | tail -30
```

常见原因：`config.yaml` 字段拼写错误、数据库文件损坏、端口被占用。

### 游戏扫描不到文件

执行扫描后游戏库仍为空。

1. 目录结构是否符合三级层级（会社/游戏/文件）
2. 文件名是否能匹配平台标识（`[PC]` `[KRKR]` 等）
3. 文件是否为支持的格式（`.zip` `.rar` `.7z` `.apk` 等）
4. 容器内用户能否读取挂载的游戏目录

### Steam 补丁扫描返回 0

显示"扫描完成，找到 0 个文件"，但补丁文件实际存在。

1. **补丁目录挂载错误——最常见。** 默认目录是 `/data/steam_patches`，不是 `/steam_patch`。确认：
   ```bash
   docker exec sena-repo ls /data/steam_patches/
   ```
2. 可在 `docker run` 时加 `-e SENA_PATCH_DIR=/steam_patch` 显式指定
3. 容器内区分大小写，`.ZIP` 不会被识别
4. 支持的扩展名：`.zip` `.rar` `.7z` `.tar` `.gz` `.xz`

### 补丁扫描提示 401 / 403

`POST /api/steam/scan-patches` 需要管理员权限。

- **401** — 请求未携带有效 token。重新登录客户端
- **403** — 当前用户不是管理员。切换管理员账号

### 自动扫描不生效

设置页打开了"自动扫描"但服务端没有自动触发。

1. 确认当前用户是管理员——自动扫描 API 需要管理员权限
2. 检查设置是否持久化：
   ```bash
   docker exec sena-repo cat /data/scan_settings.json
   ```
3. 自动扫描每 5 分钟检查一次，刚设置完后等几分钟再观察

### OpenList 游戏扫描不到

OpenList 源添加成功，但扫描后游戏库为空。

1. 确认 OpenList 地址带有客户端和 Sena 服务端都能访问的 IP/域名，例如 `http://192.168.1.100:5244`
2. 服务端日志中如果出现 `Request URL is missing an 'http://' or 'https://' protocol`，说明旧配置缺少协议；编辑 OpenList 服务器后保存一次
3. 确认 OpenList 路径填的是游戏库根目录，例如 `/115/Games/GalGame/Library`
4. 确认路径下面仍符合 Sena 的目录结构：`会社/游戏/压缩包`
5. 在 Sena 容器内测试 OpenList API：
   ```bash
   docker exec -i sena-repo python - <<'PY'
   import json, urllib.request
   base = "http://你的OpenList地址:5244"
   username = "用户名"
   password = "密码"
   path = "/115/Games/GalGame/Library"
   req = urllib.request.Request(
       base + "/api/auth/login",
       data=json.dumps({"username": username, "password": password}).encode(),
       headers={"Content-Type": "application/json"},
   )
   with urllib.request.urlopen(req, timeout=10) as r:
       token = json.loads(r.read().decode())["data"]["token"]
   req = urllib.request.Request(
       base + "/api/fs/list",
       data=json.dumps({"path": path, "password": "", "page": 1, "per_page": 50, "refresh": False}).encode(),
       headers={"Content-Type": "application/json", "Authorization": token},
   )
   with urllib.request.urlopen(req, timeout=10) as r:
       data = json.loads(r.read().decode())
   print(data.get("code"), data.get("message"))
   for item in (data.get("data", {}).get("content") or [])[:20]:
       print(item.get("name"), "dir=", item.get("is_dir"))
   PY
   ```

### SQLite database is locked

并发写入导致。SQLite 只支持单写者。减少并发写入操作。SQLAlchemy 的 `aiosqlite` 驱动会排队，但超时后仍会报错。

### GHCR 拉取 / 推送失败

**拉取：** GHCR 公开，不需要登录。404 则检查 tag 是否存在。

**推送：** Settings → Actions → General → Workflow permissions 设为 "Read and write"。

### DockerHub 镜像

正式版：

```bash
docker pull 404gcross/sena-repo:latest
```

测试版：

```bash
docker pull 404gcross/sena-repo:pre-release
```

---

## 客户端

### 连接报 503 Service Unavailable

服务端进程正在启动但尚未就绪，或启动过程中崩溃。症状是客户端发起请求后收到 503。

排查：

```bash
docker ps -a | grep sena-repo
docker logs sena-repo --tail 20
docker exec sena-repo python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:11451/api/health').read())"
```

常见原因：数据库损坏、容器内存不足、首次全量扫描耗时过长、`games_path` 路径不存在。

### 连接超时或拒绝
- 服务端是否绑定 `--host 0.0.0.0`
- 防火墙是否放行 11451 端口
- Docker 端口映射 `-p 11451:11451` 是否正确
- 客户端协议（HTTP/HTTPS）与服务端是否匹配

**自签名 HTTPS 证书：** 客户端仅对配置过的服务器 host 允许自签名证书。更换服务器 IP/域名后在连接页重新输入地址即可。

### Linux AppImage 启动报错

Flutter 桌面应用依赖 Qt/GTK 运行时库，精简版 Linux 发行版可能缺少以下依赖：

**`dlopen(): error loading libfuse.so.2`**

```bash
sudo apt-get install -y libfuse2      # Debian/Ubuntu
sudo dnf install fuse-libs            # Fedora
```

**`error while loading shared libraries: libgtk-3.so.0`**

```bash
sudo apt-get install -y libgtk-3-0    # Debian/Ubuntu
sudo dnf install gtk3                 # Fedora
```

**`libayatana-appindicator3.so.1`**

```bash
sudo apt-get install -y libayatana-appindicator3-1   # Debian/Ubuntu
# Fedora 上该库可能不可用，不影响主窗口显示
```

**`libEGL.so.1`**

```bash
sudo apt-get install -y libegl1 libegl-mesa0
```

**`libGL.so.1 or libOpenGL.so.0`**

```bash
sudo apt-get install -y libgl1 libopengl0 libegl1 libegl-mesa0
```

**字体缺失 / 中文显示为方块**

```bash
sudo apt-get install -y fonts-noto-cjk fonts-wqy-microhei
```

**一键全装（Debian/Ubuntu）：**

```bash
sudo apt-get install -y libfuse2 libgtk-3-0 libayatana-appindicator3-1 libegl1 libgles2 libgl1 libopengl0 fonts-noto-cjk fonts-wqy-microhei
```

**依赖汇总：**

| 依赖 | Debian/Ubuntu | Fedora | 用途 |
|------|------|------|------|
| FUSE | `libfuse2` | `fuse-libs` | AppImage 挂载 |
| GTK3 | `libgtk-3-0` | `gtk3` | 窗口框架 |
| EGL | `libegl1 libegl-mesa0` | `mesa-libEGL` | GPU 渲染 |
| OpenGL | `libgl1 libopengl0` | `mesa-libGL` | 3D 加速 |
| AppIndicator | `libayatana-appindicator3-1` | — | 系统托盘 |
| 中文字体 | `fonts-noto-cjk fonts-wqy-microhei` | `google-noto-cjk-fonts` | UI 文字 |

如仍缺其他 `.so`，搜包名：

```bash
# Debian/Ubuntu
apt-file search <文件名>      # 或: dnf provides <文件名> (Fedora)
```

### Linux 触摸屏无响应

Linux AppImage 会在 runner 层启用触控兼容，并优先使用 `GDK_BACKEND=wayland,x11`。如果触摸无响应，先从终端启动应用收集日志：

```bash
./Sena-Repo_Linux_v0.1.4-x86_64.AppImage 2>&1 | tee sena-touch.log
```

重点查看以下日志：

```text
Sena Linux input backend preference: wayland,x11
Sena Linux GTK display: wayland-0
Sena Linux touch event: begin ...
```

判断方法：

- 有 `Sena Linux touch event`：系统和 GTK 已收到触摸，应用会把单指触摸桥接为鼠标左键点击/拖动
- 没有 `Sena Linux touch event`：桌面环境、Gamescope 或启动方式可能没有把触摸事件送进 GTK
- 看不到任何 `Sena Linux ...` 日志：确认是否从终端启动了新版 AppImage，Steam/游戏模式可能会吞掉 stderr

### 保存扫描设置失败(500)



### Windows：7z 解压报 "Cannot open the file as archive"

下载的临时文件不完整或损坏。

1. 手动用 `7z.exe t <文件路径>` 测试
2. 如文件正确但仍打不开，删除 `%APPDATA%\senarepo\sena_repo\7z.exe` 和 `7z.dll` 让应用重新提取

### 下载解压后文件不在预期目录

压缩包自带文件夹名与游戏名不一致。`_fixLayout` 会自动将单顶层文件夹重命名为游戏名。

### 导入 Steam 提示"未找到 Python 运行环境"

Python 随客户端分发，在 `sena_repo.exe` 同级目录的 `python/` 文件夹中。

1. 确认 `python/python.exe` 与 `sena_repo.exe` 在同一目录
2. 便携版解压时需保留完整文件夹结构
3. 如版本过旧，下载最新 Release（`pyd` 文件曾因 `.gitignore` 被排除）

### 头像不显示

头像通过 `/api/files/avatars/` 加载，确认客户端已连接到服务端。

### 游戏库 Tab 切换后不刷新

`IndexedStack` 保活页面但不会自动重构。在 Tab 切换回调中显式调用 `refreshGames()`。

### Android：权限弹窗无法跳转设置

通过 `permission_handler` 打开系统设置页。如仍失败，手动在系统设置中搜索"所有文件访问"并开启。

### OpenList 下载卡在正在连接

新版客户端日志会记录每一跳：

```text
download request[0]: Sena /api/download ...
download redirect[0]: Sena -> OpenList /d/...
download request[1]: OpenList /d/...
download redirect[1]: OpenList -> 网盘/CDN
download request[2]: CDN ...
download final[2]: HTTP 200/206 ...
download first chunk: ...
```

判断方法：

- 停在 `request[0]`：客户端到 Sena 服务端不通
- 停在 `request[1]`：客户端访问不了 OpenList 地址。OpenList 地址必须对客户端可达，不能只对 Sena 服务端可达
- 停在 `request[2]`：客户端访问网盘/CDN 不通或被 CDN 限制
- 有 `final` 但无 `first chunk`：CDN 返回响应头后长时间不发数据，客户端会在空闲超时后失败
- 有 `first chunk`：下载已经开始，速度慢通常是网络/CDN 或客户端写盘性能问题

可在客户端所在设备上用 curl 验证完整链路：

```bash
curl -v -L -r 0-1023 -o /dev/null \
  -H "Authorization: Bearer <SenaToken>" \
  "http://Sena地址:11451/api/download/游戏ID/版本ID"
```

如果 curl 能拿到 `206 Partial Content`，说明 Sena → OpenList → CDN 的 302 链路正常。

### OpenList 下载比网页慢

优先检查：

1. 下载设置里的限速是否为 `0`
2. 客户端日志是否已经出现 `download first chunk`
3. 客户端设备到 CDN 的网络是否与 OpenList 网页测试设备一致
4. 磁盘写入是否较慢，尤其是 AppImage、SD 卡、移动硬盘或 Android 共享存储

客户端下载器已对 UI 刷新和任务状态保存做节流，避免每个网络分片都写 `SharedPreferences`。如果仍显著慢于浏览器，通常是 CDN 对客户端设备网络、UA 或连接方式的差异。

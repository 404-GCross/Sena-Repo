# 疑难排查

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

默认补丁目录是 `/steam_patch`，确认挂载是否正确：

```bash
docker exec sena-repo ls /steam_patch/
```

如需使用其他路径，在 `docker run` 时加 `-e SENA_PATCH_DIR=/你的路径`。容器内区分大小写，`.ZIP` 不会被识别。

### 补丁扫描提示 401 / 403

`POST /api/steam/scan-patches` 需要管理员权限。

- **401** — 请求未携带有效 token，重新登录客户端
- **403** — 当前用户不是管理员，切换管理员账号

### 自动扫描不生效

设置项打开了"自动扫描"但服务端没有自动触发。

1. 确认当前用户是管理员（自动扫描 API 需要管理员权限）
2. 检查设置是否持久化：

   ```bash
   docker exec sena-repo cat /data/scan_settings.json
   ```

3. 自动扫描每 5 分钟检查一次，刚设置完后等几分钟再观察

### OpenList 游戏扫描不到

OpenList 源添加成功，但扫描后游戏库为空。

1. 确认 OpenList 地址带有 `http://` 或 `https://` 协议前缀，例如 `http://192.168.1.100:5244`
2. 服务端日志如果出现 `Request URL is missing an 'http://' or 'https://' protocol`，说明旧配置缺少协议；编辑 OpenList 服务器后保存一次
3. 确认 OpenList 路径填的是游戏库根目录，例如 `/115/Games/GalGame/Library`
4. 确认路径下面仍符合 Sena 的目录结构：`会社/游戏/压缩包`
5. 在 Sena 容器内测试 OpenList API：

   ```bash
   docker exec -i sena-repo python - <<'PY'
   import json, urllib.request
   base = "http://你的OpenList地址:5244"
   req = urllib.request.Request(
       base + "/api/auth/login",
       data=json.dumps({"username": "用户名", "password": "密码"}).encode(),
       headers={"Content-Type": "application/json"},
   )
   with urllib.request.urlopen(req, timeout=10) as r:
       token = json.loads(r.read().decode())["data"]["token"]
   req = urllib.request.Request(
       base + "/api/fs/list",
       data=json.dumps({"path": "/你的路径", "page": 1, "per_page": 20, "refresh": False}).encode(),
       headers={"Content-Type": "application/json", "Authorization": token},
   )
   with urllib.request.urlopen(req, timeout=10) as r:
       data = json.loads(r.read().decode())
   for item in (data.get("data", {}).get("content") or [])[:10]:
       print(item.get("name"), "dir=", item.get("is_dir"))
   PY
   ```

### GHCR 拉取 / 推送失败

**拉取：** GHCR 公开，不需要登录。404 则检查 tag 是否存在。

**推送：** Settings → Actions → General → Workflow permissions 设为 "Read and write"。

### DockerHub 镜像

正式版：`docker pull 404gcross/sena-repo:latest`

测试版：`docker pull 404gcross/sena-repo:pre-release`

---

## 客户端

### 连接超时 / 无法连接服务器

1. 确认服务端容器正在运行：`docker ps | grep sena-repo`
2. 确认客户端所在设备能访问服务端 IP 和端口 11451
3. 防火墙是否放行 11451 端口
4. 如果使用反代，确认反代配置正确转发请求

### 连接失败：RangeError(end)

客户端版本与服务端 API 不兼容，通常是服务端未更新到最新版本。拉取最新镜像重启服务端。

### 下载报 401

Token 已过期或无效，退出登录后重新登录。每次服务端重置（清空数据库）后旧 token 即失效，需重新登录。

### OpenList 下载卡在正在连接

新版客户端日志会记录每一跳：

```
download request[0]: http://Sena/api/download/...
download redirect[0]: Sena → OpenList /d/...
download request[1]: OpenList /d/...
download redirect[1]: OpenList → 网盘/CDN
download first chunk: ...
```

判断方法：

- 停在 `request[0]`：客户端到 Sena 服务端不通
- 停在 `request[1]`：客户端访问不了 OpenList 地址（OpenList 地址必须对客户端可达，不能只对 Sena 服务端可达）
- 停在 `request[2]`：客户端访问网盘/CDN 不通或被 CDN 限制
- 有 `final` 但无 `first chunk`：CDN 返回响应头后长时间不发数据，客户端会在空闲超时后失败

用 curl 验证完整链路：

```bash
curl -v -L -r 0-1023 -o /dev/null \
  -H "Authorization: Bearer <SenaToken>" \
  "http://Sena地址:11451/api/download/游戏ID/版本ID"
```

能拿到 `206 Partial Content` 说明 Sena → OpenList → CDN 的 302 链路正常。

### OpenList 下载比网页慢

1. 检查下载设置里的限速是否为 `0`（无限制）
2. 确认客户端所在设备到 CDN 的网络与 OpenList 网页测试设备一致
3. 磁盘写入是否较慢（SD 卡、移动硬盘或 Android 共享存储）

### Windows：7z 解压报"Cannot open the file as archive"

下载的临时文件不完整或损坏。手动用 `7z.exe t <文件路径>` 测试。
如文件正确但仍打不开，删除 `%APPDATA%\senarepo\sena_repo\7z.exe` 和 `7z.dll` 让应用重新提取。

### 下载解压后文件不在预期目录

压缩包自带文件夹名与游戏名不一致时，`_fixLayout` 会自动将单顶层文件夹重命名为游戏名。

### Android：权限弹窗无法跳转设置

通过 `permission_handler` 打开系统设置页。如仍失败，手动在系统设置中搜索"所有文件访问"并开启。

### Linux 触摸屏无响应

Linux AppImage 会在 runner 层启用触控兼容，并优先使用 `GDK_BACKEND=wayland,x11`。如触摸无响应，先从终端启动应用收集日志：

```bash
./Sena-Repo_Linux_v0.1.4-x86_64.AppImage 2>&1 | tee sena-touch.log
```

重点查看：

```
Sena Linux input backend preference: wayland,x11
Sena Linux GTK display: wayland-0
Sena Linux touch event: begin ...
```

- 有 `Sena Linux touch event`：GTK 已收到触摸，应用应将单指点击桥接为鼠标左键点击/拖动
- 没有 `Sena Linux touch event`：桌面环境或 Gamescope 未将触摸事件传入 GTK
- 看不到任何 `Sena Linux ...` 日志：确认是否从终端启动了新版 AppImage，Steam/游戏模式可能会吞掉 stderr

### 管理员授权用户后权限未生效

授权后用户需要退出登录并重新登录才能刷新权限信息。

### 审批通知消已读后仍有小红点

在消息通知里审批操作本身没有标记通知为已读。重新打开通知列表，手动点击通知条目可将其标记已读。

### 每次更新客户端都需要重新登录

不需要。客户端 Token 持久化在安全存储中，升级后不会清除。如果升级后下载报 401，通常是服务端也重置了，需重新登录服务端。
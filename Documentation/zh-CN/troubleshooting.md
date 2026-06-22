# 疑难杂症

## 服务端

### 启动崩溃：SyntaxError: non-default argument follows default argument

服务端部分路由函数参数顺序错误——带默认值的 `user: User = Depends(...)` 放在了必选参数 `body: SomeModel` 之前。

**解决：** 重建镜像，或手动把有默认值的认证参数移到最后。

### Docker 容器启动后立即退出

`docker ps` 看不到容器，`docker ps -a` 显示 `Exited`。

**排查：**
```bash
docker logs sena-repo 2>&1 | tail -30
```

常见原因：`config.yaml` 字段拼写错误、数据库文件损坏、端口被占用。

### GHCR 拉取 / 推送失败

**拉取：** GHCR 默认公开，不需要登录。如果 404，检查 tag 是否存在。

**推送：** 需要仓库 Settings → Actions → Workflow permissions 设为 "Read and write"，且 workflow 有 `packages: write` 权限。

### 游戏扫描不到文件

`/api/roots/refresh-all` 执行后游戏库仍为空。

**排查：**
1. 目录结构是否符合三级层级（会社/游戏/文件）
2. 文件名是否能匹配正则提取平台标识（`[PC]` `[KRKR]` 等）
3. 文件是否为支持的格式（`.zip` `.rar` `.7z` `.apk` 等）
4. 权限问题——容器内用户能否读取挂载的游戏目录

### Steam 补丁扫描返回 0

`scan_patches.py` 只扫描 `patches.json` 里有的扩展名：`.zip` `.rar` `.7z` `.tar` `.gz` `.xz`。Linux 下区分大小写，`.ZIP` 不会被识别。

另外 `patches.json` 中只要有一个条目的 `app_id` 为 null，API 就会返回该条目，但如果所有条目的 `app_id` 都是 null，客户端 Tab 的匹配逻辑需要服务端 Tab 先设定 AppID 或在文件名中用数字标识。

### SQLite database is locked

并发写入导致。SQLite 只支持单写者，如果多个请求同时写数据库会报锁错误。

**解决：** 减少并发写入操作。SQLAlchemy 的 `aiosqlite` 驱动会排队，但超时后仍会报错。

### 封面 / 头像上传后不显示

服务端返回的文件系统路径（`/data/covers/xxx.jpg`）被客户端用 `FileImage` 当成本地文件加载，而 Windows 上没有这个路径。

**解决：** 服务端返回 `url` 字段（`/api/files/covers/xxx.jpg`），客户端用 `NetworkImage` 加载。头像同理。

---

## 客户端

### Windows：7z 解压报 "Cannot open the file as archive"

下载的临时文件不完整或损坏。

**排查：**
1. 检查日志中 `extract diag` 行——文件大小是否等于 Content-Length
2. 文件魔数是否正确（7z=\x37\x7A，RAR=Rar!，ZIP=PK）
3. 手动用 `7z.exe t <文件路径>` 测试
4. 如果文件正确但 7z 仍打不开，可能是下载流写入损坏，尝试删除 `%APPDATA%\senarepo\sena_repo\7z.exe` 和 `7z.dll` 让应用重新提取

### 游戏下载解压后文件不在预期目录

解压后压缩包自带文件夹名与游戏名相同，导致多了一层嵌套目录。

**解决：** `_fixLayout` 会处理这种情况，将内容提升一级。

### 双击 exe 无法拉起已运行实例

第二次启动检测到端口被占用后直接退出了，没有把窗口拉到前台。

**解决：** 确认单实例锁监听端口 11452 正常，第二个实例应连接该端口发送信号。

### "我的" 界面头像不显示

`_userId` 是把 JWT token 当数字解析出来的（永远为 0），导致头像从不加载。

**解决：** 改用 `/api/auth/profile/me` 端点，不依赖 userId。

### 游戏库切换 Tab 后不自动刷新

`IndexedStack` 保活页面但不会自动触发重构，`build` 只在依赖变化时调用。

**解决：** 在 Tab 切换回调中显式调用 `refreshGames()`。

---

## 网络

### 连接服务端超时或拒绝

- 检查 `--host 0.0.0.0` 是否已设置（默认绑定 0.0.0.0）
- 防火墙是否放行 11451 端口
- Docker 容器的端口映射 `-p 11451:11451` 是否正确
- 客户端使用的协议（HTTP/HTTPS）与服务端是否匹配

### 自签名 HTTPS 证书报错

客户端默认忽略证书验证（`badCertificateCallback` 始终返回 true），如果使用了自定义 CA 可能需要手动导入。

---

## 构建

### Windows CI：fastforge 找不到 packaging 文件

`flutter create .` 会重新生成 `windows/` 目录，删除之前放进去的 `packaging/exe/` 配置。

**解决：** 在 CI 中 `flutter create .` 之后用 `Copy-Item` 从 `windows_assets/packaging` 拷贝回 `windows/packaging`。

### Linux CI：AppImage 构建失败缺少图标

`appimagetool` 检查 desktop 文件中 `Icon=` 指定的图标文件，不存在则退出码 1。

**解决：** 在构建 AppImage 前先生成一个 png 图标（`convert` 命令或使用 `assets/icon.png`）。

### Release 发布 403：Resource not accessible by integration

- `GITHUB_TOKEN` 权限不足。检查 Settings → Actions → General → Workflow permissions 是否设为 "Read and write"
- 组织仓库可能需要组织级别的 Actions 权限

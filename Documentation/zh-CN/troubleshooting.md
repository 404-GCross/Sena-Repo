# 疑难杂症

## 服务端

### Docker 容器启动后立即退出

`docker ps` 看不到容器，`docker ps -a` 显示 `Exited`。

**排查：**

```bash
docker logs sena-repo 2>&1 | tail -30
```

常见原因：`config.yaml` 字段拼写错误、数据库文件损坏、端口被占用。

### GHCR 拉取 / 推送失败

**拉取：** GHCR 公开，不需要登录。如果 404，检查 tag 是否存在。

**推送：** 需要仓库 Settings → Actions → General → Workflow permissions 设为 "Read and write"，且 workflow 有 `packages: write` 权限。

### 游戏扫描不到文件

执行扫描后游戏库仍为空。

**排查：**

1. 目录结构是否符合三级层级（会社/游戏/文件）
2. 文件名是否能匹配平台标识（`[PC]` `[KRKR]` 等）
3. 文件是否为支持的格式（`.zip` `.rar` `.7z` `.apk` 等）
4. 容器内用户能否读取挂载的游戏目录

### Steam 补丁扫描返回 0

客户端显示"扫描完成，找到 0 个文件"，但文件实际存在。

**常见原因：**

1. **补丁目录挂载错误——这是最常见的问题。** 服务端补丁目录默认是 `/data/steam_patches`（`data_path` 下的 `steam_patches` 子目录），不是 `/steam_patch`。确认挂载：

   ```bash
   docker exec sena-repo ls /data/steam_patches/
   ```

2. **配置文件里的 `patch_dir` 未生效。** 可在 `docker run` 时加 `-e SENA_PATCH_DIR=/steam_patch` 显式指定。

3. 容器内扫描与大写扩展名不兼容（Linux 区分大小写，`.ZIP` 不会被识别）。

4. 扩展名不在支持列表中：`.zip` `.rar` `.7z` `.tar` `.gz` `.xz`。

### 补丁扫描提示 401 / 403

`POST /api/steam/scan-patches` 需要管理员权限。

- **401** — 请求未携带有效 token。重新登录客户端，确认连接状态正常。
- **403** — 当前用户不是管理员。普通用户在 Steam 补丁页点击"扫描补丁"会被拒绝。切换为管理员账号，或让管理员在用户管理中提升你的权限。

### 加密压缩包下载后长时间卡住

7z 遇到有密码的压缩包且没有提供密码时，旧版会等待终端输入直到超时（最长 30 分钟）。新版在命令行中默认携带 `-p-`（告知无密码），会立即报错并显示"需要密码"。

如果仍遇到卡住问题，确保客户端和服务端都是最新版本。

### 加密压缩包如何解压

如果压缩包有密码，7z 报错后会显示状态"需要密码"。在下载弹窗或下载管理页面可以直接输入密码，点击"带密码重试"。密码正确则继续解压。

### 自动扫描不生效

设置页打开了"自动扫描"并设置了间隔，但服务端没有自动触发。

**排查：**

1. 确认你是管理员——自动扫描设置的 API 需要管理员权限。
2. 检查服务端是否正确保存了设置。在服务端查看：

   ```bash
   docker exec sena-repo cat /data/scan_settings.json
   ```

3. 自动扫描每 5 分钟检查一次，不会立即触发。如果刚设置完，等几分钟再观察。

### SQLite database is locked

并发写入导致。SQLite 只支持单写者。

**解决：** 减少并发写入操作。SQLAlchemy 的 `aiosqlite` 驱动会排队，但超时后仍会报错。

---

## 客户端

### Windows：7z 解压报 "Cannot open the file as archive"

下载的临时文件不完整或损坏。

**排查：**

1. 手动用 `7z.exe t <文件路径>` 测试文件完整性
2. 如果文件正确但 7z 仍打不开，删除 `%APPDATA%\senarepo\sena_repo\7z.exe` 和 `7z.dll` 让应用重新提取

### 游戏下载解压后文件不在预期目录

解压后压缩包自带文件夹名与游戏名不一致。`_fixLayout` 会自动处理——如果压缩包只有一个顶层文件夹，会重命名为游戏名。

### 导入 Steam 提示"未找到 Python 运行环境"

Windows 下添加游戏到 Steam 需要 Python 运行时。Python 随便携版/安装版一起分发，在 `sena_repo.exe` 同级目录下的 `python/` 文件夹中。

如果提示找不到：

1. 确认 `python/python.exe` 与 `sena_repo.exe` 在同一目录下
2. 如果使用便携版，确认解压时保留了完整的文件夹结构
3. 如果使用安装版，确认安装在默认路径（`C:\Program Files\Sena Repo`）

### 下载的便携版 / 安装版缺少 Python 文件

已修复。旧版构建产物因 `.gitignore` 排除了 `.pyd` 文件导致 Python 不完整。下载最新的 Release 即可。

### "我的" 界面头像不显示

头像文件通过 URL 加载（`/api/files/avatars/`），确认客户端已连接到服务端且网络通畅。

### 游戏库切换 Tab 后不自动刷新

`IndexedStack` 保活页面但不会自动触发重构。

**解决：** 在 Tab 切换回调中显式调用 `refreshGames()`。

### Android：权限弹窗无法跳转设置

已修复。点击"前往设置"通过 `permission_handler` 打开系统设置页。如仍失败，手动在系统设置中搜索"所有文件访问"并开启。

### 关于弹窗图标的显示

关于弹窗（"我的" → "关于"）中的图标使用应用图标（`assets/icon.png`），如不显示检查客户端是否完整。

---

## 网络

### 连接服务端超时或拒绝

- 检查 `--host 0.0.0.0` 是否已设置（默认绑定 `0.0.0.0`）
- 防火墙是否放行 11451 端口
- Docker 容器的端口映射 `-p 11451:11451` 是否正确
- 客户端使用的协议（HTTP/HTTPS）与服务端是否匹配

### 自签名 HTTPS 证书

客户端仅对配置过的服务器 host 允许自签名证书。如果更换了服务器 IP/域名，重新在连接页面输入新地址即可。

对于第三方图片 CDN 等，使用系统标准 TLS 验证，不受自签名影响。

---

## 构建

### Windows 安装包缺少 Python

已修复。旧版使用 fastforge 打安装包时会内部调用 `flutter build` 清掉打包进去的文件。新版改用 ISCC 直接从 ISS 模板编译，不再触发二次构建。

### Linux CI：AppImage 构建失败缺少图标

`appimagetool` 检查 desktop 文件中 `Icon=` 指定的图标文件，不存在则退出码 1。

**解决：** 在构建 AppImage 前先生成一个 png 图标（`convert` 命令或使用 `assets/icon.png`）。

### Release 发布 403：Resource not accessible by integration

- `GITHUB_TOKEN` 权限不足。检查 Settings → Actions → General → Workflow permissions 是否设为 "Read and write"
- 组织仓库可能需要组织级别的 Actions 权限

### CI 构建产物（便携版 / 安装版）缺少文件

1. 检查对应 workflow 的 "Bundle Python + VDF" 步骤日志，确认 `python.exe` 被正确复制
2. 便携版：检查 "Package portable zip" 步骤的验证输出
3. 安装版：检查 "Build installer (ISCC)" 步骤是否成功编译

### Fork 仓库构建注意事项

Fork 后使用 Actions 需修改：
1. Workflow permissions 设为 "Read and write"
2. GHCR 推送地址从 `ghcr.io/404-gcross/sena-repo` 改为你自己的仓库路径
3. `build.yml`（自动构建）不需要任何修改即可使用

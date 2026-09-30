# Changelog

<!--
发版时在最上面加一段 `## <版本号>`（与 VERSION 文件和 v<版本号> tag 保持一致），
发版流程会把它整段复制到 GitHub Release 说明里。段内可以用 ### 小标题、列表、表格、
<details> 折叠块等，但不要再出现 ## 级别的标题。

Add a `## <version>` section at the top for each release (matching the VERSION file and the
`v<version>` tag); the release workflow copies it into the GitHub Release body.
-->

## 1.0.0-beta.1

Sena Repo 是自托管的视觉小说私有库管理器：把 NAS / OpenList 上的游戏收藏整理成可浏览、可搜索、可下载的私有库。

> [!TIP]
> 首个测试版：功能与界面仍在调整，可能存在未知问题，欢迎在 [Issues](https://github.com/404-GCross/Sena-Repo/issues) 反馈。

### 支持平台

| 端 | 平台 |
|----|------|
| 客户端 | Windows（amd64，安装版 / 便携版）、Android（universal APK）、Linux（amd64，AppImage / tar.gz / deb / rpm） |
| 服务端 | Docker / Docker Compose（amd64、arm64）、Tarball、一键安装脚本（apt / dnf / yum / zypper / pacman，需 systemd） |

### 亮点功能

- **游戏库**：网格 / 列表视图，按会社、标签、平台筛选，别名搜索与批量操作
- **多源刮削**：VNDB / Bangumi / Steam / Hikarinagi / NextMoe，逐字段对比与覆盖，元数据锁定
- **Steam 补丁**：自动匹配本地 Steam 游戏，aria2 下载解压注入，关键词匹配与元数据锁定
- **下载与安装**：aria2 多连接与并行分片，OpenList 接入，导入 Steam 非 Steam 游戏并生成快捷方式
- **推送到管理器**：LunaBox / ReinaManager 继续下载入库
- **自托管**：一键安装与 senacli 维护命令，三级权限，备份导出 / 导入

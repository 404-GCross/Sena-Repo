# 贡献指南

欢迎为 Sena-Repo 做出贡献！无论是 bug 反馈、功能建议，还是代码贡献，都非常感谢。

## 开始之前

- 请先搜索 [Issues](https://github.com/404-GCross/Sena-Repo/issues) 中是否已有相同问题或建议，避免重复。
- 大的功能改动建议先开 Issue 讨论，确认方向后再开始写代码。

## 如何贡献

### 报告 Bug

1. 描述清除问题现象和复现步骤
2. 提供运行环境信息（操作系统、Docker 版本等）

### 提交代码

1. **Fork** 本仓库，从 `dev` 分支创建新分支
2. 安装并配置 pre-commit 或手动确保代码风格一致
3. 编写或更新测试以覆盖你的改动
4. 确保所有测试通过
5. 提交清晰描述更改内容的 Pull Request 到 `dev` 分支

## 构建与运行

### 本地运行

**服务端**

```bash
cd server
pip install -r requirements.txt
python main.py --host 0.0.0.0 --port 11451 \
  --games-path /path/to/games \
  --data-path /path/to/data
```

**客户端**

需要安装 [Flutter SDK](https://flutter.dev/docs/get-started/install)（3.29+）。

```bash
cd client
flutter pub get
flutter run
```

### 使用 GitHub Actions

项目提供三个 CI 工作流，Fork 后可直接使用：

**自动构建（`build.yml`）** — 推送或 PR 到 `dev`/`main` 分支时自动触发，编译 Android APK + Windows + Linux AppImage + Server Tarball，产物上传为 Artifact。不发布 Release。

**发布 PreRelease（`build_PreRelease.yml`）** — 手动触发。在 Actions 页面选择此工作流，填入版本号（如 `0.2.0-pre1`），编译全部平台并发布 Pre-Release，同时推送 Docker 镜像到 GHCR（tag 为 `pre-release` 和 `v版本号`）。

**发布 Release（`build_Release.yml`）** — 手动触发。填入版本号（如 `0.2.0`），编译全部平台并发布正式 Release，同时推送 Docker 镜像到 GHCR（tag 为 `latest` 和 `v版本号`）。

> 使用前需在 Fork 仓库的 Settings → Actions → General → Workflow permissions 中勾选 "Read and write permissions"，否则 Release 创建会失败。

## 代码风格

- **Python** — 遵循 PEP 8
- **Dart / Flutter** — 使用 `flutter analyze` 进行静态检查
- 提交信息使用中文或英文均可

## 许可证

贡献的代码将采用本项目相同的 [AGPL-3.0 许可证](https://github.com/404-GCross/Sena-Repo/blob/main/LICENSE)。

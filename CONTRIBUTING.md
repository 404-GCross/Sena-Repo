# 贡献指南

欢迎为 Sena Repo 做出贡献！无论是 bug 反馈、功能建议，还是代码贡献，都非常感谢。

## 开始之前

- 请先搜索 [Issues](https://github.com/404-GCross/Sena-Repo/issues) 中是否已有相同问题或建议，避免重复。
- 大的功能改动建议先开 Issue 讨论，确认方向后再开始写代码。

## 如何贡献

### 报告 Bug

1. 使用 Bug Report 模板（若有）
2. 描述问题现象和复现步骤
3. 提供运行环境信息（操作系统、Docker 版本等）

### 提交代码

1. **Fork** 本仓库，从 `dev` 分支创建新分支
2. 安装并配置 pre-commit 或手动确保代码风格一致
3. 编写或更新测试以覆盖你的改动
4. 确保所有测试通过
5. 提交清晰描述更改内容的 Pull Request 到 `dev` 分支

## 项目结构

```
Sena-Repo/
├── client/          # Flutter 客户端（Windows / Android / Linux）
│   ├── lib/
│   │   ├── models/      # 数据模型
│   │   ├── providers/   # 状态管理
│   │   ├── screens/     # 页面
│   │   ├── services/    # API 客户端、下载服务等
│   │   ├── utils/       # 工具类
│   │   └── widgets/     # 可复用组件
│   └── pubspec.yaml
├── server/          # Python 服务端
│   ├── api/             # FastAPI 路由
│   ├── schemas/         # Pydantic 模型
│   ├── services/        # 业务逻辑（扫描、刮削等）
│   └── Dockerfile
├── docs/            # 文档
├── 7z/              # 各平台 7z 二进制文件
└── 参考项目源码/     # 参考的优秀开源项目
```

## 构建与运行

### 服务端

```bash
cd server
pip install -r requirements.txt
python main.py --host 0.0.0.0 --port 11451 \
  --games-path /path/to/games \
  --data-path /path/to/data
```

### 客户端

需要安装 [Flutter SDK](https://flutter.dev/docs/get-started/install)（3.29+）。

```bash
cd client
flutter pub get
flutter run
```

## 代码风格

- **Python** — 遵循 PEP 8
- **Dart / Flutter** — 使用 `flutter analyze` 进行静态检查
- 提交信息使用中文或英文均可

## 许可证

贡献的代码将采用本项目相同的 [AGPL-3.0 许可证](https://github.com/404-GCross/Sena-Repo/blob/main/LICENSE)。

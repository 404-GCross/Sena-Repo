# Steam 补丁注入

为 Steam 正版游戏自动匹配并注入 额外内容/汉化/音声/剧情 补丁。

## 目录结构

```
steam_patches/
├── patches.json
├── 123456/
│   └── hanhua_v2.zip
└── 巧克甜恋/
    └── hanhua_v2.zip
```

目录命名方式不重要，只要 `patches.json` 里正确指定 `file` 路径即可。

## patches.json 格式

### 最小配置

```json
{
  "patches": [
    { "app_id": 123456, "file": "hanhua_v2.zip" }
  ]
}
```

### 完整配置

```json
{
  "patches": [
    {
      "app_id": 123456,
      "file": "巧克甜恋/hanhua_v2.zip",
      "patch_dir": "汉化文件",
      "target_dir": "data",
      "label": "汉化补丁 v2",
      "type": "translation"
    }
  ]
}
```

### 字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `app_id` | 是 | Steam 游戏 AppID |
| `file` | 是 | 压缩包相对补丁目录的路径 |
| `patch_dir` | 否 | 解压后取哪个子目录的内容。不填自动匹配 |
| `target_dir` | 否 | 复制到游戏目录的哪个子路径。不填则根目录 |
| `label` | 否 | 界面显示的补丁名称 |
| `type` | 否 | 补丁类型，默认 `misc` |

### 补丁类型

| 值 | 显示 |
|------|------|
| `translation` | 汉化 |
| `voice` | 音声 |
| `story` | 剧情 |
| `extra` | 额外 |
| `misc` | 其他 |

## 使用流程

1. **准备补丁**：把压缩包放到服务端补丁目录（默认 `data/steam_patches/`）
2. **创建索引**：运行 `scan_patches.py` 或手写 `patches.json`（见下方格式）
3. **客户端操作**：
   - 打开 Steam 补丁管理页
   - 选择 `steamapps` 目录 → 自动扫描匹配
   - 点击 ✏️ 编辑补丁参数（不用回服务端改 JSON）
   - 有补丁的游戏点击「注入」→ 自动下载解压覆盖
4. **验证**：Steam 启动游戏，检查补丁是否生效

## 客户端编辑

补丁卡片右上角 ✏️ 按钮可以修改以下字段，点击「保存」后自动写回服务端 `patches.json`：

- **补丁源目录** — 对应 `patch_dir`
- **目标目录** — 对应 `target_dir`
- **显示名称** — 对应 `label`
- **补丁类型** — 对应 `type`

无需手动编辑 JSON、SSH 进服务器或重启服务端。

## 快速生成 JSON

不想手写的话，在服务端运行扫描脚本：

```bash
docker exec sena-repo python scan_patches.py
```

自动扫描补丁目录，生成带默认值的 `patches.json`。

手动新增一条：

```bash
docker exec sena-repo python scan_patches.py \
  --add 123456 "巧克甜恋/hanhua_v2.zip" "汉化文件" "data" "汉化补丁 v2" translation
```

## AppID 获取方式

- Steam 商店 URL：`store.steampowered.com/app/123456/`
- 文件名：`steamapps/appmanifest_123456.acf`
- 客户端扫描后自动显示

## 排障

| 问题 | 原因 | 解决 |
|------|------|------|
| 扫描后找不到补丁 | `patches.json` 不存在或 `app_id` 不匹配 | 检查 JSON 文件，确认 AppID 正确 |
| 注入后游戏文件没变化 | `patch_dir` / `target_dir` 路径填错 | 解压补丁，对比目录结构修正 |
| 游戏无法启动 | 补丁覆盖了核心文件 | Steam 右键 → 验证游戏完整性恢复 |

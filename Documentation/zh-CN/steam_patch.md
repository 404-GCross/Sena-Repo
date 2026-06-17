# Steam 补丁注入

为 Steam 正版游戏自动匹配并注入汉化补丁。

## 目录结构

在服务端补丁目录（默认 `data/steam_patches/`）下组织补丁文件：

```
steam_patches/
├── patches.json          # 索引文件（必须）
├── 123456/               # 按 AppID 命名（可选）
│   └── hanhua_v2.zip
└── 巧克甜恋/             # 或按游戏名命名
    └── hanhua_v2.zip
```

各目录的命名方式不重要，只要在 `patches.json` 里正确指定 `file` 路径即可。

## patches.json 格式

### 最小配置

```json
{
  "patches": [
    {
      "app_id": 123456,
      "file": "hanhua_v2.zip"
    }
  ]
}
```

解压后将自动匹配单子文件夹，覆盖到游戏根目录。

### 完整配置

```json
{
  "patches": [
    {
      "app_id": 123456,
      "file": "巧克甜恋/hanhua_v2.zip",
      "patch_dir": "汉化文件",
      "target_dir": "data",
      "label": "汉化补丁 v2"
    }
  ]
}
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `app_id` | 数字 | 是 | Steam 游戏的 AppID（在 `steamapps/appmanifest_*.acf` 里找到） |
| `file` | 字符串 | 是 | 补丁压缩包相对补丁目录的路径 |
| `patch_dir` | 字符串 | 否 | 解压后取哪个子目录的内容。不填时自动匹配（只有一个子文件夹则取其内容，否则取根） |
| `target_dir` | 字符串 | 否 | 复制到游戏安装目录的哪个子路径下。不填则覆盖游戏根目录 |
| `label` | 字符串 | 否 | 在界面上显示的补丁名称 |

## 快速生成

不想手写 JSON 的话，在服务端运行：

```bash
docker exec sena-repo python scan_patches.py
```

会自动扫描补丁目录下的所有压缩包、尝试从文件名或父目录名提取 AppID，生成带默认值的 `patches.json`。你只需要补填 `patch_dir` 和 `target_dir`。

### 手动新增一条

```bash
docker exec sena-repo python scan_patches.py \
  --add 123456 "巧克甜恋/hanhua_v2.zip" "汉化文件" "data" "汉化补丁 v2"
```

## 使用流程

1. **准备补丁**：把压缩包放到补丁目录
2. **创建索引**：运行 `scan_patches.py` 或手写 `patches.json`
3. **配置字段**：根据补丁实际结构填写 `patch_dir` 和 `target_dir`
4. **客户端操作**：
   - 打开 Steam 补丁管理页
   - 选择 `steamapps` 目录 → 自动扫描匹配
   - 有补丁的游戏点击「注入」→ 自动下载解压覆盖
5. **验证**：Steam 启动游戏，检查补丁是否生效

## AppID 获取方式

- 在 Steam 商店页面 URL 中：`store.steampowered.com/app/123456/`
- 在 `steamapps/appmanifest_123456.acf` 文件名中
- 客户端扫描后自动显示

## 排障

| 问题 | 原因 | 解决 |
|------|------|------|
| 扫描后找不到补丁 | `patches.json` 不存在或 `app_id` 不匹配 | 检查 JSON 文件，确认 AppID 正确 |
| 注入后游戏文件没变化 | `patch_dir` / `target_dir` 路径填错 | 解压补丁，对比目录结构修正 |
| 游戏无法启动 | 补丁覆盖了核心文件 | Steam 右键 → 验证游戏完整性恢复 |

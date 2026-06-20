# Steam 补丁注入

为 Steam 正版游戏自动匹配并注入额外内容 / 汉化 / 音声 / 剧情补丁。

## 工作原理

```
服务端                              客户端
──────                              ──────
补丁目录（.zip/.rar/.7z 等）
    │                                 
scan_patches.py ──→ patches.json
    │                   ↓             客户端Tab: 扫 steamapps → POST /scan → 匹配 → 注入
    │              ┌─ 服务端Tab: 查看/编辑/扫描索引
    └─ Steam API ─┘  (根据文件名搜索 AppID)
```

补丁文件放在服务端，客户端扫描本地 Steam 库后自动匹配并注入。

## 目录结构

```
steam_patches/
├── patches.json               ← 自动生成
├── patch_type_keywords.json   ← 类型识别关键词（可自定义）
├── 想要传达给你的爱恋_Steam_extra_Patch.7z
└── LOST：SMILE memories+promise_Steam_Chinese_Patch.rar
```

文件直接放在根目录，`scan_patches.py` 递归扫描所有子目录。

## 自动识别

### AppID

扫描按以下顺序尝试获取 Steam AppID：

1. 文件名中的纯数字（如 `123456.zip` → 123456）
2. 父目录名中的纯数字（如 `123456/v2.zip` → 123456）
3. 从文件名提取游戏名 → 调 Steam Store API 搜索 → 获取 AppID
4. 都失败则 `app_id: null`，客户端"服务端"Tab 中可手动编辑

游戏名提取规则：去掉文件扩展名 → 去掉类型关键词后缀（`_Steam_Chinese_Patch` 等）→ 下划线替换空格。

### 补丁类型

根据文件名中的关键词自动分类（大小写不敏感）：

| 类型 | 默认关键词 |
|------|-----------|
| `translation`（汉化） | `_Steam_Chinese_Patch` |
| `voice`（音声） | `_Steam_Voice_Patch` |
| `story`（剧情） | `_Steam_Story_Patch` |
| `extra`（额外） | `_Steam_Extra_Patch` |
| `misc`（其他） | 默认 |

关键词映射保存在 `patch_type_keywords.json`，可在客户端 Steam 补丁页右上角 🔍 按钮自定义。默认每种类型只预设一个关键词，用户可根据自己的文件命名习惯自由添加。

## patches.json 格式

```json
{
  "patches": [
    {
      "app_id": 123456,
      "file": "想要传达给你的爱恋_Steam_extra_Patch.7z",
      "patch_dir": "",
      "target_dir": "",
      "label": "想要传达给你的爱恋",
      "type": "extra"
    }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `app_id` | Steam AppID，可自动识别或手动填写 |
| `file` | 压缩包相对补丁目录的路径 |
| `patch_dir` | 解压后取哪个子目录的内容，空则自动 |
| `target_dir` | 复制到游戏目录的哪个子路径，空则根目录 |
| `label` | 界面显示名称 |
| `type` | 补丁类型 |

## 使用流程

1. **初始设置**：在 Setup 向导 Step 3 填入补丁目录路径，完成后自动扫描生成 `patches.json`
2. **放补丁文件**：把 `.zip/.rar/.7z` 放到补丁目录下
3. **客户端操作**：
   - 打开 Steam 补丁管理页
   - **服务端 Tab**：点「扫描补丁」→ Steam API 自动查 AppID → 显示索引列表
   - 可在这里编辑每条补丁的 AppID、类型、源/目标目录
   - **客户端 Tab**：选 `steamapps` 目录 → 「刷新」→ 按 AppID 匹配 → 有补丁的游戏点「注入」
4. 注入支持**暂停/继续/取消**，暂停后可断点续传

## 客户端界面

### 客户端 Tab

扫描本地 Steam 库，按 AppID 匹配服务端补丁。

- 选择 steamapps 目录 → 自动扫描
- 有补丁的游戏显示「注入」按钮，点击自动下载解压
- 注入过程可暂停、取消，暂停后支持断点续传
- ✏️ 编辑按钮可修改补丁参数

### 服务端 Tab

管理服务端 `patches.json` 索引。

- 「加载」获取当前索引列表
- 「扫描补丁」触发服务端重新扫描，Steam API 自动查 AppID。扫描完成后如客户端已配置 steamapps 目录则自动切回客户端 Tab 匹配本地游戏
- 每条显示：类型标签、名称、AppID chip、匹配游戏、文件路径、源/目标配置状态
- ✏️ 编辑可改：AppID、补丁源目录、目标目录、显示名称、补丁类型
- 保存后直接写回服务端，无需 SSH。所有操作反馈使用弹窗提示

## 关键词自定义

客户端 Steam 补丁页 → 右上角 🔍 → 弹窗编辑每种类型的关键词（逗号分隔）→ 保存。下次扫描生效。

也可直接编辑服务端 `patch_type_keywords.json`：

```json
{
  "translation": ["_Steam_Chinese_Patch"],
  "voice": ["_Steam_Voice_Patch"],
  "story": ["_Steam_Story_Patch"],
  "extra": ["_Steam_Extra_Patch"],
  "misc": []
}
```

## 服务端命令

```bash
# 手动扫描
docker exec <容器名> python /app/scan_patches.py --dir /steam_patch

# 手动新增一条
docker exec <容器名> python /app/scan_patches.py \
  --add 123456 "v2.zip" "汉化文件" "data" "汉化 v2" translation
```

## 排障

| 问题 | 原因 | 解决 |
|------|------|------|
| 扫描补丁返回 0 | `config.yaml` 的 `patch_dir` 与实际路径不一致 | 检查 `docker exec <容器> cat /app/config.yaml \| grep patch_dir` |
| | 大写扩展名（Linux 区分大小写） | 重新扫描已支持大写 |
| 补丁匹配不到本地游戏 | `app_id` 为 null | 服务端 Tab 编辑 AppID，或等 Steam API 自动查到后重新扫描 |
| 编辑补丁报 404 | 被编辑的补丁 app_id 为 null | 已修复，改为用文件路径定位 |
| 注入后游戏文件没变化 | `patch_dir`/`target_dir` 填错 | 解压补丁确认目录结构 |
| 游戏无法启动 | 补丁覆盖了核心文件 | Steam 右键验证游戏完整性 |

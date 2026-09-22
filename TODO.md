# TODO

## Hikarinagi OAuth 登录（暂缓，先不做）

**目标**：像 NextMoe 一样，用 Hikarinagi 账号登录 / 绑定 Sena Repo。

**可行性（已查证）**：Hikarinagi 是标准 OIDC 提供方 `https://id.hikarinagi.org/oidc`：

- 授权码 + PKCE（`S256`）；`token_endpoint_auth_methods_supported` 含 `none` → 支持 public client（无 secret）
- 支持 `refresh_token` / `offline_access`；端点 `/oidc/auth`、`/oidc/token`、`/oidc/jwks`、`/oidc/session/end`
- claims：`sub` / `name` / `nickname` / `preferred_username` / `picture` / `email` / `email_verified`
- scope：`openid profile email`、`catalog:read/full`、`user:read`、`status:read/write`、`collection:read/write`
- 开发者平台明确「用户级令牌 = 授权码 + PKCE」，控制台可配置回调地址与用户级 scope

**待办（分两阶段）**

1. 阶段一：登录 + 绑定
   - 服务端：OAuth 层泛化为多 provider（配置 `oauth.providers.*`、端点 `/api/auth/oauth/{provider}/...`、`/providers` 返回两家）
   - 数据库：新建 `user_oauth_bindings`（`user_id, provider, subject, name, oauth_user_id`，唯一索引 `(provider, subject)`、`(user_id, provider)`），迁移现有 NextMoe 绑定并回填
   - 客户端：`nextmoe_oauth.dart` / `nextmoe_token_store.dart` 泛化为 provider 感知；登录弹窗双按钮、个人信息两张绑定卡、用户管理 chip、初始化向导两个可选绑定
   - 首次登录自动建号（pending 审批）；Hikarinagi 无数字 ID，不支持预置 ID 绑定
2. 阶段二（可选）：用户令牌刮削
   - 客户端直连 Hikarinagi（`catalog:read`）搜索与映射，替代/补充服务端 client credentials

**开放决策**

- 是否允许同一用户同时绑定 NextMoe 与 Hikarinagi（推荐是，需要新表 + 迁移）
- Hikarinagi 首次登录是否自动建号 + 待管理员审批（建议与 NextMoe 一致）
- 客户端注册：在 Hikarinagi 控制台创建 public 应用，回调填 `http://127.0.0.1/callback`；需先确认是否支持环回 / 端口无关，否则自建实例需各自注册（与 NextMoe 相同的取舍）
- 登录页是否同时展示两个 provider 按钮（建议是）

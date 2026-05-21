# 背景与决策记录

> 这份文档给后续接手者（人或 AI）读，目的是补全 `README.md` / 代码本身看不出来的「为什么是现在这个样子」和「上次聊到哪里」。

## 这个 repo 的来历

它是隔壁 `../claude_code_patch/`（`claude-code-usage-display`）项目的姊妹版。

- `claude_code_patch/` 已经做完：**CLI 侧**，把 Claude Code 自带 statusline 改造成显示 5h / 7d 用量
  - 实现路径：自定义 statusline Python 脚本，从 CC 透传给 statusline 的 stdin JSON 里读取已经被 CC 缓存过的用量数据
  - 限制：只在 CC 运行时才能看见，没开终端就没数据
- 本 repo 要做的是 **GUI 侧**：macOS 菜单栏常驻 widget，不依赖 CC 是否在跑

两个 repo 互不依赖，只是动机相同（想随时看到自己烧了多少额度）。

## 客户端方案的几条路 + 选择

讨论过三条路，最后选了第 3 条：

1. **复用 CLI 那套**（让菜单栏调 CC 的缓存）
   pass — CC 不开就没数据，菜单栏要 always-on，前提就不成立。

2. **挂载到桌面 app 的 DevTools**（Cmd+Opt+I 抓前端 fetch）
   pass — Claude 桌面 app 把 DevTools 关掉了，快捷键打不开。

3. **直接读桌面 app 的本地 session 模拟前端调用** ← **当前方案**
   - 用户已经登录过桌面 app → cookie 全在 `~/Library/Application Support/Claude/Cookies`（SQLite，cookie value 是 AES-128-CBC 加密的）
   - 解密 key 在 macOS Keychain：service name `Claude Safe Storage`，PBKDF2-HMAC-SHA1(salt=`saltysalt`, iter=1003, len=16) —— Chromium/Electron 在 macOS 上的标准约定
   - 拿到 `sessionKey` + `cf_clearance` + `lastActiveOrg` 三个 cookie，就能直接 `GET /api/organizations/<org>/usage` 拿到和网页一样的 JSON

## 目前进度

**数据层**
- `claude_usage.py`：库（`read_session_cookies()` + `fetch_usage()`），stdlib only
  - `_detect_claude_app_ua()` 从 Claude.app bundle 凑出 UA，cf_clearance 必须这个
  - HTTP 走系统 `curl`（不走 urllib，TLS 指纹理论上不卡但保险）
  - `CLAUDE_USAGE_DEBUG=1` 打印 cookie 名、UA、HTTP 状态
  - `CLAUDE_USAGE_UA=...` 手工覆盖 UA（极端情况）
- `poc_fetch_usage.py`：调用库的 CLI，stderr 进度 + stdout JSON

**UI 层（现状）**
- `float_widget.swift` + `build_app.sh` → `dist/Claude Usage.app`（**主 UI**）
  - 始终置顶浮窗，无 Dock 图标（`LSUIElement`）
  - 自适应材质 (`NSVisualEffectView.popover`) + 语义色 (`labelColor` / `secondaryLabelColor`) + 警告色 (`systemRed/Orange`)
  - 右键菜单切 Theme（System / Dark / Light）和 Refresh Every（1 / 5 / 15 / 30 min），偏好 + 窗口位置存 `UserDefaults`（domain `io.github.claude-desktop-usage`）
  - Swift 通过 `Bundle.main.resourcePath` 找 `poc_fetch_usage.py`；raw binary 模式用 `CLAUDE_USAGE_SCRIPT` 或 CLI 参数指定
- `swiftbar_plugin.py` **已弃用**（保留代码，README 标注）

**已在真机跑通**：浮窗显示 `5h 25% · 7d 23%`（不同数）+ 主题/间隔切换可用 + 窗口位置可拖可记忆

## 关键约束 / 已踩过的坑

- **Cookies SQLite 在 Claude.app 运行时会被锁**：POC 用 `shutil.copy2` 拷到 tmp 再读。后续 widget 也要保留这个动作
- **Keychain 第一次会弹窗**：「python wants to access 'Claude Safe Storage'」。点 Always Allow 之后才不会再问。换 Python 解释器路径（pyenv / venv）会重新触发
- **同名 cookie 有两条**（`.claude.ai` 和 `claude.ai`），POC 里用「encrypted_value 更长的那条」做了简单去重；如果以后看到鉴权失败，可以先怀疑这里
- **Chromium ≥ v130 给解密后的明文加了 32 字节 host-binding 哈希前缀**：`_decrypt()` 里用「首 32 字节是否含非可打印字符」启发式判断并跳过。POC 最初版没处理，第一次接菜单栏 widget 时撞到了（org UUID 前面带一串乱码导致 URL 非法），改完后才通。后续若再撞到「decrypted 看起来正确但请求 401」类问题，可以怀疑前缀长度变了
- **Cloudflare `cf_clearance` 严格匹配 UA 全字符串**：单独把 cf_clearance 传过去**不够**，UA 必须跟当初签发它时一模一样。Claude.app 发的实际 UA 是 `Mozilla/5.0 (Macintosh; …) AppleWebKit/537.36 (KHTML, like Gecko) Claude/<bundle-ver> Chrome/<chrome-ver> Electron/<electron-ver> Safari/537.36` —— 通用 Chrome UA（哪怕 Chrome 主版本号也对）会直接被打回 403 + JS 挑战页。`_detect_claude_app_ua()` 从 Claude.app 的 plist + Electron framework 二进制（`strings` 抓 `Chrome/x.y.z.w` 和 `Electron/x.y.z`）里凑出这个 UA。TLS / HTTP2 指纹反而**不卡** —— macOS 自带 curl 就够了。如果未来 cf 升级到也卡 TLS，得上 `curl_cffi` 或 `curl-impersonate`
- **也别只送 sessionKey + cf_clearance + lastActiveOrg 三个 cookie**：必须把整个 `claude.ai` cookie jar 一起回放（特别是 `__cf_bm`），少一个 Cloudflare 也会发挑战。`_load_encrypted_cookies()` 现在拉所有 host 在 `.claude.ai` / `claude.ai` 的 cookie，`fetch_usage` 时除了 `lastActiveOrg`（URL 用）以外都拼进 Cookie 头
- **接口是非官方的**：claude.ai 前端自己用的，没有契约保证，**可能随时变**。出错时第一反应应该是抓一下网页里那个请求对比
- **不要 commit 任何 cookie / key dump**：`.gitignore` 已经挡了 `cookies.json` / `*.cookie`，新增脚本也别落盘明文

## 下一步候选

1. ~~**SwiftBar / xbar 文本 widget**~~ ✅ 已做（后弃用）
2. ~~**原生 Swift 浮窗 app**~~ ✅ 已做 — `dist/Claude Usage.app`
3. **失败降级**：fetch 失败时显示「上次成功值 + stale 12m ago」而不是只显示 ⚠（需要本地缓存最近一次成功数据，比如 `~/Library/Caches/io.github.claude-desktop-usage/last.json`）
4. **App 图标**：现在是 macOS 通用图标，做一个 `.icns` 放进 Resources 里
5. **签名 + Notarization**：分发给别人用必须做；个人本机不需要（macOS 会因为 unsigned binary 提示一次，右键 Open 即可绕过）
6. **launchd plist 取代手工加 Login Item**：repo 里提供一份 `~/Library/LaunchAgents/io.github.claude-desktop-usage.plist`，`launchctl load` 一行装上

可以顺手做的小事：
- 显示重置倒计时（`5h 25% · 2h 39m`）—— 当前布局只显示百分比
- 单击浮窗弹出更详细面板（按模型分桶、reset 倒计时）
- 把请求结果在内存里缓存 30s，避免「连点 Refresh」重复打接口

## 不要做的事

- **不要把它包装成"Claude 官方工具"或大规模分发** —— 接口非公开，给个人玩可以，规模化会被 rate limit 也会让 Anthropic 不开心
- **不要持久化 sessionKey / AES key** —— 现在每次现拿现用就行，落盘等于多一个泄密面
- **不要引入第三方依赖**除非真的必要 —— 当前 stdlib + 系统 `openssl` / `security` 跑得很顺，多一个 pip 包就多一份打包复杂度

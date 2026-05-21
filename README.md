# claude-desktop-usage

> A tiny macOS floating widget that shows your Claude.ai usage at a glance — without opening the browser.

![status](https://img.shields.io/badge/stage-prototype-yellow)
![platform](https://img.shields.io/badge/platform-macOS%2011%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## 痛点

用 Claude（Pro / Max 订阅）时总想知道自己还有多少额度：
- 这 5 小时窗口还能不能接着用？
- 7 天周配额烧到哪了？
- 离重置还有多久？

打开网页 → 登录 → 进 Settings → 滚到 Usage 部分 —— 一天里查个三五次太烦。

这个工具把这些信息常驻在桌面右上角的一个小浮窗里，不用切窗口就能瞟一眼。

## What it looks like

两档（右键菜单切换）：

```
┌──────────────────────┐       ┌──────────────────────┐
│ PLAN                 │       │ 5-hour    ███░░  44% │
│ 5-hour    ███░░  44% │       │           ↻ 1h36m    │
│           ↻ 1h36m    │       └──────────────────────┘
│ WEEKLY               │
│ All models █░░░  24% │           ↑ Compact mode
│           ↻ 4h6m     │
│ Sonnet    ░░░░░   0% │
│ Opus      ░░░░░   —  │
│ Apps      ░░░░░   —  │
└──────────────────────┘

   ↑ Full mode (default)
```

- 始终置顶（可关）
- 拖动任意位置，自动记忆
- 5h 利用率 ≥75% 变黄、≥90% 变红
- 右键菜单：Refresh / Open Claude.ai / Always on Top / Compact View / Theme (System/Dark/Light) / Opacity (50/65/80/100%) / Refresh Every (1/5/15/30 min)
- 无 Dock 图标，安静常驻

## How it works

数据走你已经登录的 **Claude 桌面 app** 的本地 session — 不需要二次登录、不需要 API key。

```
macOS Keychain            Claude.app cookies (SQLite)
       │                            │
       │  PBKDF2-SHA1               │  AES-128-CBC
       │  (saltysalt, 1003)         │  (IV = 16 spaces)
       ▼                            ▼
  AES-128 key  ────────►  sessionKey / cf_clearance / __cf_bm / ...
                                     │
                                     │ Cookie 头 + Claude.app's exact UA
                                     │ (Claude/x.y Chrome/z.w Electron/v Safari/...)
                                     ▼
                  GET claude.ai/api/organizations/<org>/usage
                                     │
                                     ▼
                  { five_hour: {...}, seven_day: {...}, ... }
```

实现分三层：

- `claude_usage.py`：数据通路（库，stdlib only）—— 读 Keychain、解密 cookie、构造 Claude.app UA、走 `curl` 请求
- `poc_fetch_usage.py`：CLI 验证脚本，打印完整 JSON
- `float_widget.swift` + `build_app.sh` → `Claude Usage.app`：原生 macOS 浮窗

## Install

前置：已经登录过 **Claude 桌面 app**（cookie 才在）。

### 方案 A — 一键安装（推荐）

```bash
curl -L -o /tmp/claude-usage.zip \
  https://github.com/eastonsuo/claude-desktop-usage/releases/latest/download/Claude-Usage.app.zip \
  && unzip -oq /tmp/claude-usage.zip -d /Applications/ \
  && xattr -dr com.apple.quarantine "/Applications/Claude Usage.app" \
  && rm /tmp/claude-usage.zip \
  && open "/Applications/Claude Usage.app"
```

干的事：拉最新 release → 解压到 `/Applications/` → 去除 quarantine（绕 Gatekeeper，因为 app 未签名）→ 启动。

手动版（不想跑脚本）：到 [Releases](https://github.com/eastonsuo/claude-desktop-usage/releases/latest) 下 `Claude-Usage.app.zip`，解压拖到 `/Applications`，**右键 → Open → 在弹窗里再点 Open**（只需一次）即可绕过 Gatekeeper。

### 方案 B — 从源码编译

```bash
git clone https://github.com/eastonsuo/claude-desktop-usage.git
cd claude-desktop-usage
./build_app.sh                          # 产物：dist/Claude Usage.app

open "dist/Claude Usage.app"             # 首次运行
cp -R "dist/Claude Usage.app" /Applications/   # 装到 Applications
```

### 第一次跑时的 Keychain 授权

首次抓取用量时会弹一次 macOS 系统弹窗：`python wants to access 'Claude Safe Storage'` —— 点 **Always Allow**。同一个 Python 解释器之后就不会再问。

### 开机自启

装到 `/Applications` 后，**System Settings → General → Login Items & Extensions → Open at Login → "+"** → 选 `Claude Usage.app`。

## Caveats / 已知约束

- **仅 macOS**：cookie 解密走 macOS Keychain；其他平台没人写过
- **接口非公开**：claude.ai 前端自己用的内部端点，Anthropic 可能随时改。挂了的话先抓网页里那个 `/api/.../usage` 请求对比
- **Claude.app 升级会让 cf_clearance 重签**：`claude_usage.py` 每次现读 Claude.app 的 plist + Electron framework 二进制构造 UA 自动跟上版本号 —— 但如果 app 改了 UA 结构，需要重新调试
- **节制刷新**：5h / 7d 数据变化慢，1–5 min 就够；过密会被 rate limit

## Debug

```bash
# 看完整 JSON
python3 poc_fetch_usage.py

# 看抓到的 UA / cookie 名 / HTTP 状态
CLAUDE_USAGE_DEBUG=1 python3 poc_fetch_usage.py 2>&1 >/dev/null | grep claude_usage

# 手工覆盖 UA（极端情况）
CLAUDE_USAGE_UA='...' python3 poc_fetch_usage.py

# 开发模式跑 raw binary（不打包成 .app）
swiftc -O -o claude-usage-float float_widget.swift
./claude-usage-float                   # 从 cwd 找 poc_fetch_usage.py

# 重置浮窗位置 / 主题 / 透明度 / 刷新间隔
defaults delete io.github.claude-desktop-usage
```

## Disclaimer

**Not affiliated with Anthropic.** This tool is a personal utility that piggybacks on Claude.ai's internal (non-public, undocumented) usage endpoint via your locally-stored Claude desktop app session. Anthropic does not endorse it, and the endpoint may change or break at any time.

**For personal use only.** Please don't redistribute pre-built binaries, run it on a schedule that hammers the endpoint, or otherwise create load that would draw rate-limiting or unwanted attention. The whole point is to glance at your own usage occasionally.

## License

[MIT](./LICENSE)

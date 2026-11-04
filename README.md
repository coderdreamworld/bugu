<p align="center"><img src="Assets/bugu-logo.png" alt="布谷" width="120"></p>

# Bugu · 布谷

**AI 编码任务运行时，让 Mac 保持唤醒；任务结束后，把休眠决定权交还给系统。**

[简体中文](README.md) · [English](README.en.md)

布谷是 macOS 菜单栏工具。它读取本机 AI 编码工具已有的会话记录，判断任务是否仍在执行；只在需要时阻止**系统空闲休眠**。屏幕仍可熄灭、锁定。

## 为什么用它

长任务可能被 Mac 的空闲休眠打断。反过来，让电脑一直保持唤醒，任务完成后也可能继续耗电。[Claude 官方教程](https://academy.claude.com/tutorials/navigating-the-claude-desktop-app)说明：桌面版的“Keep computer awake”会在应用打开期间阻止空闲休眠。布谷按任务状态控制**自己的**防休眠请求，任务结束后释放，不必记着手动关闭。

- **按任务判断**：进程常驻或窗口开着，不算任务执行中。
- **装好就能用**：原生读取 Codex、Claude Code、Gemini CLI、OpenCode、ZCode 和 WorkBuddy 的本地记录；无需安装 hook 或修改这些工具的配置。
- **本地、可控**：菜单显示执行中的任务数；可手动保持唤醒，提示音也能调到 0%。

## 安装

**目前这个 fork 没有公开安装包，需从源码构建。**需要 macOS 14+、Swift 5.10+ 和 Xcode Command Line Tools。

```bash
git clone https://github.com/coderdreamworld/bugu.git
cd bugu
./script/build_and_run.sh build
open dist/Bugu.app
```

应用启动后出现在菜单栏。想放入“应用程序”，先退出旧版，再把 `dist/Bugu.app` 复制到 `/Applications`。

## 怎么用

1. **自动监控任务**默认开启。开始受支持工具的任务后，布谷会自动保持系统唤醒；任务结束时释放自己的防休眠请求。
2. **空闲判定**默认 3 分钟，可输入 1–240 分钟。它只用于缺少明确运行状态的近期活动，以及可选 Magpie 的请求间隔；已知执行中的任务以结束记录为准。
3. 极长任务完全没有新记录时，可打开**手动保持唤醒**。在**声音设置**中将音量拖到 0%，即可关闭提示音。

布谷固定每 5 秒检查一次记录，在文件或数据库变化时重新读取。Magpie **不是必需品**；若本机运行了 Magpie 网关，布谷还能读取经它路由的其他 Agent 的在途请求状态。

## 隐私与边界

- 会话日志和 OpenCode 数据库只在本机读取，不上传代码或对话；布谷不安装 hook、不写入 Agent 配置。可选的 Magpie 连接只访问本机 `127.0.0.1`。
- 布谷只管理自己的系统空闲休眠请求。合盖、手动睡眠不受它控制；Claude 等其他应用若也在阻止休眠，布谷无法替它们释放请求。
- 日志格式变更或缺失可能导致误判。没有明确结束事件的执行状态，若 4 小时都无新记录，会自动过期；此类极长任务请使用手动开关。未支持的 Agent 不会仅因进程存在而被算作运行中。

## 开发与来源

运行行为测试：`./script/test.sh`。构建应用：`./script/build_and_run.sh build`。更多判定规则见[需求与验收](PRD-session-aware-bugu.md)。

本项目 fork 自 [LearnPrompt/bugu](https://github.com/LearnPrompt/bugu)。截至 2026-11-04，上游仓库没有提供 LICENSE 文件；复用或分发前请向原作者确认许可条件。

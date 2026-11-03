# Bugu · 布谷（本地改造版）

macOS 菜单栏工具：只读 AI 编码工具已经写在本机的日志，在任务执行时阻止电脑空闲休眠，任务结束后释放。屏幕仍可自动熄灭和锁定。

## 使用

安装后默认开启“自动监控任务”。菜单栏显示执行中的任务数和来源。需要临时无条件保持唤醒时，打开“手动保持唤醒”；它不受任务结束影响。提示音和音量可在“声音设置”中调整。

目前自动识别 **Codex**（`~/.codex/sessions`）和 **ZCode**（`~/.zcode/cli/log`、`~/.zcode/cli/rollout`）。无需为它们安装 hook，也不会修改它们的配置、读取代码文件或上传对话。其他工具的日志格式尚未验证时，不会仅凭常驻进程阻止休眠。

Bugu 每 5 秒检查一次目标日志的文件元数据，只读取新增记录。任务、模型请求或工具调用已有开始事件但尚无结束事件时，即使没有 token 增量也保持唤醒；仅有 token 增量的会话采用 3 分钟活动窗口。未结束且 4 小时没有新事件的状态会过期，避免异常日志永久阻止休眠。超过 4 小时完全无日志的极长任务可用手动开关保护。

## 构建与验证

需要 macOS 14+、Swift 5.10+ 和 Xcode Command Line Tools。

```bash
./script/test_activity.sh
./script/build_and_run.sh build
```

构建产物位于 `dist/Bugu.app`，已做本机 ad-hoc 签名。`Bugu --activity-snapshot` 只显示本机日志推断的任务状态，可用于诊断。仓库原有的 XCTest 需要完整 Xcode；`test_activity.sh` 在只有 Command Line Tools 的机器上测试核心活动判定。

## 边界

Bugu 只控制自己创建的空闲系统休眠断言。合盖、手动睡眠或其他应用创建的断言不受它控制。日志格式变更可能让某个工具暂时无法被识别；此时不会从进程名猜测活动状态。

[上游项目](https://github.com/LearnPrompt/bugu) · [改造需求与验收](PRD-session-aware-bugu.md)

<p align="center"><img src="Assets/bugu-logo.png" alt="Bugu" width="120"></p>

# Bugu

**Keep your Mac awake while an AI coding task runs. Let macOS handle sleep again when the task ends.**

[简体中文](README.md) · [English](README.en.md)

Bugu is a macOS menu bar app. It reads existing local coding-agent session records to detect active work and prevents **idle system sleep** only while needed. The display can still turn off and lock.

## Why Bugu

An unattended coding task can stop when the Mac goes to sleep. Leaving the computer awake all the time can also keep it running after the task is done. [Claude's official tutorial](https://academy.claude.com/tutorials/navigating-the-claude-desktop-app) says its desktop “Keep computer awake” setting prevents idle sleep while the app is open. Bugu instead manages **its own** sleep hold from task activity and releases it when work ends.

- **Task based**: an open window or background process alone does not count as active work.
- **Works without hooks**: reads local records from Codex, Claude Code, Gemini CLI, OpenCode, ZCode, and WorkBuddy without changing their configuration.
- **Visible and controllable**: see the active task count, keep the Mac awake manually when needed, or set sound volume to 0%.

## Install

**This fork does not yet provide a public app download; build it from source.** Requires macOS 14+, Swift 5.10+, and Xcode Command Line Tools.

```bash
git clone https://github.com/coderdreamworld/bugu.git
cd bugu
./script/build_and_run.sh build
open dist/Bugu.app
```

The app appears in the menu bar. To place it in Applications, quit any older copy first, then copy `dist/Bugu.app` to `/Applications`.

## Use

The menu currently uses Chinese labels:

1. **自动监控任务** (auto-monitor tasks) is on by default. Starting a task in a supported agent holds off idle system sleep; a completion record releases Bugu's hold.
2. **空闲判定** (idle timeout) defaults to 3 minutes and accepts 1–240 minutes. It applies only to recent activity without a clear running state and to gaps between optional Magpie requests. A task known to be running waits for its completion record.
3. Use **手动保持唤醒** (keep awake manually) for an exceptionally long task with no new records. Set volume to 0% under **声音设置** (sound settings) to disable cues.

Bugu checks records every 5 seconds and rereads files or databases when they change. **Magpie is optional**: when its local gateway is running, Bugu can also see in-flight requests from other agents routed through it.

## Privacy and limits

- Session logs and the OpenCode database are read locally. Bugu does not upload code or conversations, install hooks, or write to agent configuration. Optional Magpie access is limited to `127.0.0.1`.
- Bugu controls only its own idle-sleep assertion. It cannot prevent sleep caused by closing the lid or choosing Sleep, and it cannot release sleep holds created by Claude or other apps.
- Missing or changed log formats can cause a wrong activity decision. A running state without a completion event expires after 4 hours with no new record; use the manual switch for unusually long silent tasks. Unsupported agents are not counted merely because their process exists.

## Development and origin

Run behavior tests with `./script/test.sh`; build with `./script/build_and_run.sh build`. See the [requirements and acceptance notes](PRD-session-aware-bugu.md) for detection rules.

Forked from [LearnPrompt/bugu](https://github.com/LearnPrompt/bugu). As of 2026-11-04, the upstream repository has no LICENSE file. Confirm reuse or distribution terms with the original author.

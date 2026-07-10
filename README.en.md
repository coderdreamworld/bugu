<p align="center">
  <img src="Assets/bugu-logo.png" alt="Bugu" width="160">
</p>

<h1 align="center">Bugu · 布谷</h1>

<p align="center">
  <strong>A sound beacon for your long-running coding agents.</strong>
  <br>
  A tiny native macOS menu-bar app that keeps your Mac awake and chirps when an
  agent starts, finishes, needs permission, or gets interrupted — so you can walk
  away and still know what your agents are doing.
  <br><br>
  <a href="README.md">中文</a> | <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/LearnPrompt/bugu/releases/latest"><img src="https://img.shields.io/github/v/release/LearnPrompt/bugu?style=flat-square&label=release&color=blue" alt="Latest Release"></a>
  <a href="https://github.com/LearnPrompt/bugu/stargazers"><img src="https://img.shields.io/github/stars/LearnPrompt/bugu?style=flat-square&color=yellow" alt="Stars"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-native-orange?style=flat-square&logo=swift" alt="SwiftUI">
</p>

<p align="center">
  <a href="https://github.com/LearnPrompt/bugu/releases">Download</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#supported-agents">Supported Agents</a> ·
  <a href="#how-it-works">How It Works</a> ·
  <a href="#references--credits">References</a>
</p>

---

## Quick Start

### Option 1: Download (recommended)

1. Grab the latest **`Bugu-x.y.z.dmg`** from [Releases](https://github.com/LearnPrompt/bugu/releases).
2. Open the DMG and drag **Bugu** into **Applications**.

> Requires **macOS 14+**.

### Option 2: Build from source

```bash
git clone https://github.com/LearnPrompt/bugu.git
cd bugu
./script/build_and_run.sh
```

Run the unit tests (XCTest ships with Xcode, not the bare command-line tools):

```bash
./script/test.sh
```

> Requires **macOS 14+** and the Xcode command-line tools (Swift 5.10+).

### First Launch

If the first launch says **"Bugu" is damaged and can't be opened. You should move it to the Trash** — the app isn't actually damaged. This is macOS Gatekeeper blocking an unsigned app.

- **Option A**: In Finder, right-click (Control-click) **Bugu.app → Open**, then confirm **Open** in the dialog.
- **Option B**: Clear the quarantine flag from the terminal (adjust the path to where you installed it):

```bash
xattr -cr /Applications/Bugu.app
```

If macOS still blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**.

### Turn on the basics

1. Open the menu-bar bird icon.
2. Toggle **Keep Mac awake** and **Watch coding agents**.
3. Pick a **Sound pack** and **Alert volume**.
4. Open **Manage agents…** to install hooks for the CLIs you use (one-click
   *Enable all detected*). Hook edits are backed up and fully reversible.

## What is Bugu?

When you hand a long task to a coding agent — Claude Code, Codex, Kimi, and friends —
you either babysit the terminal or wander off and lose track. Bugu solves the
"wander off" half: it lives in your menu bar, **keeps the Mac awake** while agents
work, and gives each state change its **own short sound**. You hear a task finish
from the next room, glance at the menu, and **click straight back** to the right
terminal tab.

The name is `布谷` — the cuckoo bird: a small clock that chirps when something
changes and is otherwise quiet.

Where notch-panel apps (like [Vibe Island](https://vibeisland.app/)) put a visual
control surface on screen, Bugu is **sound-first** — the one channel you can still
perceive with the lid closed or your eyes elsewhere.

## Why Bugu?

- **Sound-first** — five distinct cues (accepted / running / done / interrupted /
  permission) so you don't need to be looking at the screen.
- **Keeps your Mac awake** — IOKit power assertions hold off sleep while an agent
  runs, and release automatically when it's done.
- **Native & tiny** — SwiftUI + AppKit menu-bar app, no Electron, no server, no
  account, no telemetry. Everything runs locally.
- **Multi-agent** — detects 20+ coding agents, installs optional hooks across a
  14-agent roster, and tracks each concurrent session independently.
- **Click-to-jump** — a recent-sessions list reads your local transcripts and jumps
  back to the exact terminal tab in one click.
- **Three sound packs** — Apple system sounds, the original **Bugu Pack**, or your
  own per-state Custom mix.

## Supported Agents

**Hook integration (14 — instant, accurate events):** Claude Code, Codex,
Gemini CLI, Cursor Agent, Trae, Droid (Factory), Qoder, Qwen, Kimi, Kimi Code,
Mistral Vibe, CodeBuddy, WorkBuddy, Kiro CLI.

**Also auto-detected by the watcher:** OpenCode, Hermes, Pi Agent, Aider, Goose,
Amp, Crush, Devin, OpenHands.

<details>
<summary>Terminals &amp; jump-back support</summary>

| Host | Jump-back |
|---|---|
| **Terminal.app** | Exact tab via TTY targeting |
| **iTerm2** | Exact session via TTY matching |
| **Warp** | Precise tab via the `bugu:<project>` title the hook bridge stamps + AX menu click |
| **Ghostty** | Precise tab via title match + AX raise |
| **Desktop-app hosts** (e.g. Claude.app) | Activates the host GUI app by walking the agent's parent-process chain |
| **Other terminals/IDEs** | Activates the running host app |

Bugu **only ever activates an app that is already running** — it never spawns a
stray terminal when it can't resolve the exact tab.

</details>

## How It Works

```
Coding agent (Claude Code / Codex / Kimi / ...)
  │
  ├── hook event ──▶ bugu-bridge (~/.bugu/bin) ──▶ ~/.bugu/events.jsonl
  │                                                   │ (DispatchSource tail)
  └── or ps/lsof polling ────────────────────────────┤
                                                      ▼
                                         Bugu (menu bar app)
                                          • plays the state's sound
                                          • holds IOKit keep-awake
                                          • lists recent sessions
                                          • click → jump to the terminal tab
```

Two event sources work together: **hooks** give low-latency, accurate state for
the CLIs you opt into, and a **`ps`/`lsof` poller** covers everything else. The
hook bridge always exits `0`, so your agents are never blocked or slowed — if Bugu
isn't running, nothing changes for them.

<details>
<summary>Sound map</summary>

| State | Meaning | System | Bugu Pack |
|---|---|---|---|
| Accepted | a new agent task was detected | Funk | start |
| Running | the watched task is still active (heartbeat) | Hero | continue |
| Completed | the task ended normally | Blow | success |
| Interrupted | the task stopped unexpectedly | Basso | end |
| Permission needed | the task is waiting for your approval | Ping | need |

The original **Bugu Pack** sounds are made for this project. Bugu does not copy
Vibe Island, Claude, or Apple audio, and uses no voice/TTS.

</details>

## Privacy

Everything runs locally. The hook bridge records only the minimum needed to drive
the UI — source CLI, event name, working directory, session id, and TTY — to
`~/.bugu/events.jsonl`. No prompts, tokens, secrets, account, server, or telemetry.

## References & Credits

Bugu stands on the shoulders of these tools:

- **[Open Island](https://github.com/Octane0411/open-vibe-island)** — an open-source, notch-panel agent monitor. Bugu's independent per-session tracking (the SessionState idea), hook adapters, and precise jump-back all learned from reading its source.
- **[Amphetamine](https://apps.apple.com/app/amphetamine/id937984704)** — the classic macOS keep-awake utility. Bugu's keep-awake shares its lineage but centers on sound + agent state.
- **[Caffeinated](https://caffeinated.app)** — another lightweight macOS keep-awake app with a nice menu-bar interaction.

Bugu copies no code or audio from any of them — only ideas.

---

<div align="center">

*Close the lid and relax — let the agent call you back.*

</div>

---

<div align="center">

**更多好用 Skill · More Skills** → [learnprompt.pro/skills](https://learnprompt.pro/skills/)

[鲁班·Skill打磨](https://github.com/LearnPrompt/luban-skill) · [庖丁·博主蒸馏](https://github.com/LearnPrompt/paoding-skill) · [蔡伦·对话造纸](https://github.com/LearnPrompt/cailun-skill) · [阿福·LLM Todo](https://github.com/LearnPrompt/afu-llm-todo) · [愚公·Loop工程](https://github.com/LearnPrompt/loop-engineering) · [搭子·结对开发](https://github.com/LearnPrompt/partner-skill) · [AI雷达·零API资讯](https://github.com/LearnPrompt/ai-news-radar)

[淘金小镇·ClawHub日榜](https://github.com/LearnPrompt/skillrush-town) · [Irasutoya·正文配图](https://github.com/LearnPrompt/carl-irasutoya-illustrations) · [Humanize PPT·演讲系统](https://github.com/LearnPrompt/humanize-ppt) · [CC Harness·六件套](https://github.com/LearnPrompt/cc-harness-skills) · [微信读书教练](https://github.com/LearnPrompt/carl-weread) · [X Article发布](https://github.com/LearnPrompt/x-article-publisher-skill)

<sub>**[LearnPrompt](https://github.com/LearnPrompt) 出品** · 公众号「卡尔的AI沃茨」 · [X @aiwarts](https://x.com/aiwarts)</sub>

</div>

# Bugu · Local session-aware build

A macOS menu bar app that reads existing local coding-agent logs and prevents idle system sleep only while a task is active. The display can still turn off and lock normally.

Monitoring is on by default. The separate manual wake switch keeps the system awake regardless of task state. Sound profile and volume remain available in the menu; select Silent to disable task sounds.

Without Magpie, Bugu reads native session records from Codex, Claude Code, Gemini CLI, OpenCode, ZCode, and WorkBuddy. Magpie is optional: when its local gateway runs, Bugu also reads in-flight requests for other agents routed through it. A request gap is held for at most three minutes, or less when a native task completion is known. Bugu does not install hooks, change agent configuration, read source code, or upload conversations. An unsupported agent process alone never prevents sleep.

Bugu checks local records every five seconds and reads changed files or database rows only. An unfinished task, model request, or tool call remains active even without new tokens. Token-only evidence lasts three minutes. A state with no new event for four hours expires so a missing completion record cannot keep the Mac awake forever; use the manual switch for an exceptionally long task with no log output.

## Build and test

Requires macOS 14+, Swift 5.10+, and Xcode Command Line Tools.

```bash
./script/test_activity.sh
./script/build_and_run.sh build
```

The signed local bundle is `dist/Bugu.app`. Quit the old app before copying it to `/Applications/Bugu.app`. `Bugu --activity-snapshot` prints the locally inferred task state. `./script/test.sh` runs the activity and legacy-hook cleanup checks, plus XCTest when full Xcode is available.

[Upstream project](https://github.com/LearnPrompt/bugu) · [Requirements and acceptance (Chinese)](PRD-session-aware-bugu.md)

# Bugu · Local session-aware build

A macOS menu bar app that reads existing local coding-agent logs and prevents idle system sleep only while a task is active. The display can still turn off and lock normally.

Monitoring is on by default. The separate manual wake switch keeps the system awake regardless of task state. Sound profile and volume remain available in the menu; select Silent to disable task sounds.

This build reads Codex (`~/.codex/sessions`) and ZCode (`~/.zcode/cli/log`, `~/.zcode/cli/rollout`) logs. It does not install hooks, change agent configuration, read source code, or upload conversations. An unsupported agent process alone never prevents sleep.

Bugu checks log metadata every five seconds and reads appended records only. An unfinished task, model request, or tool call remains active even without new tokens. Token-only evidence lasts three minutes. A state with no new event for four hours expires so a missing completion record cannot keep the Mac awake forever; use the manual switch for an exceptionally long task with no log output.

## Build and test

Requires macOS 14+, Swift 5.10+, and Xcode Command Line Tools.

```bash
./script/test_activity.sh
./script/build_and_run.sh build
```

The signed local bundle is `dist/Bugu.app`. Quit the old app before copying it to `/Applications/Bugu.app`. `Bugu --activity-snapshot` prints the locally inferred task state. `./script/test.sh` runs the activity and legacy-hook cleanup checks, plus XCTest when full Xcode is available.

[Upstream project](https://github.com/LearnPrompt/bugu) · [Requirements and acceptance (Chinese)](PRD-session-aware-bugu.md)

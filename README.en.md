# Bugu · Local session-aware build

A macOS menu bar app that reads existing local coding-agent logs and prevents idle system sleep only while a task is active. The display can still turn off and lock normally.

Monitoring is on by default. Enter 1–240 minutes in the Idle timeout field (default 3); press Return or leave the field to apply it. This timeout covers recent activity without a clear running state. Explicit completion releases the sleep hold immediately; a known running task waits for its completion record. The separate manual wake switch keeps the system awake regardless of task state. Set sound volume to 0% to disable task sounds.

Without Magpie, Bugu reads native session records from Codex, Claude Code, Gemini CLI, OpenCode, ZCode, and WorkBuddy. Magpie is optional: when its local gateway runs, Bugu also reads in-flight requests for other agents routed through it. A request gap follows the selected idle timeout, or ends sooner when a native task completion is known. Bugu does not install hooks, change agent configuration, read source code, or upload conversations. An unsupported agent process alone never prevents sleep.

Bugu checks local records every five seconds and reads changed files or database rows only. An unfinished task, model request, or tool call remains active even without new tokens. Token-only evidence lasts for the selected idle timeout. A state with no new event for four hours expires so a missing completion record cannot keep the Mac awake forever; use the manual switch for an exceptionally long task with no log output.

## Build and test

Requires macOS 14+, Swift 5.10+, and Xcode Command Line Tools.

```bash
./script/test_activity.sh
./script/build_and_run.sh build
```

The signed local bundle is `dist/Bugu.app`. Quit the old app before copying it to `/Applications/Bugu.app`. `Bugu --activity-snapshot` prints the locally inferred task state. `./script/test.sh` runs the activity and legacy-hook cleanup checks.

[Upstream project](https://github.com/LearnPrompt/bugu) · [Requirements and acceptance (Chinese)](PRD-session-aware-bugu.md)

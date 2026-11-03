import Foundation

@main
struct ActivityMonitorHarness {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bugu-activity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = ActivityMonitor(home: root.path)
        expect(monitor.scan(now: now).activeCount == 0, "empty logs are idle")

        let codexDir = root.appendingPathComponent(".codex/sessions/2026/11/03")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let first = codexDir.appendingPathComponent("rollout-2026-11-03T20-00-00-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jsonl")
        let second = codexDir.appendingPathComponent("rollout-2026-11-03T20-00-01-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jsonl")
        try append(codex("task_started", at: "2026-11-03T12:00:00Z"), to: first, mtime: now)
        expect(monitor.scan(now: now).activeCount == 1, "a Codex turn starts wakefulness")
        expect(monitor.scan(now: now.addingTimeInterval(10 * 60)).activeCount == 1, "token silence does not end a running turn")

        try append(codex("task_started", at: "2026-11-03T12:00:01Z"), to: second, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(2)).activeCount == 2, "concurrent turns stay independent")
        try append(codex("task_complete", at: "2026-11-03T12:00:03Z"), to: first, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(4)).activeCount == 1, "one completed turn does not end another")
        try append(codex("task_complete", at: "2026-11-03T12:00:05Z"), to: second, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(6)).activeCount == 0, "last turn completion releases automatic wakefulness")

        let zcodeDir = root.appendingPathComponent(".zcode/cli/log")
        try FileManager.default.createDirectory(at: zcodeDir, withIntermediateDirectories: true)
        let zcode = zcodeDir.appendingPathComponent("zcode-2026-11-03.jsonl")
        try append(zcodeEvent("turn.started", at: "2026-11-03T12:01:00Z"), to: zcode, mtime: now)
        try append(zcodeEvent("tool.call.started", at: "2026-11-03T12:01:01Z"), to: zcode, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(62)).activeCount == 1, "ZCode tool call is active without new tokens")
        try append(zcodeEvent("tool.call.completed", at: "2026-11-03T12:05:00Z"), to: zcode, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(5 * 60)).activeCount == 1, "tool completion does not end its turn")
        try append(zcodeEvent("turn.completed", at: "2026-11-03T12:05:01Z"), to: zcode, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(5 * 60 + 2)).activeCount == 0, "ZCode turn completion is idle")

        let tokensOnly = codexDir.appendingPathComponent("rollout-2026-11-03T20-10-00-cccccccc-cccc-4ccc-8ccc-cccccccccccc.jsonl")
        try append(#"{"timestamp":"2026-11-03T12:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#, to: tokensOnly, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(10 * 60)).activeCount == 1, "token growth proves recent activity")
        expect(monitor.scan(now: now.addingTimeInterval(14 * 60)).activeCount == 0, "token-only evidence expires")

        try append("not json", to: tokensOnly, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(15 * 60)).activeCount == 0, "malformed log line cannot force wakefulness")

        let partial = codexDir.appendingPathComponent("rollout-2026-11-03T20-20-00-dddddddd-dddd-4ddd-8ddd-dddddddddddd.jsonl")
        try Data(codex("task_started", at: "2026-11-03T12:20:00Z").utf8).write(to: partial)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: partial.path)
        expect(monitor.scan(now: now.addingTimeInterval(20 * 60)).activeCount == 0, "incomplete JSONL record is not acted upon")
        try append("", to: partial, mtime: now)
        expect(monitor.scan(now: now.addingTimeInterval(20 * 60 + 1)).activeCount == 1, "completed JSONL record is processed")

        try FileManager.default.removeItem(at: partial)
        try append(codex("task_complete", at: "2026-11-03T12:21:00Z"), to: partial, mtime: now.addingTimeInterval(21 * 60))
        expect(monitor.scan(now: now.addingTimeInterval(21 * 60 + 1)).activeCount == 0, "replacement log file is read after rotation")

        let stale = codexDir.appendingPathComponent("rollout-2026-11-03T20-22-00-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.jsonl")
        try append(codex("task_started", at: "2026-11-03T12:22:00Z"), to: stale, mtime: now.addingTimeInterval(22 * 60))
        expect(monitor.scan(now: now.addingTimeInterval(22 * 60 + 1)).activeCount == 1, "unmatched start is initially active")
        expect(monitor.scan(now: now.addingTimeInterval(5 * 60 * 60)).activeCount == 0, "unmatched start cannot prevent sleep indefinitely")

        expect(AwakePolicy.shouldStayAwake(monitoring: false, manual: false, activeCount: 1) == false, "disabled monitor ignores activity")
        expect(AwakePolicy.shouldStayAwake(monitoring: false, manual: true, activeCount: 0), "manual wakefulness is independent")
        print("ActivityMonitorHarness: all behavior checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func append(_ line: String, to url: URL, mtime: Date) throws {
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private static func codex(_ event: String, at time: String) -> String {
        "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}"
    }

    private static func zcodeEvent(_ event: String, at time: String) -> String {
        "{\"timestamp\":\"\(time)\",\"event\":\"\(event)\",\"sessionId\":\"session-1\",\"turnId\":\"turn-1\",\"toolCallId\":\"tool-1\"}"
    }
}

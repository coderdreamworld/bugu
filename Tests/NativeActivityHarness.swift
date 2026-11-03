import Foundation
import SQLite3

@main
struct NativeActivityHarness {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bugu-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try claude(root: root, now: now)
        try workBuddy(root: root, now: now)
        try gemini(root: root, now: now)
        try openCode(root: root, now: now)
        try openCodeV2(root: root, now: now)
        try openCodeWindow(root: root, now: now)
        print("NativeActivityHarness: all behavior checks passed")
    }

    private static func claude(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("claude")
        let file = home.appendingPathComponent(".claude/projects/project/claude-session.jsonl")
        try makeParent(file)
        let monitor = ActivityMonitor(home: home.path)
        try append(#"{"type":"user","timestamp":"2026-11-03T12:00:00Z","cwd":"/work/project","message":{"content":"do work"}}"#, to: file, at: now)
        expect(monitor.scan(now: now).activeCount == 1, "Claude prompt starts a turn")
        try append(#"{"type":"assistant","timestamp":"2026-11-03T12:00:01Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1"}]}}"#, to: file, at: now.addingTimeInterval(1))
        expect(monitor.scan(now: now.addingTimeInterval(15 * 60)).activeCount == 1, "Claude tool wait survives token silence")
        try append(#"{"type":"user","timestamp":"2026-11-03T12:15:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#, to: file, at: now.addingTimeInterval(15 * 60 + 1))
        try append(#"{"type":"assistant","timestamp":"2026-11-03T12:15:02Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#, to: file, at: now.addingTimeInterval(15 * 60 + 2))
        expect(monitor.scan(now: now.addingTimeInterval(15 * 60 + 4)).activeCount == 1, "Claude final blocks get a short settle period")
        expect(monitor.scan(now: now.addingTimeInterval(15 * 60 + 8)).activeCount == 0, "Claude end_turn releases sleep hold")
    }

    private static func workBuddy(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("buddy")
        let file = home.appendingPathComponent(".workbuddy/projects/project/buddy-session.jsonl")
        try makeParent(file)
        let monitor = ActivityMonitor(home: home.path)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try append("{\"type\":\"message\",\"role\":\"user\",\"timestamp\":\(ms),\"sessionId\":\"buddy-session\"}", to: file, at: now)
        expect(monitor.scan(now: now).activeCount == 1, "WorkBuddy prompt starts a turn")
        try append("{\"type\":\"message\",\"role\":\"assistant\",\"timestamp\":\(ms+1000),\"sessionId\":\"buddy-session\"}", to: file, at: now.addingTimeInterval(1))
        try append("{\"type\":\"function_call\",\"callId\":\"tool-1\",\"timestamp\":\(ms+2000),\"sessionId\":\"buddy-session\"}", to: file, at: now.addingTimeInterval(2))
        expect(monitor.scan(now: now.addingTimeInterval(15 * 60)).activeCount == 1, "WorkBuddy tool call remains active")
        try append("{\"type\":\"function_call_result\",\"callId\":\"tool-1\",\"timestamp\":\(ms+900001),\"sessionId\":\"buddy-session\"}", to: file, at: now.addingTimeInterval(900))
        try append("{\"type\":\"message\",\"role\":\"assistant\",\"timestamp\":\(ms+900002),\"sessionId\":\"buddy-session\"}", to: file, at: now.addingTimeInterval(901))
        expect(monitor.scan(now: now.addingTimeInterval(903)).activeCount == 1, "WorkBuddy final message settles")
        expect(monitor.scan(now: now.addingTimeInterval(908)).activeCount == 0, "WorkBuddy final message releases hold")
    }

    private static func gemini(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("gemini")
        let file = home.appendingPathComponent(".gemini/tmp/project/chats/session-a.jsonl")
        try makeParent(file)
        let monitor = ActivityMonitor(home: home.path)
        try append(#"{"sessionId":"a"}"#, to: file, at: now)
        try append(#"{"type":"user","id":"u","timestamp":"2026-11-03T12:00:00Z","content":"question"}"#, to: file, at: now)
        expect(monitor.scan(now: now).activeCount == 1, "Gemini prompt starts a turn")
        try append(#"{"type":"gemini","id":"a","timestamp":"2026-11-03T12:00:02Z","toolCalls":[{"id":"tool","status":"success"}]}"#, to: file, at: now.addingTimeInterval(2))
        expect(monitor.scan(now: now.addingTimeInterval(10 * 60)).activeCount == 1, "Gemini tool chain remains active without tokens")
        try append(#"{"type":"user","id":"fr","timestamp":"2026-11-03T12:10:01Z","content":[{"functionResponse":{"id":"tool"}}]}"#, to: file, at: now.addingTimeInterval(10 * 60 + 1))
        try append(#"{"type":"gemini","id":"final","timestamp":"2026-11-03T12:10:02Z","content":"answer"}"#, to: file, at: now.addingTimeInterval(10 * 60 + 2))
        expect(monitor.scan(now: now.addingTimeInterval(10 * 60 + 8)).activeCount == 0, "Gemini final response releases hold")

        let oldHome = root.appendingPathComponent("gemini-snapshot")
        let snapshot = oldHome.appendingPathComponent(".gemini/tmp/project/chats/session-old.json")
        try makeParent(snapshot)
        try Data(#"{"sessionId":"old","messages":[{"type":"user","id":"u","timestamp":"2026-11-03T12:00:00Z"},{"type":"gemini","id":"a","timestamp":"2026-11-03T12:00:01Z","content":"done"}]}"#.utf8).write(to: snapshot)
        try touch(snapshot, at: now)
        expect(ActivityMonitor(home: oldHome.path).scan(now: now.addingTimeInterval(10)).activeCount == 0, "Gemini legacy snapshot final response is idle")
    }

    private static func openCode(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("opencode")
        let file = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try makeParent(file)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try sql(file, "CREATE TABLE session(id TEXT PRIMARY KEY,directory TEXT,time_updated INTEGER); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT); CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,data TEXT); INSERT INTO session VALUES('s','/work/project',\(ms)); INSERT INTO message VALUES('u','s',\(ms),\(ms),'{\"role\":\"user\"}');")
        let monitor = ActivityMonitor(home: home.path)
        expect(monitor.scan(now: now).activeCount == 1, "OpenCode user message starts work")
        try sql(file, "INSERT INTO message VALUES('a','s',\(ms+1000),\(ms+1000),'{\"role\":\"assistant\",\"time\":{\"created\":\(ms+1000)}}'); UPDATE session SET time_updated=\(ms+1000);")
        try touch(file, at: now.addingTimeInterval(1))
        expect(monitor.scan(now: now.addingTimeInterval(2)).activeCount == 1, "OpenCode unfinished response is active")
        try sql(file, "UPDATE message SET time_updated=\(ms+2000),data='{\"role\":\"assistant\",\"finish\":\"stop\",\"time\":{\"completed\":\(ms+2000)}}' WHERE id='a'; UPDATE session SET time_updated=\(ms+2000);")
        try touch(file, at: now.addingTimeInterval(3))
        expect(monitor.scan(now: now.addingTimeInterval(4)).activeCount == 0, "OpenCode stop releases hold")
    }

    private static func openCodeV2(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("opencode-v2")
        let file = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try makeParent(file)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try sql(file, "CREATE TABLE session_v2(id TEXT PRIMARY KEY,directory TEXT,time_updated INTEGER); CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,seq INTEGER,type TEXT,time_updated INTEGER,data TEXT); INSERT INTO session_v2 VALUES('s2','/work/v2',\(ms)); INSERT INTO session_message VALUES('u2','s2',1,'user',\(ms),'{}');")
        let monitor = ActivityMonitor(home: home.path)
        expect(monitor.scan(now: now).activeCount == 1, "OpenCode 2 user message starts work")
        try sql(file, "INSERT INTO session_message VALUES('a2','s2',2,'assistant',\(ms+1000),'{\"finish\":\"stop\",\"time\":{\"completed\":\(ms+1000)}}'); UPDATE session_v2 SET time_updated=\(ms+1000);")
        try touch(file, at: now.addingTimeInterval(2))
        expect(monitor.scan(now: now.addingTimeInterval(3)).activeCount == 0, "OpenCode 2 stop releases hold")
    }

    private static func openCodeWindow(root: URL, now: Date) throws {
        let home = root.appendingPathComponent("opencode-window")
        let file = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try makeParent(file)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try sql(file, "CREATE TABLE session(id TEXT PRIMARY KEY,directory TEXT,time_updated INTEGER); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT); INSERT INTO session VALUES('s','/work/project',\(ms)); INSERT INTO message VALUES('a','s',\(ms),\(ms),'{\"role\":\"assistant\",\"finish\":\"continue\",\"time\":{\"completed\":\(ms)}}');")
        let monitor = ActivityMonitor(home: home.path)
        expect(monitor.scan(now: now).activeCount == 1, "OpenCode recent response holds wakefulness")
        expect(monitor.scan(now: now.addingTimeInterval(4 * 60)).activeCount == 0, "OpenCode default window expires")
        expect(monitor.scan(now: now.addingTimeInterval(4 * 60), window: .fiveMinutes).activeCount == 1, "OpenCode uses the selected window")
    }

    private static func sql(_ file: URL, _ command: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
    }

    private static func makeParent(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func touch(_ file: URL, at date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private static func append(_ line: String, to file: URL, at date: Date) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try Data((line + "\n").utf8).write(to: file)
        }
        try touch(file, at: date)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

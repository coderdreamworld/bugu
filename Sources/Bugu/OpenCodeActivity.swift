import Foundation
import SQLite3

/// Reads OpenCode's own SQLite session store without changing it or depending on Magpie.
final class OpenCodeActivityMonitor {
    private struct Observation {
        let id: String
        let project: String
        let at: Date
        let running: Bool
        let ended: Bool
    }

    private let path: String
    private let fm = FileManager.default
    private var signature: String?
    private var observations: [Observation] = []

    init(home: String) {
        path = home + "/.local/share/opencode/opencode.db"
    }

    func scan(now: Date, window: RecentActivityWindow) -> [MonitoredSession] {
        guard let current = fileSignature() else {
            observations = []
            signature = nil
            return []
        }
        if current != signature {
            observations = read(now: now)
            signature = current
        }
        return observations.compactMap { item in
            let age = now.timeIntervalSince(item.at)
            guard age >= 0, age <= 4 * 60 * 60 else { return nil }
            let active = !item.ended && (item.running || age <= window.seconds)
            guard active || age <= 2 * 60 * 60 else { return nil }
            return MonitoredSession(
                id: "opencode:" + item.id, agent: "OpenCode", project: item.project,
                lastActivity: item.at,
                status: active ? (item.running ? "执行中" : "近期有 token") : "已完成",
                isActive: active
            )
        }
    }

    private func fileSignature() -> String? {
        guard let db = try? fm.attributesOfItem(atPath: path) else { return nil }
        let wal = (try? fm.attributesOfItem(atPath: path + "-wal")) ?? [:]
        func part(_ attrs: [FileAttributeKey: Any]) -> String {
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size):\(modified)"
        }
        return part(db) + ":" + part(wal)
    }

    private func read(now: Date) -> [Observation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if db != nil { sqlite3_close(db) }; return observations }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let newer = hasTable(db, "session_v2")
        let sessionTable = newer ? "session_v2" : "session"
        let query = "SELECT id, directory FROM \(sessionTable) WHERE time_updated >= ? ORDER BY time_updated DESC LIMIT 100"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return observations }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-4 * 60 * 60).timeIntervalSince1970 * 1000))
        var result: [Observation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            let directory = text(statement, 1) ?? ""
            if let observation = latest(db, session: id, directory: directory, newer: newer) {
                result.append(observation)
            }
        }
        return result
    }

    private func latest(_ db: OpaquePointer, session: String, directory: String, newer: Bool) -> Observation? {
        let query = newer
            ? "SELECT id, type, data, time_updated FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT 1"
            : "SELECT id, '', data, time_updated FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        _ = session.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let messageID = text(statement, 0),
              let raw = text(statement, 2),
              let data = raw.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let role = newer ? (text(statement, 1) ?? "") : (message["role"] as? String ?? "")
        let at = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
        let project = directory.isEmpty ? "OpenCode" : URL(fileURLWithPath: directory).lastPathComponent
        switch role {
        case "user":
            return Observation(id: session, project: project, at: at, running: true, ended: false)
        case "assistant":
            let time = message["time"] as? [String: Any] ?? [:]
            let completed = time["completed"] != nil && !(time["completed"] is NSNull)
            if !completed { return Observation(id: session, project: project, at: at, running: true, ended: false) }
            let finish = message["finish"] as? String ?? ""
            if finish == "stop" || finish == "end_turn" {
                return Observation(id: session, project: project, at: at, running: false, ended: true)
            }
            let pending = newer ? pendingToolsInMessage(message) : pendingToolsInParts(db, message: messageID)
            return Observation(id: session, project: project, at: at, running: pending, ended: false)
        case "idle":
            return Observation(id: session, project: project, at: at, running: false, ended: true)
        default:
            return nil
        }
    }

    private func pendingToolsInMessage(_ message: [String: Any]) -> Bool {
        let content = message["content"] as? [[String: Any]] ?? []
        return content.contains { part in
            guard part["type"] as? String == "tool" else { return false }
            let state = part["state"] as? [String: Any] ?? [:]
            return ["pending", "running"].contains(state["status"] as? String ?? "")
        }
    }

    private func pendingToolsInParts(_ db: OpaquePointer, message: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM part WHERE message_id = ?", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        _ = message.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = text(statement, 0), let data = raw.data(using: .utf8),
                  let part = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  part["type"] as? String == "tool",
                  let state = part["state"] as? [String: Any] else { continue }
            if ["pending", "running"].contains(state["status"] as? String ?? "") { return true }
        }
        return false
    }

    private func hasTable(_ db: OpaquePointer, _ name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        _ = name.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}

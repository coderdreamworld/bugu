import Foundation

struct MonitoredSession: Identifiable {
    let id: String
    let agent: String
    let project: String
    let lastActivity: Date
    let status: String
    let isActive: Bool
}

struct ActivitySnapshot {
    let sessions: [MonitoredSession]
    let activeCount: Int
}

enum AwakePolicy {
    static func shouldStayAwake(monitoring: Bool, manual: Bool, activeCount: Int) -> Bool {
        manual || (monitoring && activeCount > 0)
    }
}

/// Reads only local agent logs. No hooks, agent configuration edits, or network calls.
// BeaconModel confines scans of each instance to one serial queue.
final class ActivityMonitor: @unchecked Sendable {
    private enum Source { case codex, zcodeLog, zcodeUsage }
    private struct Candidate { let path: String; let source: Source }
    private struct Cursor {
        var offset: UInt64
        var inode: NSNumber?
        var modified: Date
        var partial: Data
    }
    private struct State {
        let id: String
        let agent: String
        var project: String
        var lastEvent: Date
        var lastToken: Date?
        var totalTokens: Int64?
        var running = false
        var ended = false
        var operations = Set<String>()

        func isActive(at now: Date) -> Bool {
            if ended { return false }
            let age = now.timeIntervalSince(lastEvent)
            if age < 0 { return false }
            if (running || !operations.isEmpty) && age <= 4 * 60 * 60 { return true }
            if let lastToken, now.timeIntervalSince(lastToken) >= 0,
               now.timeIntervalSince(lastToken) <= 3 * 60 { return true }
            return false
        }
    }

    private let home: String
    private let fm = FileManager.default
    private var cursors: [String: Cursor] = [:]
    private var states: [String: State] = [:]
    private let iso = ISO8601DateFormatter()

    init(home: String = NSHomeDirectory()) {
        self.home = home
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func scan(now: Date = Date()) -> ActivitySnapshot {
        for candidate in candidates(now: now) {
            readChanges(candidate, now: now)
        }
        states = states.filter { now.timeIntervalSince($0.value.lastEvent) < 24 * 60 * 60 }
        let sessions = states.values.compactMap { state -> MonitoredSession? in
            let active = state.isActive(at: now)
            guard active || now.timeIntervalSince(state.lastEvent) < 2 * 60 * 60 else { return nil }
            let status: String
            if active { status = state.running || !state.operations.isEmpty ? "执行中" : "近期有 token" }
            else if state.ended { status = "已完成" }
            else { status = "空闲" }
            return MonitoredSession(
                id: state.id, agent: state.agent, project: state.project,
                lastActivity: state.lastEvent, status: status, isActive: active
            )
        }.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastActivity > $1.lastActivity
        }
        return ActivitySnapshot(sessions: Array(sessions.prefix(12)), activeCount: sessions.filter(\.isActive).count)
    }

    private func candidates(now: Date) -> [Candidate] {
        let day = DateFormatter()
        day.dateFormat = "yyyy/MM/dd"
        let flatDay = DateFormatter()
        flatDay.dateFormat = "yyyy-MM-dd"
        var found: [Candidate] = []
        for offset in 0...2 {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let codexDir = home + "/.codex/sessions/" + day.string(from: date)
            if let names = try? fm.contentsOfDirectory(atPath: codexDir) {
                found += names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
                    .map { Candidate(path: codexDir + "/" + $0, source: .codex) }
            }
            let zcodeLog = home + "/.zcode/cli/log/zcode-" + flatDay.string(from: date) + ".jsonl"
            if fm.fileExists(atPath: zcodeLog) { found.append(Candidate(path: zcodeLog, source: .zcodeLog)) }
        }
        let usageDir = home + "/.zcode/cli/rollout"
        if let names = try? fm.contentsOfDirectory(atPath: usageDir) {
            found += names.filter { $0.hasPrefix("model-io-") && $0.hasSuffix(".jsonl") }
                .map { Candidate(path: usageDir + "/" + $0, source: .zcodeUsage) }
        }
        return found
    }

    private func readChanges(_ candidate: Candidate, now: Date) {
        guard let attributes = try? fm.attributesOfItem(atPath: candidate.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return }
        guard now.timeIntervalSince(modified) < 4 * 60 * 60 || cursors[candidate.path] != nil else { return }
        let inode = attributes[.systemFileNumber] as? NSNumber
        var cursor = cursors[candidate.path] ?? Cursor(offset: 0, inode: inode, modified: modified, partial: Data())
        let length = size.uint64Value
        if cursor.inode != inode || length < cursor.offset || (length == cursor.offset && modified > cursor.modified) {
            cursor = Cursor(offset: 0, inode: inode, modified: modified, partial: Data())
        }
        guard length > cursor.offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.path)) else { return }
        defer { try? handle.close() }
        let tailLimit: UInt64 = 8 * 1024 * 1024
        let start = max(cursor.offset, length > tailLimit ? length - tailLimit : 0)
        if start > cursor.offset { cursor.partial = Data() }
        do {
            try handle.seek(toOffset: start)
            let bytes = handle.readDataToEndOfFile()
            var data = cursor.partial + bytes
            if start > 0 && cursor.offset == 0, let newline = data.firstIndex(of: 10) {
                data.removeSubrange(...newline)
            }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            for line in lines.dropLast() {
                parse(Data(line), source: candidate.source, path: candidate.path)
            }
            cursor.partial = Data(lines.last ?? Data.SubSequence())
            cursor.offset = start + UInt64(bytes.count)
            cursor.modified = modified
            cursor.inode = inode
            cursors[candidate.path] = cursor
        } catch { return }
    }

    private func parse(_ line: Data, source: Source, path: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let timeString = (object["timestamp"] as? String) ?? (object["completedAt"] as? String),
              let time = iso.date(from: timeString) ?? ISO8601DateFormatter().date(from: timeString) else { return }
        switch source {
        case .codex: parseCodex(object, path: path, time: time)
        case .zcodeLog: parseZCode(object, time: time)
        case .zcodeUsage: parseZCodeUsage(object, time: time)
        }
    }

    private func update(_ id: String, agent: String, time: Date, _ body: (inout State) -> Void) {
        var state = states[id] ?? State(id: id, agent: agent, project: agent, lastEvent: time)
        state.lastEvent = max(state.lastEvent, time)
        body(&state)
        states[id] = state
    }

    private func parseCodex(_ object: [String: Any], path: String, time: Date) {
        let id = "codex:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            if let cwd = payload["cwd"] as? String {
                update(id, agent: "Codex", time: time) { $0.project = URL(fileURLWithPath: cwd).lastPathComponent }
            }
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                update(id, agent: "Codex", time: time) { $0.running = true; $0.ended = false }
            case "task_complete", "turn_aborted":
                update(id, agent: "Codex", time: time) { $0.running = false; $0.ended = true; $0.operations.removeAll() }
            case "token_count":
                let info = payload["info"] as? [String: Any]
                let total = info?["total_token_usage"] as? [String: Any]
                if let count = (total?["total_tokens"] as? NSNumber)?.int64Value {
                    let previous = states[id]?.totalTokens
                    if previous.map({ count > $0 }) ?? true {
                        update(id, agent: "Codex", time: time) { state in
                            state.lastToken = time
                            state.totalTokens = count
                        }
                    }
                }
            default: break
            }
        case "response_item":
            guard let kind = payload["type"] as? String,
                  let callID = payload["call_id"] as? String else { return }
            if kind == "function_call" || kind == "custom_tool_call" {
                update(id, agent: "Codex", time: time) { $0.operations.insert(callID) }
            } else if kind == "function_call_output" || kind == "custom_tool_call_output" {
                update(id, agent: "Codex", time: time) { $0.operations.remove(callID) }
            }
        default: break
        }
    }

    private func parseZCode(_ object: [String: Any], time: Date) {
        guard let session = object["sessionId"] as? String,
              let turn = object["turnId"] as? String,
              let event = object["event"] as? String else { return }
        let id = "zcode:\(session):\(turn)"
        switch event {
        case "turn.started":
            update(id, agent: "ZCode", time: time) { $0.running = true; $0.ended = false }
        case "turn.completed", "turn.failed":
            update(id, agent: "ZCode", time: time) { $0.running = false; $0.ended = true; $0.operations.removeAll() }
        case "tool.call.started", "model.request.started":
            let operation = (object["toolCallId"] as? String) ?? (object["spanId"] as? String) ?? event
            update(id, agent: "ZCode", time: time) { $0.operations.insert(operation) }
        case "tool.call.completed", "model.request.completed", "model.request.failed":
            let operation = (object["toolCallId"] as? String) ?? (object["spanId"] as? String)
                ?? event.replacingOccurrences(of: ".completed", with: ".started")
            update(id, agent: "ZCode", time: time) { $0.operations.remove(operation) }
        default: break
        }
    }

    private func parseZCodeUsage(_ object: [String: Any], time: Date) {
        guard let session = object["sessionId"] as? String,
              let turn = object["turnId"] as? String,
              let response = object["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any],
              (usage["totalTokens"] as? NSNumber)?.int64Value ?? 0 > 0 else { return }
        update("zcode:\(session):\(turn)", agent: "ZCode", time: time) { $0.lastToken = time }
    }
}

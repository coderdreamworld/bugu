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

struct RecentActivityWindow: Equatable {
    static let standard = RecentActivityWindow(minutes: 3)!
    static let allowedMinutes = 1...240

    let minutes: Int
    var seconds: TimeInterval { TimeInterval(minutes * 60) }

    init?(minutes: Int) {
        guard Self.allowedMinutes.contains(minutes) else { return nil }
        self.minutes = minutes
    }

    static func parse(_ text: String) -> Self? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Self(minutes: minutes)
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(minutes: defaults.integer(forKey: "recentActivityMinutes")) ?? .standard
    }
}

/// Reads only local agent logs. No hooks, agent configuration edits, or network calls.
// BeaconModel confines scans of each instance to one serial queue.
final class ActivityMonitor: @unchecked Sendable {
    private enum Source { case codex, zcodeLog, zcodeUsage, claude, gemini, geminiSnapshot, workbuddy }
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
        var completionAt: Date?
        var operations = Set<String>()

        func isActive(at now: Date, window: RecentActivityWindow) -> Bool {
            let age = now.timeIntervalSince(lastEvent)
            if age < 0 { return false }
            if ended { return completionAt.map { now < $0 } ?? false }
            if (running || !operations.isEmpty) && age <= 4 * 60 * 60 { return true }
            if let lastToken, now.timeIntervalSince(lastToken) >= 0,
               now.timeIntervalSince(lastToken) <= window.seconds { return true }
            return false
        }
    }

    private let home: String
    private let fm = FileManager.default
    private var cursors: [String: Cursor] = [:]
    private var states: [String: State] = [:]
    private let openCode: OpenCodeActivityMonitor
    private let iso = ISO8601DateFormatter()

    init(home: String = NSHomeDirectory()) {
        self.home = home
        openCode = OpenCodeActivityMonitor(home: home)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func scan(now: Date = Date(), window: RecentActivityWindow = .standard) -> ActivitySnapshot {
        for candidate in candidates(now: now) {
            readChanges(candidate, now: now)
        }
        let openCodeSessions = openCode.scan(now: now, window: window)
        states = states.filter { now.timeIntervalSince($0.value.lastEvent) < 24 * 60 * 60 }
        let sessions = states.values.compactMap { state -> MonitoredSession? in
            let active = state.isActive(at: now, window: window)
            guard active || now.timeIntervalSince(state.lastEvent) < 2 * 60 * 60 else { return nil }
            let status: String
            if active { status = state.ended ? "收尾中" : state.running || !state.operations.isEmpty ? "执行中" : "近期有 token" }
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
        let combined = (sessions + openCodeSessions).sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastActivity > $1.lastActivity
        }
        return ActivitySnapshot(sessions: Array(combined.prefix(12)), activeCount: combined.filter(\.isActive).count)
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
        let claudeRoot = home + "/.claude/projects"
        if let projects = try? fm.contentsOfDirectory(atPath: claudeRoot) {
            for project in projects {
                let dir = claudeRoot + "/" + project
                if let names = try? fm.contentsOfDirectory(atPath: dir) {
                    found += names.filter { $0.hasSuffix(".jsonl") }
                        .map { Candidate(path: dir + "/" + $0, source: .claude) }
                }
            }
        }
        let geminiRoot = home + "/.gemini/tmp"
        if let projects = try? fm.contentsOfDirectory(atPath: geminiRoot) {
            for project in projects {
                let dir = geminiRoot + "/" + project + "/chats"
                if let names = try? fm.contentsOfDirectory(atPath: dir) {
                    found += names.filter { $0.hasPrefix("session-") && $0.hasSuffix(".jsonl") }
                        .map { Candidate(path: dir + "/" + $0, source: .gemini) }
                    found += names.filter { $0.hasPrefix("session-") && $0.hasSuffix(".json") }
                        .map { Candidate(path: dir + "/" + $0, source: .geminiSnapshot) }
                }
            }
        }
        let buddyRoot = home + "/.workbuddy/projects"
        if let projects = try? fm.contentsOfDirectory(atPath: buddyRoot) {
            for project in projects {
                let dir = buddyRoot + "/" + project
                if let names = try? fm.contentsOfDirectory(atPath: dir) {
                    found += names.filter { $0.hasSuffix(".jsonl") }
                        .map { Candidate(path: dir + "/" + $0, source: .workbuddy) }
                }
            }
        }
        return found
    }

    private func readChanges(_ candidate: Candidate, now: Date) {
        if candidate.source == .geminiSnapshot { readGeminiSnapshot(candidate, now: now); return }
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

    private func readGeminiSnapshot(_ candidate: Candidate, now: Date) {
        guard let attributes = try? fm.attributesOfItem(atPath: candidate.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024,
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < 4 * 60 * 60 else { return }
        let inode = attributes[.systemFileNumber] as? NSNumber
        if let cursor = cursors[candidate.path], cursor.offset == size.uint64Value,
           cursor.inode == inode, cursor.modified == modified { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        parseGemini(object, path: candidate.path)
        cursors[candidate.path] = Cursor(offset: size.uint64Value, inode: inode, modified: modified, partial: Data())
    }

    private func parse(_ line: Data, source: Source, path: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if source == .gemini || source == .geminiSnapshot { parseGemini(object, path: path); return }
        let time: Date
        if source == .workbuddy, let millis = object["timestamp"] as? NSNumber {
            time = Date(timeIntervalSince1970: millis.doubleValue / 1000)
        } else if let timeString = (object["timestamp"] as? String) ?? (object["completedAt"] as? String),
                  let parsed = iso.date(from: timeString) ?? ISO8601DateFormatter().date(from: timeString) {
            time = parsed
        } else { return }
        switch source {
        case .codex: parseCodex(object, path: path, time: time)
        case .zcodeLog: parseZCode(object, time: time)
        case .zcodeUsage: parseZCodeUsage(object, time: time)
        case .claude: parseClaude(object, path: path, time: time)
        case .workbuddy: parseWorkBuddy(object, path: path, time: time)
        case .gemini, .geminiSnapshot: break
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

    private func parseClaude(_ object: [String: Any], path: String, time: Date) {
        let id = "claude:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let message = object["message"] as? [String: Any] ?? [:]
        let blocks = message["content"] as? [[String: Any]] ?? []
        let cwd = object["cwd"] as? String
        switch object["type"] as? String {
        case "user":
            if object["isMeta"] as? Bool == true { return }
            let results = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "tool_result" else { return nil }
                return block["tool_use_id"] as? String
            }
            if !results.isEmpty {
                update(id, agent: "Claude Code", time: time) { state in
                    state.running = true
                    state.ended = false
                    state.completionAt = nil
                    for result in results { state.operations.remove(result) }
                }
            } else if !(message["content"] as? String ?? "").hasPrefix("<local-command") {
                update(id, agent: "Claude Code", time: time) {
                    $0.running = true; $0.ended = false; $0.completionAt = nil; $0.operations.removeAll()
                }
            }
        case "assistant":
            let reason = message["stop_reason"] as? String ?? ""
            let calls = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "tool_use" else { return nil }
                return block["id"] as? String
            }
            update(id, agent: "Claude Code", time: time) { state in
                if object["isApiErrorMessage"] as? Bool == true {
                    state.running = false; state.ended = true; state.completionAt = nil; state.operations.removeAll()
                } else if reason == "end_turn" {
                    state.running = false; state.ended = true
                    state.completionAt = time.addingTimeInterval(5)
                    state.operations.removeAll()
                } else {
                    state.running = true; state.ended = false; state.completionAt = nil
                    state.operations.formUnion(calls)
                }
            }
        case "system" where object["subtype"] as? String == "turn_duration":
            update(id, agent: "Claude Code", time: time) {
                $0.running = false; $0.ended = true; $0.completionAt = nil; $0.operations.removeAll()
            }
        default: break
        }
        if let cwd, !cwd.isEmpty, states[id] != nil {
            states[id]?.project = URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    private func parseWorkBuddy(_ object: [String: Any], path: String, time: Date) {
        let session = object["sessionId"] as? String
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let id = "workbuddy:" + session
        switch object["type"] as? String {
        case "message":
            switch object["role"] as? String {
            case "user":
                update(id, agent: "WorkBuddy", time: time) {
                    $0.running = true; $0.ended = false; $0.completionAt = nil; $0.operations.removeAll()
                }
            case "assistant":
                update(id, agent: "WorkBuddy", time: time) { state in
                    if state.operations.isEmpty {
                        state.running = false; state.ended = true
                        state.completionAt = time.addingTimeInterval(5)
                    }
                }
            default: break
            }
        case "function_call":
            if let call = object["callId"] as? String {
                update(id, agent: "WorkBuddy", time: time) {
                    $0.running = true; $0.ended = false; $0.completionAt = nil; $0.operations.insert(call)
                }
            }
        case "function_call_result":
            if let call = object["callId"] as? String {
                update(id, agent: "WorkBuddy", time: time) {
                    $0.running = true; $0.ended = false; $0.completionAt = nil; $0.operations.remove(call)
                }
            }
        default: break
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty, states[id] != nil {
            states[id]?.project = URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    private func parseGemini(_ object: [String: Any], path: String) {
        if let messages = object["messages"] as? [[String: Any]] {
            for message in messages { parseGeminiMessage(message, path: path) }
        }
        if let set = object["$set"] as? [String: Any],
           let messages = set["messages"] as? [[String: Any]] {
            for message in messages { parseGeminiMessage(message, path: path) }
        }
        if let patch = object["$patch"] as? [String: Any],
           let calls = patch["toolCalls"] as? [[String: Any]], !calls.isEmpty {
            let id = "gemini:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if let time = states[id]?.lastEvent {
                update(id, agent: "Gemini CLI", time: time) {
                    $0.running = true; $0.ended = false; $0.completionAt = nil
                }
            }
        }
        parseGeminiMessage(object, path: path)
    }

    private func parseGeminiMessage(_ object: [String: Any], path: String) {
        guard let kind = object["type"] as? String,
              let stamp = object["timestamp"] as? String,
              let time = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return }
        let id = "gemini:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        switch kind {
        case "user":
            let content = object["content"] as? [[String: Any]] ?? []
            if content.contains(where: { $0["functionResponse"] != nil }) { return }
            update(id, agent: "Gemini CLI", time: time) {
                $0.running = true; $0.ended = false; $0.completionAt = nil
            }
        case "gemini":
            let calls = object["toolCalls"] as? [[String: Any]] ?? []
            update(id, agent: "Gemini CLI", time: time) { state in
                if calls.isEmpty {
                    state.running = false; state.ended = true
                    state.completionAt = time.addingTimeInterval(5)
                } else {
                    state.running = true; state.ended = false; state.completionAt = nil
                }
            }
        case "error":
            update(id, agent: "Gemini CLI", time: time) {
                $0.running = false; $0.ended = true; $0.completionAt = nil
            }
        default: break
        }
    }
}

import Foundation

/// Queries only Magpie's loopback status endpoint. It does not route requests or change agent settings.
struct MagpieGatewayClient: Sendable {
    let home: String

    func fetch() async -> Data? {
        guard FileManager.default.fileExists(atPath: home + "/.config/magpie") else { return nil }
        let port = Self.port(home: home)
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/magpie/concurrency") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func port(home: String) -> Int {
        let path = home + "/.config/magpie/settings.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 < 1_000_000,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = settings["port"] as? Int, (1024...65535).contains(port) else { return 3425 }
        return port
    }
}

struct MagpieActivityState {
    private struct Seen {
        let agent: String
        let session: String
        var at: Date
    }

    private var seen: [String: Seen] = [:]

    mutating func update(_ data: Data?, now: Date, window: RecentActivityWindow = .standard) -> ActivitySnapshot {
        var live = Set<String>()
        if let data,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object["object"] as? String == "concurrency",
           let requests = object["requests"] as? Int, requests >= 0,
           let tools = object["tools"] as? Int, tools >= 0 {
            if let active = object["active"] as? [[String: Any]] {
                for request in active {
                    guard let agent = request["agent"] as? String, !agent.isEmpty, agent.count <= 64 else { continue }
                    let session = request["session"] as? String ?? ""
                    let key = !session.isEmpty && session.count <= 128
                        ? "magpie:\(agent):\(session)"
                        : "magpie:\(agent):request-\((request["id"] as? NSNumber)?.stringValue ?? "unknown")"
                    seen[key] = Seen(agent: agent, session: session, at: now)
                    live.insert(key)
                }
            }
            if requests > 0 && live.isEmpty {
                seen["magpie:requests"] = Seen(agent: "magpie", session: "", at: now)
                live.insert("magpie:requests")
            } else if !live.isEmpty {
                seen.removeValue(forKey: "magpie:requests")
            }
            if tools > 0 {
                seen["magpie:tools"] = Seen(agent: "claude", session: "", at: now)
                live.insert("magpie:tools")
            }
        }

        seen = seen.filter { now.timeIntervalSince($0.value.at) >= 0 && now.timeIntervalSince($0.value.at) <= window.seconds }
        let sessions = seen.map { key, item in
            let name = Self.name(item.agent)
            return MonitoredSession(
                id: key,
                agent: "Magpie · \(name)",
                project: item.session.isEmpty ? "代理请求" : "会话 \(item.session.suffix(8))",
                lastActivity: item.at,
                status: live.contains(key) ? (key == "magpie:tools" ? "等待工具" : "执行中") : "近期请求",
                isActive: true
            )
        }.sorted { $0.lastActivity > $1.lastActivity }
        return ActivitySnapshot(sessions: sessions, activeCount: sessions.count)
    }

    private static func name(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "zcode": return "ZCode"
        case "workbuddy": return "WorkBuddy"
        default: return agent
        }
    }
}

extension ActivitySnapshot {
    static func merging(_ local: ActivitySnapshot, _ magpie: ActivitySnapshot) -> ActivitySnapshot {
        let routed = magpie.sessions.filter { route in
            guard route.id.hasPrefix("magpie:") else { return true }
            let parts = route.id.dropFirst("magpie:".count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, !parts[1].hasPrefix("request-") else { return true }
            let agent = String(parts[0]).lowercased()
            let session = String(parts[1])
            return !local.sessions.contains { native in
                Self.agentKey(native.agent) == agent && native.id.contains(session)
                    && (native.isActive || route.status == "近期请求")
            }
        }
        return ActivitySnapshot(
            sessions: Array((local.sessions + routed).sorted { $0.lastActivity > $1.lastActivity }.prefix(12)),
            activeCount: local.activeCount + routed.count
        )
    }

    private static func agentKey(_ name: String) -> String {
        switch name {
        case "Claude Code": return "claude"
        case "Gemini CLI": return "gemini"
        default: return name.lowercased()
        }
    }
}

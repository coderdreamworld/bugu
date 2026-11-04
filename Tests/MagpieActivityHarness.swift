import Foundation

@main
struct MagpieActivityHarness {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_793_770_000)
        var state = MagpieActivityState()
        expect(state.update(nil, now: now).activeCount == 0, "missing Magpie is idle")

        let active = Data(#"{"object":"concurrency","requests":1,"tools":0,"active":[{"id":1,"agent":"codex","session":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]}"#.utf8)
        let first = state.update(active, now: now)
        expect(first.activeCount == 1 && first.sessions[0].status == "执行中", "in-flight request is active")
        let sameSession = Data(#"{"object":"concurrency","requests":2,"tools":0,"active":[{"id":1,"agent":"codex","session":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},{"id":2,"agent":"codex","session":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]}"#.utf8)
        expect(state.update(sameSession, now: now).activeCount == 1, "parallel requests in one session count once")

        let native = ActivitySnapshot(sessions: [MonitoredSession(
            id: "codex:rollout-2026-11-04T12-00-00-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            agent: "Codex", project: "project", lastActivity: now, status: "执行中", isActive: true
        )], activeCount: 1)
        expect(ActivitySnapshot.merging(native, ActivitySnapshot(sessions: [], activeCount: 0)).activeCount == 1, "native monitoring works without Magpie")
        expect(ActivitySnapshot.merging(native, first).activeCount == 1, "native and Magpie view of one session count once")
        let claudeRequest = Data(#"{"object":"concurrency","requests":1,"tools":0,"active":[{"id":3,"agent":"claude","session":"claude-session"}]}"#.utf8)
        var claudeState = MagpieActivityState()
        let claudeNative = ActivitySnapshot(sessions: [MonitoredSession(
            id: "claude:claude-session", agent: "Claude Code", project: "project",
            lastActivity: now, status: "执行中", isActive: true
        )], activeCount: 1)
        expect(ActivitySnapshot.merging(claudeNative, claudeState.update(claudeRequest, now: now)).activeCount == 1, "Claude source names deduplicate")

        let idle = Data(#"{"object":"concurrency","requests":0,"tools":0,"active":[]}"#.utf8)
        let grace = state.update(idle, now: now.addingTimeInterval(10))
        expect(grace.activeCount == 1 && grace.sessions[0].status == "近期请求", "tool gap gets a bounded grace period")
        let completed = ActivitySnapshot(sessions: [MonitoredSession(
            id: native.sessions[0].id, agent: "Codex", project: "project",
            lastActivity: now, status: "已完成", isActive: false
        )], activeCount: 0)
        expect(ActivitySnapshot.merging(completed, grace).activeCount == 0, "native completion ends Magpie grace")
        expect(state.update(idle, now: now.addingTimeInterval(181)).activeCount == 0, "grace expires")

        var shortWindow = MagpieActivityState()
        _ = shortWindow.update(active, now: now)
        expect(shortWindow.update(idle, now: now.addingTimeInterval(59), window: RecentActivityWindow(minutes: 1)!).activeCount == 1, "short Magpie window holds briefly")
        expect(shortWindow.update(idle, now: now.addingTimeInterval(61), window: RecentActivityWindow(minutes: 1)!).activeCount == 0, "short Magpie window expires")
        var longWindow = MagpieActivityState()
        _ = longWindow.update(active, now: now)
        expect(longWindow.update(idle, now: now.addingTimeInterval(29 * 60), window: RecentActivityWindow(minutes: 30)!).activeCount == 1, "custom Magpie window holds requests")
        expect(longWindow.update(idle, now: now.addingTimeInterval(30 * 60 + 1), window: RecentActivityWindow(minutes: 30)!).activeCount == 0, "custom Magpie window expires")

        let tools = Data(#"{"object":"concurrency","requests":0,"tools":1,"active":[]}"#.utf8)
        expect(state.update(tools, now: now).sessions.first?.status == "等待工具", "Claude bridge tool wait is active")
        let unknown = Data(#"{"object":"concurrency","requests":1,"tools":0}"#.utf8)
        var fallback = MagpieActivityState()
        expect(fallback.update(unknown, now: now).sessions.first?.id == "magpie:requests", "older status without per-request list stays active")
        expect(state.update(Data("not json".utf8), now: now.addingTimeInterval(181)).activeCount == 0, "bad response cannot hold awake indefinitely")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bugu-magpie-tests-\(UUID().uuidString)")
        let absent = await MagpieGatewayClient(home: home.path).fetch()
        expect(absent == nil, "no Magpie install needs no network or setup")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/magpie"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        expect(MagpieGatewayClient.port(home: home.path) == 3425, "default gateway port")
        let settings = home.appendingPathComponent(".config/magpie/settings.json")
        try Data(#"{"port":4567}"#.utf8).write(to: settings)
        expect(MagpieGatewayClient.port(home: home.path) == 4567, "custom local gateway port")
        try Data(#"{"port":80}"#.utf8).write(to: settings)
        expect(MagpieGatewayClient.port(home: home.path) == 3425, "invalid port falls back to loopback default")
        print("MagpieActivityHarness: all behavior checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

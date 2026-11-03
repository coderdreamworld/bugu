import AppKit
import IOKit.pwr_mgt
import SwiftUI

@main
struct BuguApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BeaconModel()

    init() {
        if CommandLine.arguments.contains("--activity-snapshot") {
            let home = ProcessInfo.processInfo.environment["BUGU_LOG_HOME"] ?? NSHomeDirectory()
            let snapshot = ActivityMonitor(home: home).scan()
            print("active=\(snapshot.activeCount)")
            for session in snapshot.sessions {
                print("\(session.agent)\t\(session.project)\t\(session.status)")
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Bugu", systemImage: model.menuIconName) {
            BuguMenu(model: model)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct BuguMenu: View {
    @ObservedObject var model: BeaconModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.menuIconName)
                    .font(.title2)
                    .foregroundStyle(model.statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("布谷 · \(model.statusTitle)")
                        .font(.headline)
                    Text(model.statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Toggle("自动监控任务", isOn: $model.monitoringEnabled)
            Toggle("手动保持唤醒", isOn: $model.manualAwake)
            Text("本地记录自动监控；Magpie 可选增强")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.monitoringEnabled && model.snapshot.activeCount > 0 {
                Divider()
                Text("执行中的任务")
                    .font(.caption.bold())
                ForEach(model.snapshot.sessions.filter(\.isActive).prefix(8)) { session in
                    HStack(spacing: 7) {
                        Image(systemName: session.isActive ? "circle.fill" : "circle")
                            .font(.system(size: 7))
                            .foregroundStyle(session.isActive ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.project)
                                .font(.caption)
                                .lineLimit(1)
                            Text(session.agent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.status)
                            .font(.caption2)
                            .foregroundStyle(session.isActive ? .primary : .secondary)
                    }
                }
            }

            Divider()
            DisclosureGroup("声音设置") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("提示音")
                        Spacer()
                        Picker("", selection: $model.soundProfile) {
                            ForEach(BuguSoundProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 115)
                    }
                    HStack {
                        Text("音量")
                        Spacer()
                        Text("\(Int(model.alertVolume * 100))%")
                            .monospacedDigit()
                    }
                    Slider(value: $model.alertVolume, in: 0...1.0, step: 0.05)
                }
                .font(.caption)
                .padding(.top, 5)
            }
            .font(.caption)

            if let message = model.lastEventMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("退出布谷") {
                model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .padding(16)
    }
}

@MainActor
final class BeaconModel: ObservableObject {
    @Published var monitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: "passiveMonitoringEnabled")
            if monitoringEnabled { scheduleScan() }
            else { snapshot = ActivitySnapshot(sessions: [], activeCount: 0) }
            refreshAssertion()
        }
    }
    @Published var manualAwake = false {
        didSet { refreshAssertion() }
    }
    @Published var alertVolume: Double {
        didSet { UserDefaults.standard.set(alertVolume, forKey: "alertVolume") }
    }
    @Published var soundProfile: BuguSoundProfile {
        didSet {
            soundEngine.setProfile(soundProfile)
            UserDefaults.standard.set(soundProfile.rawValue, forKey: "soundProfile")
        }
    }
    @Published private(set) var snapshot = ActivitySnapshot(sessions: [], activeCount: 0)
    @Published private(set) var lastEventMessage: String?

    private let monitor: ActivityMonitor
    private let magpie: MagpieGatewayClient
    private var magpieState = MagpieActivityState()
    private let scanQueue = DispatchQueue(label: "com.learnprompt.Bugu.activity", qos: .utility)
    private let soundEngine = BuguSoundEngine()
    private var timer: Timer?
    private var scanning = false
    private var scannedOnce = false
    private var assertionID: IOPMAssertionID?

    init() {
        let defaults = UserDefaults.standard
        monitoringEnabled = defaults.object(forKey: "passiveMonitoringEnabled") as? Bool ?? true
        let savedProfile = defaults.string(forKey: "soundProfile")
        alertVolume = savedProfile == "silent" ? 0 : (defaults.object(forKey: "alertVolume") as? Double ?? 0.65)
        soundProfile = BuguSoundProfile(rawValue: savedProfile ?? "") ?? .system
        if savedProfile == "silent" {
            defaults.set(0.0, forKey: "alertVolume")
            defaults.set(BuguSoundProfile.system.rawValue, forKey: "soundProfile")
        }
        let sourceHome = ProcessInfo.processInfo.environment["BUGU_LOG_HOME"] ?? NSHomeDirectory()
        monitor = ActivityMonitor(home: sourceHome)
        magpie = MagpieGatewayClient(home: sourceHome)
        soundEngine.setProfile(soundProfile)
        scheduleScan()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleScan() }
        }
    }

    var menuIconName: String { snapshot.activeCount > 0 && monitoringEnabled || manualAwake ? "bird.fill" : "bird" }
    var statusColor: Color { snapshot.activeCount > 0 && monitoringEnabled || manualAwake ? .green : .secondary }
    var statusTitle: String {
        if monitoringEnabled && snapshot.activeCount > 0 { return "\(snapshot.activeCount) 个任务执行中" }
        if manualAwake { return "手动保持唤醒" }
        return monitoringEnabled ? "空闲" : "已暂停监控"
    }
    var statusSubtitle: String {
        if monitoringEnabled && snapshot.activeCount > 0 { return "任务结束后自动恢复休眠" }
        return manualAwake ? "电脑保持运行" : "电脑按系统设置休眠"
    }

    private func scheduleScan() {
        guard monitoringEnabled && !scanning else { return }
        scanning = true
        let monitor = self.monitor
        let magpie = self.magpie
        scanQueue.async {
            let local = monitor.scan()
            Task { [weak self] in
                let payload = await magpie.fetch()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.scanning = false
                    let previous = self.snapshot.activeCount
                    let routed = self.magpieState.update(payload, now: Date())
                    let result = ActivitySnapshot.merging(local, routed)
                    self.snapshot = self.monitoringEnabled ? result : ActivitySnapshot(sessions: [], activeCount: 0)
                    self.refreshAssertion()
                    if self.scannedOnce && self.monitoringEnabled {
                        if previous == 0 && result.activeCount > 0 { self.play(.accepted) }
                        if previous > 0 && result.activeCount == 0 { self.play(.completed) }
                    }
                    self.scannedOnce = true
                }
            }
        }
    }

    private func refreshAssertion() {
        let wanted = AwakePolicy.shouldStayAwake(
            monitoring: monitoringEnabled, manual: manualAwake, activeCount: snapshot.activeCount
        )
        if wanted && assertionID == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Bugu: active coding task or manual wake" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertionID = id }
            else { lastEventMessage = "无法开启防休眠（IOKit \(result)）" }
        } else if !wanted, let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    private func play(_ cue: BuguSoundEngine.Cue) {
        soundEngine.play(cue, volume: Float(alertVolume))
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let id = assertionID { IOPMAssertionRelease(id); assertionID = nil }
    }
}

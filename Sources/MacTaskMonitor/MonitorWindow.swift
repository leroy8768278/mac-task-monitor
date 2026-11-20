import SwiftUI

@MainActor
struct MonitorWindow: View {
    @Binding var section: MonitorSection
    @ObservedObject private var runtime: MonitorRuntime
    @ObservedObject private var watchdog: Watchdog
    private let awake: AwakeController
    @State private var taskFocus: String?

    init(section: Binding<MonitorSection>, runtime: MonitorRuntime, awake: AwakeController) {
        _section = section
        self.runtime = runtime
        watchdog = runtime.watchdog
        self.awake = awake
    }

    var body: some View {
        HStack(spacing: 0) {
            MonitorSidebar(section: Binding(get: { section }, set: { navigate($0) }))
            page
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MonitorTint.canvas)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .device:
            scrollPage {
                DevicePage(deviceName: deviceName,
                           snapshot: runtime.health, cpuHistory: runtime.cpuHistory,
                           taskSummary: taskSummary, watchdogSummary: watchdogSummary,
                           navigate: { navigate($0) })
            }
        case .processes:
            ProcessesPage()
                .padding(.horizontal, 24)
                .padding(.vertical, 23)
        case .runningApps:
            RunningAppsPage()
                .padding(.horizontal, 24)
                .padding(.vertical, 23)
        case .tasks:
            scrollPage {
                TasksPage(snapshot: runtime.tasks, isScanning: runtime.isScanning, focusTask: taskFocus) {
                    Task { await runtime.refreshTasks() }
                }
            }
        case .watchdog:
            scrollPage {
                WatchdogPage(watchdog: watchdog, existingMT5Rule: runtime.existingMT5Rule, didScan: runtime.tasks != nil,
                             legacyBusy: runtime.legacyGuardBusy || runtime.isScanning, legacyError: runtime.legacyGuardError,
                             changeLegacy: { action in Task { await runtime.changeLegacyGuard(action) } }) { label in
                    navigate(.tasks, focus: label)
                }
            }
        case .tools:
            scrollPage { ToolsPage(awake: awake) }
        }
    }

    private func scrollPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 1080)
                .padding(.horizontal, 24)
                .padding(.vertical, 23)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var taskSummary: String {
        guard let tasks = runtime.tasks else { return "正在扫描" }
        let timed = tasks.tasks.filter(\.isScheduled)
        return "\(timed.count) 项定时 · \(timed.filter { $0.status == .running }.count) 项运行中"
    }

    private var deviceName: String {
        guard let health = runtime.health else { return "正在识别设备" }
        return [health.deviceName, health.modelIdentifier].compactMap { $0 }.joined(separator: " · ")
    }

    private var watchdogSummary: String {
        if watchdog.isEnabled { return watchdog.status.title }
        if runtime.existingMT5Rule?.status == .disabled { return "MT5 守护已停用" }
        if runtime.existingMT5Rule != nil { return "已发现 MT5 守护规则" }
        return "未启用"
    }

    private func navigate(_ destination: MonitorSection, focus: String? = nil) {
        taskFocus = focus
        section = destination
    }
}

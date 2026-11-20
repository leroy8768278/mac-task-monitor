import SwiftUI

@MainActor
struct MonitorWindow: View {
    @Binding var section: MonitorSection
    @StateObject private var watchdog = Watchdog()
    @State private var healthMonitor = HealthMonitor()
    @State private var health: HealthSnapshot?
    @State private var cpuHistory: [Double] = []
    @State private var tasks: ScheduledTaskSnapshot?
    @State private var isScanning = false
    @State private var scanAgain = false
    @State private var taskFocus: String?
    @State private var legacyGuardBusy = false
    @State private var legacyGuardError: String?

    private var existingMT5Rule: ScheduledTask? {
        guard let tasks else { return nil }
        let rules = tasks.tasks.filter { $0.label == LegacyMT5Guard.label }
        return rules.first(where: LegacyMT5Guard.matches) ?? rules.first { rule in
            rule.status == .loaded || rule.status == .running
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            MonitorSidebar(section: Binding(get: { section }, set: { navigate($0) }))
            page
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MonitorTint.canvas)
        }
        .task { await sampleHealth() }
        .task { await scanPeriodically() }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .device:
            scrollPage {
                DevicePage(deviceName: deviceName,
                           snapshot: health, cpuHistory: cpuHistory,
                           taskSummary: taskSummary, watchdogSummary: watchdogSummary,
                           navigate: { navigate($0) })
            }
        case .processes:
            ProcessesPage()
                .padding(.horizontal, 24)
                .padding(.vertical, 23)
        case .tasks:
            scrollPage {
                TasksPage(snapshot: tasks, isScanning: isScanning, focusTask: taskFocus) {
                    Task { await refreshTasks() }
                }
            }
        case .watchdog:
            scrollPage {
                WatchdogPage(watchdog: watchdog, existingMT5Rule: existingMT5Rule, didScan: tasks != nil,
                             legacyBusy: legacyGuardBusy || isScanning, legacyError: legacyGuardError,
                             changeLegacy: { action in Task { await changeLegacyGuard(action) } }) { label in
                    navigate(.tasks, focus: label)
                }
            }
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
        guard let tasks else { return "正在扫描" }
        let timed = tasks.tasks.filter(\.isScheduled)
        return "\(timed.count) 项定时 · \(timed.filter { $0.status == .running }.count) 项运行中"
    }

    private var deviceName: String {
        guard let health else { return "正在识别设备" }
        return [health.deviceName, health.modelIdentifier].compactMap { $0 }.joined(separator: " · ")
    }

    private var watchdogSummary: String {
        if watchdog.isEnabled { return watchdog.status.title }
        if existingMT5Rule?.status == .disabled { return "MT5 守护已停用" }
        if existingMT5Rule != nil { return "已发现 MT5 守护规则" }
        return "未启用"
    }

    private func navigate(_ destination: MonitorSection, focus: String? = nil) {
        taskFocus = focus
        section = destination
    }

    private func sampleHealth() async {
        while !Task.isCancelled {
            let snapshot = await healthMonitor.sample()
            health = snapshot
            if let usage = snapshot.cpuUsage {
                cpuHistory.append(usage)
                if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func scanPeriodically() async {
        while !Task.isCancelled {
            await refreshTasks()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func refreshTasks(afterGuardChange: Bool = false) async {
        if isScanning {
            if afterGuardChange { scanAgain = true }
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            scanAgain = false
            tasks = await Task.detached(priority: .utility) { TaskScanner.scan() }.value
        } while scanAgain
    }

    private func changeLegacyGuard(_ action: LegacyMT5Guard.Action) async {
        guard !legacyGuardBusy else { return }
        legacyGuardBusy = true
        legacyGuardError = nil
        defer { legacyGuardBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) { try LegacyMT5Guard.perform(action) }.value
        } catch {
            legacyGuardError = error.localizedDescription
        }
        await refreshTasks(afterGuardChange: true)
    }
}

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
    @State private var taskFocus: String?

    private var existingMT5Rule: ScheduledTask? {
        tasks?.tasks.first { task in
            task.label == "local.mt5.keepalive" && (task.status == .loaded || task.status == .running)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            MonitorSidebar(section: Binding(get: { section }, set: { navigate($0) }))
            ScrollView {
                page
                    .frame(maxWidth: 1080)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 23)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
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
            DevicePage(deviceName: deviceName,
                       snapshot: health, cpuHistory: cpuHistory,
                       taskSummary: taskSummary, watchdogSummary: watchdogSummary,
                       navigate: { navigate($0) })
        case .tasks:
            TasksPage(snapshot: tasks, isScanning: isScanning, focusTask: taskFocus) {
                Task { await refreshTasks() }
            }
        case .watchdog:
            WatchdogPage(watchdog: watchdog, existingMT5Rule: existingMT5Rule, didScan: tasks != nil) { label in
                navigate(.tasks, focus: label)
            }
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

    private func refreshTasks() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        tasks = await Task.detached(priority: .utility) { TaskScanner.scan() }.value
    }
}

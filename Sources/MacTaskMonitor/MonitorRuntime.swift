import Combine
import Foundation

@MainActor
final class MonitorRuntime: ObservableObject {
    @Published private(set) var health: HealthSnapshot?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var tasks: ScheduledTaskSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var legacyGuardBusy = false
    @Published private(set) var legacyGuardError: String?

    let watchdog = Watchdog()
    let cleanup = CleanupModel()

    private let healthMonitor = HealthMonitor()
    private var healthLoop: Task<Void, Never>?
    private var taskLoop: Task<Void, Never>?
    private var scanWorker: Task<ScheduledTaskSnapshot, Never>?
    private var scanAgain = false

    var existingMT5Rule: ScheduledTask? {
        guard let tasks else { return nil }
        let rules = tasks.tasks.filter { $0.label == LegacyMT5Guard.label }
        return rules.first(where: LegacyMT5Guard.matches) ?? rules.first { rule in
            rule.status == .loaded || rule.status == .running
        }
    }

    func start() {
        guard healthLoop == nil else { return }
        healthLoop = Task { [weak self, healthMonitor] in
            while !Task.isCancelled {
                let snapshot = await healthMonitor.sample()
                guard !Task.isCancelled, self != nil else { return }
                self?.recordHealth(snapshot)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        if isScanning { scanAgain = true }
        taskLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshTasks()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func stop() {
        healthLoop?.cancel()
        healthLoop = nil
        taskLoop?.cancel()
        taskLoop = nil
        scanWorker?.cancel()
        scanAgain = false
    }

    deinit {
        healthLoop?.cancel()
        taskLoop?.cancel()
        scanWorker?.cancel()
    }

    func refreshTasks(afterGuardChange: Bool = false) async {
        guard taskLoop != nil else { return }
        if isScanning {
            if afterGuardChange { scanAgain = true }
            return
        }
        isScanning = true
        defer {
            scanWorker = nil
            isScanning = false
        }
        repeat {
            scanAgain = false
            let worker = Task.detached(priority: .utility) { TaskScanner.scan() }
            scanWorker = worker
            let snapshot = await worker.value
            if !worker.isCancelled { tasks = snapshot }
        } while scanAgain
    }

    func changeLegacyGuard(_ action: LegacyMT5Guard.Action) async {
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

    private func recordHealth(_ snapshot: HealthSnapshot) {
        health = snapshot
        if let usage = snapshot.cpuUsage {
            cpuHistory.append(usage)
            if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) }
        }
    }
}

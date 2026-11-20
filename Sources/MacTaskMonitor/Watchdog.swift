import AppKit
import Combine
import Darwin
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class Watchdog: ObservableObject {
    struct Status: Codable, Equatable {
        enum Kind: String, Codable {
            case idle, running, waiting, launching, warning, failure
        }

        let title: String
        let detail: String
        let kind: Kind
    }

    static let checkInterval: TimeInterval = 5
    static let missingGrace: TimeInterval = 15
    private static let serviceName = "local.mactaskmonitor.watchdog.plist"
    private static let emptyPreferences = WatchdogPreferences()

    @Published private(set) var targetURL: URL?
    @Published private(set) var isEnabled = false
    @Published private(set) var needsBackgroundApproval = false
    @Published private(set) var lastLaunchAt: Date?
    @Published private(set) var status = Status(
        title: "未设置守护", detail: "选择应用后可开启后台守护。", kind: .idle
    )

    private let service = SMAppService.agent(plistName: Watchdog.serviceName)
    private var preferences = Watchdog.emptyPreferences
    private var refreshLoop: Task<Void, Never>?
    private var inspection: Task<Void, Never>?
    private var operationError: Status?
    private var enabledAt: Date?

    init() {
        checkNow()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.checkInterval)) } catch { return }
                guard let self else { return }
                refresh()
            }
        }
    }

    deinit {
        refreshLoop?.cancel()
        inspection?.cancel()
    }

    func selectApplication() {
        guard !isEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要守护的应用"
        panel.prompt = "选择应用"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    func setEnabled(_ enabled: Bool) {
        operationError = nil
        let previous = WatchdogStore.readPreferences() ?? preferences
        guard previous.enabled != enabled else {
            refresh()
            return
        }
        guard !enabled || previous.target?.isAvailable == true else {
            reportError("无法开启守护", "请选择可用的应用。")
            return
        }

        var registeredNow = false
        do {
            if enabled, service.status != .enabled, service.status != .requiresApproval {
                let definition = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(Self.serviceName)")
                guard FileManager.default.fileExists(atPath: definition.path) else {
                    reportError("后台服务未打包", "请使用构建好的 Mac 任务台应用开启后台守护。")
                    return
                }
                do {
                    try service.register()
                    registeredNow = true
                } catch {
                    guard service.status == .enabled || service.status == .requiresApproval else { throw error }
                }
            }

            let updated = WatchdogPreferences(target: previous.target, enabled: enabled)
            try WatchdogStore.write(updated, to: WatchdogStore.preferencesURL)
            enabledAt = enabled ? Date() : nil

            if !enabled { try unregisterBackgroundService() }
            refresh()
        } catch {
            if registeredNow { try? service.unregister() }
            refresh()
            reportError(enabled ? "无法开启守护" : "关闭守护时遇到问题", error.localizedDescription)
        }
    }

    func deleteRule() {
        operationError = nil
        let previous = WatchdogStore.readPreferences() ?? preferences
        do {
            if previous.enabled {
                try WatchdogStore.write(
                    WatchdogPreferences(target: previous.target, enabled: false),
                    to: WatchdogStore.preferencesURL
                )
            }
            try unregisterBackgroundService()
            try WatchdogStore.removeRule()
            enabledAt = nil
            refresh()
        } catch {
            refresh()
            reportError("无法删除守护规则", error.localizedDescription)
        }
    }

    func checkNow() {
        refresh(inspectImmediately: true)
    }

    func openBackgroundSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func runAgent() {
        guard let lock = WatchdogStore.acquireAgentLock() else { return }
        defer { Darwin.close(lock) }
        let agent = WatchdogAgent()
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            Task { @MainActor in await agent.check() }
        }
        timer.tolerance = 0.5
        timer.fire()
        RunLoop.main.run()
    }

    private func select(_ url: URL) {
        guard !isEnabled else { return }
        guard let target = WatchdogTarget(applicationURL: url) else {
            reportError("无法选择应用", "请选择一个可执行的 macOS 应用。")
            return
        }
        do {
            try WatchdogStore.write(
                WatchdogPreferences(target: target, enabled: false), to: WatchdogStore.preferencesURL
            )
            operationError = nil
            refresh()
        } catch {
            reportError("无法保存所选应用", error.localizedDescription)
        }
    }

    private func refresh(inspectImmediately: Bool = false) {
        let persisted = WatchdogStore.readPreferences() ?? Self.emptyPreferences
        if persisted != preferences { inspection?.cancel() }
        preferences = persisted
        if targetURL != persisted.target?.url { targetURL = persisted.target?.url }
        if isEnabled != persisted.enabled { isEnabled = persisted.enabled }

        let serviceStatus = isEnabled ? service.status : .notRegistered
        let approval = serviceStatus == .requiresApproval
        if needsBackgroundApproval != approval { needsBackgroundApproval = approval }
        let snapshot = WatchdogStore.readSnapshot()
        let lastLaunch = snapshot?.target == persisted.target ? snapshot?.lastLaunchAt : nil
        if lastLaunchAt != lastLaunch { lastLaunchAt = lastLaunch }

        if let operationError {
            publish(operationError)
            return
        }
        guard let target = persisted.target else {
            publish(Status(title: "未设置守护", detail: "选择应用后可开启后台守护。", kind: .idle))
            return
        }
        guard target.isAvailable else {
            publish(Status(title: "应用不可用", detail: "请恢复应用所在路径，或暂停后重新选择。", kind: .failure))
            return
        }
        if isEnabled {
            switch serviceStatus {
            case .requiresApproval:
                publish(Status(title: "等待后台权限", detail: "在系统设置的「登录项与扩展」中允许 Mac 任务台在后台运行。", kind: .warning))
                return
            case .enabled:
                if let snapshot, snapshot.revision == persisted.revision,
                   Date().timeIntervalSince(snapshot.updatedAt) < Self.checkInterval * 4 {
                    publish(snapshot.status)
                } else if let enabledAt, Date().timeIntervalSince(enabledAt) < Self.checkInterval * 4 {
                    publish(Status(title: "等待后台守护启动", detail: "后台服务正在进入当前登录会话。", kind: .waiting))
                } else {
                    publish(Status(title: "等待后台服务反馈", detail: "可暂停后重新开启守护，再等待下一次检查。", kind: .warning))
                }
            default:
                publish(Status(title: "后台服务不可用", detail: "请暂停后重新开启守护。", kind: .failure))
                return
            }
            guard inspectImmediately else { return }
        }

        inspection?.cancel()
        let shouldDisplayRunningOnly = isEnabled
        inspection = Task { [weak self] in
            let presence = await target.presence()
            guard let self, !Task.isCancelled, self.preferences.revision == persisted.revision else { return }
            if shouldDisplayRunningOnly {
                if presence == .running, status.kind == .launching || status.kind == .waiting {
                    publish(Status(title: "正在运行", detail: target.runningDetail, kind: .running))
                } else if presence == .stopped, status.kind == .running {
                    publish(Status(title: "等待后台确认", detail: "当前检查没有发现进程，后台会继续检查。", kind: .waiting))
                }
            } else {
                publish(presence.pausedStatus(for: target))
            }
        }
    }

    private func reportError(_ title: String, _ detail: String) {
        inspection?.cancel()
        let error = Status(title: title, detail: detail, kind: .failure)
        operationError = error
        publish(error)
    }

    private func unregisterBackgroundService() throws {
        let state = service.status
        if state == .enabled || state == .requiresApproval { try service.unregister() }
    }

    private func publish(_ update: Status) {
        if status != update { status = update }
    }
}

private struct WatchdogTarget: Codable, Equatable, Sendable {
    static let metaTraderIdentifier = "net.metaquotes.wine.MetaTrader5"
    let path: String
    let identifier: String

    init?(applicationURL: URL) {
        let file = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard file.isFileURL, file.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: file), let identifier = bundle.bundleIdentifier,
              identifier != "local.mactaskmonitor.app", identifier != Bundle.main.bundleIdentifier,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        path = file.path
        self.identifier = identifier
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var isMetaTrader: Bool { identifier.caseInsensitiveCompare(Self.metaTraderIdentifier) == .orderedSame }
    var isAvailable: Bool { Self(applicationURL: url) == self }
    var runningDetail: String { isMetaTrader ? "已检测到 MT5 交易终端进程。" : "已检测到所选应用的进程。" }

    @MainActor
    func presence() async -> WatchdogPresence {
        let nativeProcessIsRunning = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { app in
            !app.isTerminated && app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
        guard isMetaTrader else { return nativeProcessIsRunning ? .running : .stopped }

        let terminalIsRunning = await Task.detached(priority: .utility) { Self.detectMetaTraderTerminal() }.value
        switch terminalIsRunning {
        case true: return .running
        case false: return nativeProcessIsRunning ? .wrapperOnly : .stopped
        case nil: return .unavailable
        }
    }

    // The official Mac bundle runs the trading terminal as a Wine child process.
    private static func detectMetaTraderTerminal() -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-ww", "-o", "stat=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let listing = String(decoding: data, as: UTF8.self)
        return listing.split(whereSeparator: \.isNewline).contains { line in
            let columns = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard columns.count == 2, columns[0].first != "Z" else { return false }
            let command = columns[1].trimmingCharacters(in: .whitespaces).lowercased()
            return command == #"c:\program files\metatrader 5\terminal64.exe"#
        }
    }
}

private enum WatchdogPresence: Equatable {
    case running, wrapperOnly, stopped, unavailable

    func pausedStatus(for target: WatchdogTarget) -> Watchdog.Status {
        switch self {
        case .running:
            return .init(title: "正在运行", detail: target.isMetaTrader ? "已检测到 MT5 交易终端，守护未开启。" : "应用进程正在运行，守护未开启。", kind: .running)
        case .wrapperOnly:
            return .init(title: "MT5 正在启动或未就绪", detail: "已检测到启动程序，正在等待交易终端进程。", kind: .waiting)
        case .stopped:
            return .init(title: "应用未运行", detail: "守护未开启。", kind: .idle)
        case .unavailable:
            return .init(title: "暂时无法读取进程", detail: "等待下一次检查。", kind: .warning)
        }
    }
}

private struct WatchdogPreferences: Codable, Equatable {
    var target: WatchdogTarget? = nil
    var enabled = false
    var revision = UUID()
}

private struct WatchdogSnapshot: Codable {
    var target: WatchdogTarget
    var revision: UUID
    var updatedAt: Date
    var status: Watchdog.Status
    var lastLaunchAt: Date?
    var failures: Int
}

private enum WatchdogStore {
    private static let logger = Logger(subsystem: "local.mactaskmonitor.app", category: "Watchdog")
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/local.mactaskmonitor.app", isDirectory: true)

    static let preferencesURL = directory.appendingPathComponent("watchdog.json")
    private static let snapshotURL = directory.appendingPathComponent("watchdog-status.json")

    static func readPreferences() -> WatchdogPreferences? { read(from: preferencesURL) }
    static func readSnapshot() -> WatchdogSnapshot? { read(from: snapshotURL) }

    static func writeSnapshot(_ snapshot: WatchdogSnapshot) {
        do {
            try write(snapshot, to: snapshotURL)
        } catch {
            logger.error("Could not save watchdog status: \(error.localizedDescription)")
        }
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try createDirectory()
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func removeRule() throws {
        for url in [snapshotURL, preferencesURL] {
            if Darwin.unlink(url.path) != 0 {
                let failure = errno
                if failure != ENOENT {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                }
            }
        }
    }

    static func acquireAgentLock() -> Int32? {
        do { try createDirectory() } catch {
            logger.error("Could not create watchdog directory: \(error.localizedDescription)")
            return nil
        }
        let path = directory.appendingPathComponent("watchdog.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func read<Value: Decodable>(from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

@MainActor
private final class WatchdogAgent {
    private typealias Status = Watchdog.Status
    private var snapshot: WatchdogSnapshot?
    private var missingSince: Date?
    private var wrapperSince: Date?
    private var runningSince: Date?
    private var busy = false

    func check() async {
        guard !busy else { return }
        guard let preferences = WatchdogStore.readPreferences(), preferences.enabled, let target = preferences.target else {
            snapshot = nil
            missingSince = nil
            wrapperSince = nil
            runningSince = nil
            return
        }
        busy = true
        defer { busy = false }

        if snapshot?.revision != preferences.revision {
            let previous = WatchdogStore.readSnapshot()
            snapshot = WatchdogSnapshot(
                target: target, revision: preferences.revision, updatedAt: Date(),
                status: .init(title: "守护检查中", detail: "正在确认进程状态。", kind: .waiting),
                lastLaunchAt: previous?.target == target ? previous?.lastLaunchAt : nil,
                failures: previous?.revision == preferences.revision ? previous?.failures ?? 0 : 0
            )
            missingSince = nil
            wrapperSince = nil
            runningSince = nil
        }
        guard target.isAvailable else {
            missingSince = nil
            wrapperSince = nil
            runningSince = nil
            publish(.init(title: "应用不可用", detail: "请恢复应用所在路径，或暂停后重新选择。", kind: .failure))
            return
        }

        let presence = await target.presence()
        guard current(preferences) else { return }
        let now = Date()
        if presence != .running { runningSince = nil }
        switch presence {
        case .running:
            missingSince = nil
            wrapperSince = nil
            let start = runningSince ?? now
            runningSince = start
            if now.timeIntervalSince(start) >= 45 { snapshot?.failures = 0 }
            publish(.init(title: "正在运行", detail: target.runningDetail, kind: .running))
        case .wrapperOnly:
            missingSince = nil
            let start = wrapperSince ?? now
            wrapperSince = start
            if now.timeIntervalSince(start) < 45 {
                publish(.init(title: "等待 MT5 交易终端", detail: "已检测到 MT5 启动程序。", kind: .waiting))
            } else {
                publish(.init(title: "MT5 交易终端未就绪", detail: "启动程序仍在运行。退出 MT5 后，守护会再次尝试打开应用。", kind: .warning))
            }
        case .unavailable:
            missingSince = nil
            wrapperSince = nil
            publish(.init(title: "暂时无法读取进程", detail: "后台将在下一轮重新检查。", kind: .warning))
        case .stopped:
            wrapperSince = nil
            await handleStopped(target, preferences: preferences, now: now)
        }
    }

    private func handleStopped(_ target: WatchdogTarget, preferences: WatchdogPreferences, now: Date) async {
        let since = missingSince ?? now
        missingSince = since
        let missingFor = now.timeIntervalSince(since)
        guard missingFor >= Watchdog.missingGrace else {
            let remaining = Int(ceil(Watchdog.missingGrace - missingFor))
            publish(.init(title: "等待重新启动", detail: "连续未检测到进程时，约 \(remaining) 秒后尝试打开应用。", kind: .waiting))
            return
        }

        if let lastLaunch = snapshot?.lastLaunchAt, let count = snapshot?.failures, count > 0 {
            let retryDelay: TimeInterval = [60, 120, 240][min(count - 1, 2)]
            let elapsed = now.timeIntervalSince(lastLaunch)
            if elapsed < retryDelay {
                let remaining = Int(ceil(retryDelay - elapsed))
                let previouslyFailed = snapshot?.status.kind == .failure
                publish(.init(
                    title: previouslyFailed ? "应用启动失败" : "等待应用就绪",
                    detail: previouslyFailed ? "打开应用失败，约 \(remaining) 秒后重试。" : "约 \(remaining) 秒后再次检查是否需要重试。",
                    kind: previouslyFailed ? .failure : .launching
                ))
                return
            }
        }

        guard current(preferences) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let failures = snapshot?.failures ?? 0
        snapshot?.lastLaunchAt = now
        snapshot?.failures = min(failures + 1, 3)
        publish(.init(title: "正在打开应用", detail: "已向 macOS 发出启动请求。", kind: .launching))
        do {
            _ = try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
        } catch {
            guard current(preferences) else { return }
            publish(.init(title: "应用启动失败", detail: error.localizedDescription, kind: .failure))
        }
    }

    private func current(_ preferences: WatchdogPreferences) -> Bool {
        WatchdogStore.readPreferences() == preferences
    }

    private func publish(_ status: Status) {
        guard var update = snapshot else { return }
        update.updatedAt = Date()
        update.status = status
        snapshot = update
        WatchdogStore.writeSnapshot(update)
    }
}

import AppKit
import Darwin
import Foundation

struct RunningApp: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        fileprivate let pid: pid_t
        fileprivate let instance: NSRunningApplication

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pid == rhs.pid && lhs.instance.isEqual(rhs.instance)
        }

        func hash(into hasher: inout Hasher) {
            // Capture the PID for hashing so subsequent AppKit changes cannot change this value.
            hasher.combine(pid)
        }
    }

    enum State: String, Sendable {
        case active = "前台"
        case background = "后台"
        case hidden = "已隐藏"
        case starting = "启动中"
    }

    var pid: Int { Int(id.pid) }

    let id: ID
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let state: State
    let processCount: Int?
    let cpuPercent: Double?
    let residentBytes: UInt64?
}

struct RunningAppsSnapshot: Sendable {
    let apps: [RunningApp]
    let sampledAt: Date
    let notice: String?
}

enum RunningAppTerminationResult: Equatable, Sendable {
    case requestSubmitted
    case alreadyExited
    case systemRejected
}

enum RunningAppsMonitor {
    @MainActor
    static func sample() async -> RunningAppsSnapshot {
        let before = workspaceApps()
        let snapshot = await Task.detached(priority: .utility) { ProcessMonitor.sample() }.value
        let current = workspaceApps()
        let previous = Dictionary(before.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // AppKit identity distinguishes instances even if a PID is recycled during the sample.
        let steady = current.filter { app in
            previous[app.pid].map { app.instance.isEqual($0.instance) } ?? false
        }
        let totals = measure(snapshot.processes, for: steady, separating: before + current)
        let apps = current.map { app in
            let usage = totals[app.pid]
            return RunningApp(id: .init(pid: pid_t(app.pid), instance: app.instance),
                              name: app.name, bundleIdentifier: app.instance.bundleIdentifier,
                              bundleURL: app.bundleURL, state: app.state(asOf: snapshot.sampledAt),
                              processCount: usage?.count, cpuPercent: usage?.cpu, residentBytes: usage?.memory)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
        }
        return RunningAppsSnapshot(apps: apps, sampledAt: snapshot.sampledAt, notice: snapshot.notice)
    }

    @MainActor
    static func forceTerminate(_ id: RunningApp.ID) -> RunningAppTerminationResult {
        guard isRunning(id) else { return .alreadyExited }
        // Force the selected AppKit instance to quit. The result only acknowledges the request.
        if id.instance.forceTerminate() { return .requestSubmitted }
        return isRunning(id) ? .systemRejected : .alreadyExited
    }

    @MainActor
    static func isRunning(_ id: RunningApp.ID) -> Bool {
        guard !id.instance.isTerminated, id.instance.processIdentifier == id.pid,
              let current = NSRunningApplication(processIdentifier: id.pid), !current.isTerminated else { return false }
        return current.isEqual(id.instance)
    }

    private struct Application {
        let instance: NSRunningApplication
        let pid: Int
        let name: String
        let bundleURL: URL?
        let bundlePath: String?
        let executablePath: String?

        func state(asOf date: Date) -> RunningApp.State {
            if instance.isActive { return .active }
            if instance.isHidden { return .hidden }
            // Some applications never publish AppKit's did-finish-launching notification.
            if !instance.isFinishedLaunching, let launch = instance.launchDate,
               abs(date.timeIntervalSince(launch)) < 30 { return .starting }
            return .background
        }
    }

    @MainActor
    private static func workspaceApps() -> [Application] {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let installRoots = ["/Applications", normalizedPath(userApps.path)].map { $0 + "/" }
        var knownPIDs: Set<Int> = []
        return NSWorkspace.shared.runningApplications.compactMap { instance in
            let pid = Int(instance.processIdentifier)
            guard !instance.isTerminated, pid > 0 else { return nil }
            let bundleURL = instance.bundleURL
            let bundlePath = bundleURL.map { normalizedPath($0.path) }
            let executable = instance.executableURL.map { normalizedPath($0.path) }
            if instance.activationPolicy != .regular {
                guard instance.activationPolicy == .accessory,
                      let bundleURL, let bundlePath, let executable,
                      isInstalledStandaloneApp(bundlePath, in: installRoots),
                      let mainExecutable = Bundle(url: bundleURL)?.executableURL,
                      executable == normalizedPath(mainExecutable.path) else { return nil }
            }
            guard knownPIDs.insert(pid).inserted else { return nil }
            let name = instance.localizedName ?? bundleURL?.deletingPathExtension().lastPathComponent ?? "进程 \(pid)"
            return Application(instance: instance, pid: pid, name: name, bundleURL: bundleURL,
                               bundlePath: bundlePath, executablePath: executable)
        }
    }

    private static func isInstalledStandaloneApp(_ path: String, in roots: [String]) -> Bool {
        guard let root = roots.first(where: path.hasPrefix), path.lowercased().hasSuffix(".app") else { return false }
        let components = path.dropFirst(root.count).split(separator: "/")
        return !components.dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }

    private struct Totals {
        var count = 0
        var cpu = 0.0
        var memory: UInt64 = 0

        mutating func include(_ process: RunningProcess) {
            count += 1
            cpu += process.cpuPercent
            memory += process.residentBytes
        }
    }

    private struct BundleOwnership {
        let contentsPrefix: String
        let appPIDs: Set<Int>
    }

    private static func measure(_ processes: [RunningProcess], for apps: [Application], separating neighboringApps: [Application]) -> [Int: Totals] {
        let live = processes.filter { $0.stateCode.first != "Z" }
        let byPID = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: byPID.values, by: \.parentPID)
        let appPIDs = Set(neighboringApps.map(\.pid))
        var bundlePIDs: [String: Set<Int>] = [:]
        for app in neighboringApps {
            if let path = app.bundlePath { bundlePIDs[path + "/Contents/", default: []].insert(app.pid) }
        }
        // The innermost registered app owns its bundle even inside a different registered app.
        let bundles = bundlePIDs.map { BundleOwnership(contentsPrefix: $0.key, appPIDs: $0.value) }
            .sorted { $0.contentsPrefix.count > $1.contentsPrefix.count }

        var totals: [Int: Totals] = [:]
        for app in apps {
            guard let root = byPID[app.pid], matchesExecutable(root, application: app) else { continue }
            var group = [root]
            var visited: Set<Int> = [root.pid]
            for helper in children[1] ?? [] {
                guard !appPIDs.contains(helper.pid), helper.uid == root.uid,
                      let age = helper.elapsedSeconds, let rootAge = root.elapsedSeconds, age <= rootAge,
                      let reported = bundleExecutablePath(helper.command),
                      reported != app.executablePath, owners(of: reported, in: bundles) == [root.pid],
                      let actual = executablePath(pid: helper.pid),
                      reported == actual else { continue }
                // A reparented helper still has an exact, uniquely registered bundle executable.
                if visited.insert(helper.pid).inserted { group.append(helper) }
            }

            var index = 0
            var usage = Totals()
            while index < group.count {
                let parent = group[index]
                index += 1
                usage.include(parent)
                for child in children[parent.pid] ?? [] {
                    guard !appPIDs.contains(child.pid), child.uid == root.uid,
                          isPlausibleChild(child, of: parent) else { continue }
                    if let path = bundleExecutablePath(child.command), owners(of: path, in: bundles)?.contains(root.pid) != true {
                        continue
                    }
                    if visited.insert(child.pid).inserted { group.append(child) }
                }
            }
            totals[app.pid] = usage
        }
        return totals
    }

    private static func owners(of path: String, in bundles: [BundleOwnership]) -> Set<Int>? {
        bundles.first { path.hasPrefix($0.contentsPrefix) }?.appPIDs
    }

    private static func isPlausibleChild(_ child: RunningProcess, of parent: RunningProcess) -> Bool {
        guard let childAge = child.elapsedSeconds, let parentAge = parent.elapsedSeconds else { return true }
        return childAge <= parentAge
    }

    private static func matchesExecutable(_ process: RunningProcess, application: Application) -> Bool {
        guard let expected = application.executablePath, process.command.hasPrefix("/") else { return true }
        return normalizedPath(process.command) == expected || executablePath(pid: process.pid) == expected
    }

    private static func bundleExecutablePath(_ command: String) -> String? {
        guard command.hasPrefix("/"), command.contains(".app/Contents/") else { return nil }
        return normalizedPath(command)
    }

    private static func executablePath(pid: Int) -> String? {
        guard let pid = Int32(exactly: pid) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is defined as four times MAXPATHLEN in the SDK.
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let result = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard result > 0 else { return nil }
        return normalizedPath(String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self))
    }

    private static func normalizedPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let dataVolume = "/System/Volumes/Data"
        return path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }
}

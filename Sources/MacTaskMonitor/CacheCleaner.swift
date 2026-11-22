import AppKit
import Darwin
import Foundation

struct CacheCleanupItem: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        fileprivate let folder: String
        fileprivate let root: CacheObject
        fileprivate let directory: CacheObject
    }

    let id: ID
    let name: String
    let bundleIdentifier: String
    let path: String
    let allocatedBytes: UInt64
    let isPartial: Bool
    fileprivate let entries: [CachePreviewEntry]
}

struct CacheCleanupSnapshot: Sendable {
    let items: [CacheCleanupItem]
    let scannedAt: Date
    let skippedCount: Int
    let notices: [String]
}

struct CacheCleanupResult: Sendable {
    let removedCount: Int
    let skippedCount: Int
    let removedFileCount: Int
    let skippedEntryCount: Int
    let removedAllocatedBytes: UInt64
    let wasCancelled: Bool
    let notices: [String]
}

fileprivate struct CacheObject: Hashable, Sendable {
    let volume: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ info: stat) {
        volume = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
    }
}

fileprivate struct CacheFile: Equatable, Sendable {
    let object: CacheObject
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    init(_ info: stat) {
        object = CacheObject(info)
        size = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
    }
}

fileprivate enum CachePreviewEntry: Sendable {
    case file(String, CacheFile)
    case directory(String, CacheObject, [CachePreviewEntry])
}

enum CacheCleaner {
    @MainActor
    static func scan() async throws -> CacheCleanupSnapshot {
        let liveApps = activeIdentifiers()
        let task = Task.detached(priority: .utility) {
            let apps = try InstalledSoftwareScanner.scan().apps
            try Task.checkCancellation()
            let processes = ProcessMonitor.sample()
            try Task.checkCancellation()
            guard processes.notice == nil else {
                return CacheCleanupSnapshot(items: [], scannedAt: Date(), skippedCount: 0,
                                            notices: ["无法完整确认进程状态，请刷新后再扫描缓存。"])
            }
            return try preview(at: rootURL(), owners: owners(from: apps),
                               liveApps: liveApps, processes: processes.processes)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    @MainActor
    static func clear(_ items: [CacheCleanupItem]) async -> CacheCleanupResult {
        var seen: Set<CacheCleanupItem.ID> = []
        let selected = items.filter { seen.insert($0.id).inserted }
        var result = RemovalTotals()
        guard !selected.isEmpty else { return result.snapshot(selected: 0, cancelled: Task.isCancelled) }

        let applications = Task.detached(priority: .utility) { owners(from: try InstalledSoftwareScanner.scan().apps) }
        let currentOwners: [String: Owner]
        do {
            currentOwners = try await withTaskCancellationHandler { try await applications.value } onCancel: { applications.cancel() }
        } catch {
            if !Task.isCancelled { result.notices.append("无法重新确认已安装的软件。请刷新后重试。") }
            return result.snapshot(selected: selected.count, cancelled: Task.isCancelled)
        }

        for item in selected {
            if Task.isCancelled { break }
            let key = item.bundleIdentifier.lowercased()
            guard let owner = currentOwners[key], !activeIdentifiers().contains(key) else {
                result.notices.append("跳过「\(item.name)」，软件正在运行或无法确认归属。")
                continue
            }
            let work = Task.detached(priority: .utility) { clearPreview(item, owner: owner, root: rootURL()) }
            let workspace = NSWorkspace.shared.notificationCenter
            let observer = workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier?.lowercased() == key { work.cancel() }
            }
            let report = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            workspace.removeObserver(observer)
            result.record(report, for: item.name, cancelledByUser: Task.isCancelled)
        }
        return result.snapshot(selected: selected.count, cancelled: Task.isCancelled)
    }

    struct Owner: Sendable {
        let name: String
        let bundleIdentifier: String
        var bundlePaths: Set<String>
    }

    private struct PreviewTally {
        var allocated: UInt64 = 0
        var skipped = 0
        var seenFiles: Set<CacheObject> = []
        var seenDirectories: Set<CacheObject> = []
    }

    struct EntryReport: Sendable {
        var removed = 0
        var skipped = 0
        var allocated: UInt64 = 0
        var interrupted = false
        var notice: String?
    }

    private struct RemovalTotals {
        var groups = 0
        var files = 0
        var skippedEntries = 0
        var allocated: UInt64 = 0
        var notices: [String] = []

        mutating func record(_ report: EntryReport, for name: String, cancelledByUser: Bool) {
            if report.removed > 0 { groups += 1 }
            files += report.removed
            skippedEntries += report.skipped
            allocated = sum(allocated, report.allocated)
            if let notice = report.notice { notices.append("「\(name)」\(notice)") }
            if report.skipped > 0 { notices.append("「\(name)」保留了 \(report.skipped) 个已变化或无法读取的预览项目。") }
            if report.interrupted && !cancelledByUser { notices.append("「\(name)」启动后停止了该项清理。") }
        }

        func snapshot(selected: Int, cancelled: Bool) -> CacheCleanupResult {
            CacheCleanupResult(removedCount: groups, skippedCount: selected - groups, removedFileCount: files,
                               skippedEntryCount: skippedEntries, removedAllocatedBytes: allocated,
                               wasCancelled: cancelled, notices: notices)
        }
    }

    private enum ScopeError: LocalizedError {
        case unreadable

        var errorDescription: String? { "无法读取当前用户的缓存目录。" }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let previewLimit = 150_000
    private static let depthLimit = 64

    private static func rootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    @MainActor
    private static func activeIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.isTerminated ? nil : app.bundleIdentifier?.lowercased()
        })
    }

    private static func owners(from apps: [InstalledSoftware]) -> [String: Owner] {
        var result: [String: Owner] = [:]
        for app in apps where !app.isSystem && !app.isCurrentApp {
            guard let identifier = app.bundleIdentifier, isApplicationIdentifier(identifier) else { continue }
            let key = identifier.lowercased()
            let bundlePath = normalizedPath(app.path)
            result[key, default: Owner(name: app.name, bundleIdentifier: identifier, bundlePaths: [])].bundlePaths.insert(bundlePath)
        }
        return result
    }

    private static func isApplicationIdentifier(_ identifier: String) -> Bool {
        identifier.contains(".") && !identifier.hasPrefix(".") && !identifier.lowercased().hasPrefix("com.apple.")
            && identifier.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
            }
    }

    private static func normalizedPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let dataVolume = "/System/Volumes/Data"
        return path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }

    private static func runningBundleExecutables(_ processes: [RunningProcess]) -> [String] {
        processes.compactMap { process in
            guard process.stateCode.first != "Z", process.command.hasPrefix("/"), process.command.contains(".app/") else { return nil }
            return normalizedPath(process.command)
        }
    }

    private static func hasActiveProcess(_ owner: Owner, executables: [String]) -> Bool {
        owner.bundlePaths.contains { bundle in executables.contains { $0.hasPrefix(bundle + "/") } }
    }

    static func preview(at url: URL, owners: [String: Owner], liveApps: Set<String>, processes: [RunningProcess]) throws -> CacheCleanupSnapshot {
        let root = try openCacheRoot(at: url)
        defer { close(root) }
        guard let rootInfo = info(root), rootInfo.st_uid == getuid() else { throw ScopeError.unreadable }
        let rootIdentity = CacheObject(rootInfo)
        let activePaths = runningBundleExecutables(processes)
        var items: [CacheCleanupItem] = []
        var skipped = 0
        var remaining = previewLimit
        try visit(root) { name in
            guard let name, !name.hasPrefix(".") else { return true }
            let key = name.lowercased()
            guard let owner = owners[key], !liveApps.contains(key), !hasActiveProcess(owner, executables: activePaths), remaining > 0,
                  let directory = itemInfo(name, in: root), directory.st_dev == rootInfo.st_dev,
                  directory.st_uid == getuid(), kind(directory) == S_IFDIR,
                  let fd = openMatchedDirectory(name, within: root, matching: CacheObject(directory)) else {
                skipped += 1
                return true
            }
            defer { close(fd) }
            var tally = PreviewTally()
            let plan = try previewFiles(fd, volume: directory.st_dev, depth: 0, remaining: &remaining, tally: &tally)
            if !plan.isEmpty {
                items.append(CacheCleanupItem(id: .init(folder: name, root: rootIdentity, directory: CacheObject(directory)), name: owner.name,
                                              bundleIdentifier: owner.bundleIdentifier, path: url.appendingPathComponent(name).path,
                                              allocatedBytes: tally.allocated, isPartial: tally.skipped > 0, entries: plan))
            } else if tally.skipped > 0 {
                skipped += 1
            }
            return true
        }
        items.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        let notices = remaining == 0 ? ["预览已达到本次扫描上限，列表包含已完成核对的缓存文件。"] : []
        return CacheCleanupSnapshot(items: items, scannedAt: Date(), skippedCount: skipped, notices: notices)
    }

    private static func previewFiles(_ fd: Int32, volume: dev_t, depth: Int, remaining: inout Int, tally: inout PreviewTally) throws -> [CachePreviewEntry] {
        guard depth < depthLimit, let directory = info(fd), directory.st_dev == volume,
              tally.seenDirectories.insert(CacheObject(directory)).inserted else {
            tally.skipped += 1
            return []
        }
        var result: [CachePreviewEntry] = []
        do {
            try visit(fd) { name in
                guard remaining > 0 else { tally.skipped += 1; return false }
                remaining -= 1
                guard let name, let entry = itemInfo(name, in: fd), entry.st_dev == volume,
                      entry.st_uid == getuid() else { tally.skipped += 1; return true }
                switch kind(entry) {
                case S_IFREG:
                    let file = CacheFile(entry)
                    if entry.st_nlink <= 1 || tally.seenFiles.insert(file.object).inserted {
                        tally.allocated = sum(tally.allocated, allocatedBytes(entry))
                    }
                    result.append(.file(name, file))
                case S_IFDIR:
                    let identity = CacheObject(entry)
                    guard let child = openMatchedDirectory(name, within: fd, matching: identity) else {
                        tally.skipped += 1
                        return true
                    }
                    defer { close(child) }
                    let children = try previewFiles(child, volume: volume, depth: depth + 1, remaining: &remaining, tally: &tally)
                    if !children.isEmpty { result.append(.directory(name, identity, children)) }
                default:
                    tally.skipped += 1
                }
                return true
            }
        } catch is ScopeError {
            tally.skipped += 1
        }
        return result
    }

    private static func clearPreview(_ item: CacheCleanupItem, owner: Owner, root url: URL) -> EntryReport {
        var report = EntryReport()
        do {
            try Task.checkCancellation()
            let processes = ProcessMonitor.sample()
            try Task.checkCancellation()
            guard processes.notice == nil else {
                report.notice = "的进程状态未能重新确认，已跳过。"
                return report
            }
            guard !hasActiveProcess(owner, executables: runningBundleExecutables(processes.processes)) else {
                report.notice = "正在运行，已跳过。"
                return report
            }
            return clearFiles(from: item, at: url)
        } catch {
            report.interrupted = true
            return report
        }
    }

    static func clearFiles(from item: CacheCleanupItem, at url: URL) -> EntryReport {
        var report = EntryReport()
        do {
            try Task.checkCancellation()
            let root = try openCacheRoot(at: url)
            defer { close(root) }
            guard let rootInfo = info(root), CacheObject(rootInfo) == item.id.root, rootInfo.st_uid == getuid(),
                  let folder = openMatchedDirectory(item.id.folder, within: root, matching: item.id.directory) else {
                report.notice = "的缓存位置已变化，已跳过。"
                return report
            }
            defer { close(folder) }
            try removePreview(item.entries, in: folder, report: &report)
            if report.removed == 0 && report.skipped == 0 { report.notice = "当前没有可清理的预览文件。" }
        } catch is CancellationError {
            report.interrupted = true
        } catch {
            report.notice = "的缓存目录无法读取，已跳过。"
        }
        return report
    }

    private static func removePreview(_ entries: [CachePreviewEntry], in fd: Int32, report: inout EntryReport) throws {
        for entry in entries {
            try Task.checkCancellation()
            switch entry {
            case .directory(let name, let identity, let children):
                guard let child = openMatchedDirectory(name, within: fd, matching: identity) else {
                    report.skipped += 1
                    continue
                }
                defer { close(child) }
                try removePreview(children, in: child, report: &report)
            case .file(let name, let expected):
                guard let file = itemInfo(name, in: fd), kind(file) == S_IFREG, file.st_uid == getuid(),
                      CacheFile(file) == expected else {
                    report.skipped += 1
                    continue
                }
                try Task.checkCancellation()
                guard unlinkat(fd, name, 0) == 0 else { report.skipped += 1; continue }
                report.removed += 1
                if file.st_nlink <= 1 { report.allocated = sum(report.allocated, allocatedBytes(file)) }
            }
        }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let components = url.pathComponents
        guard url.isFileURL, components.first == "/", !components.contains("."), !components.contains("..") else { throw ScopeError.unreadable }
        var fd = open("/", directoryFlags)
        guard fd >= 0 else { throw ScopeError.unreadable }
        for name in components.dropFirst() {
            let child = openat(fd, name, directoryFlags)
            close(fd)
            guard child >= 0 else { throw ScopeError.unreadable }
            fd = child
        }
        return fd
    }

    private static func openCacheRoot(at url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        let home = try openDirectory(at: parent.deletingLastPathComponent())
        defer { close(home) }
        guard let homeInfo = info(home), homeInfo.st_uid == getuid(),
              let libraryInfo = itemInfo(parent.lastPathComponent, in: home), libraryInfo.st_dev == homeInfo.st_dev,
              let library = openMatchedDirectory(parent.lastPathComponent, within: home, matching: CacheObject(libraryInfo)) else {
            throw ScopeError.unreadable
        }
        defer { close(library) }
        guard let cacheInfo = itemInfo(url.lastPathComponent, in: library), cacheInfo.st_dev == homeInfo.st_dev,
              let caches = openMatchedDirectory(url.lastPathComponent, within: library, matching: CacheObject(cacheInfo)) else {
            throw ScopeError.unreadable
        }
        return caches
    }

    private static func openMatchedDirectory(_ name: String, within fd: Int32, matching expected: CacheObject) -> Int32? {
        let child = openat(fd, name, directoryFlags)
        guard child >= 0 else { return nil }
        guard let directory = info(child), CacheObject(directory) == expected, directory.st_uid == getuid() else {
            close(child)
            return nil
        }
        return child
    }

    private static func info(_ fd: Int32) -> stat? {
        var result = stat()
        return fstat(fd, &result) == 0 ? result : nil
    }

    private static func itemInfo(_ name: String, in fd: Int32) -> stat? {
        var result = stat()
        return fstatat(fd, name, &result, AT_SYMLINK_NOFOLLOW) == 0 ? result : nil
    }

    private static func kind(_ info: stat) -> mode_t { info.st_mode & S_IFMT }

    private static func allocatedBytes(_ info: stat) -> UInt64 {
        UInt64(clamping: min(max(0, info.st_blocks), Int64.max / 512)) * 512
    }

    private static func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (total, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : total
    }

    private static func visit(_ fd: Int32, each: (String?) throws -> Bool) throws {
        let reader = openat(fd, ".", directoryFlags)
        guard reader >= 0 else { throw ScopeError.unreadable }
        guard let stream = fdopendir(reader) else { close(reader); throw ScopeError.unreadable }
        defer { closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ScopeError.unreadable }
                return
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            if name == "." || name == ".." { continue }
            if try !each(name) { return }
        }
    }
}

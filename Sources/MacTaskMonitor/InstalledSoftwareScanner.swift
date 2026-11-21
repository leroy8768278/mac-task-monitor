import Darwin
import Foundation

struct InstalledSoftware: Identifiable, Sendable {
    struct Identity: Hashable, Sendable {
        let volumeDevice: Int32
        let inode: UInt64
        fileprivate let path: String
        fileprivate let birthSeconds: Int
        fileprivate let birthNanoseconds: Int
        fileprivate let manifest: FileStamp
        fileprivate let executable: FileStamp?
    }

    fileprivate struct FileStamp: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            bytes = info.st_size
            modificationSeconds = info.st_mtimespec.tv_sec
            modificationNanoseconds = info.st_mtimespec.tv_nsec
            changeSeconds = info.st_ctimespec.tv_sec
            changeNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    enum Source: String, Sendable, CaseIterable {
        case applications = "应用程序"
        case userApplications = "用户应用程序"
        case externalApplications = "本地卷应用程序"
        case system = "macOS 内置"
        case currentApp = "本应用"
    }

    let id: Identity
    let name: String
    let version: String?
    let buildVersion: String?
    let bundleIdentifier: String?
    let url: URL
    let source: Source
    let category: String?
    let executableURL: URL?

    var path: String { url.path }
    var isSystem: Bool { source == .system }
    var isCurrentApp: Bool { source == .currentApp }
}

struct InstalledSoftwareSnapshot: Sendable {
    let apps: [InstalledSoftware]
    let scannedAt: Date
    let notices: [String]
}

struct InstalledSoftwareSize: Sendable {
    let allocatedBytes: UInt64
    let skippedCount: Int
    var isPartial: Bool { skippedCount > 0 }
}

enum InstalledSoftwareScanner {
    static func scan(includeExternalVolumes: Bool = false) throws -> InstalledSoftwareSnapshot {
        try Task.checkCancellation()
        let roots = localRoots() + (includeExternalVolumes ? externalRoots() : [])
        return try scan(roots: roots, currentApp: currentAppURL())
    }

    static func measure(_ app: InstalledSoftware) throws -> InstalledSoftwareSize {
        try Task.checkCancellation()
        let fd = try directory(at: app.url)
        defer { close(fd) }
        guard try inspect(fd, url: app.url, source: app.source, localize: false).id == app.id else { throw ScanError.changed }

        var allocation = Allocation()
        try measureDirectory(fd, volume: app.id.volumeDevice, result: &allocation)
        try Task.checkCancellation()
        guard matchesOnDisk(app) else { throw ScanError.changed }
        return InstalledSoftwareSize(allocatedBytes: allocation.bytes, skippedCount: allocation.skipped)
    }

    static func revalidate(_ app: InstalledSoftware) -> Bool {
        if app.isCurrentApp { return currentAppURL() == app.url && matchesOnDisk(app) }
        if app.source == .externalApplications {
            guard let root = externalRoot(containing: app), contains(app, in: root) else { return false }
        } else {
            guard localRoots().contains(where: { contains(app, in: $0) }) else { return false }
        }
        return matchesOnDisk(app)
    }

    static func canMoveToTrash(_ app: InstalledSoftware) -> Bool {
        guard !app.isCurrentApp, !app.isSystem, revalidate(app) else { return false }
        let parent = app.url.deletingLastPathComponent().path
        var mount = statfs()
        return statfs(parent, &mount) == 0
            && mount.f_flags & UInt32(MNT_RDONLY) == 0
            && access(parent, W_OK | X_OK) == 0
    }

    private struct Root {
        let url: URL
        let source: InstalledSoftware.Source
        let isSingleBundle: Bool

        init(_ path: String, _ source: InstalledSoftware.Source, singleBundle: Bool = false) {
            self.url = URL(fileURLWithPath: path, isDirectory: true)
            self.source = source
            self.isSingleBundle = singleBundle
        }
    }

    private struct DiskObject: Hashable {
        let device: Int32
        let inode: UInt64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }

        init(_ id: InstalledSoftware.Identity) {
            device = id.volumeDevice
            inode = id.inode
        }
    }

    private struct Inventory {
        let currentAppPath: String?
        var apps: [InstalledSoftware] = []
        var directories: Set<DiskObject> = []
        var bundles: Set<DiskObject> = []
        var skipped = 0
    }

    private struct Allocation {
        var bytes: UInt64 = 0
        var skipped = 0
        var visited: Set<DiskObject> = []

        mutating func add(_ info: stat) throws {
            let blocks = UInt64(max(0, info.st_blocks))
            let (allocated, conversionOverflow) = blocks.multipliedReportingOverflow(by: 512)
            let (total, sumOverflow) = bytes.addingReportingOverflow(allocated)
            guard !conversionOverflow, !sumOverflow else { throw ScanError.allocationOverflow }
            bytes = total
        }
    }

    private enum ScanError: LocalizedError {
        case changed, invalidBundle, allocationOverflow, fileSystem(Int32)

        var errorDescription: String? {
            switch self {
            case .changed: "这个软件包已变化，请刷新后重试。"
            case .invalidBundle: "无法读取有效的软件包信息。"
            case .allocationOverflow: "软件包占用空间超出可显示范围。"
            case .fileSystem(let code): "无法读取软件包。\(String(cString: strerror(code)))"
            }
        }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let finderPath = "/System/Library/CoreServices/Finder.app"
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "component", "dext", "framework", "kext", "mpkg", "pkg", "plugin", "prefpane", "xpc"
    ]

    private static func localRoots() -> [Root] {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        var roots = [
            Root("/Applications", .applications),
            Root("/System/Applications", .system),
            Root("/System/Library/CoreServices/Applications", .system),
            Root(finderPath, .system, singleBundle: true),
            // Safari is provided by the system cryptex on newer macOS versions.
            Root("/System/Volumes/Preboot/Cryptexes/App/System/Applications", .system)
        ]
        if !userApps.path.hasPrefix("/Volumes/") { roots.insert(Root(userApps.path, .userApplications), at: 1) }
        return roots
    }

    private static func externalRoots() -> [Root] {
        // Query cached mount metadata without opening the volumes during discovery.
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { free(mounts) }
        guard count > 0, let mounts else { return [] }
        return UnsafeBufferPointer(start: mounts, count: Int(count)).compactMap { externalRoot(for: $0) }
    }

    private static func externalRoot(containing app: InstalledSoftware) -> Root? {
        let components = app.url.pathComponents
        guard components.count >= 5, components[1] == "Volumes", components[3] == "Applications",
              components[2] != ".", components[2] != ".." else { return nil }
        let mountPath = "/Volumes/\(components[2])"
        var mount = statfs()
        guard statfs(mountPath, &mount) == 0,
              let root = externalRoot(for: mount), root.url.path == mountPath + "/Applications" else { return nil }
        return root
    }

    private static func externalRoot(for mount: statfs) -> Root? {
        guard mount.f_flags & UInt32(MNT_LOCAL) != 0,
              mount.f_flags & UInt32(MNT_ROOTFS | MNT_DONTBROWSE) == 0 else { return nil }
        let mountPath = withUnsafeBytes(of: mount.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let components = mountPath.split(separator: "/")
        guard mountPath.hasPrefix("/Volumes/"), components.count == 2,
              !components[1].hasPrefix(".") else { return nil }
        return Root(mountPath + "/Applications", .externalApplications)
    }

    private static func currentAppURL() -> URL? {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "local.mactaskmonitor.app", bundle.bundleURL.pathExtension.lowercased() == "app" else { return nil }
        return bundle.bundleURL
    }

    private static func scan(roots: [Root], currentApp: URL?) throws -> InstalledSoftwareSnapshot {
        var inventory = Inventory(currentAppPath: currentApp?.path)
        var notices: [String] = []
        for root in roots {
            try Task.checkCancellation()
            do {
                let fd = try directory(at: root.url)
                defer { close(fd) }
                if root.isSingleBundle {
                    let app = try inspect(fd, url: root.url, source: root.source)
                    if inventory.bundles.insert(DiskObject(app.id)).inserted { inventory.apps.append(app) }
                } else {
                    let info = try fileInfo(fd)
                    try discover(fd, url: root.url, source: root.source, volume: info.st_dev, inventory: &inventory)
                }
            } catch let error as ScanError {
                if case .fileSystem(ENOENT) = error { continue }
                notices.append("无法完整读取 \(root.url.path)。")
            }
        }
        if inventory.skipped > 0 { notices.append("有 \(inventory.skipped) 个软件包或目录无法完整读取。") }
        inventory.apps.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return InstalledSoftwareSnapshot(apps: inventory.apps, scannedAt: Date(), notices: notices)
    }

    private static func discover(_ fd: Int32, url: URL, source: InstalledSoftware.Source, volume: Int32, inventory: inout Inventory) throws {
        let parent = try fileInfo(fd)
        guard parent.st_dev == volume, inventory.directories.insert(DiskObject(parent)).inserted else { return }
        try visitEntries(in: fd) { entry in
            guard let entry else { inventory.skipped += 1; return }
            guard !entry.hasPrefix(".") else { return }
            do {
                let info = try childInfo(entry, in: fd)
                guard kind(info) == S_IFDIR, info.st_dev == volume else { return }
                let destination = url.appendingPathComponent(entry, isDirectory: true)
                let extensionName = destination.pathExtension.lowercased()
                if extensionName != "app", packageExtensions.contains(extensionName) { return }

                let child = try childDirectory(entry, in: fd)
                defer { close(child) }
                if extensionName == "app" {
                    let appSource: InstalledSoftware.Source = destination.path == inventory.currentAppPath ? .currentApp : source
                    let app = try inspect(child, url: destination, source: appSource)
                    if app.id.volumeDevice == volume, inventory.bundles.insert(DiskObject(app.id)).inserted {
                        inventory.apps.append(app)
                    }
                } else {
                    try discover(child, url: destination, source: source, volume: volume, inventory: &inventory)
                }
            } catch is ScanError {
                inventory.skipped += 1
            }
        }
    }

    private static func inspect(_ fd: Int32, url: URL, source: InstalledSoftware.Source, localize: Bool = true) throws -> InstalledSoftware {
        let info = try fileInfo(fd)
        let contents = try childDirectory("Contents", in: fd)
        defer { close(contents) }
        guard try fileInfo(contents).st_dev == info.st_dev else { throw ScanError.invalidBundle }
        let (plist, manifestStamp) = try readDictionary("Info.plist", in: contents, volume: info.st_dev)
        guard let executable = property("CFBundleExecutable", in: plist),
              executable != ".", executable != "..", !executable.contains("/"), !executable.utf8.contains(0) else {
            throw ScanError.invalidBundle
        }
        let identifier = property("CFBundleIdentifier", in: plist)
        var executableURL: URL?
        var executableStamp: InstalledSoftware.FileStamp?
        var hasRunnableExecutable = false
        if let bin = try? childDirectory("MacOS", in: contents) {
            defer { close(bin) }
            if let actual = try? childInfo(executable, in: bin), kind(actual) == S_IFREG, actual.st_dev == info.st_dev {
                executableURL = url.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executable)
                executableStamp = InstalledSoftware.FileStamp(actual)
                hasRunnableExecutable = actual.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
            }
        }
        if let packageType = property("CFBundlePackageType", in: plist), packageType != "APPL" {
            // Some standalone apps in protected system directories carry a service-specific package type.
            guard source == .system, identifier != nil, hasRunnableExecutable else {
                throw ScanError.invalidBundle
            }
        }
        let localizedName = localize ? try localizedName(in: contents, volume: info.st_dev, fallback: property("CFBundleDevelopmentRegion", in: plist)) : nil
        return InstalledSoftware(
            id: .init(volumeDevice: info.st_dev, inode: info.st_ino, path: url.path,
                      birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec,
                      manifest: manifestStamp, executable: executableStamp),
            name: localizedName ?? displayName(in: plist) ?? url.deletingPathExtension().lastPathComponent,
            version: property("CFBundleShortVersionString", in: plist), buildVersion: property("CFBundleVersion", in: plist),
            bundleIdentifier: identifier, url: url, source: source,
            category: property("LSApplicationCategoryType", in: plist), executableURL: executableURL
        )
    }

    private static func readDictionary(_ entry: String, in fd: Int32, volume: Int32) throws -> ([String: Any], InstalledSoftware.FileStamp) {
        let candidate = try childInfo(entry, in: fd)
        guard kind(candidate) == S_IFREG else { throw ScanError.invalidBundle }
        let file = openat(fd, entry, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw ScanError.fileSystem(errno) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        defer { try? handle.close() }
        let info = try fileInfo(file)
        let stamp = InstalledSoftware.FileStamp(info)
        let maximumBytes = 8 * 1024 * 1024
        guard kind(info) == S_IFREG, info.st_dev == volume,
              (1...Int64(maximumBytes)).contains(info.st_size),
              let data = try? handle.read(upToCount: maximumBytes + 1), data.count == info.st_size,
              stamp == InstalledSoftware.FileStamp(try fileInfo(file)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw ScanError.invalidBundle
        }
        return (plist, stamp)
    }

    private static func localizedName(in contents: Int32, volume: Int32, fallback: String?) throws -> String? {
        guard let resources = try? childDirectory("Resources", in: contents) else { return nil }
        defer { close(resources) }
        guard (try? fileInfo(resources).st_dev) == volume else { return nil }
        let preferences = Locale.preferredLanguages + [fallback ?? "en", "en"]
        if let (table, _) = try? readDictionary("InfoPlist.loctable", in: resources, volume: volume) {
            for locale in Bundle.preferredLocalizations(from: table.keys.sorted(), forPreferences: preferences) {
                if let strings = table[locale] as? [String: Any], let name = displayName(in: strings) { return name }
            }
        }
        var languages: [String] = []
        do {
            try visitEntries(in: resources) { entry in
                if let entry, entry.hasSuffix(".lproj") { languages.append(String(entry.dropLast(".lproj".count))) }
            }
        } catch is ScanError {
            return nil
        }
        for locale in Bundle.preferredLocalizations(from: languages.sorted(), forPreferences: preferences) {
            guard let localized = try? childDirectory(locale + ".lproj", in: resources) else { continue }
            defer { close(localized) }
            guard (try? fileInfo(localized).st_dev) == volume else { continue }
            if let (strings, _) = try? readDictionary("InfoPlist.strings", in: localized, volume: volume),
               let name = displayName(in: strings) { return name }
        }
        return nil
    }

    private static func displayName(in plist: [String: Any]) -> String? {
        property("CFBundleDisplayName", in: plist) ?? property("CFBundleName", in: plist)
    }

    private static func property(_ key: String, in plist: [String: Any]) -> String? {
        guard let value = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func contains(_ app: InstalledSoftware, in root: Root) -> Bool {
        if root.isSingleBundle { return app.source == root.source && app.url == root.url }
        let prefix = root.url.path + "/"
        guard root.source == app.source, app.path.hasPrefix(prefix) else { return false }
        let relative = app.path.dropFirst(prefix.count).split(separator: "/")
        return !relative.dropLast().contains { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private static func matchesOnDisk(_ app: InstalledSoftware) -> Bool {
        guard app.url.isFileURL, app.path == app.id.path,
              app.url.pathExtension.lowercased() == "app", let fd = try? directory(at: app.url) else { return false }
        defer { close(fd) }
        return (try? inspect(fd, url: app.url, source: app.source, localize: false).id) == app.id
    }

    private static func measureDirectory(_ fd: Int32, volume: Int32, result: inout Allocation) throws {
        let parent = try fileInfo(fd)
        guard parent.st_dev == volume else { result.skipped += 1; return }
        guard result.visited.insert(DiskObject(parent)).inserted else { return }
        try result.add(parent)
        try visitEntries(in: fd) { entry in
            guard let entry else { result.skipped += 1; return }
            do {
                let info = try childInfo(entry, in: fd)
                guard info.st_dev == volume else { result.skipped += 1; return }
                if kind(info) == S_IFDIR {
                    let child = try childDirectory(entry, in: fd)
                    defer { close(child) }
                    try measureDirectory(child, volume: volume, result: &result)
                } else if info.st_nlink <= 1 || result.visited.insert(DiskObject(info)).inserted {
                    // For a symbolic link, count its own blocks without reading its target.
                    try result.add(info)
                }
            } catch ScanError.fileSystem {
                result.skipped += 1
            }
        }
    }

    private static func directory(at url: URL) throws -> Int32 {
        let components = url.pathComponents
        guard url.isFileURL, components.first == "/", !components.contains(".."), !components.contains(".") else {
            throw ScanError.invalidBundle
        }
        var fd = open("/", directoryFlags)
        guard fd >= 0 else { throw ScanError.fileSystem(errno) }
        for component in components.dropFirst() {
            let child = openat(fd, component, directoryFlags)
            let code = errno
            close(fd)
            guard child >= 0 else { throw ScanError.fileSystem(code) }
            fd = child
        }
        return fd
    }

    private static func childDirectory(_ entry: String, in fd: Int32) throws -> Int32 {
        let child = openat(fd, entry, directoryFlags)
        guard child >= 0 else { throw ScanError.fileSystem(errno) }
        return child
    }

    private static func fileInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ScanError.fileSystem(errno) }
        return info
    }

    private static func childInfo(_ entry: String, in fd: Int32) throws -> stat {
        var info = stat()
        guard fstatat(fd, entry, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScanError.fileSystem(errno) }
        return info
    }

    private static func kind(_ info: stat) -> mode_t { info.st_mode & S_IFMT }

    private static func visitEntries(in fd: Int32, process: (String?) throws -> Void) throws {
        let copy = try childDirectory(".", in: fd)
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw ScanError.fileSystem(code)
        }
        defer { closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ScanError.fileSystem(errno) }
                return
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            if name == "." || name == ".." { continue }
            try process(name)
        }
    }
}

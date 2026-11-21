import AppKit
import Foundation

enum InstalledSoftwareUninstaller {
    enum Eligibility: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    @MainActor private static var isMovingToTrash = false

    @MainActor
    static func eligibility(for apps: [InstalledSoftware]) -> [InstalledSoftware.ID: Eligibility] {
        let running = workspacePaths()
        return Dictionary(apps.map { ($0.id, eligibility(for: $0, running: running)) },
                          uniquingKeysWith: { first, _ in first })
    }

    @MainActor
    static func eligibility(for app: InstalledSoftware) -> Eligibility {
        eligibility(for: app, running: workspacePaths())
    }

    @MainActor
    static func uninstall(_ app: InstalledSoftware) async throws {
        guard !isMovingToTrash else {
            throw Failure("正在处理另一项卸载，请稍后重试。")
        }
        try requireEligible(eligibility(for: app))
        isMovingToTrash = true
        defer { isMovingToTrash = false }

        let snapshot = await Task.detached(priority: .utility) { ProcessMonitor.sample() }.value
        try Task.checkCancellation()
        try requireEligible(eligibility(for: app))

        let bundle = normalized(app.path)
        if snapshot.processes.contains(where: { process in
            process.stateCode.first != "Z"
                && process.command.hasPrefix("/")
                && belongsToBundle(normalized(process.command), bundle: bundle)
        }) {
            throw Failure("「\(app.name)」或它的辅助程序仍在运行。请先退出再试。")
        }
        guard !snapshot.processes.isEmpty else {
            throw Failure("暂时无法检查是否还有辅助程序在运行，请稍后重试。")
        }

        try await Task.detached(priority: .userInitiated) {
            guard InstalledSoftwareScanner.revalidate(app) else {
                throw Failure("「\(app.name)」的位置或文件已变化。请刷新列表后重新确认。")
            }
            guard InstalledSoftwareScanner.canMoveToTrash(app) else {
                throw Failure("当前无法将这个位置的软件移到废纸篓。请检查磁盘是否可写和你对该文件夹的权限。")
            }
            do {
                try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
            } catch {
                throw Failure("无法将「\(app.name)」移到废纸篓。\(error.localizedDescription)")
            }
        }.value
    }

    private static func eligibility(for app: InstalledSoftware, running: [String]) -> Eligibility {
        let bundle = normalized(app.path)
        if app.isSystem { return .unavailable("系统软件受保护") }
        if app.isCurrentApp || bundle == normalized(Bundle.main.bundleURL.path) {
            return .unavailable("任务台正在运行")
        }
        if running.contains(where: { belongsToBundle($0, bundle: bundle) }) {
            return .unavailable("请先退出软件及其辅助程序")
        }
        if !FileManager.default.isDeletableFile(atPath: app.path) {
            return .unavailable("当前位置无法移动到废纸篓。请刷新列表或检查文件夹权限。")
        }
        return .available
    }

    @MainActor
    private static func workspacePaths() -> [String] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.flatMap { app in
            [app.bundleURL, app.executableURL].compactMap { url in
                guard let url, url.isFileURL else { return nil }
                return normalized(url.path)
            }
        }
    }

    private static func requireEligible(_ eligibility: Eligibility) throws {
        if case let .unavailable(reason) = eligibility { throw Failure(reason) }
    }

    private static func belongsToBundle(_ path: String, bundle: String) -> Bool {
        path == bundle || path.hasPrefix(bundle + "/")
    }

    private static func normalized(_ path: String) -> String {
        let resolved = (path as NSString).standardizingPath
        let dataVolumePrefix = "/System/Volumes/Data"
        return resolved.hasPrefix(dataVolumePrefix + "/") ? String(resolved.dropFirst(dataVolumePrefix.count)) : resolved
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ description: String) { errorDescription = description }
    }
}

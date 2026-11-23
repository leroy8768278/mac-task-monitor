import AppKit
import OSLog

@main
@MainActor
enum MacTaskMonitorLoginItem {
    private static let parentIdentifier = "local.mactaskmonitor.app"
    private static let logger = Logger(subsystem: parentIdentifier + ".login-item", category: "Launch")

    static func main() async {
        guard let parent = containingApplication() else {
            logger.error("Could not find the application's bundle containing this login item.")
            return
        }
        // Another installed copy of the monitor is also enough to satisfy login launch.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: parentIdentifier)
            .contains(where: { !$0.isTerminated }) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--login-item"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: parent, configuration: configuration)
        } catch {
            logger.error("Could not open the monitor at login: \(error.localizedDescription)")
        }
    }

    private static func containingApplication() -> URL? {
        let helper = Bundle.main.bundleURL.standardizedFileURL
        let loginItems = helper.deletingLastPathComponent()
        let library = loginItems.deletingLastPathComponent()
        let contents = library.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helper.pathExtension.lowercased() == "app",
              loginItems.lastPathComponent == "LoginItems",
              library.lastPathComponent == "Library",
              contents.lastPathComponent == "Contents",
              app.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: app), bundle.bundleIdentifier == parentIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return app
    }
}

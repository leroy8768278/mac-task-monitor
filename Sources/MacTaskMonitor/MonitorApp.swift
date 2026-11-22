import SwiftUI

@main
@MainActor
enum MacTaskMonitorEntry {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--watchdog-agent" {
            Watchdog.runAgent()
            return
        }
        MonitorApp.main()
    }
}

@MainActor
private final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = MonitorRuntime()
    let awake = AwakeController()
    private weak var monitorWindow: NSWindow?

    func trackWindow(_ window: NSWindow) {
        guard window !== monitorWindow else { return }
        let center = NotificationCenter.default
        if let previous = monitorWindow {
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: previous)
            center.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: previous)
        }
        monitorWindow = window
        center.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowBecameMain), name: NSWindow.didBecomeMainNotification, object: window)
    }

    @objc private func windowClosing(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func windowBecameMain(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stopForTermination()
        runtime.stop()
    }
}

private struct MonitorWindowReader: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    final class Reader: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.onAttach = onAttach
        return reader
    }

    func updateNSView(_ nsView: Reader, context: Context) {}
}

@MainActor
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate
    @State private var section = MonitorSection.device

    var body: some Scene {
        Window("Mac 任务台", id: "monitor") {
            MonitorWindow(section: $section, runtime: delegate.runtime, awake: delegate.awake)
                .background(MonitorWindowReader(onAttach: delegate.trackWindow))
                .frame(minWidth: 790, minHeight: 570)
                .tint(MonitorTint.accent)
        }
        .defaultSize(width: 1060, height: 700)
        .commands {
            CommandMenu("监控") {
                ForEach(MonitorSection.allCases) { item in
                    Button(item.title) { section = item }
                        .keyboardShortcut(item.shortcut, modifiers: .command)
                }
            }
        }

        MenuBarExtra("Mac 任务台", systemImage: "waveform.path.ecg") {
            MonitorMenu(runtime: delegate.runtime, awake: delegate.awake)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MonitorSection: String, Identifiable, CaseIterable {
    case device, cleanup, runningApps, processes, installedSoftware, tasks, watchdog, tools

    var id: Self { self }

    var title: String {
        switch self {
        case .device: "设备状态"
        case .cleanup: "清理释放"
        case .processes: "运行进程"
        case .installedSoftware: "已装软件"
        case .runningApps: "运行软件"
        case .tasks: "计划任务"
        case .watchdog: "应用守护"
        case .tools: "常用工具"
        }
    }

    var icon: String {
        switch self {
        case .device: "waveform.path.ecg"
        case .cleanup: "sparkles"
        case .processes: "list.bullet.rectangle"
        case .installedSoftware: "shippingbox"
        case .runningApps: "macwindow.on.rectangle"
        case .tasks: "calendar.badge.clock"
        case .watchdog: "shield.lefthalf.filled"
        case .tools: "wrench.and.screwdriver"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .device: "1"
        case .cleanup: "8"
        case .processes: "4"
        case .installedSoftware: "7"
        case .runningApps: "6"
        case .tasks: "2"
        case .watchdog: "3"
        case .tools: "5"
        }
    }
}

struct MonitorSidebar: View {
    @Binding var section: MonitorSection

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "macmini")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 37, height: 37)
                    .foregroundStyle(MonitorTint.accent)
                    .background(MonitorTint.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text("Mac 任务台").font(.system(size: 15, weight: .bold))
            }
            .padding(.leading, 5)

            VStack(spacing: 5) {
                ForEach(MonitorSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 19)
                                .accessibilityHidden(true)
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundStyle(section == item ? MonitorTint.accent : .secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(section == item ? MonitorTint.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 23)
        .frame(width: 182)
        .background(MonitorTint.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        }
    }
}

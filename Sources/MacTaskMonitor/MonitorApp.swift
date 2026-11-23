import AppKit
import SwiftUI

@main
@MainActor
enum MacTaskMonitorEntry {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--watchdog-agent" {
            Watchdog.runAgent()
            return
        }

        let application = NSApplication.shared
        let delegate = MonitorAppDelegate(openWindowOnLaunch: !arguments.contains("--login-item"))
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class MonitorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let runtime = MonitorRuntime()
    private let awake = AwakeController()
    private let navigation = MonitorNavigation()
    private let openWindowOnLaunch: Bool
    private var launched = false
    private var monitorWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenu: MonitorMenu?

    init(openWindowOnLaunch: Bool) {
        self.openWindowOnLaunch = openWindowOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        installStatusMenu()
        runtime.start()
        launched = true
        if openWindowOnLaunch { showWindow() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if launched { showWindow() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === monitorWindow else { return }
        monitorWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stopForTermination()
        runtime.stop()
    }

    private func showWindow(in section: MonitorSection? = nil) {
        if let section { navigation.section = section }
        let window = monitorWindow ?? makeWindow()
        monitorWindow = window
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if NSApp.isHidden { NSApp.unhide(nil) }
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeWindow() -> NSWindow {
        let contentSize = NSSize(width: 1060, height: 700)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Mac 任务台"
        window.identifier = NSUserInterfaceItemIdentifier("monitor")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MonitorWindowContent(navigation: navigation, runtime: runtime, awake: awake))
        window.contentMinSize = NSSize(width: 790, height: 570)
        window.setContentSize(contentSize)
        window.center()
        let frameName = NSWindow.FrameAutosaveName("MacTaskMonitorMainWindow")
        window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)
        return window
    }

    private func installStatusMenu() {
        let menu = MonitorMenu(runtime: runtime, awake: awake,
                               openMonitor: { [weak self] in self?.showWindow() },
                               openSettings: { [weak self] in self?.showWindow(in: .settings) })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Mac 任务台") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "任务台"
            item.length = NSStatusItem.variableLength
        }
        item.button?.toolTip = "Mac 任务台"
        item.button?.setAccessibilityLabel("Mac 任务台")
        item.menu = menu.menu
        statusMenu = menu
        statusItem = item
    }

    private func installApplicationMenu() {
        let main = NSMenu()

        let application = addMenu("Mac 任务台", to: main)
        application.addItem(withTitle: "关于 Mac 任务台", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        let settings = application.addItem(withTitle: MonitorSection.settings.title, action: #selector(openSettings), keyEquivalent: MonitorSection.settings.shortcut)
        settings.target = self
        application.addItem(.separator())
        let services = addMenu("服务", to: application)
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(withTitle: "隐藏 Mac 任务台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "退出 Mac 任务台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = addMenu("编辑", to: main)
        edit.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = addMenu("显示", to: main)
        let fullScreen = view.addItem(withTitle: "切换全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let monitor = addMenu("监控", to: main)
        for section in MonitorSection.allCases where section != .settings {
            let item = monitor.addItem(withTitle: section.title, action: #selector(openSection(_:)), keyEquivalent: section.shortcut)
            item.target = self
            item.representedObject = section.rawValue
        }

        let windows = addMenu("窗口", to: main)
        windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func addMenu(_ title: String, to main: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @objc private func openSettings() {
        showWindow(in: .settings)
    }

    @objc private func openSection(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let section = MonitorSection(rawValue: value) else { return }
        showWindow(in: section)
    }
}

@MainActor
private final class MonitorNavigation: ObservableObject {
    @Published var section = MonitorSection.device
}

private struct MonitorWindowContent: View {
    @ObservedObject var navigation: MonitorNavigation
    let runtime: MonitorRuntime
    let awake: AwakeController

    var body: some View {
        MonitorWindow(section: $navigation.section, runtime: runtime, awake: awake)
            .frame(minWidth: 790, minHeight: 570)
            .tint(MonitorTint.accent)
    }
}

enum MonitorSection: String, Identifiable, CaseIterable {
    case device, cleanup, runningApps, processes, installedSoftware, tasks, watchdog, tools, settings

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
        case .settings: "软件设置"
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
        case .settings: "gearshape"
        }
    }

    var shortcut: String {
        switch self {
        case .device: "1"
        case .cleanup: "8"
        case .processes: "4"
        case .installedSoftware: "7"
        case .runningApps: "6"
        case .tasks: "2"
        case .watchdog: "3"
        case .tools: "5"
        case .settings: ","
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

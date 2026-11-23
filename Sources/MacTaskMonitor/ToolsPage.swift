import AppKit
import SwiftUI

struct KeepAwakeToggle: View {
    @ObservedObject var awake: AwakeController

    var body: some View {
        Toggle("防止休眠与熄屏", isOn: Binding(get: { awake.isEnabled }, set: awake.setEnabled))
    }
}

@MainActor
struct ToolsPage: View {
    @ObservedObject var awake: AwakeController
    @State private var isLocking = false
    @State private var lockError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: MonitorSection.tools.title, subtitle: "管理 Mac 的锁屏、空闲休眠和显示器") { EmptyView() }
            MonitorCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.max")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(MonitorTint.accent)
                            .accessibilityHidden(true)
                        KeepAwakeToggle(awake: awake)
                            .toggleStyle(.switch)
                            .font(.headline)
                            .disabled(isLocking)
                    }
                    Text("开启后，Mac 和显示器在空闲时保持唤醒。关闭窗口后开关继续生效，关闭开关或退出任务台即可恢复系统原有的休眠设置。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = awake.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
            }
            MonitorCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("锁屏", systemImage: "lock")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Button("一键锁屏") { lockScreen(turnOffDisplay: false) }
                            .help("锁定当前会话")
                        Button("一键锁屏并熄屏") { lockScreen(turnOffDisplay: true) }
                            .help("锁定当前会话后让显示器休眠")
                        if isLocking {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在锁屏")
                        }
                    }
                    .disabled(isLocking)
                    Text("一键锁屏会保留「防止休眠与熄屏」的状态。一键锁屏并熄屏会自动关闭已开启的开关。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lockError {
                        Label(lockError, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func lockScreen(turnOffDisplay: Bool) {
        guard !isLocking else { return }
        isLocking = true
        lockError = nil
        Task { @MainActor in
            defer { isLocking = false }
            do {
                try await ScreenLockController.perform(turnOffDisplay: turnOffDisplay, awake: awake)
            } catch {
                lockError = error.localizedDescription
            }
        }
    }
}

@MainActor
final class MonitorMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Mac 任务台")
    private let runtime: MonitorRuntime
    private let awake: AwakeController
    private let openMonitor: () -> Void
    private let openSettings: () -> Void

    init(runtime: MonitorRuntime, awake: AwakeController,
         openMonitor: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.runtime = runtime
        self.awake = awake
        self.openMonitor = openMonitor
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let health = runtime.health {
            let cpu = health.cpuUsage.map { "CPU \($0.formatted(.percent.precision(.fractionLength(0))))" }
            let temperature = health.temperatureCelsius.map { "核心最高 \($0.formatted(.number.precision(.fractionLength(1)))) °C" }
            let metrics = [cpu, temperature].compactMap { $0 }
            if !metrics.isEmpty {
                menu.addItem(withTitle: metrics.joined(separator: " · "), action: nil, keyEquivalent: "").isEnabled = false
            }
        }

        addItem("打开 Mac 任务台", action: #selector(showMonitor))
        addItem(MonitorSection.settings.title, action: #selector(showSettings))
        menu.addItem(.separator())
        let keepAwake = addItem("防止休眠与熄屏", action: #selector(toggleAwake))
        keepAwake.state = awake.isEnabled ? .on : .off
        if let error = awake.errorMessage {
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Mac 任务台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showMonitor() {
        openMonitor()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func toggleAwake() {
        awake.setEnabled(!awake.isEnabled)
    }
}

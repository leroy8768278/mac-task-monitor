import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemSettings: ObservableObject {
    private static let identifier = "local.mactaskmonitor.app.login-item"

    static let shared: LoginItemSettings = {
        let identifier = LoginItemSettings.identifier
        let service = SMAppService.loginItem(identifier: identifier)
        return LoginItemSettings(readStatus: { service.status }) { enabled in
            try await Task.detached(priority: .userInitiated) {
                let item = SMAppService.loginItem(identifier: identifier)
                if enabled {
                    try item.register()
                } else {
                    try await item.unregister()
                }
            }.value
        }
    }()

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let readStatus: @MainActor () -> SMAppService.Status
    private let setRegistration: @MainActor (Bool) async throws -> Void
    private var failedChange: Bool?

    init(readStatus: @escaping @MainActor () -> SMAppService.Status,
         setRegistration: @escaping @MainActor (Bool) async throws -> Void) {
        self.readStatus = readStatus
        self.setRegistration = setRegistration
        status = readStatus()
    }

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var hasPackagedLoginItem: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MacTaskMonitorLoginItem.app", isDirectory: true)
        guard let helper = Bundle(url: url), helper.bundleIdentifier == Self.identifier,
              let executable = helper.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    func refresh() {
        guard !isUpdating else { return }
        status = readStatus()
        if let failedChange, matchesRequest(failedChange) {
            self.failedChange = nil
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        refresh()
        guard !matchesRequest(enabled) else { return }
        failedChange = nil
        errorMessage = nil
        isUpdating = true

        Task {
            await updateRegistration(enabled)
        }
    }

    func retry() {
        if let failedChange { setEnabled(failedChange) }
    }

    private func updateRegistration(_ enabled: Bool) async {
        defer { isUpdating = false }
        let failure: Error?
        do {
            try await setRegistration(enabled)
            failure = nil
        } catch {
            failure = error
        }

        status = readStatus()
        // Allow Service Management a brief interval to publish the new state after a successful call.
        if failure == nil {
            for _ in 0..<3 where !matchesRequest(enabled) {
                try? await Task.sleep(for: .milliseconds(150))
                status = readStatus()
            }
        }
        guard !matchesRequest(enabled) else { return }
        failedChange = enabled
        let action = enabled ? "开启" : "关闭"
        errorMessage = failure.map { "无法\(action)登录启动。\($0.localizedDescription)" }
            ?? "macOS 未确认已\(action)登录启动，请重试。"
    }

    private func matchesRequest(_ enabled: Bool) -> Bool {
        enabled ? isRegistered : status == .notRegistered || status == .notFound
    }
}

@MainActor
struct SettingsPage: View {
    @ObservedObject var loginItem: LoginItemSettings = .shared
    @State private var showsUpdateError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "设置", subtitle: "管理 Mac 任务台的启动方式") { EmptyView() }

            MonitorCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "power.circle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(MonitorTint.accent)
                            .frame(width: 34, height: 34)
                            .background(MonitorTint.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("开机启动")
                                .font(.system(size: 15, weight: .semibold))
                            Text("登录当前账户后，Mac 任务台会在顶部菜单栏静默启动。需要时可打开主窗口。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if loginItem.isUpdating {
                            ProgressView().controlSize(.small).accessibilityLabel("正在更新登录启动")
                        } else {
                            StatusPill(title: statusLabel, color: statusColor)
                        }

                        Toggle("开机启动", isOn: Binding(get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(loginItem.isUpdating || isMissingLoginItem)
                    }

                    if loginItem.status == .requiresApproval {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在系统设置的「登录项与扩展」中允许 Mac 任务台在后台运行。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    } else if isMissingLoginItem {
                        Text("macOS 未找到登录启动项目。请确认正在运行完整的 Mac 任务台应用。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let error = loginItem.errorMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("重试") { loginItem.retry() }
                        }
                    }
                }
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onReceive(loginItem.$errorMessage.dropFirst()) { error in
            showsUpdateError = error != nil
        }
        .alert("开机启动设置未更新", isPresented: $showsUpdateError, presenting: loginItem.errorMessage) { _ in
            Button("重试") { loginItem.retry() }
            Button("关闭", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    private var isMissingLoginItem: Bool { loginItem.status == .notFound && !loginItem.hasPackagedLoginItem }

    private var statusLabel: String {
        switch loginItem.status {
        case .notRegistered: "已关闭"
        case .enabled: "已开启"
        case .requiresApproval: "等待系统批准"
        case .notFound: isMissingLoginItem ? "暂不可用" : "已关闭"
        @unknown default: "状态未知"
        }
    }

    private var statusColor: Color {
        switch loginItem.status {
        case .enabled: MonitorTint.accent
        case .requiresApproval: .orange
        default: .secondary
        }
    }
}

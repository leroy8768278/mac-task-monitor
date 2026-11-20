import SwiftUI

struct WatchdogPage: View {
    @ObservedObject var watchdog: Watchdog
    let existingMT5Rule: ScheduledTask?
    let didScan: Bool
    let revealTask: (String) -> Void

    private var isMT5Selected: Bool {
        guard let url = watchdog.targetURL else { return false }
        return Bundle(url: url)?.bundleIdentifier?.caseInsensitiveCompare("net.metaquotes.wine.MetaTrader5") == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "应用守护", subtitle: "在当前用户登录期间重新打开退出的应用") { EmptyView() }

            if let rule = existingMT5Rule {
                MonitorCard {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(MonitorTint.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已发现 MT5 守护规则").font(.system(size: 13, weight: .semibold))
                            Text("\(rule.label) · \(rule.schedule) · \(rule.status.rawValue)")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看任务") { revealTask(rule.label) }
                    }
                }
            }

            MonitorCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        if let url = watchdog.targetURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 42, height: 42)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 23, weight: .medium)).foregroundStyle(MonitorTint.accent)
                                .frame(width: 42, height: 42)
                                .background(MonitorTint.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(watchdog.targetURL?.deletingPathExtension().lastPathComponent ?? "选择要守护的应用")
                                .font(.system(size: 15, weight: .semibold))
                            if let url = watchdog.targetURL {
                                Text(url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            } else {
                                Text("选择一个 .app 应用").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if watchdog.metaTraderURL != nil && !isMT5Selected {
                            Button("选择 MT5") { watchdog.selectMetaTrader() }.disabled(watchdog.isEnabled)
                        }
                        Button(watchdog.targetURL == nil ? "选取应用…" : "更换…") { watchdog.selectApplication() }
                            .disabled(watchdog.isEnabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("自动重启", isOn: Binding(get: { watchdog.isEnabled }, set: watchdog.setEnabled))
                            .toggleStyle(.switch)
                            .disabled(!watchdog.isEnabled && (watchdog.targetURL == nil || (isMT5Selected && (!didScan || existingMT5Rule != nil))))
                        Text(guardDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            MonitorCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("守护状态").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusPill(title: watchdog.status.title, color: statusColor)
                    }
                    Text(statusDetail)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lastLaunchAt = watchdog.lastLaunchAt {
                        DetailLine(label: "上次尝试启动", value: lastLaunchAt.formatted(date: .abbreviated, time: .standard))
                    }
                    HStack {
                        if watchdog.targetURL != nil {
                            Button { watchdog.checkNow() } label: { Label("检查状态", systemImage: "arrow.clockwise") }
                        }
                        if watchdog.needsBackgroundApproval {
                            Button("打开登录项设置") { watchdog.openBackgroundSettings() }
                        }
                    }
                }
            }
        }
    }

    private var guardDescription: String {
        if isMT5Selected && !didScan { return "正在检查此 Mac 上已有的 MT5 守护规则。" }
        if isMT5Selected && existingMT5Rule != nil { return "MT5 已由上方的规则守护。" }
        return "启用后每 \(Int(Watchdog.checkInterval)) 秒检查一次。应用连续退出约 \(Int(Watchdog.missingGrace)) 秒后自动打开。"
    }

    private var statusColor: Color {
        switch watchdog.status.kind {
        case .running: MonitorTint.accent
        case .waiting, .launching: .blue
        case .warning: .orange
        case .failure: .red
        case .idle: .secondary
        }
    }

    private var statusDetail: String {
        if isMT5Selected && existingMT5Rule != nil && !watchdog.isEnabled {
            if watchdog.status.kind == .running { return "已检测到 MT5 交易终端，守护由上方规则执行。" }
            if watchdog.status.kind == .idle { return "未检测到 MT5 交易终端。现有规则会按配置检查。" }
        }
        return watchdog.status.detail
    }
}

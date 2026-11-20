import AppKit
import SwiftUI

struct RunningAppsPage: View {
    @State private var snapshot: RunningAppsSnapshot?
    @State private var query = ""
    @State private var selection: RunningApp.ID?
    @State private var sortOrder = [KeyPathComparator(\RunningApp.cpuPercent, order: .reverse)]
    @State private var confirmation: RunningApp?
    @State private var closingApp: RunningApp?
    @State private var closeFeedback: CloseFeedback?
    @State private var refreshGeneration = 0

    private struct CloseFeedback {
        let message: String
        var warning = false
    }

    private var showsConfirmation: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var visibleApps: [RunningApp] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.apps ?? []).filter { app in
            search.isEmpty || [app.name, app.bundleIdentifier ?? "", String(app.pid)]
                .contains { $0.localizedStandardContains(search) }
        }
        .sorted(using: sortOrder + [KeyPathComparator(\RunningApp.pid)])
    }

    var body: some View {
        let visible = visibleApps
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: MonitorSection.runningApps.title, subtitle: "查看已启动的桌面软件和独立菜单栏软件") {
                EmptyView()
            }

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索软件名称、PID 或包标识符", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("清除搜索")
                    }
                }
                .padding(8)
                .background(MonitorTint.card, in: RoundedRectangle(cornerRadius: 7))
                if let snapshot {
                    Text("\(visible.count) / \(snapshot.apps.count) 款软件")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }

            if let notice = snapshot?.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            appsTable(visible)

            if let app = visible.first(where: { $0.id == selection }) {
                RunningAppDetails(app: app, isClosing: closingApp != nil) {
                    confirmation = app
                }
                .id(app.id)
            }

            if let closingApp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在确认“\(closingApp.name)”是否已退出…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if let closeFeedback {
                Label(closeFeedback.message, systemImage: closeFeedback.warning ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(closeFeedback.warning ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Text("每款软件的驻留内存按关联进程汇总，共享页可能重复计入。")
                Spacer(minLength: 0)
                if let snapshot {
                    Text(snapshot.sampledAt.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                        .help("每 3 秒刷新")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .task(id: refreshGeneration) {
            while !Task.isCancelled {
                let sample = await RunningAppsMonitor.sample()
                guard !Task.isCancelled else { return }
                updateSnapshot(sample)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task(id: closingApp?.id) {
            if let closingApp { await confirmExit(of: closingApp) }
        }
        .onChange(of: query) { _ in
            closeFeedback = nil
            if let selection, !visibleApps.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
        .onChange(of: selection) { id in
            if id != nil { closeFeedback = nil }
        }
        .alert("强制关闭软件？", isPresented: showsConfirmation, presenting: confirmation) { app in
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("强制关闭", role: .destructive) { forceClose(app) }
        } message: { app in
            Text("将强制关闭“\(app.name)”（PID \(String(app.pid))）。未保存的更改可能丢失。")
        }
    }

    private func appsTable(_ apps: [RunningApp]) -> some View {
        Table(apps, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("软件名称", value: \.name, comparator: String.StandardComparator.localizedStandard) { app in
                HStack(spacing: 8) {
                    appIcon(app.bundleURL)
                    Text(app.name).lineLimit(1)
                }
                .help(app.bundleURL?.path ?? app.bundleIdentifier ?? app.name)
            }
            .width(min: 120, ideal: 245)

            TableColumn("工作状态", value: \.state.rawValue) { app in
                Text(app.state.rawValue)
                    .foregroundStyle(app.state == .active ? MonitorTint.accent : Color.primary)
            }
            .width(min: 65, ideal: 75)

            TableColumn("CPU", sortUsing: KeyPathComparator(\RunningApp.cpuPercent)) { app in
                metric(app.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" })
                    .help("软件各关联进程的近期 CPU 使用率之和。100% 相当于一个逻辑核心满载。")
            }
            .width(min: 52, ideal: 67)

            TableColumn("驻留内存", sortUsing: KeyPathComparator(\RunningApp.residentBytes)) { app in
                metric(app.residentBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory)
                })
            }
            .width(min: 80, ideal: 95)

            TableColumn("PID", value: \.pid) { app in
                Text(String(app.pid)).monospacedDigit()
            }
            .width(min: 46, ideal: 58)

            TableColumn("进程数", sortUsing: KeyPathComparator(\RunningApp.processCount)) { app in
                metric(app.processCount.map(String.init))
            }
            .width(min: 50, ideal: 62)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if let snapshot {
                if apps.isEmpty {
                    Text(snapshot.apps.isEmpty
                         ? (snapshot.notice == nil ? "当前没有正在运行的软件" : "暂时无法读取软件列表")
                         : "没有匹配的软件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在读取软件列表")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private func updateSnapshot(_ sample: RunningAppsSnapshot) {
        snapshot = sample
        if let selection, !sample.apps.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if let confirmation, !sample.apps.contains(where: { $0.id == confirmation.id }) {
            self.confirmation = nil
            closeFeedback = CloseFeedback(message: "“\(confirmation.name)”已退出。")
        }
    }

    private func forceClose(_ app: RunningApp) {
        guard closingApp == nil else { return }
        closeFeedback = nil
        switch RunningAppsMonitor.forceTerminate(app.id) {
        case .requestSubmitted:
            closingApp = app
        case .alreadyExited:
            finishClose(CloseFeedback(message: "“\(app.name)”已退出。"), app: app, exited: true)
        case .systemRejected:
            finishClose(CloseFeedback(message: "macOS 未接受强制关闭“\(app.name)”的请求。", warning: true),
                        app: app, exited: false)
        }
    }

    private func confirmExit(of app: RunningApp) async {
        for _ in 0..<25 {
            guard !Task.isCancelled else { return }
            if !RunningAppsMonitor.isRunning(app.id) { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if RunningAppsMonitor.isRunning(app.id) {
            finishClose(CloseFeedback(message: "已请求关闭“\(app.name)”，暂未确认退出。", warning: true),
                        app: app, exited: false)
        } else {
            finishClose(CloseFeedback(message: "“\(app.name)”的所选实例已退出。"), app: app, exited: true)
        }
    }

    private func finishClose(_ feedback: CloseFeedback, app: RunningApp, exited: Bool) {
        if exited, selection == app.id { selection = nil }
        closingApp = nil
        closeFeedback = feedback
        refreshGeneration &+= 1
    }

    @ViewBuilder
    private func appIcon(_ url: URL?) -> some View {
        if let url, url.isFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func metric(_ text: String?) -> some View {
        if let text {
            Text(text).monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary).accessibilityLabel("未获取")
        }
    }
}

private struct RunningAppDetails: View {
    let app: RunningApp
    let isClosing: Bool
    let requestClose: () -> Void

    @State private var description: RunningAppDescription?

    var body: some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("软件说明 · \(app.name)")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .help(app.name)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("强制关闭…", role: .destructive, action: requestClose)
                        .disabled(isClosing)
                        .fixedSize()
                }
                if let description {
                    DetailLine(label: "主要功能", value: description.purpose)
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("说明来源").foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                        if let url = description.sourceURL {
                            Link(description.sourceLabel, destination: url)
                                .help("在浏览器中打开说明来源")
                        } else {
                            Text(description.sourceLabel).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                } else {
                    Text("正在读取软件说明…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let app = self.app
            let result = await Task.detached(priority: .utility) { RunningAppDescription.resolve(app) }.value
            guard !Task.isCancelled else { return }
            description = result
        }
    }
}

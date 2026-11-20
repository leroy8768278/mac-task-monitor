import AppKit
import SwiftUI

struct RunningAppsPage: View {
    @State private var snapshot: RunningAppsSnapshot?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\RunningApp.cpuPercent, order: .reverse)]

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
            PageHeading(title: "运行中的 App", subtitle: "查看当前会话的图形应用和独立菜单栏应用") {
                EmptyView()
            }

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索 App 名称、PID 或包标识符", text: $query)
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
                    Text("\(visible.count) / \(snapshot.apps.count) 个 App")
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

            HStack(spacing: 12) {
                Text("驻留内存为 App 各关联进程的驻留内存之和，共享页可能重复计入。")
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
        .task {
            while !Task.isCancelled {
                let sample = await RunningAppsMonitor.sample()
                guard !Task.isCancelled else { return }
                snapshot = sample
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func appsTable(_ apps: [RunningApp]) -> some View {
        Table(apps, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name, comparator: String.StandardComparator.localizedStandard) { app in
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
                    .help("App 各关联进程的近期 CPU 使用率之和。100% 相当于一个逻辑核心满载。")
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
                         ? (snapshot.notice == nil ? "当前没有运行中的图形 App" : "暂时无法显示运行中的 App")
                         : "没有匹配的 App")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在读取运行中的 App")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
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

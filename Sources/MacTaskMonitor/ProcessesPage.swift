import SwiftUI

struct ProcessesPage: View {
    @State private var snapshot: ProcessSnapshot?
    @State private var query = ""
    @State private var currentUserOnly = false
    @State private var paused = false
    @State private var selection: RunningProcess.ID?
    @State private var sortOrder = [KeyPathComparator(\RunningProcess.cpuPercent, order: .reverse)]

    private var rows: [RunningProcess] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.processes ?? []).filter { process in
            (!currentUserOnly || process.isCurrentUser)
                && (search.isEmpty || [process.name, process.command, String(process.pid), process.user]
                    .contains { $0.localizedStandardContains(search) })
        }.sorted(using: sortOrder + [KeyPathComparator(\RunningProcess.pid)])
    }

    var body: some View {
        let visible = rows
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: "运行进程", subtitle: "查看当前应用与后台进程") {
                Button {
                    paused.toggle()
                } label: {
                    Label(paused ? "继续刷新" : "暂停刷新", systemImage: paused ? "play" : "pause")
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索进程名、路径、PID 或用户", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .padding(8)
                .background(MonitorTint.card, in: RoundedRectangle(cornerRadius: 7))
                Toggle("仅当前用户", isOn: $currentUserOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Spacer(minLength: 0)
                if let snapshot {
                    Text("\(visible.count) / \(snapshot.processes.count) 个进程")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            if let notice = snapshot?.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("进程名", value: \.name) { process in
                    Text(process.name).lineLimit(1).help(process.command)
                }
                .width(min: 110, ideal: 225)

                TableColumn("CPU", value: \.cpuPercent) { process in
                    Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))%")
                        .monospacedDigit()
                }
                .width(min: 52, ideal: 65)

                TableColumn("驻留内存", value: \.residentBytes) { process in
                    Text(memory(process.residentBytes)).monospacedDigit()
                }
                .width(min: 72, ideal: 96)

                TableColumn("PID", value: \.pid) { process in
                    Text(String(process.pid)).monospacedDigit()
                }
                .width(min: 45, ideal: 57)

                TableColumn("用户", value: \.user)
                    .width(min: 60, ideal: 93)

                TableColumn("状态", value: \.state)
                    .width(min: 60, ideal: 83)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if snapshot == nil {
                    ProgressView("正在读取进程")
                } else if visible.isEmpty {
                    Text(snapshot?.notice == nil ? "没有匹配的进程" : "当前无法显示进程")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }

            if let process = visible.first(where: { $0.id == selection }) {
                MonitorCard {
                    VStack(alignment: .leading, spacing: 7) {
                        DetailLine(label: "可执行文件", value: process.command.isEmpty ? "—" : process.command)
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            DetailLine(label: "父进程 PID", value: String(process.parentPID))
                            if let seconds = process.elapsedSeconds {
                                DetailLine(label: "启动至今", value: elapsed(seconds))
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Text("CPU 为近期平均值，100% 表示占满一个逻辑核心。")
                Spacer(minLength: 0)
                if let snapshot {
                    Text(paused ? "已暂停" : "每 3 秒刷新")
                    Text(snapshot.sampledAt.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task(id: paused) {
            guard !paused else { return }
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { ProcessMonitor.sample() }.value
                guard !Task.isCancelled else { return }
                snapshot = sample
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: query) { _ in selection = nil }
        .onChange(of: currentUserOnly) { _ in selection = nil }
    }

    private func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private func elapsed(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) 秒"
    }
}

import SwiftUI

struct TasksPage: View {
    let snapshot: ScheduledTaskSnapshot?
    let isScanning: Bool
    let refresh: () -> Void

    @State private var query = ""
    @State private var allJobs = false
    @State private var runningOnly = false
    @State private var source: ScheduledTask.Source?
    @State private var expandedTask: String?

    init(snapshot: ScheduledTaskSnapshot?, isScanning: Bool, focusTask: String?, refresh: @escaping () -> Void) {
        self.snapshot = snapshot
        self.isScanning = isScanning
        self.refresh = refresh
        _query = State(initialValue: focusTask ?? "")
        _allJobs = State(initialValue: focusTask != nil)
    }

    private var filteredTasks: [ScheduledTask] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = (snapshot?.tasks ?? []).filter { task in
            (allJobs || task.isScheduled)
                && (!runningOnly || task.status == .running)
                && (source == nil || source == task.source)
                && (term.isEmpty || [task.label, task.command, task.path ?? "", task.schedule, task.status.rawValue]
                    .contains { $0.localizedStandardContains(term) })
        }
        return matches.filter { !$0.isAppleService } + matches.filter(\.isAppleService)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "计划任务", subtitle: "查看 launchd 和当前用户的 cron 任务") {
                if isScanning {
                    ProgressView().controlSize(.small).accessibilityLabel("正在扫描")
                } else if let snapshot {
                    Text("扫描于 \(snapshot.scannedAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(isScanning)
            }

            MonitorCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索任务名称、命令或路径", text: $query)
                            .textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                        }
                    }
                    .padding(8)
                    .background(MonitorTint.canvas, in: RoundedRectangle(cornerRadius: 7))
                    HStack(spacing: 14) {
                        Picker("任务类型", selection: $allJobs) {
                            Text("定时任务").tag(false)
                            Text("全部任务").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)

                        Picker("来源", selection: $source) {
                            Text("所有来源").tag(nil as ScheduledTask.Source?)
                            Text(ScheduledTask.Source.userLaunchd.rawValue).tag(Optional(ScheduledTask.Source.userLaunchd))
                            Text(ScheduledTask.Source.systemLaunchd.rawValue).tag(Optional(ScheduledTask.Source.systemLaunchd))
                            Text(ScheduledTask.Source.cron.rawValue).tag(Optional(ScheduledTask.Source.cron))
                        }
                        .labelsHidden()
                        .fixedSize()
                        Toggle("仅运行中", isOn: $runningOnly)
                            .toggleStyle(.checkbox)
                            .fixedSize()

                        Spacer()
                        if snapshot != nil {
                            Text("\(filteredTasks.count) 项")
                                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }

            if let snapshot, !snapshot.notices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.notices, id: \.self) { notice in
                        Label(notice, systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if snapshot == nil {
                MonitorCard {
                    MonitorEmptyState(icon: "calendar.badge.clock", title: "正在扫描任务", description: "正在读取当前系统和用户会话的任务。")
                }
            } else if filteredTasks.isEmpty {
                MonitorCard {
                    MonitorEmptyState(icon: "magnifyingglass", title: "没有匹配的任务", description: "试试其他关键词或调整筛选条件。")
                }
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(filteredTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedTask = expandedTask == task.id ? nil : task.id
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: task.isScheduled ? "clock" : "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(MonitorTint.accent)
                        .background(MonitorTint.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(task.source.rawValue) · \(task.schedule)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    StatusPill(title: task.status.rawValue, color: statusColor(task.status))
                    Image(systemName: expandedTask == task.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedTask == task.id {
                Divider().padding(.horizontal, 13)
                TaskDetails(task: task)
            }
        }
        .background(MonitorTint.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.07))
                .allowsHitTesting(false)
        }
    }

    private func statusColor(_ status: ScheduledTask.Status) -> Color {
        if status == .running { return MonitorTint.accent }
        if status == .loaded || status == .scheduled { return .blue }
        if status == .disabled { return .orange }
        return .secondary
    }
}

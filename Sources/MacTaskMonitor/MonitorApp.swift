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

struct MonitorApp: App {
    @State private var section = MonitorSection.device

    var body: some Scene {
        Window("Mac 任务台", id: "monitor") {
            MonitorWindow(section: $section)
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
    }
}

enum MonitorSection: String, Identifiable, CaseIterable {
    case device, processes, tasks, watchdog

    var id: Self { self }

    var title: String {
        switch self {
        case .device: "设备状态"
        case .processes: "运行进程"
        case .tasks: "计划任务"
        case .watchdog: "应用守护"
        }
    }

    var icon: String {
        switch self {
        case .device: "waveform.path.ecg"
        case .processes: "list.bullet.rectangle"
        case .tasks: "calendar.badge.clock"
        case .watchdog: "shield.lefthalf.filled"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .device: "1"
        case .processes: "4"
        case .tasks: "2"
        case .watchdog: "3"
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

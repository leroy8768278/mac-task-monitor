import SwiftUI

struct DevicePage: View {
    let deviceName: String
    let snapshot: HealthSnapshot?
    let cpuHistory: [Double]
    let taskSummary: String
    let watchdogSummary: String
    let navigate: (MonitorSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "设备状态", subtitle: deviceName) {
                StatusPill(title: snapshot == nil ? "正在采样" : "实时采样")
            }

            HStack(spacing: 14) {
                metricCard("CPU 使用率", icon: "cpu", value: percent(snapshot?.cpuUsage), color: MonitorTint.accent) {
                    Sparkline(values: cpuHistory, color: MonitorTint.accent)
                        .frame(height: 34)
                        .accessibilityHidden(true)
                }
                metricCard("内存使用率", icon: "memorychip", value: percent(memoryUsage), color: .blue) {
                    metricProgress(memoryUsage, color: .blue, description: memoryDescription)
                }
                metricCard("磁盘使用率", icon: "internaldrive", value: percent(diskUsage), color: .indigo) {
                    metricProgress(diskUsage, color: .indigo, description: diskDescription)
                }
            }

            HStack(spacing: 14) {
                MonitorCard {
                    VStack(alignment: .leading, spacing: 9) {
                        metricLabel("温度与散热", icon: "thermometer.medium", color: thermalColor)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(temperature).font(.system(size: 28, weight: .bold)).monospacedDigit()
                            StatusPill(title: thermalLabel, color: thermalColor)
                        }
                        Text(temperatureDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                MonitorCard {
                    VStack(alignment: .leading, spacing: 9) {
                        metricLabel("系统运行时间", icon: "clock", color: MonitorTint.accent)
                        Text(uptime).font(.system(size: 28, weight: .bold)).monospacedDigit()
                        Text("自上次启动以来")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(spacing: 0) {
                summaryLink(.tasks, summary: taskSummary)
                Divider().padding(.horizontal, 16)
                summaryLink(.watchdog, summary: watchdogSummary)
            }
            .background(MonitorTint.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.07))
                    .allowsHitTesting(false)
            }
        }
    }

    private func metricLabel(_ title: String, icon: String, color: Color) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func metricCard<Content: View>(_ title: String, icon: String, value: String, color: Color,
                                           @ViewBuilder content: () -> Content) -> some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 9) {
                metricLabel(title, icon: icon, color: color)
                Text(value).font(.system(size: 29, weight: .bold)).monospacedDigit()
                content().frame(height: 34, alignment: .bottom)
            }
        }
    }

    private func metricProgress(_ fraction: Double?, color: Color, description: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    if let fraction {
                        Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func summaryLink(_ section: MonitorSection, summary: String) -> some View {
        Button {
            navigate(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .frame(width: 29, height: 29)
                    .foregroundStyle(MonitorTint.accent)
                    .background(MonitorTint.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(section.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private var memoryUsage: Double? {
        guard let snapshot, let used = snapshot.memoryUsedBytes, snapshot.memoryTotalBytes > 0 else { return nil }
        return Double(used) / Double(snapshot.memoryTotalBytes)
    }

    private var memoryDescription: String {
        guard let snapshot, let used = snapshot.memoryUsedBytes else { return "等待内存数据" }
        return "\(bytes(used)) / \(bytes(snapshot.memoryTotalBytes))"
    }

    private var diskUsage: Double? {
        guard let free = snapshot?.diskAvailableBytes, let total = snapshot?.diskTotalBytes, total > 0 else { return nil }
        return 1 - Double(min(free, total)) / Double(total)
    }

    private var diskDescription: String {
        guard let free = snapshot?.diskAvailableBytes, let total = snapshot?.diskTotalBytes else { return "等待磁盘数据" }
        return "可用 \(bytes(free)) / \(bytes(total))"
    }

    private var temperature: String {
        guard let value = snapshot?.temperatureCelsius else { return "— °C" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    private var temperatureDescription: String {
        guard let snapshot else { return "等待散热数据" }
        return snapshot.temperatureCelsius == nil ? "当前设备未提供可读取的温度数值" : "CPU 核心传感器最高读数"
    }

    private var thermalLabel: String {
        switch snapshot?.thermalPressure ?? .unknown {
        case .nominal: "散热正常"
        case .fair: "轻度升温"
        case .serious: "热负载较高"
        case .critical: "热负载严重"
        case .unknown: "状态未知"
        }
    }

    private var thermalColor: Color {
        switch snapshot?.thermalPressure ?? .unknown {
        case .nominal: MonitorTint.accent
        case .fair, .serious: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    private var uptime: String {
        guard let seconds = snapshot?.uptime else { return "—" }
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days) 天 \(hours % 24) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            var guides = Path()
            for row in [CGFloat(0.15), 0.52, 0.9] {
                let y = row * size.height
                guides.move(to: CGPoint(x: 0, y: y))
                guides.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(guides, with: .color(color.opacity(0.13)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard values.count > 1 else { return }
            let maxValue = max(0.25, values.max() ?? 0)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                        y: size.height * (0.91 - 0.77 * value / maxValue))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

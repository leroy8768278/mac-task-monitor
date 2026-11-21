import AppKit
import SwiftUI

struct InstalledSoftwarePage: View {
    @State private var snapshot: InstalledSoftwareSnapshot?
    @State private var eligibility: [InstalledSoftware.ID: InstalledSoftwareUninstaller.Eligibility] = [:]
    @State private var query = ""
    @State private var includeExternalVolumes = false
    @State private var selection: InstalledSoftware.ID?
    @State private var scanGeneration = 0
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var confirmation: InstalledSoftware?
    @State private var uninstalling: InstalledSoftware?
    @State private var uninstallFeedback: UninstallFeedback?

    private struct UninstallFeedback {
        let message: String
        var isError = false
    }

    private var visibleApps: [InstalledSoftware] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.apps ?? []).filter { app in
            search.isEmpty || [app.name, app.bundleIdentifier ?? "", app.path]
                .contains { $0.localizedStandardContains(search) }
        }
    }

    private var showsConfirmation: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var emptyTableMessage: String {
        guard let snapshot else { return "暂时无法读取已装软件" }
        return snapshot.apps.isEmpty ? "未找到已装软件" : "没有匹配的软件"
    }

    var body: some View {
        let visible = visibleApps
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: MonitorSection.installedSoftware.title, subtitle: "查看本机安装的软件及其磁盘占用") {
                Button { requestRefresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(isScanning || uninstalling != nil)
            }

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索软件名称、包标识符或路径", text: $query)
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
                Toggle("包含外接磁盘", isOn: $includeExternalVolumes)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                if let snapshot {
                    Text("\(visible.count) / \(snapshot.apps.count) 款软件")
                        .monospacedDigit()
                        .fixedSize()
                }
                if isScanning && snapshot != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在刷新已装软件")
                }
            }
            .font(.system(size: 12))

            if let scanError {
                notice(scanError, isError: true)
            }
            if let snapshot, !snapshot.notices.isEmpty {
                notice(snapshot.notices.joined(separator: "\n"))
            }

            softwareTable(visible)

            if let selected = visible.first(where: { $0.id == selection }) {
                InstalledSoftwareDetails(app: selected, unavailableReason: unavailableReason(for: selected))
                    .id(DetailSelection(app: selected.id, scannedAt: snapshot?.scannedAt))
            }

            if let uninstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在将“\(uninstalling.name)”移到废纸篓…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if let uninstallFeedback {
                notice(uninstallFeedback.message, isError: uninstallFeedback.isError)
            }
        }
        .task(id: scanGeneration) { await loadSnapshot() }
        .onChange(of: includeExternalVolumes) { _ in requestRefresh() }
        .onChange(of: query) { _ in
            if let selection, !visibleApps.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: RunLoop.main)) { _ in
                refreshEligibility()
            }
        .alert("卸载软件？", isPresented: showsConfirmation, presenting: confirmation) { app in
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("移到废纸篓", role: .destructive) { uninstall(app) }
        } message: { app in
            Text("将“\(app.name)”的软件包移到废纸篓。\n\n\(app.path)")
        }
    }

    private struct DetailSelection: Hashable {
        let app: InstalledSoftware.ID
        let scannedAt: Date?
    }

    private func softwareTable(_ apps: [InstalledSoftware]) -> some View {
        Table(apps, selection: $selection) {
            TableColumn("软件名称") { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(app.name).lineLimit(1)
                }
                .help(app.path)
            }
            .width(min: 128, ideal: 230)

            TableColumn("版本") { app in
                Text(app.version ?? app.buildVersion ?? "—")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 55, ideal: 81)

            TableColumn("安装位置") { app in
                Text(app.source.rawValue).lineLimit(1).help(app.path)
            }
            .width(min: 72, ideal: 114)

            TableColumn("操作") { app in
                let reason = unavailableReason(for: app)
                Button("卸载", role: .destructive) { showUninstallConfirmation(app) }
                    .buttonStyle(UninstallButtonStyle(isSelected: selection == app.id))
                    .disabled(reason != nil || isScanning || uninstalling != nil)
                    .accessibilityLabel("卸载“\(app.name)”")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(reason ?? "将“\(app.name)”移到废纸篓")
            }
            .width(68)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if apps.isEmpty {
                if snapshot == nil && scanError == nil {
                    ProgressView("正在扫描已装软件")
                } else {
                    Text(emptyTableMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private func requestRefresh() {
        isScanning = true
        scanGeneration &+= 1
    }

    private func loadSnapshot() async {
        let generation = scanGeneration
        isScanning = true
        scanError = nil
        defer { if generation == scanGeneration { isScanning = false } }
        let scanExternal = includeExternalVolumes
        let scan = Task.detached(priority: .utility) {
            try InstalledSoftwareScanner.scan(includeExternalVolumes: scanExternal)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await scan.value
            } onCancel: {
                scan.cancel()
            }
            try Task.checkCancellation()
            snapshot = result
            if let selection, !result.apps.contains(where: { $0.id == selection }) { self.selection = nil }
            refreshEligibility()
        } catch is CancellationError {
            return
        } catch {
            scanError = "无法刷新已装软件。\(error.localizedDescription)"
        }
    }

    private func refreshEligibility() {
        guard let snapshot else { return }
        eligibility = InstalledSoftwareUninstaller.eligibility(for: snapshot.apps)
    }

    private func unavailableReason(for app: InstalledSoftware) -> String? {
        switch eligibility[app.id] {
        case .available: nil
        case let .unavailable(reason): reason
        case nil: "暂未核对卸载条件"
        }
    }

    private func showUninstallConfirmation(_ app: InstalledSoftware) {
        guard uninstalling == nil, !isScanning else { return }
        selection = app.id
        uninstallFeedback = nil
        let current = InstalledSoftwareUninstaller.eligibility(for: app)
        eligibility[app.id] = current
        if case .available = current { confirmation = app }
    }

    private func uninstall(_ app: InstalledSoftware) {
        guard uninstalling == nil else { return }
        uninstalling = app
        uninstallFeedback = nil
        Task { @MainActor in
            defer { uninstalling = nil }
            do {
                try await InstalledSoftwareUninstaller.uninstall(app)
                if selection == app.id { selection = nil }
                uninstallFeedback = UninstallFeedback(message: "已将“\(app.name)”移到废纸篓。")
                requestRefresh()
            } catch {
                refreshEligibility()
                uninstallFeedback = UninstallFeedback(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func notice(_ message: String, isError: Bool = false) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(isError ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UninstallButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let accent = colorScheme == .dark
            ? Color(red: 1.00, green: 0.69, blue: 0.67)
            : Color(red: 0.62, green: 0.20, blue: 0.18)
        let tint: Color = isEnabled ? accent : .secondary
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .frame(width: 48, height: 22)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.25 : 0.10), in: shape)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear, in: shape)
            .overlay { shape.strokeBorder(tint.opacity(isEnabled ? 0.3 : 0.12)).allowsHitTesting(false) }
            .contentShape(shape)
    }
}

private struct InstalledSoftwareDetails: View {
    let app: InstalledSoftware
    let unavailableReason: String?

    @State private var size = "正在计算…"
    @State private var description: RunningAppDescription?

    var body: some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("软件详情 · \(app.name)")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                DetailLine(label: "版本", value: version)
                DetailLine(label: "包标识符", value: app.bundleIdentifier ?? "—")
                DetailLine(label: "安装路径", value: app.path)
                DetailLine(label: "磁盘占用", value: size)
                DetailLine(label: "用途说明", value: description?.purpose ?? "正在读取说明…")
                if let description {
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
                }
                if let unavailableReason {
                    DetailLine(label: "卸载限制", value: unavailableReason)
                }
            }
        }
        .task { await measureSize() }
        .task {
            let app = self.app
            let local = await Task.detached(priority: .utility) {
                RunningAppDescription.resolve(name: app.name, bundleIdentifier: app.bundleIdentifier, bundleURL: app.url)
            }.value
            guard !Task.isCancelled else { return }
            description = local
        }
    }

    private var version: String {
        switch (app.version, app.buildVersion) {
        case let (version?, build?) where version != build: "\(version)（构建 \(build)）"
        case let (version?, _): version
        case let (nil, build?): "构建 \(build)"
        case (nil, nil): "—"
        }
    }

    private func measureSize() async {
        let app = self.app
        let measurement = Task.detached(priority: .utility) { try InstalledSoftwareScanner.measure(app) }
        do {
            let result = try await withTaskCancellationHandler {
                try await measurement.value
            } onCancel: {
                measurement.cancel()
            }
            try Task.checkCancellation()
            let amount = ByteCountFormatter.string(fromByteCount: Int64(clamping: result.allocatedBytes), countStyle: .file)
            size = result.isPartial ? "已计 \(amount)，\(result.skippedCount) 项未计入" : amount
        } catch is CancellationError {
            return
        } catch {
            size = error.localizedDescription
        }
    }
}

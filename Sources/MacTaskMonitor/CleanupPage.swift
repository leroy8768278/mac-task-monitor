import SwiftUI

@MainActor
final class CleanupModel: ObservableObject {
    enum CacheActivity {
        case idle, scanning, cancellingScan, cleaning
    }

    @Published private(set) var cacheActivity: CacheActivity = .idle
    @Published private(set) var cacheSnapshot: CacheCleanupSnapshot?
    @Published private(set) var cacheResult: CacheCleanupResult?
    @Published private(set) var cacheError: String?
    @Published private(set) var cacheScanCancelled = false
    @Published private(set) var selectedCacheIDs: Set<CacheCleanupItem.ID> = []
    @Published private(set) var isReleasingMemory = false
    @Published private(set) var memoryResult: MemoryCleaner.Result?
    @Published private(set) var memoryError: String?
    @Published private(set) var memoryReleaseCancelled = false

    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    var selectedCaches: [CacheCleanupItem] {
        (cacheSnapshot?.items ?? []).filter { selectedCacheIDs.contains($0.id) }
    }

    func scanCache() {
        guard cacheActivity == .idle else { return }
        cacheActivity = .scanning
        cacheError = nil
        cacheScanCancelled = false
        scanTask = Task { [weak self] in
            do {
                let snapshot = try await CacheCleaner.scan()
                try Task.checkCancellation()
                self?.selectedCacheIDs.formIntersection(snapshot.items.map(\.id))
                self?.cacheSnapshot = snapshot
            } catch is CancellationError {
                self?.cacheScanCancelled = true
            } catch {
                self?.cacheError = error.localizedDescription
            }
            self?.cacheActivity = .idle
            self?.scanTask = nil
        }
    }

    func cancelCacheScan() {
        guard cacheActivity == .scanning else { return }
        cacheActivity = .cancellingScan
        scanTask?.cancel()
    }

    func selectCache(_ item: CacheCleanupItem, selected: Bool) {
        guard cacheActivity == .idle else { return }
        if selected { selectedCacheIDs.insert(item.id) } else { selectedCacheIDs.remove(item.id) }
    }

    func selectAllCaches(_ selected: Bool) {
        guard cacheActivity == .idle else { return }
        selectedCacheIDs = selected ? Set(cacheSnapshot?.items.map(\.id) ?? []) : []
    }

    func cleanCache(_ items: [CacheCleanupItem]) {
        guard cacheActivity == .idle, !items.isEmpty else { return }
        cacheError = nil
        cacheResult = nil
        cacheScanCancelled = false
        cacheActivity = .cleaning
        Task { [weak self] in
            let result = await CacheCleaner.clear(items)
            guard let self else { return }
            cacheResult = result
            selectedCacheIDs = []
            cacheSnapshot = nil
            cacheActivity = .idle
            scanCache()
        }
    }

    func releaseMemory() {
        guard !isReleasingMemory else { return }
        isReleasingMemory = true
        memoryResult = nil
        memoryError = nil
        memoryReleaseCancelled = false
        Task { [weak self] in
            do {
                let result = try await MemoryCleaner.releaseCaches()
                self?.memoryResult = result
            } catch is CancellationError {
                self?.memoryReleaseCancelled = true
            } catch {
                self?.memoryError = error.localizedDescription
            }
            self?.isReleasingMemory = false
        }
    }
}

struct CleanupPage: View {
    @ObservedObject var model: CleanupModel
    let health: HealthSnapshot?
    @State private var confirmation: [CacheCleanupItem]?

    private var showsConfirmation: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: MonitorSection.cleanup.title, subtitle: "清理应用缓存与释放内存中的文件缓存") { EmptyView() }
            memoryCard
            cacheCard
        }
        .alert("清理所选缓存？", isPresented: showsConfirmation, presenting: confirmation) { items in
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("永久清理", role: .destructive) { model.cleanCache(items) }
        } message: { items in
            Text("将永久删除所选 \(items.count) 项应用缓存中可清理的文件。扫描时估算占用 \(bytes(totalSize(items)))。此操作无法撤销。")
        }
    }

    private var memoryCard: some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    cardHeading("释放内存", icon: "memorychip")
                    Spacer(minLength: 8)
                    Button("释放内存…") { model.releaseMemory() }
                        .disabled(model.isReleasingMemory)
                }
                Text("请求 macOS 释放内存中的文件缓存。执行时可能需要管理员授权。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let health {
                    let used = health.memoryUsedBytes.map(bytes) ?? "—"
                    DetailLine(label: "已用内存", value: "\(used) / \(bytes(health.memoryTotalBytes))")
                }
                if model.isReleasingMemory {
                    progress("正在请求释放文件缓存…")
                } else if let error = model.memoryError {
                    notice(error, warning: true)
                } else if model.memoryReleaseCancelled {
                    notice("已取消内存释放。")
                } else if let result = model.memoryResult {
                    Divider()
                    DetailLine(label: "采样结果", value: freeMemoryChange(result))
                    DetailLine(label: "文件相关内存", value: "\(bytes(result.before.fileBackedBytes)) → \(bytes(result.after.fileBackedBytes))")
                        .help("由文件支持的内存，包括文件映射与缓存。")
                    Text("显示操作前后的整机采样，其他进程的活动也会影响读数。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cacheCard: some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    cardHeading("应用缓存", icon: "internaldrive")
                    Spacer(minLength: 8)
                    if model.cacheActivity == .scanning || model.cacheActivity == .cancellingScan {
                        Button("取消扫描") { model.cancelCacheScan() }
                            .disabled(model.cacheActivity != .scanning)
                    }
                    Button(model.cacheSnapshot == nil ? "扫描缓存" : "重新扫描") { model.scanCache() }
                        .disabled(model.cacheActivity != .idle)
                }
                Text("扫描当前用户的应用缓存，列出已退出且能识别的第三方软件。选中并确认后，删除预览中的缓存文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                switch model.cacheActivity {
                case .scanning: progress("正在扫描应用缓存…")
                case .cancellingScan: progress("正在取消扫描…")
                case .cleaning: progress("正在清理所选缓存…")
                case .idle: EmptyView()
                }

                if let error = model.cacheError {
                    notice(error, warning: true)
                } else if model.cacheScanCancelled {
                    notice("已取消缓存扫描。")
                }

                if let result = model.cacheResult {
                    cacheResult(result)
                }
                if let snapshot = model.cacheSnapshot {
                    cachePreview(snapshot)
                }
            }
        }
    }

    @ViewBuilder
    private func cachePreview(_ snapshot: CacheCleanupSnapshot) -> some View {
        Divider()
        HStack(spacing: 12) {
            Text(snapshot.items.isEmpty ? "未发现可清理的应用缓存" : "\(snapshot.items.count) 项候选缓存 · 估算占用 \(bytes(totalSize(snapshot.items)))")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            Text(snapshot.scannedAt.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("上次扫描时间")
        }

        if snapshot.skippedCount > 0 { notice("已略过 \(snapshot.skippedCount) 项，包括系统缓存、正在使用或无法识别的项目。") }
        forEachNotice(snapshot.notices)

        if !snapshot.items.isEmpty {
            cacheSelectionBar(snapshot)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot.items) { item in
                    Divider()
                    cacheRow(item)
                }
            }
            .disabled(model.cacheActivity != .idle)
        }
    }

    private func cacheSelectionBar(_ snapshot: CacheCleanupSnapshot) -> some View {
        let selected = model.selectedCaches
        return HStack(spacing: 10) {
            Button("全选") { model.selectAllCaches(true) }
                .disabled(selected.count == snapshot.items.count)
            Button("清除选择") { model.selectAllCaches(false) }
                .disabled(selected.isEmpty)
            Spacer(minLength: 4)
            Text("已选 \(selected.count) 项 · \(bytes(totalSize(selected)))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("清理所选…") { confirmation = selected }
                .disabled(selected.isEmpty)
                .fixedSize()
        }
        .disabled(model.cacheActivity != .idle)
    }

    private func cacheRow(_ item: CacheCleanupItem) -> some View {
        Toggle(isOn: Binding(get: { model.selectedCacheIDs.contains(item.id) },
                             set: { model.selectCache(item, selected: $0) })) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 13, weight: .medium))
                    Text(item.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)
                }
                Spacer(minLength: 6)
                Text(item.isPartial ? "已计 \(bytes(item.allocatedBytes))" : bytes(item.allocatedBytes))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .fixedSize()
                    .help(item.isPartial ? "有部分项目未计入扫描估算" : "扫描时的已分配空间")
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func cacheResult(_ result: CacheCleanupResult) -> some View {
        Divider()
        Text("上次缓存清理")
            .font(.system(size: 13, weight: .semibold))
        DetailLine(label: "已处理", value: "\(result.removedCount) 项缓存，删除 \(result.removedFileCount) 个文件")
        DetailLine(label: "删除前占用", value: bytes(result.removedAllocatedBytes))
        if result.skippedCount > 0 {
            notice("清理跳过 \(result.skippedCount) 项缓存。")
        }
        if result.wasCancelled { notice("清理已取消，以上为取消前完成的结果。") }
        forEachNotice(result.notices)
    }

    private func cardHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MonitorTint.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func notice(_ message: String, warning: Bool = false) -> some View {
        Label(message, systemImage: warning ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(warning ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func forEachNotice(_ messages: [String]) -> some View {
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
            notice(message)
        }
    }

    private func totalSize(_ items: [CacheCleanupItem]) -> UInt64 {
        items.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.allocatedBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private func freeMemoryChange(_ result: MemoryCleaner.Result) -> String {
        let before = result.before.freeBytes
        let after = result.after.freeBytes
        let change: String
        if after > before {
            change = "空闲内存增加 \(bytes(after - before))"
        } else if before > after {
            change = "空闲内存减少 \(bytes(before - after))"
        } else {
            change = "空闲内存变化 0 B"
        }
        return "\(change)（\(bytes(before)) → \(bytes(after))）"
    }

    private func bytes(_ value: UInt64) -> String {
        value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

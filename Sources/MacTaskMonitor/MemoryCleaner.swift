import Darwin
import Foundation

enum MemoryCleaner {
    struct Sample: Sendable {
        let freeBytes: UInt64
        let fileBackedBytes: UInt64
        let capturedAt: Date
    }

    struct Result: Sendable {
        let before: Sample
        let after: Sample
    }

    @MainActor private static var isReleasing = false

    @MainActor
    static func releaseCaches() async throws -> Result {
        guard !isReleasing else { throw Failure("正在处理上一次缓存释放请求。") }
        try Task.checkCancellation()
        isReleasing = true
        defer { isReleasing = false }

        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/purge"),
                  FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") else {
                throw Failure("当前系统缺少缓存释放或管理员授权所需的工具。")
            }
            guard let before = sample() else {
                throw Failure("无法读取释放前的内存数据，尚未运行缓存释放命令。")
            }
            try requestSystemPurge()
            guard let after = sample() else {
                throw Failure("系统已完成缓存释放请求，但无法读取释放后的内存数据。")
            }
            return Result(before: before, after: after)
        }.value
    }

    private static func sample() -> Sample? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64_data_t()
        let wordSize = MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / wordSize)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS,
              let fileBackedOffset = MemoryLayout<vm_statistics64_data_t>.offset(of: \.external_page_count),
              Int(count) * wordSize >= fileBackedOffset + MemoryLayout<natural_t>.size else { return nil }

        let pageBytes = UInt64(getpagesize())
        // Mach counts speculative read-ahead pages in its free-page value.
        return Sample(freeBytes: UInt64(info.free_count) * pageBytes,
                      fileBackedBytes: UInt64(info.external_page_count) * pageBytes, capturedAt: Date())
    }

    private static func requestSystemPurge() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Only the fixed system executable is authorized. No arguments come from the UI.
        process.arguments = ["-l", "AppleScript", "-e", purgeScript]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw Failure("无法打开系统缓存释放工具。\(error.localizedDescription)")
        }
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        if process.terminationReason == .exit, process.terminationStatus == 0 {
            if response == "MAC_TASK_MONITOR_PURGE_CANCELLED" { throw CancellationError() }
            if response == "MAC_TASK_MONITOR_PURGE_COMPLETED" { return }
        }
        let detail = response.isEmpty ? "" : " \(String(response.prefix(240)))"
        throw Failure("系统未确认完成缓存释放。\(detail)")
    }

    private static let purgeScript = """
        try
            do shell script "/usr/sbin/purge" with administrator privileges
        on error messageText number errorNumber
            if errorNumber is -128 then
                return "MAC_TASK_MONITOR_PURGE_CANCELLED"
            end if
            error messageText number errorNumber
        end try
        return "MAC_TASK_MONITOR_PURGE_COMPLETED"
        """

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

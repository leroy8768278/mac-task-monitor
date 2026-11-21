import CoreGraphics
import Darwin
import Foundation

enum ScreenLockController {
    @MainActor private static var isPerforming = false

    @MainActor
    static func perform(turnOffDisplay: Bool, awake: AwakeController) async throws {
        guard !isPerforming else { throw Failure("正在处理上一次锁屏请求。") }
        isPerforming = true
        defer { isPerforming = false }
        if turnOffDisplay && awake.isEnabled { awake.setEnabled(false) }
        try await lockSession()
        guard turnOffDisplay else { return }
        guard !awake.isEnabled else {
            throw Failure("会话已锁定，显示器仍保持唤醒。" + (awake.errorMessage ?? "请关闭「防止休眠与熄屏」后重试。"))
        }
        try await sleepDisplays()
    }

    private static func lockSession() async throws {
        // Resolve loginwindow's lock command at runtime because it is outside the public SDK.
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            throw Failure("此系统无法调用锁屏功能。可按 Control-Command-Q 锁屏。")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SACLockScreenImmediate") else {
            throw Failure("此系统缺少锁屏接口。可按 Control-Command-Q 锁屏。")
        }
        let lock = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        let status = lock()
        guard status == 0 else {
            throw Failure("macOS 未接受锁屏请求（错误码 \(status)）。可按 Control-Command-Q 锁屏。")
        }

        // The lock screen can take a moment to appear. Never blank an unconfirmed session.
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?["CGSSessionScreenIsLocked"] as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw Failure("未能确认当前会话已锁定。可按 Control-Command-Q 锁屏。")
    }

    private static func sleepDisplays() async throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        command.arguments = ["displaysleepnow"]
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        command.standardError = errors
        do {
            try command.run()
        } catch {
            throw Failure("会话已锁定，无法启动显示器熄屏命令。\(error.localizedDescription)")
        }
        // pmset can report a display sleep failure on stderr even when it exits successfully.
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationReason == .exit, command.terminationStatus == 0, diagnostics.isEmpty else {
            throw Failure("会话已锁定，但系统未能让显示器熄屏。")
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }
}

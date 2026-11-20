import Darwin
import Foundation

enum LegacyMT5Guard {
    enum Action: Sendable {
        case stop, resume, delete
    }

    static let label = "local.mt5.keepalive"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let ruleURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    private static let python = "/usr/bin/python3"
    private static let originalArguments = [
        python,
        home.appendingPathComponent("Library/Application Support/MT5Local/scripts/mt5_keepalive.py").path
    ]
    private static let actionLock = NSLock()

    static func matches(_ task: ScheduledTask) -> Bool {
        task.source == .userLaunchd && task.label == label
            && task.path == ruleURL.path && (task.domain == nil || task.domain == "gui/\(getuid())")
            && task.executable == python && task.arguments == originalArguments
    }

    static func perform(_ action: Action) throws {
        actionLock.lock()
        defer { actionLock.unlock() }

        let definition = try readRule()
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        if try isLoaded(in: "user/\(getuid())") {
            throw Failure("发现守护规则加载在非图形会话中，无法从这里操作。")
        }
        let loaded = try isLoaded(in: domain)
        try verifyUnchanged(definition)

        switch action {
        case .stop:
            try stop(service, in: domain, definition: definition)
        case .resume:
            let previouslyDisabled = try !loaded && isDisabled(in: domain)
            try requireSuccess(["enable", service], failure: "无法启用 MT5 守护")
            if !loaded {
                do {
                    try verifyUnchanged(definition)
                    try requireSuccess(["bootstrap", domain, ruleURL.path], failure: "无法加载 MT5 守护")
                } catch {
                    // A failed bootstrap can still leave a service present. Keep a
                    // verified job as it is, and disable only when no job loaded.
                    let current = try? isLoaded(in: domain)
                    if current == true { return }
                    if current == false, previouslyDisabled {
                        try verifyUnchanged(definition)
                        try requireSuccess(["disable", service], failure: "加载失败且无法恢复 MT5 守护原有的停用状态")
                    }
                    throw error
                }
            }
            guard try isLoaded(in: domain) else {
                throw Failure("恢复命令已完成，当前会话尚未确认 MT5 守护已加载。")
            }
        case .delete:
            try stop(service, in: domain, definition: definition)
            try verifyUnchanged(definition)
            do {
                try FileManager.default.trashItem(at: ruleURL, resultingItemURL: nil)
            } catch {
                throw Failure("MT5 守护已停止。无法将配置移到废纸篓。\(error.localizedDescription)")
            }
        }
    }

    private static func stop(_ service: String, in domain: String, definition: RuleFile) throws {
        try requireSuccess(["disable", service], failure: "无法停用 MT5 守护")
        if try isLoaded(in: domain) {
            try verifyUnchanged(definition)
            do {
                try requireSuccess(["bootout", service], failure: "已停用 MT5 守护，但无法卸载当前会话中的任务")
            } catch {
                guard (try? isLoaded(in: domain)) == false else { throw error }
            }
        }
        guard try !isLoaded(in: domain) else {
            throw Failure("已停用 MT5 守护，当前会话还未确认任务已卸载。")
        }
    }

    private struct RuleFile: Equatable {
        let device: dev_t
        let inode: ino_t
        let contents: Data
    }

    private static func readRule() throws -> RuleFile {
        let descriptor = Darwin.open(ruleURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw Failure("无法读取预期位置的 MT5 守护配置。请刷新后重试。")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              (1...1_048_576).contains(info.st_size),
              ruleURL.resolvingSymlinksInPath().path == ruleURL.path else {
            throw Failure("MT5 守护配置的文件类型、所有者或路径不符合预期。")
        }

        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              plist["ProgramArguments"] as? [String] == originalArguments,
              plist["Program"] == nil || plist["Program"] as? String == python,
              plist["BundleProgram"] == nil else {
            throw Failure("配置内容与已识别的 MT5 守护规则不一致。请刷新后重试。")
        }
        if let sessions = plist["LimitLoadToSessionType"],
           (sessions as? String) != "Aqua", (sessions as? [String]) != ["Aqua"] {
            throw Failure("MT5 守护配置的登录会话类型与预期不一致。")
        }
        return RuleFile(device: info.st_dev, inode: info.st_ino, contents: data)
    }

    private static func verifyUnchanged(_ definition: RuleFile) throws {
        guard try readRule() == definition else {
            throw Failure("MT5 守护配置在操作期间发生了变化。请刷新后重试。")
        }
    }

    private static func isLoaded(in domain: String) throws -> Bool {
        let service = "\(domain)/\(label)"
        let result = run(["print", service])
        if result.status == 113 && result.output.contains("Could not find service \"\(label)\"") {
            return false
        }
        guard result.status == 0 else {
            throw Failure("无法核对 MT5 守护的加载状态（\(result.diagnostic)）。")
        }

        let lines = result.output.split(whereSeparator: \.isNewline)
        guard lines.first == "\(service) = {",
              lines.contains("\tpath = \(ruleURL.path)"), lines.contains("\ttype = LaunchAgent"),
              lines.contains("\tprogram = \(python)"),
              let argumentsStart = lines.firstIndex(of: "\targuments = {"),
              let argumentsEnd = lines[lines.index(after: argumentsStart)...].firstIndex(of: "\t}"),
              lines[lines.index(after: argumentsStart)..<argumentsEnd].map(String.init)
                == originalArguments.map({ "\t\t\($0)" }) else {
            throw Failure("当前加载的同名任务与预期的 MT5 守护配置不一致。")
        }
        return true
    }

    private static func isDisabled(in domain: String) throws -> Bool {
        let result = run(["print-disabled", domain])
        let lines = result.output.split(whereSeparator: \.isNewline)
        guard result.status == 0, lines.contains("\tdisabled services = {") else {
            throw Failure("无法核对 MT5 守护原有的停用状态（\(result.diagnostic)）。")
        }
        return lines.contains("\t\t\"\(label)\" => disabled")
    }

    private static func requireSuccess(_ arguments: [String], failure: String) throws {
        let result = run(arguments)
        guard result.status == 0 else { throw Failure("\(failure)（\(result.diagnostic)）。") }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct Result {
        let status: Int32?
        let output: String
        var diagnostic: String {
            status.map { "launchctl 状态码 \($0)" } ?? "无法运行 launchctl"
        }
    }

    private static func run(_ arguments: [String]) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        do { try process.run() } catch { return Result(status: nil, output: "") }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

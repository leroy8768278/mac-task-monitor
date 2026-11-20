import Foundation

struct RunningProcess: Identifiable, Sendable {
    var id: Int { pid }

    let pid: Int
    let parentPID: Int
    let uid: UInt32
    let user: String
    let cpuPercent: Double
    let residentBytes: UInt64
    let stateCode: String
    let elapsedSeconds: Int?
    let command: String
    let isCurrentUser: Bool

    var name: String {
        guard !command.isEmpty else { return "进程 \(pid)" }
        if command.dropFirst().hasPrefix(":\\") {
            // Wine reports Windows paths through the same ps field as Unix paths.
            return command.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? command
        }
        return command.split(separator: "/").last.map(String.init) ?? command
    }

    var state: String {
        switch stateCode.first {
        case "R": return "可运行"
        case "S": return "休眠"
        case "I": return "空闲"
        case "T": return "已暂停"
        case "U": return "不可中断等待"
        case "Z": return "僵尸"
        default: return "未知"
        }
    }
}

struct ProcessSnapshot: Sendable {
    let processes: [RunningProcess]
    let sampledAt: Date
    let notice: String?
}

enum ProcessMonitor {
    static func sample() -> ProcessSnapshot {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // comm returns the executable without argument or environment data.
        process.arguments = ["-A", "-ww", "-o", "pid=,ppid=,uid=,user=,pcpu=,rss=,state=,etime=,comm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return ProcessSnapshot(processes: [], sampledAt: Date(), notice: "无法启动系统进程查询。\(error.localizedDescription)")
        }

        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        let currentUID = getuid()
        let samplePID = Int(process.processIdentifier)
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let parsed = rows.compactMap { parse($0, currentUID: currentUID) }
        let processes = parsed.filter { $0.pid != samplePID }

        let notice: String?
        if process.terminationReason == .uncaughtSignal {
            notice = "系统进程查询中断，请刷新重试。"
        } else if process.terminationStatus != 0 {
            notice = "系统进程查询返回错误（\(process.terminationStatus)）。"
        } else if processes.isEmpty {
            notice = "没有读到进程数据，请刷新重试。"
        } else if parsed.count != rows.count {
            notice = "有 \(rows.count - parsed.count) 条进程记录无法解析。"
        } else {
            notice = nil
        }
        return ProcessSnapshot(processes: processes, sampledAt: Date(), notice: notice)
    }

    private static func parse(_ row: Substring, currentUID: UInt32) -> RunningProcess? {
        let fields = row.split(maxSplits: 8, whereSeparator: \.isWhitespace)
        guard fields.count >= 8,
              let pid = Int(fields[0]), pid >= 0,
              let parentPID = Int(fields[1]), parentPID >= 0,
              let uid = UInt32(fields[2]),
              let cpu = Double(fields[4]), cpu.isFinite, cpu >= 0,
              let rss = UInt64(fields[5]), rss <= UInt64.max / 1024 else { return nil }

        let executable = fields.count == 9 ? fields[8].trimmingCharacters(in: .whitespaces) : ""
        return RunningProcess(
            pid: pid, parentPID: parentPID, uid: uid, user: String(fields[3]), cpuPercent: cpu,
            residentBytes: rss * 1024, stateCode: String(fields[6]), elapsedSeconds: elapsedSeconds(from: fields[7]),
            command: executable == "-" ? "" : executable, isCurrentUser: uid == currentUID
        )
    }

    private static func elapsedSeconds(from value: Substring) -> Int? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let last = parts.last, parts.count <= 2 else { return nil }
        let clockFields = last.split(separator: ":", omittingEmptySubsequences: false)
        let clock = clockFields.compactMap { Int($0) }
        guard clock.count == clockFields.count,
              (2...3).contains(clock.count),
              clock.suffix(2).allSatisfy({ (0..<60).contains($0) }),
              clock.count == 2 || (0..<24).contains(clock[0]) else { return nil }

        let days = parts.count == 2 ? Int(parts[0]) : 0
        guard let days, (0..<(Int.max / 86_400)).contains(days) else { return nil }
        let seconds = clock.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }
}

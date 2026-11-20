import Foundation

struct ScheduledTask: Identifiable, Sendable {
    enum Source: String, CaseIterable, Sendable {
        case userLaunchd = "用户 LaunchAgent"
        case systemLaunchd = "系统 LaunchDaemon"
        case cron = "用户 cron"
    }

    enum Status: String, CaseIterable, Sendable {
        case running = "运行中"
        case loaded = "已加载"
        case notLoaded = "未加载"
        case disabled = "已停用"
        case scheduled = "已配置"
        case unknown = "状态未知"
    }

    let id: String
    let label: String
    let source: Source
    let status: Status
    let pid: Int?
    let lastExitStatus: Int?
    let schedule: String
    let command: String
    let path: String?
    let domain: String?
    let isScheduled: Bool
    let isAppleService: Bool
}

struct ScheduledTaskSnapshot: Sendable {
    let tasks: [ScheduledTask]
    let notices: [String]
    let scannedAt: Date
}

enum TaskScanner {
    static func scan() -> ScheduledTaskSnapshot {
        var notices: [String] = []
        let uid = getuid()
        let domains = [
            ("gui/\(uid)", ScheduledTask.Source.userLaunchd),
            ("user/\(uid)", ScheduledTask.Source.userLaunchd),
            ("system", ScheduledTask.Source.systemLaunchd)
        ].map { readDomain($0.0, source: $0.1, notices: &notices) }

        let definitions = readDefinitions(notices: &notices)
        let byIdentity = Dictionary(grouping: definitions, by: \.identity)
        var representedPaths: Set<String> = []
        var tasks: [ScheduledTask] = []

        for domain in domains {
            for service in domain.services {
                let identity = Identity(source: domain.source, label: service.label)
                let definition = matchingDefinition(byIdentity[identity] ?? [], for: service, in: domain.name)
                var id = "\(domain.name)/\(service.label)"
                if let definition, representedPaths.insert(definition.path).inserted {
                    id = "plist:\(definition.path)"
                }

                tasks.append(ScheduledTask(
                    id: id, label: service.label, source: domain.source,
                    status: service.pid == nil ? .loaded : .running, pid: service.pid,
                    lastExitStatus: service.lastExitStatus, schedule: definition?.schedule ?? "未读取到触发配置",
                    command: definition?.command ?? "", path: definition?.path, domain: domain.name,
                    isScheduled: definition?.isScheduled ?? false,
                    isAppleService: isAppleService(service.label, path: definition?.path)
                ))
            }
        }

        for definition in definitions where !representedPaths.contains(definition.path) {
            let candidates = domains.filter { definition.applies(to: $0) }
            let disabled = !candidates.isEmpty && candidates.allSatisfy {
                $0.overrides[definition.identity.label] ?? definition.disabledByDefault
            }
            let canDetermineStatus = !candidates.isEmpty && candidates.allSatisfy(\.isComplete)
            let status: ScheduledTask.Status = disabled ? .disabled : (canDetermineStatus ? .notLoaded : .unknown)
            tasks.append(ScheduledTask(
                id: "plist:\(definition.path)", label: definition.identity.label, source: definition.identity.source,
                status: status, pid: nil, lastExitStatus: nil, schedule: definition.schedule,
                command: definition.command, path: definition.path,
                domain: candidates.count == 1 ? candidates.first?.name : nil,
                isScheduled: definition.isScheduled,
                isAppleService: isAppleService(definition.identity.label, path: definition.path)
            ))
        }

        tasks.append(contentsOf: readCron(notices: &notices))
        tasks.sort {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return ScheduledTaskSnapshot(tasks: tasks, notices: notices, scannedAt: Date())
    }

    private struct Identity: Hashable {
        let source: ScheduledTask.Source
        let label: String
    }

    private struct Definition {
        let identity: Identity
        let path: String
        let schedule: String
        let command: String
        let isScheduled: Bool
        let disabledByDefault: Bool
        let sessionTypes: [String]

        func applies(to domain: Domain) -> Bool {
            guard domain.source == identity.source else { return false }
            if identity.source == .systemLaunchd { return true }
            let session = domain.name.hasPrefix("gui/") ? "Aqua" : "Background"
            return sessionTypes.isEmpty ? session == "Aqua" : sessionTypes.contains(session)
        }
    }

    private struct Service {
        let label: String
        let pid: Int?
        let lastExitStatus: Int?
    }

    private struct Domain {
        let name: String
        let source: ScheduledTask.Source
        let services: [Service]
        let overrides: [String: Bool]
        let isComplete: Bool
    }

    private static func readDomain(_ name: String, source: ScheduledTask.Source, notices: inout [String]) -> Domain {
        let result = run("/bin/launchctl", arguments: ["print", name])
        guard result.succeeded else {
            notices.append("读取 launchd 域 \(name) 失败。\(result.diagnostic)")
            return Domain(name: name, source: source, services: [], overrides: [:], isComplete: false)
        }

        let rows = outputSection("services", in: result.output)
        let services = rows?.compactMap { line -> Service? in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3 else { return nil }
            let pid = Int(fields[0])
            guard pid != nil || fields[0] == "-" else { return nil }
            let label = fields[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            return Service(label: label, pid: pid.flatMap { $0 > 0 ? $0 : nil }, lastExitStatus: Int(fields[1]))
        } ?? []
        let reportedCount = result.output.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("service count = ") }
            .flatMap { Int($0.dropFirst("service count = ".count)) }
        let complete = (rows != nil && services.count == rows?.count && (reportedCount ?? services.count) == services.count)
            || (rows == nil && reportedCount == 0)
        if !complete { notices.append("launchd 域 \(name) 的服务状态读取不完整。") }

        var overrides: [String: Bool] = [:]
        for row in outputSection("disabled services", in: result.output) ?? [] {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let separator = trimmed.range(of: "\" => ", options: .backwards) else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
            let state = trimmed[separator.upperBound...]
            if state == "enabled" || state == "disabled" { overrides[label] = state == "disabled" }
        }

        return Domain(name: name, source: source, services: services, overrides: overrides, isComplete: complete)
    }

    // launchctl print is diagnostic text. Recognize complete sections before inferring absence.
    private static func outputSection(_ title: String, in output: String) -> [Substring]? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(of: "\t\(title) = {") else { return nil }
        let remaining = lines.dropFirst(start + 1)
        guard let end = remaining.firstIndex(of: "\t}") else { return nil }
        return Array(remaining[..<end])
    }

    private static func matchingDefinition(_ definitions: [Definition], for service: Service, in domainName: String) -> Definition? {
        guard definitions.count > 1 else { return definitions.first }
        let detail = run("/bin/launchctl", arguments: ["print", "\(domainName)/\(service.label)"])
        let path = detail.output.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("\tpath = ") }?
            .dropFirst("\tpath = ".count)
        return definitions.first { $0.path == path.map(String.init) }
    }

    private static func readDefinitions(notices: inout [String]) -> [Definition] {
        let fm = FileManager.default
        let directories: [(URL, ScheduledTask.Source)] = [
            (fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), .userLaunchd),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .userLaunchd),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), .userLaunchd),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemLaunchd),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), .systemLaunchd)
        ]

        return directories.flatMap { directory, source -> [Definition] in
            do {
                let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                var unreadable = 0
                let definitions = urls.filter { $0.pathExtension.lowercased() == "plist" }.compactMap { url in
                    do {
                        return try readDefinition(at: url, source: source)
                    } catch {
                        unreadable += 1
                        return nil
                    }
                }
                if unreadable > 0 { notices.append("\(directory.path) 有 \(unreadable) 份配置无法解析。") }
                return definitions
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return []
            } catch {
                notices.append("无法读取 \(directory.path)。\(error.localizedDescription)")
                return []
            }
        }
    }

    private static func readDefinition(at url: URL, source: ScheduledTask.Source) throws -> Definition? {
        let resolved = url.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
        let data = try Data(contentsOf: resolved)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else { return nil }

        let intervals = plist["StartCalendarInterval"] as? [[String: Int]]
            ?? (plist["StartCalendarInterval"] as? [String: Int]).map { [$0] }
            ?? []
        let seconds = plist["StartInterval"] as? Int
        let hasInterval = (seconds ?? 0) > 0
        var triggers = intervals.map(describeCalendar)
        if let seconds, hasInterval { triggers.insert(describeInterval(seconds), at: 0) }
        if (plist["RunAtLoad"] as? Bool) == true { triggers.append("加载时运行") }
        if (plist["KeepAlive"] as? Bool) == true { triggers.append("保持运行") }
        if plist["KeepAlive"] is [String: Any] { triggers.append("满足条件时保持运行") }
        if plist["WatchPaths"] != nil { triggers.append("文件变化时") }
        if plist["QueueDirectories"] != nil { triggers.append("有待处理文件时") }
        if (plist["StartOnMount"] as? Bool) == true { triggers.append("挂载文件系统时") }
        if plist["MachServices"] != nil || plist["Sockets"] != nil || plist["LaunchEvents"] != nil {
            triggers.append("按需触发")
        }

        var command = plist["ProgramArguments"] as? [String] ?? []
        if let executable = (plist["Program"] ?? plist["BundleProgram"]) as? String {
            if command.isEmpty { command.append(executable) } else { command[0] = executable }
        }
        return Definition(
            identity: Identity(source: source, label: label), path: url.path,
            schedule: triggers.isEmpty ? "无显式定时配置" : triggers.joined(separator: " · "),
            command: command.map(quoteArgument).joined(separator: " "),
            isScheduled: hasInterval || !intervals.isEmpty,
            disabledByDefault: (plist["Disabled"] as? Bool) == true,
            sessionTypes: (plist["LimitLoadToSessionType"] as? [String]) ?? (plist["LimitLoadToSessionType"] as? String).map { [$0] } ?? []
        )
    }

    private static func describeInterval(_ seconds: Int) -> String {
        if seconds.isMultiple(of: 3600) { return "每 \(seconds / 3600) 小时" }
        if seconds.isMultiple(of: 60) { return "每 \(seconds / 60) 分钟" }
        return "每 \(seconds) 秒"
    }

    private static func describeCalendar(_ interval: [String: Int]) -> String {
        let days = ["日", "一", "二", "三", "四", "五", "六", "日"]
        var parts: [String] = []
        if let month = interval["Month"] { parts.append("\(month) 月") }
        if let day = interval["Day"] { parts.append("\(day) 日") }
        if let weekday = interval["Weekday"] {
            parts.append(days.indices.contains(weekday) ? "星期\(days[weekday])" : "星期 \(weekday)")
        }
        switch (interval["Hour"], interval["Minute"]) {
        case let (hour?, minute?):
            if parts.isEmpty { parts.append("每天") }
            parts.append(String(format: "%02d:%02d", hour, minute))
        case let (hour?, nil):
            parts.append("\(hour) 时内每分钟")
        case let (nil, minute?):
            parts.append("每小时第 \(minute) 分钟")
        case (nil, nil):
            parts.append("每分钟")
        }
        return parts.joined(separator: " ")
    }

    private static func quoteArgument(_ argument: String) -> String {
        let bare = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:@%+=,-"))
        if !argument.isEmpty && argument.unicodeScalars.allSatisfy(bare.contains) { return argument }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func isAppleService(_ label: String, path: String?) -> Bool {
        label.hasPrefix("com.apple.") || label.hasPrefix("application.com.apple.") || path?.hasPrefix("/System/Library/") == true
    }

    private static func readCron(notices: inout [String]) -> [ScheduledTask] {
        let result = run("/usr/bin/crontab", arguments: ["-l"])
        guard result.succeeded else {
            if !result.output.hasPrefix("crontab: no crontab for ") {
                notices.append("无法读取当前用户的 crontab。\(result.diagnostic)")
            }
            return []
        }
        return parseCron(result.output, notices: &notices)
    }

    private static func parseCron(_ contents: String, notices: inout [String]) -> [ScheduledTask] {
        let aliases: Set<String> = ["@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"]
        let assignment = #"^(?:[^\s='\"]+|'[^']*'|"[^"]*")\s*="#
        var tasks: [ScheduledTask] = []
        var invalidLineCount = 0
        for (offset, line) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
            if entry.range(of: assignment, options: .regularExpression) != nil { continue }

            let fieldCount = entry.hasPrefix("@") ? 1 : 5
            let fields = entry.split(maxSplits: fieldCount, whereSeparator: \.isWhitespace)
            guard fields.count == fieldCount + 1, let first = fields.first,
                  fieldCount == 5 || aliases.contains(String(first)) else {
                invalidLineCount += 1
                continue
            }
            tasks.append(ScheduledTask(
                id: "cron:\(offset + 1)", label: "crontab 第 \(offset + 1) 行", source: .cron,
                status: .scheduled, pid: nil, lastExitStatus: nil,
                schedule: fields.prefix(fieldCount).joined(separator: " "),
                command: fields[fieldCount].trimmingCharacters(in: .whitespaces),
                path: nil, domain: nil, isScheduled: true, isAppleService: false
            ))
        }
        if invalidLineCount > 0 {
            notices.append("当前用户的 crontab 有 \(invalidLineCount) 行无法解析。")
        }
        return tasks
    }

    private struct CommandResult {
        let status: Int32?
        let output: String

        var succeeded: Bool { status == 0 }
        var diagnostic: String {
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.prefix(240))
        }
    }

    private static func run(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        do { try process.run() } catch { return CommandResult(status: nil, output: error.localizedDescription) }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

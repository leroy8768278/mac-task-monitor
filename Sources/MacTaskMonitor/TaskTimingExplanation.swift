import Foundation

enum TaskTimingTrigger: Sendable {
    case interval(Int)
    case calendar([String: Int])
    case event(String)

    static func launchd(_ plist: [String: Any]) -> [Self] {
        var triggers: [Self] = []
        if let seconds = plist["StartInterval"] as? Int, seconds > 0 {
            triggers.append(.interval(seconds))
        }
        if let rules = plist["StartCalendarInterval"] as? [[String: Int]] {
            triggers.append(contentsOf: rules.map(Self.calendar))
        } else if let rule = plist["StartCalendarInterval"] as? [String: Int] {
            triggers.append(.calendar(rule))
        }

        if plist["RunAtLoad"] as? Bool == true {
            triggers.append(.event("任务加载时触发一次。"))
        }
        if plist["KeepAlive"] as? Bool == true {
            triggers.append(.event("launchd 会尝试让任务持续运行，并在退出后重新启动。频繁退出时可能延后重启。"))
        } else if let conditions = plist["KeepAlive"] as? [String: Any], !conditions.isEmpty {
            triggers.append(.event("launchd 会按 KeepAlive 中配置的条件决定是否保持运行或重新启动。"))
        }
        if let paths = plist["WatchPaths"] as? [String], !paths.isEmpty {
            triggers.append(.event("受监视的文件或目录发生变化时可以触发。"))
        }
        if let directories = plist["QueueDirectories"] as? [String], !directories.isEmpty {
            triggers.append(.event("配置的队列目录中有待处理文件时可以触发。"))
        }
        if plist["StartOnMount"] as? Bool == true {
            triggers.append(.event("文件系统挂载时触发。"))
        }
        if plist["MachServices"] != nil || plist["Sockets"] != nil || plist["LaunchEvents"] != nil {
            triggers.append(.event("配置的系统事件或服务请求发生时可以按需启动。"))
        }
        return triggers
    }

    var description: String {
        switch self {
        case let .interval(seconds):
            if seconds.isMultiple(of: 3_600) { return "每隔 \(seconds / 3_600) 小时触发。" }
            if seconds.isMultiple(of: 60) { return "每隔 \(seconds / 60) 分钟触发。" }
            return "每隔 \(seconds) 秒触发。"
        case let .calendar(fields):
            return Self.describeCalendar(fields)
        case let .event(text):
            return text
        }
    }

    private static func describeCalendar(_ fields: [String: Int]) -> String {
        let limits = ["Month": 1...12, "Day": 1...31, "Weekday": 0...7, "Hour": 0...23, "Minute": 0...59]
        guard fields.allSatisfy({ limits[$0.key]?.contains($0.value) == true }) else {
            return "日历规则包含未能解读的字段或数值。"
        }
        let month = fields["Month"].map { "每年 \($0) 月" }
        let day = fields["Day"].map { "\($0) 日" }
        let weekday = fields["Weekday"].map(weekdayName)
        let date: String
        // The current macOS launchd.plist(5) treats Day and Weekday as alternatives.
        switch (day, weekday) {
        case let (day?, weekday?):
            date = "\(month ?? "每月")内，日期为 \(day)或\(weekday)时，"
        case let (day?, nil):
            date = "\(month ?? "每月") \(day)"
        case let (nil, weekday?):
            date = month.map { "\($0)的每个\(weekday)" } ?? "每逢\(weekday)"
        case (nil, nil):
            date = month.map { "\($0)每天" } ?? "每天"
        }
        switch (fields["Hour"], fields["Minute"]) {
        case let (hour?, minute?):
            return "\(date) \(clock(hour, minute)) 触发。"
        case let (hour?, nil):
            return "\(date) \(clock(hour, 0)) 至 \(clock(hour, 59)) 每分钟触发。"
        case let (nil, minute?):
            return "\(date)每小时第 \(minute) 分钟触发。"
        case (nil, nil):
            return "\(date)每分钟触发。"
        }
    }
}

struct TaskTimingExplanation: Sendable {
    let trigger: String
    let status: String
    let exitResult: String?

    init(task: ScheduledTask) {
        if task.source == .cron {
            let powerCondition = task.command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
            trigger = Self.describeCron(task.schedule)
                + (powerCondition == "@AppleNotOnBattery" ? "使用电池供电时跳过。" : "")
        } else if !task.timingTriggers.isEmpty {
            var details = task.timingTriggers.map(\.description)
            if task.timingTriggers.contains(where: { if case .interval = $0 { true } else { false } }) {
                details.append("休眠或任务已在运行时，错过的固定间隔触发会被跳过。")
            }
            if task.timingTriggers.contains(where: { if case .calendar = $0 { true } else { false } }) {
                details.append("休眠期间错过的日历触发可在唤醒后合并为一次。")
            }
            trigger = details.joined()
        } else if task.path != nil {
            trigger = "当前配置未列出可解读的自动触发规则。"
        } else {
            trigger = "当前读取的服务记录未提供可解读的触发规则。"
        }

        switch task.status {
        case .running:
            status = task.pid.map { "扫描时该进程正在运行（PID \($0)）。" } ?? "扫描时该任务正在运行。"
        case .loaded:
            status = "服务已由 launchd 加载，扫描时没有活动进程。"
        case .notLoaded:
            status = "发现配置文件，扫描时服务尚未加载到对应的 launchd 域。"
        case .disabled:
            status = "该任务当前处于停用状态。"
        case .scheduled:
            status = "已在当前用户的 crontab 中配置。这里显示的是计划规则。"
        case .unknown:
            status = "当前资料不足以确认服务是否已加载或运行。"
        }

        exitResult = task.lastExitStatus.map { code in
            if code == 0 { return "上次报告正常退出（退出码 0）。" }
            if code < 0 { return "上次报告由信号 \(code.magnitude) 终止。" }
            return "上次报告退出码 \(code)，具体含义由程序决定。"
        }
    }

    private static func describeCron(_ schedule: String) -> String {
        if schedule == "@reboot" { return "cron 服务启动时触发一次。" }
        let aliases = [
            "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
            "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *",
            "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"
        ]
        let fields = (aliases[schedule] ?? schedule).split(whereSeparator: \.isWhitespace)
        guard fields.count == CronUnit.allCases.count else { return "这条 cron 表达式暂未能解读。" }

        let parsed = zip(CronUnit.allCases, fields).compactMap { CronField(unit: $0, expression: $1) }
        guard parsed.count == fields.count else { return "这条 cron 表达式暂未能解读。" }
        let (minute, hour, day, month, weekday) = (parsed[0], parsed[1], parsed[2], parsed[3], parsed[4])

        var date: [String] = []
        if let monthDescription = month.description {
            date.append("月份为 \(monthDescription)")
        }
        if let dayDescription = day.description, let weekdayDescription = weekday.description {
            // Apple's cron uses OR only if neither day field starts with a wildcard.
            let join = day.startsWithWildcard || weekday.startsWithWildcard ? "且" : "或"
            date.append("日期满足「\(dayDescription)」\(join)「\(weekdayDescription)」")
        } else if let description = day.description ?? weekday.description {
            date.append("日期为 \(description)")
        }

        let time: String
        switch (hour.singleValue, minute.singleValue) {
        case let (hourValue?, minuteValue?):
            time = "\(date.isEmpty ? "每天 " : "")\(clock(hourValue, minuteValue)) 触发"
        case let (nil, minuteValue?) where hour.description == nil:
            time = minuteValue == 0 ? "每小时整点触发" : "每小时第 \(minuteValue) 分钟触发"
        case let (hourValue?, nil) where minute.description == nil:
            time = "\(date.isEmpty ? "每天 " : "")\(clock(hourValue, 0)) 至 \(clock(hourValue, 59)) 每分钟触发"
        default:
            if hour.description == nil, let step = minute.wildcardStep, (2...59).contains(step) {
                time = "每小时从整点开始，每隔 \(step) 分钟触发"
            } else {
                let parts = [hour.description, minute.description].compactMap { $0 }
                time = parts.isEmpty ? "每分钟触发" : "在\(parts.joined(separator: "、"))匹配的时刻触发"
            }
        }

        let conditions = date.isEmpty ? "" : date.joined(separator: "，") + "时，"
        return "\(conditions)\(time)。系统休眠时可能错过计划时刻。"
    }
}

private enum CronUnit: CaseIterable {
    case minute, hour, day, month, weekday

    var limits: ClosedRange<Int> {
        switch self {
        case .minute: 0...59
        case .hour: 0...23
        case .day: 1...31
        case .month: 1...12
        case .weekday: 0...7
        }
    }

    var stepUnit: String {
        switch self {
        case .minute: "分钟"
        case .hour: "小时"
        case .day, .weekday: "天"
        case .month: "个月"
        }
    }

    func value(_ raw: Substring) -> Int? {
        if let number = Int(raw), limits.contains(number) { return number }
        let names: [String]
        switch self {
        case .month: names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        case .weekday: names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        default: return nil
        }
        return names.firstIndex(of: raw.lowercased()).map { $0 + limits.lowerBound }
    }

    func label(_ value: Int) -> String {
        switch self {
        case .minute: "第 \(value) 分钟"
        case .hour: "\(value) 时"
        case .day: "\(value) 日"
        case .month: "\(value) 月"
        case .weekday: weekdayName(value)
        }
    }
}

private struct CronField {
    let startsWithWildcard: Bool
    let singleValue: Int?
    let wildcardStep: Int?
    let description: String?

    init?(unit: CronUnit, expression: Substring) {
        startsWithWildcard = expression.hasPrefix("*")
        singleValue = unit.value(expression)
        wildcardStep = expression.hasPrefix("*/") ? Int(expression.dropFirst(2)) : nil
        if expression == "*" {
            description = nil
            return
        }
        let terms = expression.split(separator: ",", omittingEmptySubsequences: false)
        let descriptions = terms.compactMap { Self.describeTerm($0, unit: unit) }
        guard descriptions.count == terms.count else { return nil }
        description = descriptions.joined(separator: "、")
    }

    private static func describeTerm(_ term: Substring, unit: CronUnit) -> String? {
        if let single = unit.value(term) { return unit.label(single) }
        let stepped = term.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = stepped.first, stepped.count <= 2 else { return nil }
        let amount = stepped.count == 1 ? 1 : Int(stepped[1])
        guard let amount, amount > 0 else { return nil }

        let bounds: ClosedRange<Int>
        if first == "*" {
            bounds = unit.limits
        } else {
            let endpoints = first.split(separator: "-", omittingEmptySubsequences: false)
            guard endpoints.count == 2, let start = unit.value(endpoints[0]), let end = unit.value(endpoints[1]),
                  start <= end else { return nil }
            bounds = start...end
        }

        if amount > bounds.upperBound - bounds.lowerBound { return unit.label(bounds.lowerBound) }
        if unit == .weekday && bounds == 0...7 && amount == 1 { return "一周内的任意一天" }
        let range = unit == .weekday && bounds.upperBound == 7 && bounds.lowerBound < 7
            ? "\(unit.label(bounds.lowerBound))至下一周星期日"
            : "\(unit.label(bounds.lowerBound))至\(unit.label(bounds.upperBound))"
        return amount == 1 ? range : "\(range)内从首项起每隔 \(amount) \(unit.stepUnit)"
    }
}

private func clock(_ hour: Int, _ minute: Int) -> String {
    String(format: "%02d:%02d", hour, minute)
}

private func weekdayName(_ value: Int) -> String {
    let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    return weekdays[value]
}

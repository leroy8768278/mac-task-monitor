import Foundation

enum TaskKnowledge {
    struct Entry: Sendable {
        let type: String
        let role: String
        let exitImpact: String
        let source: Source?
    }

    struct Source: Sendable {
        let title: String
        let url: URL
    }

    static func lookup(_ task: ScheduledTask) -> Entry? {
        if let description = appleTasks[task.label],
           task.source == description.source,
           task.path == "/System/Library/\(description.directory)/\(task.label).plist",
           task.executable == description.executable,
           task.arguments == description.arguments {
            return description.entry
        }

        guard task.source == .userLaunchd, let description = mt5Tasks[task.label] else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(task.label).plist")
        let script = home.appendingPathComponent("Library/Application Support/MT5Local/\(description.script)")
        guard task.path == plist.path, task.executable == description.interpreter,
              task.arguments == [description.interpreter, script.path] + description.options else { return nil }
        return description.entry
    }

    private struct AppleTask {
        let source: ScheduledTask.Source
        let executable: String
        let arguments: [String]
        let entry: Entry

        var directory: String { source == .systemLaunchd ? "LaunchDaemons" : "LaunchAgents" }

        init(_ executable: String, arguments: [String]? = nil, agent: Bool = false, entry: Entry) {
            source = agent ? .userLaunchd : .systemLaunchd
            self.executable = executable
            self.arguments = arguments ?? [executable]
            self.entry = entry
        }
    }

    private struct MT5Task {
        let interpreter: String
        let script: String
        let options: [String]
        let entry: Entry

        init(_ script: String, interpreter: String = "/usr/bin/python3", options: [String] = [], entry: Entry) {
            self.interpreter = interpreter
            self.script = script
            self.options = options
            self.entry = entry
        }
    }

    private static func reference(_ title: String, _ address: String) -> Source? {
        URL(string: address).map { Source(title: title, url: $0) }
    }

    // Match the system definition and its complete argument vector before interpreting a job.
    private static let appleTasks: [String: AppleTask] = [
        "com.apple.csrutil.report": AppleTask("/usr/bin/csrutil", arguments: ["/usr/bin/csrutil", "report"],
            entry: Entry(type: "macOS 系统安全报告",
                         role: "运行 Apple 的 csrutil report，用于系统完整性保护（SIP）相关报告。SIP 保护关键系统文件免遭未经授权的修改。",
                         exitImpact: "停用这条任务会跳过定期报告。SIP 本身由独立的系统安全策略管理。",
                         source: reference("Apple 系统完整性保护", "https://support.apple.com/en-sg/102149"))),
        "com.apple.bsd.dirhelper": AppleTask("/usr/libexec/dirhelper",
            entry: Entry(type: "macOS 目录维护",
                         role: "为系统和用户创建需要特权的专用目录，并维护部分临时目录。",
                         exitImpact: "目录维护可能延迟，依赖此服务的应用可能无法准备所需目录。",
                         source: reference("Apple dirhelper 源码", "https://github.com/apple-oss-distributions/system_cmds/blob/system_cmds-550.10/dirhelper.tproj/dirhelper.c"))),
        "com.apple.corecaptured": AppleTask("/usr/libexec/corecaptured",
            entry: Entry(type: "macOS 无线网络诊断",
                         role: "当系统报告 Wi-Fi 故障时，协助收集用于诊断的无线网络日志。",
                         exitImpact: "无线故障发生时，相关日志可能无法完整收集。", source: nil)),
        "com.apple.geoanalyticsd": AppleTask("/System/Library/PrivateFrameworks/GeoAnalytics.framework/geoanalyticsd", agent: true,
            entry: Entry(type: "macOS 地理分析任务",
                         role: "运行 Apple GeoAnalytics 框架的后台分析程序。",
                         exitImpact: "该框架的定期分析任务可能跳过。", source: nil)),
        "com.apple.gkreport": AppleTask("/usr/libexec/gkreport",
            entry: Entry(type: "macOS Gatekeeper 报告",
                         role: "运行 Gatekeeper 相关的定期报告任务。Gatekeeper 会检查从外部下载的软件。",
                         exitImpact: "停用会跳过此定期报告。应用启动检查由 Gatekeeper 的安全机制负责。",
                         source: reference("Apple Gatekeeper 与运行时保护", "https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web"))),
        "com.apple.locate": AppleTask("/usr/libexec/locate.updatedb",
            entry: Entry(type: "macOS 文件名索引维护",
                         role: "更新终端 locate 命令使用的文件名数据库。",
                         exitImpact: "locate 搜索结果可能过时，缺少数据库时查询可能失败。",
                         source: reference("Apple locate.updatedb 手册", "https://github.com/apple-oss-distributions/shell_cmds/blob/main/locate/locate/locate.updatedb.8"))),
        "com.apple.locationd": AppleTask("/usr/libexec/locationd",
            entry: Entry(type: "macOS 定位服务",
                         role: "获取地理位置，管理应用和系统组件请求定位时的授权。",
                         exitImpact: "依赖定位的应用或系统功能可能暂时无法取得位置。",
                         source: reference("Apple 定位服务设置", "https://support.apple.com/en-afri/guide/mac-help/mh35873/mac"))),
        "com.apple.loginwindow.LWWeeklyMessageTracer": AppleTask("/System/Library/CoreServices/loginwindow.app/Contents/Resources/LWAnalytics", agent: true,
            entry: Entry(type: "macOS 登录窗口分析",
                         role: "按计划运行登录窗口组件附带的 LWAnalytics 分析程序。",
                         exitImpact: "停用会跳过此登录窗口分析任务。", source: nil)),
        "com.apple.logkextloadsd": AppleTask("/usr/libexec/logkextloadsd", arguments: [],
            entry: Entry(type: "macOS 内核扩展日志",
                         role: "记录系统加载内核扩展的相关信息。",
                         exitImpact: "部分内核扩展加载记录可能缺失，影响故障排查。", source: nil)),
        "com.apple.systemstats.daily": AppleTask("/usr/sbin/systemstats", arguments: ["/usr/sbin/systemstats", "--daily"],
            entry: Entry(type: "macOS 系统统计",
                         role: "运行每日系统统计处理，涉及系统耗电等运行指标。",
                         exitImpact: "定期统计结果可能缺失。", source: nil)),
        "com.apple.timed": AppleTask("/usr/libexec/timed",
            entry: Entry(type: "macOS 时间同步",
                         role: "将 Mac 的系统时钟与参考时钟同步。",
                         exitImpact: "时钟可能逐渐偏离准确时间，影响依赖时间戳的应用或服务。",
                         source: reference("Apple 自动设置日期和时间", "https://support.apple.com/guide/mac-help/set-the-date-and-time-automatically-mchlp2996/mac"))),
        "com.apple.newsyslog": AppleTask("/usr/sbin/newsyslog",
            entry: Entry(type: "macOS 日志轮换",
                         role: "按配置归档和轮换符合条件的系统日志文件。",
                         exitImpact: "相关日志可能继续增大，延迟归档。", source: nil)),
        "com.apple.atrun": AppleTask("/usr/libexec/atrun",
            entry: Entry(type: "macOS at 任务队列",
                         role: "运行通过 at 排入队列且已到执行时间的命令。",
                         exitImpact: "队列中到期的命令可能一直等待，直至安排它们的服务再次运行。",
                         source: reference("Apple atrun 手册", "https://github.com/apple-oss-distributions/system_cmds/blob/main/atrun/atrun.8"))),
        "com.apple.tmp_cleaner": AppleTask("/usr/libexec/tmp_cleaner",
            entry: Entry(type: "macOS 临时文件清理",
                         role: "清理系统临时目录 /tmp 中长期未更新的内容。",
                         exitImpact: "符合清理条件的临时文件可能占用磁盘更久。", source: nil))
    ]

    private static let mt5Tasks: [String: MT5Task] = [
        "local.mt5.keepalive": MT5Task("scripts/mt5_keepalive.py",
            entry: Entry(type: "MT5 守护",
                         role: "检查 MT5 终端是否运行，发现退出时尝试重新启动，并检查交易环境状态。",
                         exitImpact: "这条规则将停止自动拉起 MT5，关联的状态检查也会暂停。", source: nil)),
        "local.mt5.daemon": MT5Task("scripts/mt5_daemon.py", options: ["--live"],
            entry: Entry(type: "MT5 交易自动化",
                         role: "按计划检查信号和持仓，记录状态变化，并在满足脚本条件时向 MT5 提交交易指令。",
                         exitImpact: "此脚本的定期检查、交易指令和相关通知将暂停。", source: nil)),
        "local.mt5.api": MT5Task("bridge/mt5_api_server.py",
            entry: Entry(type: "MT5 本地接口",
                         role: "提供连接 MT5 的 HTTP 接口，供本机脚本读取终端状态和传递指令。",
                         exitImpact: "依赖这条接口的监测和自动化脚本可能暂时无法访问 MT5。", source: nil)),
        "local.mt5.summary": MT5Task("scripts/mt5_daily_summary.sh", interpreter: "/bin/bash",
            entry: Entry(type: "MT5 日报",
                         role: "汇总当天的持仓和交易运行记录，生成 MT5 日报。",
                         exitImpact: "停用这条规则会跳过对应日期的日报生成。", source: nil))
    ]
}

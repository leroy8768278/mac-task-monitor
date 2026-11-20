import SwiftUI

struct TaskDetails: View {
    let task: ScheduledTask

    var body: some View {
        let knowledge = TaskKnowledge.lookup(task)
        let timing = TaskTimingExplanation(task: task)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("任务说明")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let knowledge {
                    StatusPill(title: knowledge.type).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let source = knowledge?.source {
                    Link(source.title, destination: source.url)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .help("在浏览器打开说明来源")
                }
            }

            DetailLine(label: "任务内容", value: knowledge?.role ?? commandDescription)
            DetailLine(label: "何时执行", value: timing.trigger)
            DetailLine(label: "当前状态", value: timing.status)
            if let knowledge {
                DetailLine(label: "停用影响", value: knowledge.exitImpact)
            }
            if let result = timing.exitResult {
                DetailLine(label: "上次结果", value: result)
            }

            Divider()

            DetailLine(label: "触发规则", value: task.schedule)
            if !task.command.isEmpty { DetailLine(label: "执行命令", value: task.command) }
            if let path = task.path { DetailLine(label: "配置路径", value: path) }
            if let domain = task.domain { DetailLine(label: "launchd 域", value: domain) }
            if let pid = task.pid { DetailLine(label: "进程 PID", value: String(pid)) }
        }
        .padding(13)
    }

    private var commandDescription: String {
        if task.source == .cron {
            return "到达计划时间时，cron 会把下方命令交给配置的 shell 执行。涉及脚本时，具体操作由脚本决定。"
        }
        guard let executable = task.executable, let name = executable.split(separator: "/").last else {
            return "已读取任务标签。当前可见记录里缺少执行命令，暂时无法确认具体操作。"
        }

        let operands = task.arguments.dropFirst()
        if executable == "/usr/bin/open", operands.count == 2,
           operands.first == "-a", let app = operands.last {
            return "触发后，请求 macOS 打开应用「\(app)」。"
        }
        if executable == "/usr/bin/shortcuts", operands.count == 2,
           operands.first == "run", let shortcut = operands.last {
            return "触发后，运行快捷指令「\(shortcut)」。实际步骤由该快捷指令定义。"
        }
        if ["/bin/sh", "/bin/bash", "/bin/zsh"].contains(executable),
           let option = operands.first, ["-c", "-lc", "-cl", "-ic", "-ci"].contains(option) {
            return "使用「\(name)」解释执行配置中的命令。执行步骤由下方命令决定。"
        }
        if ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/osascript"].contains(executable),
           let script = operands.first, !script.hasPrefix("-"), let scriptName = script.split(separator: "/").last {
            return "使用「\(name)」运行脚本「\(scriptName)」。具体操作由脚本内容决定。"
        }
        return "触发后启动「\(name)」。当前配置能够确认启动入口，程序内部的操作尚待确认。"
    }
}

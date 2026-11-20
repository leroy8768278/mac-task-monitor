import Foundation

struct ProcessObservation: Sendable {
    let origin: String
    let context: String?
    let resources: String
    let stateNote: String?

    init(process: RunningProcess, parent: RunningProcess?) {
        origin = Self.executableLocation(process.command)
        let details = [Self.bundleContext(process.command), Self.parentContext(process, parent: parent)].compactMap { $0 }
        context = details.isEmpty ? nil : details.joined(separator: "。") + "。"
        resources = Self.resourceContext(process)
        stateNote = Self.stateContext(process.stateCode.first)
    }

    private static func executableLocation(_ command: String) -> String {
        if command.isEmpty { return "当前记录没有可执行文件路径" }
        if command.dropFirst().hasPrefix(":\\") || command.dropFirst().hasPrefix(":/") {
            return "Windows 格式的可执行路径"
        }
        guard command.hasPrefix("/") else { return "当前记录仅含命令名" }

        let dataMount = "/System/Volumes/Data"
        let path = command.hasPrefix(dataMount + "/") ? String(command.dropFirst(dataMount.count)) : command
        let components = path.split(separator: "/")
        guard !components.contains("..") else { return "本机可执行路径" }

        if path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/") {
            return "macOS 系统目录"
        }
        if ["/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"].contains(where: path.hasPrefix) {
            return "macOS 系统命令目录"
        }
        if ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Homebrew/"].contains(where: path.hasPrefix) {
            return "Homebrew 安装目录"
        }
        if ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: path.hasPrefix) {
            return "临时或缓存目录"
        }
        if (path.hasPrefix("/Users/") && components.dropFirst(2).first == "Applications")
            || path.hasPrefix("/Applications/") {
            return "应用程序目录"
        }
        if path.hasPrefix("/Library/PrivilegedHelperTools/") { return "系统级辅助工具目录" }
        if path.hasPrefix("/Library/Developer/") { return "开发工具目录" }
        if path.hasPrefix("/Library/") { return "共享 Library 目录" }
        if path.hasPrefix("/Users/") { return "用户目录" }
        if path.hasPrefix("/Volumes/") { return "已挂载卷内的路径" }
        return "本机可执行路径"
    }

    private static func bundleContext(_ command: String) -> String? {
        guard command.hasPrefix("/") else { return nil }
        let directories = command.split(separator: "/").dropLast()
        guard !directories.contains(".."),
              let appIndex = directories.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }

        let app = directories[appIndex].dropLast(4)
        let bundle = directories.dropFirst(appIndex + 1).last(where: {
            let name = $0.lowercased()
            return name.hasSuffix(".app") || name.hasSuffix(".xpc") || name.hasSuffix(".appex")
        })
        if let bundle {
            let name = bundle.lowercased()
            if name.hasSuffix(".xpc") { return "位于「\(app)」的 XPC 服务包「\(bundle.dropLast(4))」内" }
            if name.hasSuffix(".appex") { return "位于「\(app)」的应用扩展「\(bundle.dropLast(6))」内" }
            return "位于「\(app)」的子应用「\(bundle.dropLast(4))」内"
        }
        return "位于「\(app)」的应用包内"
    }

    private static func parentContext(_ process: RunningProcess, parent: RunningProcess?) -> String? {
        guard let parent, parent.pid > 0, parent.pid == process.parentPID, parent.pid != process.pid else {
            return nil
        }
        return "当前父进程为「\(parent.name)」"
    }

    private static func resourceContext(_ process: RunningProcess) -> String {
        let cpu: String
        if process.cpuPercent < 1 {
            cpu = "近期 CPU 占用低于单个逻辑核心的 1%"
        } else {
            let cores = (process.cpuPercent / 100).formatted(.number.precision(.fractionLength(0...2)))
            cpu = "近期 CPU 占用约为 \(cores) 个逻辑核心"
        }

        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        if process.residentBytes == 0 {
            return "\(cpu)。系统报告的驻留内存为 0。"
        }
        guard memoryBytes > 0 else { return "\(cpu)。" }

        let ratio = Double(process.residentBytes) / Double(memoryBytes)
        let memory = ratio < 0.001 ? "不到 0.1%" : "约为 \(ratio.formatted(.percent.precision(.fractionLength(1))))"
        return "\(cpu)。驻留内存占本机物理内存的比例\(memory)，含共享页。"
    }

    private static func stateContext(_ code: Character?) -> String? {
        switch code {
        case "I": return "进程处于较长时间的休眠。"
        case "R": return "进程正在运行或等待 CPU 调度。"
        case "S": return "进程正在休眠，等待事件或资源。"
        case "T": return "进程已暂停，恢复后可继续执行。"
        case "U": return "进程正在等待内核操作完成。"
        case "Z": return "进程已退出，正等待父进程回收退出状态。"
        default: return nil
        }
    }
}

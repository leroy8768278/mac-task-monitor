import Foundation

enum ProcessKnowledge {
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

    static func lookup(_ process: RunningProcess) -> Entry? {
        let command = process.command
        if process.pid == 0 && process.uid == 0 && ["kernel_task", "(kernel_task)", "[kernel_task]"].contains(command) {
            return kernelTask
        }

        // Wine can report escaped or repeated separators in its Windows executable path.
        let windowsPath = command.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .joined(separator: "/")
        if windowsPath.caseInsensitiveCompare("C:/Program Files/MetaTrader 5/terminal64.exe") == .orderedSame,
           command.hasPrefix("C:") || command.hasPrefix("c:") {
            return metaTraderTerminal
        }

        guard command.hasPrefix("/") else { return nil }
        let path = (command as NSString).standardizingPath
        if path == "/sbin/launchd", process.pid == 1, process.uid == 0 { return launchd }
        if let systemEntry = systemEntries[path] { return systemEntry }

        if Bundle.main.bundleIdentifier == "local.mactaskmonitor.app",
           let executable = Bundle.main.executableURL,
           path == (executable.path as NSString).standardizingPath {
            return taskMonitor
        }

        if let appPath = appRelativePath(path, bundle: "Google Chrome") { return chromeEntry(appPath) }
        for bundle in ["ChatGPT", "Codex"] {
            if let appPath = appRelativePath(path, bundle: bundle) { return codexEntry(appPath, bundle: bundle) }
        }
        if let appPath = appRelativePath(path, bundle: "MetaTrader 5") {
            switch appPath {
            case "MacOS/MetaTrader 5": return metaTraderLauncher
            case "SharedSupport/wine/bin/wineserver": return wineServer
            default: break
            }
        }
        return nil
    }

    private static func appRelativePath(_ path: String, bundle: String) -> Substring? {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        for directory in ["/Applications", "/System/Volumes/Data/Applications", userApps] {
            let prefix = "\(directory)/\(bundle).app/Contents/"
            if path.hasPrefix(prefix) { return path.dropFirst(prefix.count) }
        }
        return nil
    }

    private static func frameworkHelperPath(_ path: Substring, framework: String) -> Substring? {
        let prefix = "Frameworks/\(framework).framework/Versions/"
        guard path.hasPrefix(prefix) else { return nil }
        let remaining = path.dropFirst(prefix.count)
        guard let slash = remaining.firstIndex(of: "/") else { return nil }
        let version = remaining[..<slash]
        guard version == "Current" || (!version.isEmpty && version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })) else { return nil }
        let helpers = remaining.dropFirst(version.count + 1)
        return helpers.hasPrefix("Helpers/") ? helpers.dropFirst("Helpers/".count) : nil
    }

    private static func helperName(_ path: Substring) -> String? {
        guard let name = path.split(separator: "/").last, path == "\(name).app/Contents/MacOS/\(name)" else { return nil }
        return String(name)
    }

    private static func chromeEntry(_ path: Substring) -> Entry? {
        if path == "MacOS/Google Chrome" {
            return Entry(type: "浏览器主进程", role: "管理 Chrome 的窗口、标签页和各类子进程。",
                         exitImpact: "Chrome 窗口和浏览会话会中断，正在下载或填写的内容可能丢失。", source: chromiumArchitecture)
        }
        guard let helperPath = frameworkHelperPath(path, framework: "Google Chrome Framework") else { return nil }
        if helperPath == "chrome_crashpad_handler" { return crashpad }
        switch helperName(helperPath) {
        case "Google Chrome Helper (Renderer)", "Google Chrome Helper (Aperitif Renderer)":
            return Entry(type: "浏览器渲染进程", role: "处理网页内容、页面布局和脚本。多个页面或子框架可能共用一个进程。",
                         exitImpact: "受影响的标签页或页面区域可能崩溃，通常需要重新加载。", source: chromiumArchitecture)
        case "Google Chrome Helper (GPU)", "Google Chrome Helper (Aperitif GPU)":
            return Entry(type: "浏览器图形进程", role: "为 Chrome 处理 GPU 加速和图形渲染。",
                         exitImpact: "部分页面、视频或图形加速可能短暂异常。", source: chromiumArchitecture)
        case "Google Chrome Helper (Alerts)", "Google Chrome Helper (Aperitif Alerts)":
            return Entry(type: "浏览器通知辅助进程", role: "为 Chrome 提供 macOS 通知相关支持。",
                         exitImpact: "Chrome 的部分通知可能暂时无法显示。", source: source("Chromium macOS 辅助程序", "https://chromium.googlesource.com/chromium/src/+/079ad5b81506fb387ec158e184ff95535c3b9f92/chrome/installer/mac/signing/parts.py"))
        case "Google Chrome Helper", "Google Chrome Helper (Aperitif)":
            return Entry(type: "浏览器辅助进程", role: "运行 Chrome 的独立辅助任务。这个通用可执行文件可承载多种服务。",
                         exitImpact: "影响取决于正在运行的服务，相关浏览器功能可能短暂中断。", source: chromiumArchitecture)
        default: return nil
        }
    }

    private static func codexEntry(_ path: Substring, bundle: String) -> Entry? {
        if path == "MacOS/\(bundle)" {
            return Entry(type: "OpenAI 桌面应用", role: "运行 ChatGPT 或 Codex 的桌面界面和本地应用功能。",
                         exitImpact: "桌面窗口会关闭，依赖桌面端的本地操作可能中断。", source: codexApp)
        }
        if path == "Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" || path == "Resources/codex" {
            return Entry(type: "Codex 后台程序", role: "运行随桌面应用分发的 Codex 本地程序。",
                         exitImpact: "由这一实例执行的本地任务可能中断。", source: source("Codex CLI", "https://learn.chatgpt.com/docs/codex/cli"))
        }
        guard let helperPath = frameworkHelperPath(path, framework: "Codex Framework") else { return nil }
        if helperPath == "browser_crashpad_handler" { return crashpad }
        switch helperName(helperPath) {
        case "Codex (Renderer)", "Codex (Aperitif Renderer)":
            return Entry(type: "OpenAI 界面渲染进程", role: "为桌面应用渲染界面内容。",
                         exitImpact: "相关界面可能空白或需要重新打开。", source: nil)
        case "Codex (GPU)", "Codex (Aperitif GPU)":
            return Entry(type: "OpenAI 图形辅助进程", role: "为桌面应用提供图形渲染支持。",
                         exitImpact: "相关界面的显示可能短暂异常。", source: nil)
        case "Codex (Aperitif)", "Codex (Service)", "Codex (Alerts)", "Codex (Aperitif Alerts)":
            return Entry(type: "OpenAI 桌面辅助进程", role: "为桌面应用提供后台支持。具体职责取决于该实例加载的服务。",
                         exitImpact: "依赖该实例的界面或后台操作可能中断。", source: nil)
        default: return nil
        }
    }

    private static func source(_ name: String, _ url: String) -> Source? {
        URL(string: url).map { Source(title: name, url: $0) }
    }

    private static let chromiumArchitecture = source("Chromium 多进程架构", "https://www.chromium.org/developers/design-documents/multi-process-architecture/")
    private static let codexApp = source("OpenAI 桌面应用文档", "https://learn.chatgpt.com/docs/app")
    private static let metaTraderMac = source("MetaTrader 5 macOS 安装文档", "https://www.metatrader5.com/en/terminal/help/start_advanced/install_mac")
    private static let sessionLifecycle = source("Apple macOS 会话与守护进程", "https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/Lifecycle.html")

    private static let crashpad = Entry(type: "崩溃报告进程", role: "捕获应用异常并记录崩溃报告。",
                                        exitImpact: "后续崩溃的诊断信息可能无法完整记录。",
                                        source: source("Crashpad handler", "https://chromium.googlesource.com/crashpad/crashpad/+/HEAD/handler/crashpad_handler.md"))
    private static let metaTraderLauncher = Entry(type: "MT5 macOS 启动程序", role: "启动通过 Wine 运行的 MetaTrader 5 终端。",
                                                  exitImpact: "从应用正常退出会结束本机 MT5 会话。单独停止启动程序的影响取决于终端是否仍在运行。", source: metaTraderMac)
    private static let metaTraderTerminal = Entry(type: "MT5 交易终端", role: "此路径对应 Wine 中的 MT5 终端，负责行情、图表和本地交易程序。",
                                                  exitImpact: "本机终端和在其中运行的 EA 会停止。依赖客户端的移动止损也会暂停。",
                                                  source: source("MetaTrader 5 交易机制", "https://www.metatrader5.com/en/terminal/help/trading/general_concept"))
    private static let wineServer = Entry(type: "MT5 Wine 服务", role: "为使用这一 Wine 环境的程序提供类似 Windows 内核的共享服务。",
                                          exitImpact: "同一 Wine 环境内的 MT5 等程序可能一起中断。",
                                          source: source("Wine wineserver 手册", "https://github.com/wine-mirror/wine/blob/master/server/wineserver.man.in"))
    private static let taskMonitor = Entry(type: "Mac 任务台", role: "运行设备、任务和进程监测界面，或执行后台应用守护。",
                                           exitImpact: "根据运行模式，监测界面会关闭，或这一实例的后台守护会中断。", source: nil)
    private static let launchd = Entry(type: "macOS 核心进程", role: "系统启动后的第一个用户态进程，负责启动和管理系统服务、用户代理及 XPC 服务。",
                                       exitImpact: "系统依赖此进程维持运行。它退出会造成严重的系统故障。", source: sessionLifecycle)
    private static let kernelTask = Entry(type: "macOS 内核任务", role: "代表内核的后台工作，也参与 CPU 温度管理。",
                                          exitImpact: "内核任务属于系统的核心运行机制，不能像普通应用一样退出。",
                                          source: source("Apple kernel_task 说明", "https://support.apple.com/en-us/102172"))

    private static let windowServer = Entry(type: "macOS 图形会话服务", role: "管理窗口、合成桌面画面并传递界面输入事件。",
                                            exitImpact: "可能中断图形会话并返回登录界面，未保存的工作可能丢失。",
                                            source: source("Apple Quartz Window Services", "https://developer.apple.com/documentation/coregraphics/quartz-window-services"))
    private static let assistant = Entry(type: "macOS Siri 服务", role: "在后台支持 Siri 功能。",
                                         exitImpact: "正在执行的 Siri 请求可能中断，Siri 功能可能暂时不可用。",
                                         source: source("Apple 在 Mac 上使用 Siri", "https://support.apple.com/guide/mac-help/mchlb66b4ad6/mac"))
    private static let audioRegistrar = Entry(type: "macOS 音频组件服务", role: "协助注册和查找 Audio Unit、编解码器等音频组件。",
                                              exitImpact: "音频软件可能暂时无法发现或加载部分组件。",
                                              source: source("Apple Audio Components", "https://developer.apple.com/documentation/audiotoolbox/audio-components"))
    private static let wifiDriver = Entry(type: "macOS Wi-Fi 驱动", role: "Apple DriverKit 系统扩展，负责受支持无线网卡的联网。",
                                           exitImpact: "Wi-Fi 可能断开，正在使用无线网络的连接可能中断。",
                                           source: source("Apple DriverKit", "https://developer.apple.com/documentation/driverkit"))

    // System entries use exact executable paths so a same-named user process does not pick up their descriptions.
    private static let systemEntries: [String: Entry] = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer": windowServer,
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer": windowServer,
        "/System/Library/Frameworks/CoreGraphics.framework/Resources/WindowServer": windowServer,
        "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Support/assistantd": assistant,
        "/System/Library/PrivateFrameworks/AssistantServices.framework/Support/assistantd": assistant,
        "/System/Library/Frameworks/AudioToolbox.framework/AudioComponentRegistrar": audioRegistrar,
        "/System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioComponentRegistrar": audioRegistrar,
        "/System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext/com.apple.DriverKit-AppleBCMWLAN": wifiDriver,
        "/usr/libexec/opendirectoryd": Entry(type: "macOS 目录服务", role: "查询本地和网络目录，提供账户、组和身份验证服务。",
                                            exitImpact: "登录验证、用户查询和依赖目录的功能可能暂时失败。",
                                            source: source("Apple 目录实用工具", "https://support.apple.com/guide/directory-utility/diru7606aa37/mac")),
        "/usr/sbin/systemsoundserverd": Entry(type: "macOS 系统音频服务", role: "为 Core Audio 提供系统声音相关的后台支持。",
                                             exitImpact: "部分系统声音可能暂时无法播放。", source: nil),
        "/usr/sbin/coreaudiod": Entry(type: "macOS 核心音频服务", role: "支持音频设备与应用的声音输入和输出。",
                                      exitImpact: "正在进行的音频播放、录制或通话可能短暂中断。", source: nil),
        "/usr/sbin/mDNSResponder": Entry(type: "macOS 网络名称服务", role: "处理 DNS 名称解析，并通过 Bonjour 发现本地网络服务。",
                                         exitImpact: "域名查询和局域网设备发现可能暂时失败。",
                                         source: source("Apple mDNSResponder", "https://github.com/apple-oss-distributions/mDNSResponder")),
        "/usr/sbin/bluetoothd": Entry(type: "macOS 蓝牙服务", role: "为蓝牙设备发现与连接提供后台支持。",
                                      exitImpact: "蓝牙键鼠、耳机和其他设备可能断开。", source: nil),
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow":
            Entry(type: "macOS 登录会话", role: "管理登录界面、用户会话，以及注销、重启和关机流程。",
                  exitImpact: "可能中断当前会话，导致正在运行的应用关闭。", source: sessionLifecycle),
        "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder":
            Entry(type: "macOS 文件管理器", role: "显示桌面、文件窗口和已挂载磁盘。",
                  exitImpact: "Finder 窗口和正在进行的文件操作可能中断。", source: sessionLifecycle),
        "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock":
            Entry(type: "macOS 桌面组件", role: "显示程序坞并支持应用切换、调度中心和桌面空间。",
                  exitImpact: "程序坞和相关桌面切换功能可能暂时消失。", source: sessionLifecycle),
        "/System/Library/CoreServices/powerd.bundle/powerd":
            Entry(type: "macOS 电源管理服务", role: "负责电源设置及与系统休眠相关的后台管理。",
                  exitImpact: "休眠或电源策略可能暂时无法正常应用。", source: nil),
        "/usr/libexec/logd": Entry(type: "macOS 统一日志服务", role: "收集、处理和保存系统及应用的统一日志。",
                                    exitImpact: "这段时间的诊断日志可能缺失。",
                                    source: source("Apple Logging", "https://developer.apple.com/documentation/os/logging")),
        "/usr/sbin/cfprefsd": Entry(type: "macOS 偏好设置服务", role: "为系统和应用处理偏好设置的读取与写入。",
                                    exitImpact: "应用设置的读取或同步可能短暂中断。", source: nil),
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds":
            Entry(type: "macOS 搜索索引服务", role: "维护 Spotlight 的文件元数据索引。",
                  exitImpact: "Spotlight 结果可能暂时不完整，索引更新可能中断。", source: nil),
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd":
            Entry(type: "macOS 文件事件服务", role: "记录文件系统变化，为索引和备份等功能提供变更通知。",
                  exitImpact: "依赖文件事件的应用可能推迟处理最近的变更。",
                  source: source("Apple 文件系统事件", "https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html"))
    ]
}

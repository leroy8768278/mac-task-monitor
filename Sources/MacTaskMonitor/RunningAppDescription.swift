import Foundation

struct RunningAppDescription: Sendable {
    let purpose: String
    let sourceLabel: String
    let sourceURL: URL?

    static func resolve(_ app: RunningApp) -> Self {
        resolve(name: app.name, bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL)
    }

    static func resolve(name: String, bundleIdentifier: String?, bundleURL: URL?) -> Self {
        let bundle = localBundle(at: bundleURL, matching: bundleIdentifier)
        let identifier = bundleIdentifier ?? bundle?.bundleIdentifier

        if let key = identifier?.lowercased(), let purpose = knownPurposes[key] {
            let reference = references[key]
            return Self(purpose: purpose, sourceLabel: reference?.title ?? "内置软件说明",
                        sourceURL: reference.flatMap { URL(string: $0.url) })
        }

        if let bundle, let purpose = localPurpose(bundle, appName: name) {
            return Self(purpose: purpose, sourceLabel: "本机软件包提供的简介", sourceURL: nil)
        }

        if let identifier = bundle?.infoDictionary?["LSApplicationCategoryType"] as? String,
           let category = categoryName(identifier) {
            return Self(purpose: "软件包标注为「\(category)」类，具体用途未确认。",
                        sourceLabel: "本机软件包的 App Store 类别", sourceURL: nil)
        }

        return Self(purpose: "暂未确认「\(name)」的具体用途。",
                    sourceLabel: identifier.map { "本机软件包标识 \($0)" } ?? "本机软件名称",
                    sourceURL: nil)
    }

    private static func localBundle(at url: URL?, matching identifier: String?) -> Bundle? {
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url) else { return nil }
        if let identifier, bundle.bundleIdentifier?.caseInsensitiveCompare(identifier) != .orderedSame {
            return nil
        }
        return bundle
    }

    private static func localPurpose(_ bundle: Bundle, appName: String) -> String? {
        // Only use fields specifically labeled as descriptions of the app itself.
        let fields = ["CFBundleDescription", "CFBundleShortDescription", "NSApplicationDescription", "ApplicationDescription", "AppDescription"]
        for field in fields {
            for value in [bundle.localizedInfoDictionary?[field], bundle.infoDictionary?[field]] {
                guard let raw = value as? String else { continue }
                let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let lower = text.lowercased()
                guard (4...280).contains(text.count),
                      text.caseInsensitiveCompare(appName) != .orderedSame,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      !lower.hasPrefix("http://"), !lower.hasPrefix("https://"), !lower.hasPrefix("<"),
                      !nonPurposeText.contains(where: lower.contains),
                      !startsWithVersion(lower) else { continue }
                return text
            }
        }
        return nil
    }

    private static func startsWithVersion(_ text: String) -> Bool {
        ["version ", "版本 ", "版本", "v"].contains { prefix in
            text.hasPrefix(prefix) && text.dropFirst(prefix.count).first?.isNumber == true
        }
    }

    private static let nonPurposeText = [
        "copyright", "©", "all rights reserved", "版权所有", "保留所有权利",
        "what's new", "what’s new", "release notes", "changelog", "bug fixes", "fixed an issue",
        "performance improvements", "update available", "new version available", "更新日志", "版本更新", "修复了", "性能改进",
        "would like to access", "needs access to", "permission to access", "requires permission",
        "grant access", "allow access", "允许访问", "需要访问", "请求访问", "授权访问", "访问权限"
    ]

    private static func categoryName(_ identifier: String) -> String? {
        let prefix = "public.app-category."
        guard identifier.hasPrefix(prefix) else { return nil }
        let name = String(identifier.dropFirst(prefix.count))
        if name.hasSuffix("-games") { return "游戏" }
        return categories[name]
    }

    private static let categories = [
        "books": "图书", "business": "商务", "developer-tools": "开发工具", "education": "教育",
        "entertainment": "娱乐", "finance": "财务", "games": "游戏", "graphics-design": "图形与设计",
        "healthcare-fitness": "健康与健身", "lifestyle": "生活方式", "medical": "医疗", "music": "音乐",
        "news": "新闻", "photography": "摄影", "productivity": "效率", "reference": "参考资料",
        "social-networking": "社交", "sports": "体育", "travel": "旅行", "utilities": "实用工具",
        "video": "视频", "weather": "天气"
    ]

    private static let knownPurposes = [
        "com.apple.finder": "macOS 的文件管理器，用于浏览磁盘和文件夹，以及复制、移动和整理文件。",
        "com.google.chrome": "网页浏览器，用于打开网站、管理标签页和书签，以及下载文件。",
        "com.openai.chat": "ChatGPT 的桌面应用，用于与 AI 对话、提问、写作和分析文件。",
        "com.openai.codex": "OpenAI 桌面应用，提供 Codex 编程协作，可阅读、修改和验证代码，并协助处理本地项目任务。",
        "net.metaquotes.wine.metatrader5": "MetaTrader 5 的 macOS 客户端，用于查看行情和图表，并在交易终端中管理交易、运行指标和自动化程序。",
        "local.mactaskmonitor.app": "查看运行中的应用、进程、计划任务和设备状态，并管理应用守护。",
        "pro.betterdisplay.betterdisplay": "显示器管理工具，用于调整分辨率、缩放和亮度，并管理显示器和虚拟屏幕。",
        "com.jetbrains.pycharm": "Python 开发环境，用于编辑、运行、调试和测试 Python 项目。",
        "com.jetbrains.pycharm.ce": "Python 开发环境，用于编辑、运行、调试和测试 Python 项目。",
        "com.tencent.xinwechat": "微信桌面版，用于收发消息、参加群聊，以及传输文件。",
        "com.tencent.qq": "QQ 桌面客户端，用于即时聊天、群聊和传输文件。",
        "com.bot.neotix.doubao": "豆包桌面应用，用于 AI 对话、提问和辅助处理文本。",
        "com.bytedance.macos.feishu": "飞书桌面客户端，用于团队沟通、开会和协作文档。",
        "com.microsoft.vscode": "代码编辑器，用于编辑项目文件、调试代码和通过扩展支持不同开发环境。",
        "com.microsoft.word": "撰写、排版和审阅文档，支持批注和修订。",
        "com.microsoft.excel": "通过电子表格整理数据、使用公式计算和制作图表。",
        "com.microsoft.powerpoint": "制作和播放演示文稿，可在幻灯片中编排文字、图表和视频。",
        "com.apple.iwork.pages": "创建、排版和协作编辑文稿。",
        "com.apple.iwork.numbers": "使用表格和公式整理数据，并通过图表呈现结果。",
        "com.apple.iwork.keynote": "设计幻灯片并播放演示文稿。",
        "com.google.android.studio": "Android 应用开发环境，用于编写代码、构建应用，以及在模拟器或设备上调试。",
        "com.sublimetext.4": "编辑文本和源代码，可跨文件搜索和批量修改。",
        "org.mozilla.firefox": "网页浏览器，用于访问网站、管理标签页和书签。",
        "org.videolan.vlc": "媒体播放器，用于播放本地音视频文件和网络媒体流。",
        "ru.keepcoder.telegram": "Telegram 的 Mac 客户端，用于收发消息、共享文件和浏览频道。",
        "com.apple.safari": "Apple 的网页浏览器，用于浏览网站、管理标签页和书签。",
        "com.apple.terminal": "macOS 的命令行终端，用于运行 shell、脚本和命令行工具，也可通过 SSH 连接远程计算机。",
        "com.apple.systempreferences": "管理 macOS 系统设置，包括网络、显示器、账户及隐私权限。",
        "com.apple.iphonesimulator": "Xcode 提供的设备模拟器，用于在 Mac 上运行和测试面向 Apple 移动设备的应用。",
        "com.apple.dt.xcode": "Apple 的开发环境，用于开发、构建、调试和测试 Apple 平台的应用。",
        "com.apple.activitymonitor": "查看 macOS 进程及其 CPU、内存、能耗、磁盘和网络使用情况。",
        "com.apple.notes": "记录和整理笔记，可保存清单、图片及附件。",
        "com.apple.ical": "管理日程、会议、邀请和日历提醒。",
        "com.apple.mobilesms": "在 Mac 上收发 iMessage，并查看支持转发的短信。",
        "com.apple.mail": "设置邮件账户和收发、搜索、整理电子邮件。",
        "com.apple.music": "播放和整理音乐，以及访问 Apple Music。",
        "com.apple.photos": "浏览、整理和编辑照片与视频。",
        "com.apple.preview": "查看 PDF 和图像，可添加标注、签名以及进行基础图像编辑。",
        "com.apple.textedit": "编辑纯文本和富文本文件。",
        "com.apple.appstore": "在 Mac App Store 中查找、下载和更新应用。",
        "com.apple.automator": "用可组合的操作建立自动化工作流程。",
        "com.apple.shortcuts": "创建和运行快捷指令，用于自动化重复操作。",
        "com.apple.reminders": "创建、整理和跟踪待办事项及提醒。",
        "com.apple.facetime": "通过 FaceTime 进行语音通话和视频通话。",
        "com.apple.maps": "查找地点、浏览地图和规划路线。",
        "com.apple.weather": "查看本地及其他地点的天气预报。",
        "com.apple.clock": "使用世界时钟、闹钟、秒表和计时器。",
        "com.apple.calculator": "执行常用数学运算和单位换算。",
        "com.apple.addressbook": "保存、查看和整理联系人及地址。",
        "com.apple.voicememos": "录制、管理和编辑语音备忘录。",
        "com.apple.passwords": "管理保存的密码、通行密钥和验证码。",
        "com.apple.quicktimeplayerx": "播放和修剪音视频，也可录制屏幕、声音或相机画面。",
        "com.apple.ibooksx": "阅读和整理电子书与有声读物。",
        "com.apple.podcasts": "收听、关注和管理播客节目。",
        "com.apple.stocks": "查看市场行情、自选股票及相关资讯。",
        "com.apple.dictionary": "在本机安装的词典中查找词义和用法。",
        "com.apple.testflight": "安装和体验通过 TestFlight 分发的测试版应用。",
        "com.colliderli.iina": "macOS 媒体播放器，用于播放本地视频和音频。"
    ]

    private static let references: [String: (title: String, url: String)] = [
        "com.google.chrome": ("Google Chrome 官方介绍", "https://www.google.com/chrome/"),
        "com.openai.codex": ("OpenAI 桌面应用文档", "https://developers.openai.com/codex/app"),
        "net.metaquotes.wine.metatrader5": ("MetaTrader 5 官方帮助", "https://www.metatrader5.com/en/terminal/help"),
        "pro.betterdisplay.betterdisplay": ("BetterDisplay 官方项目", "https://github.com/waydabber/BetterDisplay"),
        "com.jetbrains.pycharm": ("JetBrains PyCharm", "https://www.jetbrains.com/pycharm/")
    ]
}

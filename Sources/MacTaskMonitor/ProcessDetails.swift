import SwiftUI

struct ProcessDetails: View {
    let process: RunningProcess
    let parent: RunningProcess?

    var body: some View {
        let knowledge = ProcessKnowledge.lookup(process)
        let observation = ProcessObservation(process: process, parent: parent)

        MonitorCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text("进程说明 · \(process.name)").font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    StatusPill(title: knowledge?.type ?? observation.origin)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let source = knowledge?.source {
                        Link(source.title, destination: source.url)
                            .lineLimit(1)
                            .help("在浏览器打开说明来源")
                    }
                    if let searchURL {
                        Link(destination: searchURL) {
                            Label("联网搜索", systemImage: "magnifyingglass")
                        }
                        .fixedSize()
                        .help("在浏览器中按可执行文件名搜索")
                    }
                }
                .font(.system(size: 12))

                DetailLine(label: "主要作用", value: knowledge?.role ?? unknownRole(observation.context))
                DetailLine(label: "退出影响", value: knowledge?.exitImpact ?? "目前无法确认会影响哪些功能。")
                DetailLine(label: "当前占用", value: [observation.resources, observation.stateNote].compactMap { $0 }.joined(separator: " "))

                Divider()

                DetailLine(label: "可执行文件", value: process.command.isEmpty ? "—" : process.command)
                    .lineLimit(2)
                    .help(process.command)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    DetailLine(label: "父进程 PID", value: parentDescription)
                    if let seconds = process.elapsedSeconds {
                        DetailLine(label: "启动至今", value: elapsed(seconds))
                    }
                }
            }
        }
    }

    private var parentDescription: String {
        if let parent, process.parentPID > 0 { return "\(parent.pid) · \(parent.name)" }
        return String(process.parentPID)
    }

    private func unknownRole(_ context: String?) -> String {
        ["用途尚未确认。", context].compactMap { $0 }.joined(separator: " ")
    }

    private var searchURL: URL? {
        let name = process.name
        guard !process.command.isEmpty, !name.isEmpty, name.count <= 160,
              !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.bing.com"
        url.path = "/search"
        url.queryItems = [URLQueryItem(name: "q", value: "\(name) macOS process")]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }

    private func elapsed(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) 秒"
    }
}

import SwiftUI

enum MonitorTint {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.39, green: 0.86, blue: 0.73, alpha: 1)
            : NSColor(srgbRed: 0.00, green: 0.42, blue: 0.35, alpha: 1)
    })

    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.09, green: 0.11, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.97, alpha: 1)
    })

    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.07, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.92, green: 0.95, blue: 0.94, alpha: 1)
    })

    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.13, green: 0.15, blue: 0.17, alpha: 1) : .white
    })
}

struct MonitorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(MonitorTint.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(Color.primary.opacity(0.07))
                    .allowsHitTesting(false)
            }
    }
}

struct PageHeading<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.bottom, 5)
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = MonitorTint.accent

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.09), in: Capsule())
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

struct MonitorEmptyState: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(MonitorTint.accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

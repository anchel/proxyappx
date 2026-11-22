import AppKit
import ProxyAppXCore
import SwiftUI

/// 当前界面实际使用的语言（已考虑「设置 › 语言」里的覆盖），用于日期、时长等格式化。
enum AppLocale {
    static var localization: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var locale: Locale { Locale(identifier: localization) }
}

enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        var calendar = Calendar.current
        calendar.locale = AppLocale.locale
        f.calendar = calendar
        return f
    }()

    static func duration(from start: Date, to end: Date?) -> String {
        let seconds = max(0, (end ?? Date()).timeIntervalSince(start).rounded(.down))
        return durationFormatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct AppIcon: View {
    let path: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: AppInspector.icon(forPath: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// 规则动作的彩色标签。
struct ActionBadge: View {
    let text: String
    let color: Color

    init(action: RuleAction, servers: [ProxyServer]) {
        switch action {
        case let .proxy(id):
            text = servers.first { $0.id == id }?.name ?? String(localized: "Server missing")
            color = servers.contains { $0.id == id } ? .accentColor : .orange
        case .direct:
            text = String(localized: "Direct")
            color = .secondary
        case .block:
            text = String(localized: "Block")
            color = .red
        }
    }

    init(verdict: ConnectionVerdict, server: String?) {
        switch verdict {
        case .proxy: text = server ?? String(localized: "Proxy"); color = .accentColor
        case .direct: text = String(localized: "Direct"); color = .secondary
        case .block: text = String(localized: "Block"); color = .red
        case .fallbackDirect: text = String(localized: "Fell back to direct"); color = .orange
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// 空状态占位。
struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

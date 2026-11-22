import AppKit
import ProxyAppXCore
import SwiftUI

enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    static func duration(from start: Date, to end: Date?) -> String {
        let seconds = Int((end ?? Date()).timeIntervalSince(start))
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 时 \(seconds % 3600 / 60) 分"
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
            text = servers.first { $0.id == id }?.name ?? "服务器缺失"
            color = servers.contains { $0.id == id } ? .accentColor : .orange
        case .direct:
            text = "直连"
            color = .secondary
        case .block:
            text = "阻断"
            color = .red
        }
    }

    init(verdict: ConnectionVerdict, server: String?) {
        switch verdict {
        case .proxy: text = server ?? "代理"; color = .accentColor
        case .direct: text = "直连"; color = .secondary
        case .block: text = "阻断"; color = .red
        case .fallbackDirect: text = "回落直连"; color = .orange
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
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

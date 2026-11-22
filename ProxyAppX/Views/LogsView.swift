import AppKit
import ProxyAppXCore
import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var minLevel: LogEntry.Level = .info
    @State private var search = ""

    private var entries: [LogEntry] {
        model.monitor.logs.reversed().filter {
            $0.level >= minLevel && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(systemImage: "doc.plaintext", title: "暂无日志",
                               message: model.isRunning ? "扩展的事件会显示在这里。" : "代理未运行。")
            } else {
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Format.time.string(from: entry.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: icon(entry.level))
                            .foregroundStyle(color(entry.level))
                            .font(.caption)
                        Text(entry.message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("日志")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Picker("级别", selection: $minLevel) {
                Text("全部").tag(LogEntry.Level.debug)
                Text("信息").tag(LogEntry.Level.info)
                Text("警告").tag(LogEntry.Level.warning)
                Text("错误").tag(LogEntry.Level.error)
            }
            .pickerStyle(.menu)
            Button {
                let text = entries.reversed().map { "\(Format.time.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .disabled(entries.isEmpty)
            Button {
                Task { await model.monitor.clearLogs() }
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
    }

    private func icon(_ level: LogEntry.Level) -> String {
        switch level {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

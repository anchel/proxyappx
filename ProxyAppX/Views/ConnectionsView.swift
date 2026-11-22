import ProxyAppXCore
import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .active
    @State private var search = ""

    enum Mode: String, CaseIterable, Identifiable {
        case active = "活动", recent = "最近结束"
        var id: String { rawValue }
    }

    private var rows: [ConnectionSnapshot] {
        let base = mode == .active ? (model.monitor.snapshot?.active ?? []) : (model.monitor.snapshot?.recent ?? [])
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.appName.localizedCaseInsensitiveContains(search) || $0.target.localizedCaseInsensitiveContains(search)
                || $0.signingID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if !model.isRunning {
                EmptyStateView(systemImage: "pause.circle", title: "代理未运行", message: "启用后这里会实时显示被接管的连接。")
            } else if rows.isEmpty {
                EmptyStateView(systemImage: "arrow.left.arrow.right", title: mode == .active ? "暂无活动连接" : "暂无记录",
                               message: "只显示被代理或阻断的连接，以及命中「直连」规则的连接。")
            } else {
                table
            }
        }
        .navigationTitle("连接")
        .searchable(text: $search, placement: .toolbar, prompt: "应用或目标")
        .toolbar {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("应用") { c in
                HStack(spacing: 6) {
                    AppIcon(path: c.executablePath ?? "", size: 18)
                    Text(c.appName).lineLimit(1)
                }
                .help(c.signingID + (c.executablePath.map { "\n" + $0 } ?? ""))
            }
            .width(min: 120, ideal: 160)
            TableColumn("目标") { c in
                Text(c.target).lineLimit(1).truncationMode(.middle).help(c.target)
            }
            .width(min: 160, ideal: 240)
            TableColumn("协议") { c in
                Text(c.transport.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(44)
            TableColumn("动作") { c in
                ActionBadge(verdict: c.verdict, server: c.serverName)
                    .help(c.error.map { "错误：\($0)" } ?? c.reason.displayName)
            }
            .width(min: 80, ideal: 110)
            TableColumn("上传") { c in
                Text(Format.bytes(c.bytesUp)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            TableColumn("下载") { c in
                Text(Format.bytes(c.bytesDown)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            TableColumn(mode == .active ? "时长" : "结束") { c in
                if let end = c.endedAt, mode == .recent {
                    HStack(spacing: 4) {
                        if c.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(c.error ?? "")
                        }
                        Text(Format.time.string(from: end)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    Text(Format.duration(from: c.startedAt, to: c.endedAt)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 80)
        }
    }
}

// MARK: - 未匹配的应用

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var hideSystem = true
    @State private var editing: AppRule?

    private var apps: [UnmatchedApp] {
        let all = model.monitor.snapshot?.unmatched ?? []
        return hideSystem ? all.filter { !$0.isSystem } : all
    }

    var body: some View {
        Group {
            if !model.isRunning {
                EmptyStateView(systemImage: "pause.circle", title: "代理未运行", message: "启用后，这里会列出最近联网、但没有命中任何规则的进程。")
            } else if apps.isEmpty {
                EmptyStateView(systemImage: "checkmark.seal", title: "暂无未匹配的应用", message: "最近联网的进程都已命中规则。")
            } else {
                List(apps) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.executablePath.flatMap(AppInspector.outermostAppBundle(of:)) ?? app.executablePath ?? "", size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.appName).fontWeight(.medium)
                            Text(app.signingID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(app.flowCount) 个连接 · 最近：\(app.lastTarget) · \(Format.time.string(from: app.lastSeen))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("添加规则") { editing = draftRule(for: app) }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("未匹配的应用")
        .toolbar {
            Toggle("隐藏系统进程", isOn: $hideSystem)
                .toggleStyle(.checkbox)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { model.store.upsertRule($0) }
        }
    }

    private func draftRule(for app: UnmatchedApp) -> AppRule {
        let action: RuleAction = model.store.configuration.servers.first.map { .proxy(serverID: $0.id) } ?? .direct
        // 尽量以 .app 为单位创建规则，这样 helper 进程也一并命中。
        if let exe = app.executablePath, let bundle = AppInspector.outermostAppBundle(of: exe),
           let inspected = AppInspector.inspect(url: URL(fileURLWithPath: bundle)) {
            return AppRule(name: inspected.name, bundleID: inspected.bundleID, path: inspected.path, action: action)
        }
        return AppRule(name: app.appName, bundleID: app.signingID, path: app.executablePath ?? "", action: action)
    }
}

import ProxyAppXCore
import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .active
    @State private var search = ""

    enum Mode: String, CaseIterable, Identifiable {
        case active, recent
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .active: return "Active"
            case .recent: return "Recently Closed"
            }
        }
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
                EmptyStateView(systemImage: "pause.circle", title: "Proxy Is Off",
                               message: "Once it is on, connections taken over by ProxyAppX show up here live.")
            } else if rows.isEmpty {
                if mode == .active {
                    EmptyStateView(systemImage: "arrow.left.arrow.right", title: "No Active Connections",
                                   message: "Only proxied or blocked connections, and connections matching a Direct rule, are listed.")
                } else {
                    EmptyStateView(systemImage: "arrow.left.arrow.right", title: "Nothing Yet",
                                   message: "Only proxied or blocked connections, and connections matching a Direct rule, are listed.")
                }
            } else {
                table
            }
        }
        .navigationTitle(SidebarItem.connections.title)
        .searchable(text: $search, placement: .toolbar, prompt: Text("App or destination"))
        .toolbar {
            Picker(selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("App") { c in
                HStack(spacing: 6) {
                    AppIcon(path: c.executablePath ?? "", size: 18)
                    Text(c.appName).lineLimit(1)
                }
                .help(c.signingID + (c.executablePath.map { "\n" + $0 } ?? ""))
            }
            .width(min: 120, ideal: 160)
            TableColumn("Destination") { c in
                Text(c.target).lineLimit(1).truncationMode(.middle).help(c.target)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Protocol") { c in
                Text(c.transport.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 60)
            TableColumn("Action") { c in
                ActionBadge(verdict: c.verdict, server: c.serverName)
                    .help(c.error.map { String(localized: "Error: \($0)") } ?? c.reason.displayName)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Upload") { c in
                Text(Format.bytes(c.bytesUp)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            TableColumn("Download") { c in
                Text(Format.bytes(c.bytesDown)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            TableColumn(mode == .active ? Text("Duration") : Text("Ended")) { c in
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
    @State private var search = ""
    @State private var editing: AppRule?

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var apps: [UnmatchedApp] {
        let all = model.monitor.snapshot?.unmatched ?? []
        let engine = RuleEngine(configuration: model.store.configuration)
        let visible = all.filter { app in
            (!hideSystem || !app.isSystem) && !engine.matches(app)
        }
        guard !query.isEmpty else { return visible }
        return visible.filter { app in
            app.appName.localizedCaseInsensitiveContains(query)
                || app.signingID.localizedCaseInsensitiveContains(query)
                || app.lastTarget.localizedCaseInsensitiveContains(query)
                || (app.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if !model.isRunning {
                EmptyStateView(systemImage: "pause.circle", title: "Proxy Is Off",
                               message: "Once it is on, processes that recently used the network without matching any rule are listed here.")
            } else if apps.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    EmptyStateView(systemImage: "checkmark.seal", title: "No Unmatched Apps",
                                   message: "Every process that recently used the network matched a rule.")
                }
            } else {
                List(apps) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.executablePath.flatMap(AppInspector.outermostAppBundle(of:)) ?? app.executablePath ?? "", size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.appName).fontWeight(.medium)
                            Text(app.signingID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let path = app.executablePath, !path.isEmpty {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(app.flowCount) connections · latest: \(app.lastTarget) · \(Format.time.string(from: app.lastSeen))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .help(app.executablePath ?? app.signingID)
                        Spacer()
                        Button("Add Rule") { editing = draftRule(for: app) }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(SidebarItem.discover.title)
        .searchable(text: $search, placement: .toolbar, prompt: Text("App or destination"))
        .toolbar {
            Toggle("Hide system processes", isOn: $hideSystem)
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
            if var existing = model.store.existingRule(bundleID: inspected.bundleID, path: inspected.path) {
                existing.enabled = true
                return existing
            }
            return AppRule(name: inspected.name, bundleID: inspected.bundleID, path: inspected.path, action: action)
        }
        if var existing = model.store.existingRule(bundleID: app.signingID, path: app.executablePath ?? "") {
            existing.enabled = true
            return existing
        }
        return AppRule(name: app.appName, bundleID: app.signingID, path: app.executablePath ?? "", action: action)
    }
}

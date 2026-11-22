import ProxyAppXCore
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<AppRule.ID>()
    @State private var search = ""
    @State private var editing: AppRule?
    @State private var showRunningApps = false
    @State private var duplicateNotice: String?

    private var rules: [AppRule] {
        let all = model.store.configuration.rules
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
                || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.store.configuration.rules.isEmpty {
                EmptyStateView(systemImage: "square.stack.3d.up.slash", title: "No App Rules Yet",
                               message: "Click Add in the toolbar and choose the apps or command-line tools to proxy.")
            } else {
                table
            }
        }
        .navigationTitle(SidebarItem.rules.title)
        .searchable(text: $search, placement: .toolbar, prompt: Text("Search apps"))
        .toolbar { toolbar }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                model.store.upsertRule(updated)
            }
        }
        .sheet(isPresented: $showRunningApps) {
            RunningAppsPicker { apps in add(apps) }
        }
        .alert("Some Apps Already Have Rules",
               isPresented: Binding(get: { duplicateNotice != nil }, set: { if !$0 { duplicateNotice = nil } })) {
            Button("OK") {}
        } message: {
            Text(duplicateNotice ?? "")
        }
    }

    private var table: some View {
        let servers = model.store.configuration.servers
        return Table(rules, selection: $selection) {
            TableColumn("On") { rule in
                Toggle(isOn: Binding(
                    get: { rule.enabled },
                    set: { model.store.setRuleEnabled(rule.id, $0) }
                )) {
                    Text("Enabled")
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .width(40)

            TableColumn("App") { rule in
                HStack(spacing: 8) {
                    AppIcon(path: rule.path, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name).lineLimit(1)
                        Text(rule.bundleID.isEmpty ? rule.path : rule.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .opacity(rule.enabled ? 1 : 0.5)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Action") { rule in
                ActionBadge(action: rule.action, servers: servers)
            }
            .width(min: 90, ideal: 130)

            TableColumn("UDP") { rule in
                Text(rule.action.isProxy ? rule.udpPolicy.displayName : "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Path") { rule in
                Text(rule.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.path)
            }
        }
        .contextMenu(forSelectionType: AppRule.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let rule = rules.first(where: { $0.id == id }) {
                Button("Edit…") { editing = rule }
                if rule.enabled {
                    Button("Disable") { model.store.setRuleEnabled(rule.id, false) }
                } else {
                    Button("Enable") { model.store.setRuleEnabled(rule.id, true) }
                }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(rule.path, inFileViewerRootedAtPath: "") }
                Divider()
            }
            if !ids.isEmpty {
                Menu("Set Action") {
                    ForEach(model.store.configuration.servers) { s in
                        Button("Proxy: \(s.name)") { setAction(.proxy(serverID: s.id), for: ids) }
                    }
                    Button("Direct") { setAction(.direct, for: ids) }
                    Button("Block") { setAction(.block, for: ids) }
                }
                Button("Delete", role: .destructive) { delete(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let rule = rules.first(where: { $0.id == id }) { editing = rule }
        }
        .onDeleteCommand { delete(selection) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                delete(selection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Menu {
                Button("Choose from Applications…") { add(AppInspector.pickApplications()) }
                Button("Choose from Running Apps…") { showRunningApps = true }
                Divider()
                Button("Choose a Command-Line Tool or Executable…") { add(AppInspector.pickExecutables()) }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    // MARK: 操作

    private func add(_ apps: [InspectedApp]) {
        guard !apps.isEmpty else { return }
        let defaultAction: RuleAction = model.store.configuration.servers.first.map { .proxy(serverID: $0.id) } ?? .direct
        var added: [AppRule] = []
        var duplicates: [String] = []
        for app in apps {
            if model.store.existingRule(bundleID: app.bundleID, path: app.path) != nil {
                duplicates.append(app.name)
                continue
            }
            let rule = AppRule(name: app.name, bundleID: app.bundleID, path: app.path, action: defaultAction)
            model.store.upsertRule(rule)
            added.append(rule)
        }
        if !duplicates.isEmpty {
            let names = duplicates.joined(separator: String(localized: ", ", comment: "Separator between app names"))
            duplicateNotice = String(localized: "These apps already have rules and were skipped: \(names)")
        }
        if added.count == 1 {
            editing = added[0]
        }
        selection = Set(added.map(\.id))
    }

    private func delete(_ ids: Set<AppRule.ID>) {
        guard !ids.isEmpty else { return }
        model.store.deleteRules(ids)
        selection.subtract(ids)
    }

    private func setAction(_ action: RuleAction, for ids: Set<AppRule.ID>) {
        for var rule in model.store.configuration.rules where ids.contains(rule.id) {
            rule.action = action
            model.store.upsertRule(rule)
        }
    }
}

// MARK: - 规则编辑

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AppRule
    let onSave: (AppRule) -> Void

    private enum ActionKind: String, CaseIterable, Identifiable {
        case proxy, direct, block
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .proxy: return "Proxy"
            case .direct: return "Direct"
            case .block: return "Block"
            }
        }
    }

    @State private var kind: ActionKind
    @State private var serverID: UUID?

    init(rule: AppRule, onSave: @escaping (AppRule) -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        switch rule.action {
        case let .proxy(id):
            _kind = State(initialValue: .proxy)
            _serverID = State(initialValue: id)
        case .direct:
            _kind = State(initialValue: .direct)
            _serverID = State(initialValue: nil)
        case .block:
            _kind = State(initialValue: .block)
            _serverID = State(initialValue: nil)
        }
    }

    var body: some View {
        let servers = model.store.configuration.servers
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(path: rule.path, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $rule.name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                    Text(rule.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Picker("Action", selection: $kind) {
                    ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .proxy {
                    if servers.isEmpty {
                        Text("There are no proxy servers yet. Add one under Proxy Servers first.")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Proxy server", selection: $serverID) {
                            ForEach(servers) { s in
                                Text(verbatim: "\(s.name)  (\(s.endpointDescription))").tag(Optional(s.id))
                            }
                        }
                        Picker("UDP traffic", selection: $rule.udpPolicy) {
                            ForEach(UDPPolicy.allCases) { Text($0.displayName).tag($0) }
                        }
                        Text(udpHint(servers: servers))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Matching") {
                    TextField("Signing identifier / bundle ID", text: $rule.bundleID)
                        .font(.body.monospaced())
                    Text("Also matches helper processes whose identifier starts with \"\(rule.bundleID.isEmpty ? "…" : rule.bundleID).\", and every process inside this app bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Enable this rule", isOn: $rule.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(kind == .proxy && serverID == nil)
            }
            .padding(20)
        }
        .frame(width: 540)
        .onAppear {
            if kind == .proxy && serverID == nil { serverID = servers.first?.id }
        }
        .onChange(of: kind) { _, new in
            if new == .proxy && serverID == nil { serverID = servers.first?.id }
        }
    }

    private func udpHint(servers: [ProxyServer]) -> String {
        guard let s = servers.first(where: { $0.id == serverID }) else { return "" }
        switch rule.udpPolicy {
        case .block:
            return String(localized: "With UDP blocked, apps can retry over TCP. If an app reports a QUIC error, check the proxy connection and try disabling QUIC in the app.")
        case .direct:
            return String(localized: "UDP bypasses the proxy and may reveal your real IP address.")
        case .proxy:
            return s.canRelayUDP
                ? String(localized: "UDP will be relayed with SOCKS5 UDP ASSOCIATE.")
                : String(localized: "\"\(s.name)\" cannot relay UDP (it is an HTTP proxy, or \"Supports UDP\" is off), so UDP will be blocked.")
        }
    }

    private func save() {
        switch kind {
        case .proxy: rule.action = serverID.map { .proxy(serverID: $0) } ?? .direct
        case .direct: rule.action = .direct
        case .block: rule.action = .block
        }
        rule.bundleID = rule.bundleID.trimmingCharacters(in: .whitespaces)
        onSave(rule)
    }
}

// MARK: - 正在运行的应用

struct RunningAppsPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InspectedApp] = []
    @State private var chosen = Set<String>()
    let onAdd: ([InspectedApp]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose Running Apps")
                .font(.headline)
                .padding()
            List(apps, selection: $chosen) { app in
                HStack(spacing: 8) {
                    AppIcon(path: app.path, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(app.path)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 360)
            .padding(.horizontal)
            HStack {
                Text("Hold ⌘ to select several").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count)") {
                    let picked = apps.filter { chosen.contains($0.path) }
                    dismiss()
                    onAdd(picked)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear { apps = AppInspector.runningApps() }
    }
}

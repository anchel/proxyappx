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
                EmptyStateView(systemImage: "square.stack.3d.up.slash", title: "还没有应用规则",
                               message: "点击右上角的「添加」，选择要走代理的应用或命令行工具。")
            } else {
                table
            }
        }
        .navigationTitle("应用规则")
        .searchable(text: $search, placement: .toolbar, prompt: "搜索应用")
        .toolbar { toolbar }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                model.store.upsertRule(updated)
            }
        }
        .sheet(isPresented: $showRunningApps) {
            RunningAppsPicker { apps in add(apps) }
        }
        .alert("部分应用已存在", isPresented: Binding(get: { duplicateNotice != nil }, set: { if !$0 { duplicateNotice = nil } })) {
            Button("好") {}
        } message: {
            Text(duplicateNotice ?? "")
        }
    }

    private var table: some View {
        let servers = model.store.configuration.servers
        return Table(rules, selection: $selection) {
            TableColumn("启用") { rule in
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.store.setRuleEnabled(rule.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .width(40)

            TableColumn("应用") { rule in
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

            TableColumn("动作") { rule in
                ActionBadge(action: rule.action, servers: servers)
            }
            .width(min: 90, ideal: 130)

            TableColumn("UDP") { rule in
                Text(rule.action.isProxy ? rule.udpPolicy.displayName : "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)

            TableColumn("路径") { rule in
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
                Button("编辑…") { editing = rule }
                Button(rule.enabled ? "停用" : "启用") { model.store.setRuleEnabled(rule.id, !rule.enabled) }
                Button("在访达中显示") { NSWorkspace.shared.selectFile(rule.path, inFileViewerRootedAtPath: "") }
                Divider()
            }
            if !ids.isEmpty {
                Menu("设置动作") {
                    ForEach(model.store.configuration.servers) { s in
                        Button("代理：\(s.name)") { setAction(.proxy(serverID: s.id), for: ids) }
                    }
                    Button("直连") { setAction(.direct, for: ids) }
                    Button("阻断") { setAction(.block, for: ids) }
                }
                Button("删除", role: .destructive) { delete(ids) }
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
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Menu {
                Button("从「应用程序」中选择…") { add(AppInspector.pickApplications()) }
                Button("从正在运行的应用中选择…") { showRunningApps = true }
                Divider()
                Button("选择命令行工具 / 可执行文件…") { add(AppInspector.pickExecutables()) }
            } label: {
                Label("添加", systemImage: "plus")
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
            duplicateNotice = "以下应用已有规则，已跳过：\(duplicates.joined(separator: "、"))"
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
        case proxy = "代理", direct = "直连", block = "阻断"
        var id: String { rawValue }
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
                    TextField("名称", text: $rule.name)
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
                Picker("动作", selection: $kind) {
                    ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .proxy {
                    if servers.isEmpty {
                        Text("还没有代理服务器，请先到「代理服务器」中添加。")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("代理服务器", selection: $serverID) {
                            ForEach(servers) { s in
                                Text("\(s.name)  (\(s.endpointDescription))").tag(Optional(s.id))
                            }
                        }
                        Picker("UDP 流量", selection: $rule.udpPolicy) {
                            ForEach(UDPPolicy.allCases) { Text($0.displayName).tag($0) }
                        }
                        Text(udpHint(servers: servers))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("匹配") {
                    TextField("签名标识 / Bundle ID", text: $rule.bundleID)
                        .font(.body.monospaced())
                    Text("同时匹配以「\(rule.bundleID.isEmpty ? "…" : rule.bundleID).」开头的 helper 进程，以及位于该应用包内的所有进程。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("启用此规则", isOn: $rule.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(kind == .proxy && serverID == nil)
            }
            .padding(20)
        }
        .frame(width: 520)
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
        case .block: return "阻断后，浏览器等应用会自动从 QUIC 回落到 TCP，流量仍经过代理，不会泄漏。"
        case .direct: return "UDP 不经过代理，可能暴露真实 IP。"
        case .proxy:
            return s.canRelayUDP ? "UDP 将通过 SOCKS5 UDP ASSOCIATE 转发。"
                : "「\(s.name)」不支持 UDP 转发（HTTP 代理，或未勾选「支持 UDP」），UDP 会被阻断。"
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
            Text("选择正在运行的应用")
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
                Text("可按住 ⌘ 多选").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加 \(chosen.count) 个") {
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

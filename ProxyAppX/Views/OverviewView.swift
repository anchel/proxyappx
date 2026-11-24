import ProxyAppXCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                setupSteps
                messages
                if model.isRunning { stats }
                rulesSummary
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(SidebarItem.overview.title)
    }

    // MARK: 顶部开关

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(model.isRunning ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Per-App Proxy")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(color: model.isRunning ? .green : (model.controller.isTransitioning ? .orange : .secondary))
                    Text(model.controller.statusTitle)
                        .foregroundStyle(.secondary)
                    if let s = model.monitor.snapshot {
                        Text("· running for \(Format.duration(from: s.startedAt, to: nil))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button {
                Task { await model.toggle() }
            } label: {
                Group {
                    if model.isRunning { Text("Turn Off") } else { Text("Turn On") }
                }
                .frame(minWidth: 64)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
            .disabled(model.controller.isBusy || model.controller.isTransitioning)
        }
    }

    // MARK: 引导

    @ViewBuilder
    private var setupSteps: some View {
        let ext = model.extensionManager.state
        let hasServer = !model.store.configuration.servers.isEmpty
        let hasRule = !model.store.configuration.rules.isEmpty
        if !ext.isInstalled || !hasServer || !hasRule {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Install the network extension", done: ext.isInstalled, detail: extensionDetail(ext)) {
                        if case .awaitingApproval = ext {
                            Button("Open System Settings") { openExtensionSettings() }
                        } else if !ext.isInstalled {
                            Button("Install") { model.extensionManager.activate() }
                                .disabled(ext == .activating)
                        }
                    }
                    Divider()
                    step(2, "Add a proxy server", done: hasServer,
                         detail: String(localized: "SOCKS5 and HTTP proxies are supported")) {
                        if !hasServer { Button("Add") { selection = .servers } }
                    }
                    Divider()
                    step(3, "Choose the apps to proxy", done: hasRule,
                         detail: String(localized: "Works with .app bundles and command-line tools such as curl and git")) {
                        if !hasRule { Button("Add") { selection = .rules } }
                    }
                }
                .padding(6)
            } label: {
                Text("Get Started").font(.headline)
            }
        }
    }

    private func extensionDetail(_ state: ExtensionManager.State) -> String {
        switch state {
        case .awaitingApproval:
            return String(localized: "Open System Settings › General › Login Items & Extensions › Network Extensions and allow ProxyAppX.")
        case let .failed(message):
            return message
        default:
            return state.title
        }
    }

    private func step<Accessory: View>(_ n: Int, _ title: LocalizedStringKey, done: Bool, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(n)").font(.caption.bold())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory()
        }
    }

    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 提示

    @ViewBuilder
    private var messages: some View {
        let errors = [model.controller.lastError, model.store.lastSaveError, model.monitor.lastError].compactMap { $0 }
        let extError: String? = {
            if case let .failed(m) = model.extensionManager.state { return m }
            return nil
        }()
        let all = errors + (extError.map { [$0] } ?? [])
        ForEach(all, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        ForEach(model.configurationWarnings, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: 统计

    private var stats: some View {
        let s = model.monitor.snapshot
        let t = s?.totals ?? TrafficTotals()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatTile(title: "Active connections", value: "\(s?.active.count ?? 0)", systemImage: "link")
            StatTile(title: "Upload", value: Format.rate(model.monitor.upRate),
                     caption: String(localized: "Total \(Format.bytes(t.bytesUp))"), systemImage: "arrow.up")
            StatTile(title: "Download", value: Format.rate(model.monitor.downRate),
                     caption: String(localized: "Total \(Format.bytes(t.bytesDown))"), systemImage: "arrow.down")
            StatTile(title: "Proxied / blocked", value: "\(t.proxied) / \(t.blocked)",
                     caption: t.failed > 0 ? String(localized: "\(t.failed) failed") : String(localized: "\(t.direct) direct"),
                     systemImage: "arrow.triangle.branch")
        }
    }

    // MARK: 规则摘要

    @ViewBuilder
    private var rulesSummary: some View {
        let cfg = model.store.configuration
        let trafficByRule = model.isRunning ? model.monitor.snapshot?.trafficByRule : nil
        if !cfg.rules.isEmpty {
            GroupBox {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if trafficByRule != nil {
                        Text("Traffic forwarded by the extension this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    ForEach(cfg.rules) { rule in
                        HStack(spacing: 10) {
                            AppIcon(path: rule.path, size: 22)
                            Text(rule.name)
                                .layoutPriority(1)
                            Spacer()
                            if let trafficByRule {
                                let traffic = trafficByRule[rule.id] ?? RuleTraffic()
                                let up = Format.bytes(traffic.bytesUp)
                                let down = Format.bytes(traffic.bytesDown)
                                Text(verbatim: "U: \(up)   D: \(down)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(Text("Uploaded \(up) · Downloaded \(down)"))
                            }
                            if rule.enabled {
                                ActionBadge(action: rule.action, servers: cfg.servers)
                            } else {
                                Text("Disabled").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .padding(.vertical, 6)
                        if rule.id != cfg.rules.last?.id { Divider() }
                    }
                }
                .padding(4)
            } label: {
                HStack {
                    Text("App Rules").font(.headline)
                    Spacer()
                    Text("Apps without a rule: \(defaultActionText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var defaultActionText: String {
        let cfg = model.store.configuration
        switch cfg.settings.defaultAction {
        case .direct: return String(localized: "Direct")
        case .block: return String(localized: "Block")
        case let .proxy(id):
            let name = cfg.server(id: id)?.name ?? String(localized: "Server missing")
            return String(localized: "Proxy (\(name))")
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var caption: String? = nil
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

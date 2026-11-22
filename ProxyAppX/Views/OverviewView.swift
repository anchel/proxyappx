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
        .navigationTitle("概览")
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
                Text("按应用代理")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(color: model.isRunning ? .green : (model.controller.isTransitioning ? .orange : .secondary))
                    Text(model.controller.statusTitle)
                        .foregroundStyle(.secondary)
                    if let s = model.monitor.snapshot {
                        Text("· 已运行 \(Format.duration(from: s.startedAt, to: nil))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button {
                Task { await model.toggle() }
            } label: {
                Text(model.isRunning ? "停用" : "启用")
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
                    step(1, "安装网络扩展", done: ext.isInstalled, detail: extensionDetail(ext)) {
                        if case .awaitingApproval = ext {
                            Button("打开系统设置") { openExtensionSettings() }
                        } else if !ext.isInstalled {
                            Button("安装") { model.extensionManager.activate() }
                                .disabled(ext == .activating)
                        }
                    }
                    Divider()
                    step(2, "添加代理服务器", done: hasServer, detail: "支持 SOCKS5 和 HTTP 代理") {
                        if !hasServer { Button("添加") { selection = .servers } }
                    }
                    Divider()
                    step(3, "选择要走代理的应用", done: hasRule, detail: "支持 .app 和命令行工具（如 curl、git）") {
                        if !hasRule { Button("添加") { selection = .rules } }
                    }
                }
                .padding(6)
            } label: {
                Text("开始使用").font(.headline)
            }
        }
    }

    private func extensionDetail(_ state: ExtensionManager.State) -> String {
        switch state {
        case .awaitingApproval:
            return "请打开「系统设置 › 通用 › 登录项与扩展 › 网络扩展」，允许 ProxyAppX。"
        case let .failed(message):
            return message
        default:
            return state.title
        }
    }

    private func step<Accessory: View>(_ n: Int, _ title: String, done: Bool, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold())
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
            StatTile(title: "活动连接", value: "\(s?.active.count ?? 0)", systemImage: "link")
            StatTile(title: "上传", value: Format.rate(model.monitor.upRate), caption: "累计 \(Format.bytes(t.bytesUp))",
                     systemImage: "arrow.up")
            StatTile(title: "下载", value: Format.rate(model.monitor.downRate), caption: "累计 \(Format.bytes(t.bytesDown))",
                     systemImage: "arrow.down")
            StatTile(title: "已代理 / 阻断", value: "\(t.proxied) / \(t.blocked)",
                     caption: t.failed > 0 ? "\(t.failed) 次失败" : "直连 \(t.direct)", systemImage: "arrow.triangle.branch")
        }
    }

    // MARK: 规则摘要

    @ViewBuilder
    private var rulesSummary: some View {
        let cfg = model.store.configuration
        let enabled = cfg.rules.filter(\.enabled)
        if !enabled.isEmpty {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(enabled.prefix(8)) { rule in
                        HStack(spacing: 10) {
                            AppIcon(path: rule.path, size: 22)
                            Text(rule.name)
                            Spacer()
                            ActionBadge(action: rule.action, servers: cfg.servers)
                        }
                        .padding(.vertical, 6)
                        if rule.id != enabled.prefix(8).last?.id { Divider() }
                    }
                    if enabled.count > 8 {
                        Button("查看全部 \(enabled.count) 条规则") { selection = .rules }
                            .buttonStyle(.link)
                            .padding(.top, 6)
                    }
                }
                .padding(4)
            } label: {
                HStack {
                    Text("生效中的规则").font(.headline)
                    Spacer()
                    Text("未命中规则的应用：\(defaultActionText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var defaultActionText: String {
        let cfg = model.store.configuration
        switch cfg.settings.defaultAction {
        case .direct: return "直连"
        case .block: return "阻断"
        case let .proxy(id): return "代理（\(cfg.server(id: id)?.name ?? "服务器缺失")）"
        }
    }
}

private struct StatTile: View {
    let title: String
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

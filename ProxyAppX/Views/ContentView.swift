import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, rules, servers, connections, discover, logs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .rules: return "应用规则"
        case .servers: return "代理服务器"
        case .connections: return "连接"
        case .discover: return "未匹配的应用"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .rules: return "square.stack.3d.up"
        case .servers: return "server.rack"
        case .connections: return "arrow.left.arrow.right"
        case .discover: return "questionmark.app.dashed"
        case .logs: return "doc.plaintext"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach([SidebarItem.overview, .rules, .servers]) { item in
                        row(item)
                    }
                }
                Section("监控") {
                    ForEach([SidebarItem.connections, .discover, .logs]) { item in
                        row(item)
                    }
                }
                Section {
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(12)
            }
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(selection: $selection)
            case .rules: RulesView()
            case .servers: ServersView()
            case .connections: ConnectionsView()
            case .discover: DiscoverView()
            case .logs: LogsView()
            case .settings: SettingsView()
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .badge(badge(for: item))
            .tag(item)
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .rules: return model.store.configuration.rules.filter(\.enabled).count
        case .connections: return model.monitor.snapshot?.active.count ?? 0
        default: return 0
        }
    }
}

/// 侧栏底部的开关。
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.isRunning ? .green : (model.controller.isTransitioning ? .orange : .secondary))
            Text(model.controller.statusTitle)
                .font(.callout)
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.isRunning || model.controller.status == .connecting },
                set: { on in Task { await model.setEnabled(on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(model.controller.isBusy || model.controller.status == .disconnecting)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

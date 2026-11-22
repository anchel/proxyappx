import AppKit
import ProxyAppXCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "ProxyAppX").font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(color: model.isRunning ? .green : (model.controller.isTransitioning ? .orange : .secondary))
                        Text(model.controller.statusTitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { model.isRunning || model.controller.status == .connecting },
                    set: { on in Task { await model.setEnabled(on) } }
                )) {
                    Text("Enabled")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.controller.isBusy || model.controller.status == .disconnecting)
            }

            if model.isRunning {
                HStack {
                    Label { Text(verbatim: Format.rate(model.monitor.upRate)) } icon: { Image(systemName: "arrow.up") }
                    Spacer()
                    Label { Text(verbatim: Format.rate(model.monitor.downRate)) } icon: { Image(systemName: "arrow.down") }
                    Spacer()
                    Label { Text(verbatim: "\(model.monitor.snapshot?.active.count ?? 0)") } icon: { Image(systemName: "link") }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            let rules = model.store.configuration.rules.filter(\.enabled)
            if !rules.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rules.prefix(6)) { rule in
                        HStack(spacing: 8) {
                            AppIcon(path: rule.path, size: 16)
                            Text(rule.name).lineLimit(1)
                            Spacer()
                            ActionBadge(action: rule.action, servers: model.store.configuration.servers)
                        }
                        .font(.callout)
                    }
                    if rules.count > 6 {
                        Text("\(rules.count - 6) more…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let err = model.controller.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Open Main Window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

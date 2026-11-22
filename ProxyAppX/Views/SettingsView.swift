import AppKit
import ProxyAppXCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importError: String?
    @State private var confirmUninstall = false
    @State private var language = LanguagePreference.saved
    @State private var resolverDraft: String?

    private var settings: GeneralSettings { model.store.configuration.settings }

    private func binding<T>(_ keyPath: WritableKeyPath<GeneralSettings, T>) -> Binding<T> {
        Binding(get: { model.store.configuration.settings[keyPath: keyPath] },
                set: { v in model.store.updateSettings { $0[keyPath: keyPath] = v } })
    }

    /// 默认动作选择：nil = 直连，UUID = 代理，blockTag = 阻断
    private static let blockTag = UUID(uuidString: "00000000-0000-0000-0000-00000000B10C")!

    private var defaultActionBinding: Binding<UUID?> {
        Binding(
            get: {
                switch settings.defaultAction {
                case .direct: return nil
                case .block: return Self.blockTag
                case let .proxy(id): return id
                }
            },
            set: { v in
                model.store.updateSettings {
                    switch v {
                    case .none: $0.defaultAction = .direct
                    case Self.blockTag?: $0.defaultAction = .block
                    case let id?: $0.defaultAction = .proxy(serverID: id)
                    }
                }
            }
        )
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Apps without a rule", selection: defaultActionBinding) {
                    Text("Direct (recommended)").tag(UUID?.none)
                    ForEach(model.store.configuration.servers) { s in
                        Text("Proxy: \(s.name)").tag(Optional(s.id))
                    }
                    Text("Block").tag(Optional(Self.blockTag))
                }
                if settings.defaultAction != .direct {
                    Toggle("Keep system processes direct", isOn: binding(\.exemptSystemProcesses))
                    Text("Apple-signed processes in /System, /usr and similar folders (system services, command-line tools) skip the default action unless a rule matches them explicitly. Turning this off may affect software updates, iCloud and more.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.defaultAction.isProxy {
                    Picker("UDP for the default action", selection: binding(\.defaultUDPPolicy)) {
                        ForEach(UDPPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            } header: {
                Text("Default Action")
            } footer: {
                Text("Choosing a proxy turns on exclusion mode: every app goes through the proxy except those set to Direct.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Connections") {
                Picker("When the proxy is unavailable", selection: binding(\.onProxyFailure)) {
                    ForEach(FailurePolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Send hostnames to the proxy for resolution", isOn: binding(\.preferHostname))
                Toggle("Route app DNS queries through their proxy", isOn: binding(\.proxyAppDNS))
                if settings.proxyAppDNS {
                    HStack {
                        TextField("DNS resolver IP", text: Binding(
                            get: { resolverDraft ?? settings.dnsResolver.rawValue },
                            set: { resolverDraft = $0 }
                        ))
                        .onSubmit { applyResolver() }
                        Button("Apply") { applyResolver() }
                            .disabled(resolverDraft.flatMap(DNSResolver.init(rawValue:)) == nil)
                    }
                    if let resolverDraft, DNSResolver(rawValue: resolverDraft) == nil {
                        Text("Enter an IPv4 or IPv6 address.").foregroundStyle(.red).font(.caption)
                    }
                    Text("Identifiable apps with a proxy rule send port 53 queries to this resolver through their proxy over TCP. A failed query is blocked. Queries attributed only to the system use system DNS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Connect to local network addresses directly", isOn: binding(\.bypassLAN))
                Stepper(value: binding(\.connectTimeout), in: 3...60, step: 1) {
                    LabeledContent("Connection timeout", value: String(localized: "\(Int(settings.connectTimeout)) s"))
                }
            }

            Section {
                LabeledContent("Detected") {
                    Text(model.network.tunnel?.summary ?? String(localized: "No VPN or TUN is carrying public traffic"))
                        .foregroundStyle(model.network.tunnel == nil ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Bound connections go direct (recommended)", isOn: binding(\.bypassBoundFlows))
                Text("VPN and proxy cores (such as Clash's) bind their own connections to the physical interface to escape their TUN. Taking such a connection over drops the binding and creates a loop.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Hand fake IPs without a hostname to the TUN (recommended)", isOn: binding(\.fakeIPFallback))
                Text("When the destination is a fake IP in 198.18.0.0/15 and no hostname is known, a remote proxy cannot connect; the connection goes back to the tool that issued the fake IP. Proxies on this Mac are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Upstream connections bypass other VPN / TUN", isOn: binding(\.upstreamAvoidTunnels))
                Text("When on, the extension reaches proxy servers over the physical interface, so tools like Clash do not process that traffic again. Leave it off if your proxy server is only reachable through a company VPN.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Or let the extension through in your Clash rules:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: AppModel.clashDirectRule)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppModel.clashDirectRule, forType: .string)
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Coexisting with Other VPN / TUN")
            }

            Section("General") {
                Picker("Language", selection: $language) {
                    Text("Follow System").tag(LanguagePreference.system)
                    Text(verbatim: "English").tag(LanguagePreference.english)
                    Text(verbatim: "简体中文").tag(LanguagePreference.simplifiedChinese)
                }
                .onChange(of: language) { _, new in new.save() }
                if language != LanguagePreference.atLaunch {
                    HStack {
                        Text("Relaunch ProxyAppX to apply the new language.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now") { LanguagePreference.relaunch() }
                            .controlSize(.small)
                    }
                }
                Toggle("Launch ProxyAppX at login", isOn: $model.launchAtLogin)
                if let e = model.loginItemError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Configuration File") {
                HStack {
                    Button("Export…") { exportConfig() }
                    Button("Import…") { importConfig() }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                    }
                }
                Text("Exported files do not include passwords. Importing replaces all current servers and rules.")
                    .font(.caption).foregroundStyle(.secondary)
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Network Extension") {
                LabeledContent("Status", value: model.extensionManager.state.title)
                LabeledContent("Identifier", value: model.extensionManager.extensionIdentifier)
                if let s = model.monitor.snapshot {
                    LabeledContent("Extension version", value: s.extensionVersion)
                }
                HStack {
                    Button("Reinstall") { model.extensionManager.activate() }
                    Button("Uninstall Extension…", role: .destructive) { confirmUninstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SidebarItem.settings.title)
        .confirmationDialog("Uninstall the network extension?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                Task {
                    await model.controller.removeConfiguration()
                    model.extensionManager.deactivate()
                }
            }
        } message: {
            Text("This stops the proxy and removes the proxy configuration and the network extension from macOS. Your rules and servers are kept.")
        }
    }

    private func applyResolver() {
        guard let resolverDraft, let resolver = DNSResolver(rawValue: resolverDraft) else { return }
        model.store.updateSettings { $0.dnsResolver = resolver }
        self.resolverDraft = nil
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "ProxyAppX-Configuration.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportData().write(to: url, options: .atomic)
        } catch {
            importError = String(localized: "Export failed: \(error.localizedDescription)")
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.importData(Data(contentsOf: url))
            importError = nil
        } catch {
            importError = String(localized: "Import failed: \(error.localizedDescription)")
        }
    }
}

import ProxyAppXCore
import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProxyServer?
    @State private var pendingDelete: ProxyServer?
    @State private var testResults: [UUID: TestResult] = [:]

    var body: some View {
        Group {
            if model.store.configuration.servers.isEmpty {
                EmptyStateView(systemImage: "server.rack", title: "No Proxy Servers Yet",
                               message: "Click Add in the toolbar to set up a SOCKS5 or HTTP proxy.\nLocal clients such as Clash or v2ray usually listen on a port like 127.0.0.1:7890.")
            } else {
                list
            }
        }
        .navigationTitle(SidebarItem.servers.title)
        .toolbar {
            Button {
                editing = ProxyServer(name: "", type: .socks5, host: "127.0.0.1", port: 1080)
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: !model.store.configuration.servers.contains { $0.id == server.id }) {
                model.store.upsertServer($0)
                testResults[$0.id] = nil
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { server in
            Button("Delete", role: .destructive) { model.store.deleteServer(server.id) }
        } message: { server in
            let n = model.store.rulesUsing(server: server.id).count
            if n > 0 {
                Text("\(n) rules use this server. After it is deleted, they will switch to Direct.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    private var deleteTitle: String {
        String(localized: "Delete \"\(pendingDelete?.name ?? "")\"?")
    }

    private var list: some View {
        List {
            ForEach(model.store.configuration.servers) { server in
                ServerRow(server: server,
                          usage: model.store.rulesUsing(server: server.id).count,
                          result: testResults[server.id],
                          onTest: { test(server) },
                          onEdit: { editing = server },
                          onDelete: { pendingDelete = server })
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func test(_ server: ProxyServer) {
        testResults[server.id] = .running
        Task {
            do {
                let latency = try await ProxyConnector.test(server: server, timeout: model.store.configuration.settings.connectTimeout)
                testResults[server.id] = .success(latency)
            } catch {
                testResults[server.id] = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

enum TestResult: Equatable {
    case running
    case success(TimeInterval)
    case failure(String)
}

private struct ServerRow: View {
    let server: ProxyServer
    let usage: Int
    let result: TestResult?
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.type == .socks5 ? "shield.lefthalf.filled" : "globe")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name.isEmpty ? server.endpointDescription : server.name).fontWeight(.medium)
                    if server.hasCredentials {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Requires authentication")
                    }
                    if server.canRelayUDP {
                        Text(verbatim: "UDP").font(.caption2.bold()).padding(.horizontal, 4)
                            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(server.endpointDescription) · used by \(usage) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            resultView
            Button("Test", action: onTest)
                .disabled(result == .running)
            Menu {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    @ViewBuilder
    private var resultView: some View {
        switch result {
        case .none:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case let .success(t):
            Label { Text(verbatim: "\(Int(t * 1000)) ms") } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
                .font(.callout.monospacedDigit())
        case let .failure(message):
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .help(message)
                .frame(maxWidth: 240, alignment: .trailing)
        }
    }
}

// MARK: - 编辑

struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server: ProxyServer
    @State private var portText: String
    @State private var password: String
    @State private var testResult: TestResult?
    let isNew: Bool
    let onSave: (ProxyServer) -> Void

    init(server: ProxyServer, isNew: Bool, onSave: @escaping (ProxyServer) -> Void) {
        _server = State(initialValue: server)
        _portText = State(initialValue: String(server.port))
        _password = State(initialValue: server.password ?? "")
        self.isNew = isNew
        self.onSave = onSave
    }

    private var port: UInt16? { UInt16(portText.trimmingCharacters(in: .whitespaces)) }

    private var isValid: Bool {
        !server.host.trimmingCharacters(in: .whitespaces).isEmpty && (port ?? 0) > 0
    }

    private var draft: ProxyServer {
        var s = server
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.port = port ?? 0
        s.password = password.isEmpty ? nil : password
        s.username = s.username.trimmingCharacters(in: .whitespaces)
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = "\(s.type.displayName) \(s.host):\(s.port)" }
        if s.type == .http { s.supportsUDP = false }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("e.g. Office proxy"))
                    Picker("Type", selection: $server.type) {
                        ForEach(ProxyProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: server.type) { old, new in
                        if portText == String(old.defaultPort) { portText = String(new.defaultPort) }
                    }
                    TextField("Server", text: $server.host, prompt: Text("IP address or domain"))
                    TextField("Port", text: $portText)
                }
                Section("Authentication (optional)") {
                    TextField("Username", text: $server.username)
                    SecureField("Password", text: $password)
                }
                if server.type == .socks5 {
                    Section {
                        Toggle("Server supports UDP relay (UDP ASSOCIATE)", isOn: $server.supportsUDP)
                    } footer: {
                        Text("When on, rules can choose \"Relay via SOCKS5\" for UDP. Dante, Shadowsocks local clients and Clash usually support it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(!isValid || testResult == .running)
                testView
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onSave(draft)
                    dismiss()
                } label: {
                    if isNew { Text("Add") } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private var testView: some View {
        switch testResult {
        case .none: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case let .success(t):
            Text("Reachable · \(Int(t * 1000)) ms").foregroundStyle(.green).font(.callout)
        case let .failure(m):
            Text(m).foregroundStyle(.red).font(.callout).lineLimit(2).help(m)
        }
    }

    private func runTest() {
        testResult = .running
        let s = draft
        Task {
            do {
                testResult = .success(try await ProxyConnector.test(server: s, timeout: 8))
            } catch {
                testResult = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

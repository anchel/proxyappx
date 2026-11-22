import AppKit
import ProxyAppXCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importError: String?
    @State private var confirmUninstall = false

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
                Picker("未命中规则的应用", selection: defaultActionBinding) {
                    Text("直连（推荐）").tag(UUID?.none)
                    ForEach(model.store.configuration.servers) { s in
                        Text("代理：\(s.name)").tag(Optional(s.id))
                    }
                    Text("阻断").tag(Optional(Self.blockTag))
                }
                if settings.defaultAction != .direct {
                    Toggle("系统进程仍然直连", isOn: binding(\.exemptSystemProcesses))
                    Text("Apple 签名且位于 /System、/usr 等目录的进程（系统服务、命令行工具）不走默认动作，除非被规则显式命中。关闭后可能影响系统更新、iCloud 等。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.defaultAction.isProxy {
                    Picker("默认动作的 UDP 流量", selection: binding(\.defaultUDPPolicy)) {
                        ForEach(UDPPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            } header: {
                Text("默认动作")
            } footer: {
                Text("选择「代理」即为排除模式：除了设为「直连」的应用外，所有应用都走代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("连接") {
                Picker("代理不可用时", selection: binding(\.onProxyFailure)) {
                    ForEach(FailurePolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("优先把域名交给代理解析", isOn: binding(\.preferHostname))
                Toggle("局域网地址直连", isOn: binding(\.bypassLAN))
                Stepper(value: binding(\.connectTimeout), in: 3...60, step: 1) {
                    LabeledContent("连接超时", value: "\(Int(settings.connectTimeout)) 秒")
                }
            }

            Section("通用") {
                Toggle("登录时启动 ProxyAppX", isOn: $model.launchAtLogin)
                if let e = model.loginItemError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }

            Section("配置文件") {
                HStack {
                    Button("导出…") { exportConfig() }
                    Button("导入…") { importConfig() }
                    Spacer()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                    }
                }
                Text("导出的文件不包含密码。导入会替换当前所有服务器和规则。")
                    .font(.caption).foregroundStyle(.secondary)
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("网络扩展") {
                LabeledContent("状态", value: model.extensionManager.state.title)
                LabeledContent("标识", value: model.extensionManager.extensionIdentifier)
                if let s = model.monitor.snapshot {
                    LabeledContent("扩展版本", value: s.extensionVersion)
                }
                HStack {
                    Button("重新安装") { model.extensionManager.activate() }
                    Button("卸载扩展…", role: .destructive) { confirmUninstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .confirmationDialog("卸载网络扩展？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) {
                Task {
                    await model.controller.removeConfiguration()
                    model.extensionManager.deactivate()
                }
            }
        } message: {
            Text("会停止代理并从系统中移除代理配置和网络扩展。你的规则和服务器配置会保留。")
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ProxyAppX-配置.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportData().write(to: url, options: .atomic)
        } catch {
            importError = "导出失败：\(error.localizedDescription)"
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
            importError = "导入失败：\(error.localizedDescription)"
        }
    }
}

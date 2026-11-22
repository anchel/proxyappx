import Foundation
import Observation
import ProxyAppXCore
import ServiceManagement

/// 应用的顶层状态容器，把各个服务串起来。
@MainActor
@Observable
final class AppModel {
    let store = ConfigStore()
    let extensionManager = ExtensionManager()
    let controller: ProxyController
    let monitor: StatusMonitor

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { updateLoginItem() }
    }
    private(set) var loginItemError: String?

    init() {
        controller = ProxyController(providerBundleIdentifier: extensionManager.extensionIdentifier)
        monitor = StatusMonitor(controller: controller)

        store.onChange = { [weak self] cfg in
            guard let self else { return }
            Task { await self.controller.apply(cfg) }
        }
        controller.onUnexpectedDisconnect = { [weak self] in
            guard let self, self.extensionManager.state.isInstalled else { return }
            Task { await self.controller.start(with: self.store.configuration) }
        }
        extensionManager.onInstalled = { [weak self] in
            guard let self else { return }
            Task { await self.restoreIfNeeded() }
        }
    }

    /// App 启动时调用。
    func bootstrap() async {
        // 先读取系统中的代理配置状态，再查询扩展；扩展就绪回调里会据此决定是否自动恢复。
        await controller.load()
        // 代理可能在 App 未运行时一直开着；把当前配置同步给系统和正在运行的扩展。
        await controller.apply(store.configuration)
        extensionManager.refresh()
        monitor.start()
    }

    var isRunning: Bool { controller.isRunning }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            guard extensionManager.state.isInstalled else {
                extensionManager.activate()
                controller.wantsEnabled = true
                return
            }
            await controller.start(with: store.configuration)
        } else {
            controller.stop()
        }
    }

    func toggle() async {
        await setEnabled(!(controller.isRunning || controller.status == .connecting))
    }

    /// 扩展就绪后，如果用户上次是开启状态，自动恢复。
    private func restoreIfNeeded() async {
        guard controller.wantsEnabled, !controller.isRunning, !controller.isTransitioning else { return }
        await controller.start(with: store.configuration)
    }

    // MARK: 配置提示

    /// 需要用户注意的配置问题。
    var configurationWarnings: [String] {
        let cfg = store.configuration
        var out: [String] = []
        if cfg.servers.isEmpty {
            out.append("还没有添加代理服务器。")
        }
        if cfg.rules.filter(\.enabled).isEmpty && !cfg.settings.defaultAction.isProxy {
            out.append("还没有启用的应用规则，目前所有流量都直连。")
        }
        if let id = cfg.settings.defaultAction.serverID, let server = cfg.server(id: id),
           TargetAddress(host: server.host, port: server.port).isLoopback {
            out.append("默认动作是代理到本机的「\(server.name)」。请给本机的代理客户端（如 Clash、v2ray）添加一条「直连」规则，否则它自己的出站流量会被再次代理，形成回环。")
        }
        let missing = cfg.rules.filter { r in r.action.serverID.map { cfg.server(id: $0) == nil } ?? false }
        if !missing.isEmpty {
            out.append("有 \(missing.count) 条规则引用的代理服务器已不存在。")
        }
        return out
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
    }
}

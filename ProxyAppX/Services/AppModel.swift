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
    let network = NetworkEnvironment()

    /// Clash 类工具里放行本扩展出站流量的规则。
    static let clashDirectRule = "PROCESS-NAME,com.proxyappx.app.extension,DIRECT"

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
        // 以 App 的开关为准：用户上次关闭了代理，但系统里的会话还开着时，把它停掉。
        if !controller.wantsEnabled && (controller.isRunning || controller.status == .connecting) {
            controller.stopSession()
        }
        extensionManager.refresh()
        monitor.start()
        network.start()
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
        out.append(contentsOf: tunnelWarnings)
        return out
    }

    /// 检测到其他 VPN / TUN 工具时的共存提示。
    var tunnelWarnings: [String] {
        guard let tunnel = network.tunnel else { return [] }
        let settings = store.configuration.settings
        var out: [String] = []
        if !settings.upstreamAvoidTunnels && !remoteServersInUse.isEmpty {
            let names = remoteServersInUse.map(\.name).joined(separator: "、")
            out.append("检测到 \(tunnel.summary)。ProxyAppX 连接远程代理（\(names)）的流量会再经过它，可能被它二次代理。可在「设置 › 与其他 VPN / TUN 共存」中开启「上游连接绕过其他 VPN / TUN」，或在 Clash 规则中加入 \(Self.clashDirectRule)。")
        }
        if tunnel.isFakeIP && !settings.preferHostname {
            out.append("\(tunnel.interface) 处于 fake-IP 模式，建议在设置中开启「优先把域名交给代理解析」，否则远程代理收到的是 198.18.x.x 这类无效地址。")
        }
        if !settings.bypassBoundFlows && settings.defaultAction.isProxy {
            out.append("已关闭「绑定网卡的连接直连」且默认动作为代理，\(tunnel.interface) 背后的代理内核可能被接管，形成回环。")
        }
        return out
    }

    /// 规则或默认动作正在使用的、不在本机的代理服务器。
    private var remoteServersInUse: [ProxyServer] {
        let cfg = store.configuration
        var ids = Set(cfg.rules.filter(\.enabled).compactMap(\.action.serverID))
        if let d = cfg.settings.defaultAction.serverID { ids.insert(d) }
        return cfg.servers.filter { ids.contains($0.id) && !TargetAddress(host: $0.host, port: $0.port).isLoopback }
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

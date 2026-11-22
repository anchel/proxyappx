import Foundation
import Network
import NetworkExtension
import ProxyAppXCore

/// 当前生效的规则引擎，可在运行中热更新。
private final class EngineStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine = RuleEngine(configuration: ProxyAppXConfig())

    var engine: RuleEngine {
        lock.lock()
        defer { lock.unlock() }
        return _engine
    }

    func update(_ configuration: ProxyAppXConfig) {
        let e = RuleEngine(configuration: configuration)
        lock.lock()
        _engine = e
        lock.unlock()
    }
}

/// 透明代理：拦截所有出站 TCP/UDP，按来源应用决定直连、阻断或转发到代理。
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let store = EngineStore()
    private let tracker = ConnectionTracker.shared
    private let resolver = ProcessResolver()

    // MARK: 生命周期

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let configuration = loadConfiguration(options: options)
        store.update(configuration)
        tracker.log(.info, "扩展启动：\(configuration.servers.count) 个代理，\(configuration.rules.filter(\.enabled).count) 条启用的规则")

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .UDP, direction: .outbound),
        ]

        setTunnelNetworkSettings(settings) { [tracker] error in
            if let error {
                tracker.log(.error, "设置网络规则失败：\(error.localizedDescription)")
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tracker.log(.info, "扩展停止（原因 \(reason.rawValue)）")
        completionHandler()
    }

    private func loadConfiguration(options: [String: Any]?) -> ProxyAppXConfig {
        // 优先使用启动参数里的配置（最新），其次是持久化的 providerConfiguration。
        let candidates: [Data?] = [
            options?[ProviderConfigurationKey.configuration] as? Data,
            (protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration?[ProviderConfigurationKey.configuration] as? Data,
        ]
        for case let data? in candidates {
            do {
                return try ProxyAppXConfig.decode(data)
            } catch {
                tracker.log(.error, "配置解析失败：\(error.localizedDescription)")
            }
        }
        tracker.log(.warning, "没有找到配置，所有流量直连")
        return ProxyAppXConfig()
    }

    // MARK: IPC

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let response: IPCResponse
        do {
            switch try IPCRequest.decode(messageData) {
            case let .updateConfiguration(configuration):
                store.update(configuration)
                tracker.log(.info, "配置已更新：\(configuration.rules.filter(\.enabled).count) 条启用的规则")
                response = .ok
            case let .status(logsAfter):
                response = .status(tracker.snapshot(logsAfter: logsAfter, ruleCount: store.engine.configuration.rules.count))
            case .clearLogs:
                tracker.clearLogs()
                response = .ok
            }
        } catch {
            response = .error("无法解析请求：\(error.localizedDescription)")
        }
        completionHandler?(try? response.encoded())
    }

    // MARK: 流量分发

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow,
              let destination = TargetAddress(endpoint: tcp.remoteFlowEndpoint) else {
            return false
        }
        let engine = store.engine
        let (ctx, process) = context(for: flow, destination: destination, transport: .tcp)
        let decision = engine.decide(ctx)

        switch decision.verdict {
        case .direct:
            recordDirect(ctx, process, decision)
            return false

        case .block:
            tracker.recordImmediate(snapshot(ctx, process, decision, verdict: .block))
            flow.reject()
            return true

        case let .proxy(server):
            let id = tracker.begin(snapshot(ctx, process, decision, verdict: .proxy, server: server))
            let settings = engine.configuration.settings
            let plan = TCPRelay.Plan(
                proxyTarget: engine.upstreamTarget(for: ctx),
                directTarget: destination,
                upstream: .proxy(server),
                failurePolicy: settings.onProxyFailure,
                timeout: settings.connectTimeout,
                avoidTunnels: settings.upstreamAvoidTunnels
            )
            TCPRelay(flow: tcp, id: id, plan: plan, tracker: tracker).start()
            return true
        }
    }

    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        guard let destination = TargetAddress(endpoint: remoteEndpoint) else { return false }
        let engine = store.engine
        let (ctx, process) = context(for: flow, destination: destination, transport: .udp)
        let decision = engine.decide(ctx)

        switch decision.verdict {
        case .direct:
            recordDirect(ctx, process, decision)
            return false

        case .block:
            // UDP 阻断很常见（QUIC），不写日志，只记录连接。
            tracker.recordImmediate(snapshot(ctx, process, decision, verdict: .block))
            flow.reject()
            return true

        case let .proxy(server):
            let id = tracker.begin(snapshot(ctx, process, decision, verdict: .proxy, server: server))
            let settings = engine.configuration.settings
            UDPRelay(flow: flow, id: id, server: server, timeout: settings.connectTimeout,
                     avoidTunnels: settings.upstreamAvoidTunnels, tracker: tracker).start()
            return true
        }
    }

    // MARK: 辅助

    private func context(for flow: NEAppProxyFlow, destination: TargetAddress,
                         transport: FlowContext.Transport) -> (FlowContext, ProcessResolver.Info) {
        let meta = flow.metaData
        let signingID = meta.sourceAppSigningIdentifier
        let process = resolver.resolve(auditToken: meta.sourceAppAuditToken, signingID: signingID)
        let hostname = flow.remoteHostname.flatMap { $0.isEmpty ? nil : $0 }
        let ctx = FlowContext(signingID: signingID, executablePath: process.path, destination: destination,
                              hostname: hostname, transport: transport, isBound: flow.isBound)
        return (ctx, process)
    }

    private func recordDirect(_ ctx: FlowContext, _ process: ProcessResolver.Info, _ decision: Decision) {
        switch decision.reason {
        case .rule, .udpPolicy, .missingServer:
            tracker.recordImmediate(snapshot(ctx, process, decision, verdict: .direct))
        case .fakeIP:
            tracker.recordImmediate(snapshot(ctx, process, decision, verdict: .direct))
            tracker.logOnce(.warning, key: "fakeip:\(ctx.signingID)",
                            "\(process.name) 连接 fake-IP \(ctx.destination) 时没有域名，远程代理无法解析，已交给 TUN 工具处理（此提示每个应用只显示一次）")
        case .boundInterface where decision.rule != nil:
            tracker.recordImmediate(snapshot(ctx, process, decision, verdict: .direct))
            tracker.logOnce(.info, key: "bound:\(ctx.signingID)",
                            "\(process.name) 的连接绑定了网卡，按「绑定网卡的连接直连」放行（此提示每个应用只显示一次）")
        case .defaultAction, .systemProcess, .boundInterface:
            tracker.recordUnmatched(
                signingID: ctx.signingID, name: process.name, path: process.path,
                isSystem: RuleEngine.isSystemProcess(signingID: ctx.signingID, executablePath: ctx.executablePath),
                target: displayTarget(ctx)
            )
        case .loopback, .localNetwork, .proxyServer, .udpUnsupported, .dns:
            break
        }
    }

    private func displayTarget(_ ctx: FlowContext) -> String {
        if let h = ctx.hostname { return "\(h):\(ctx.destination.port)" }
        return ctx.destination.description
    }

    private func snapshot(_ ctx: FlowContext, _ process: ProcessResolver.Info, _ decision: Decision,
                          verdict: ConnectionVerdict, server: ProxyServer? = nil) -> ConnectionSnapshot {
        ConnectionSnapshot(
            id: 0,
            appName: process.name,
            signingID: ctx.signingID,
            executablePath: ctx.executablePath,
            transport: ctx.transport,
            target: displayTarget(ctx),
            verdict: verdict,
            reason: decision.reason,
            ruleName: decision.rule?.name,
            serverName: server.map { $0.name.isEmpty ? $0.endpointDescription : $0.name }
        )
    }
}

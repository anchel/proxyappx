import Foundation

/// 一个新连接的上下文，由扩展从 NEAppProxyFlow 中提取。
public struct FlowContext: Sendable, Hashable {
    public enum Transport: String, Codable, Sendable { case tcp = "TCP", udp = "UDP" }

    /// 来源进程的代码签名标识（`NEFlowMetaData.sourceAppSigningIdentifier`）。
    public var signingID: String
    /// 来源进程的可执行文件路径（由 audit token 解析，可能拿不到）。
    public var executablePath: String?
    /// 远端地址（通常是 IP）。
    public var destination: TargetAddress
    /// 应用连接时使用的域名（`NEAppProxyFlow.remoteHostname`）。
    public var hostname: String?
    public var transport: Transport
    /// 应用是否把这个连接绑定到了某块网卡（`NEAppProxyFlow.isBound`）。
    /// VPN / 代理内核常用这种方式绕开自己的 TUN，接管后会丢失绑定而形成回环。
    public var isBound: Bool

    public init(signingID: String, executablePath: String?, destination: TargetAddress, hostname: String?,
                transport: Transport, isBound: Bool = false) {
        self.signingID = signingID
        self.executablePath = executablePath
        self.destination = destination
        self.hostname = hostname
        self.transport = transport
        self.isBound = isBound
    }
}

public struct Decision: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case direct
        case block
        case proxy(ProxyServer)
    }

    public enum Reason: String, Sendable, Equatable, Codable {
        case rule                  // 命中应用规则
        case defaultAction         // 未命中规则，走默认动作
        case loopback              // 环回地址
        case localNetwork          // 局域网绕过
        case missingServer         // 规则引用的服务器不存在
        case udpPolicy             // 按规则的 UDP 策略处理
        case udpUnsupported        // 服务器不支持 UDP 转发
        case systemProcess         // 系统进程（未被规则显式命中时不走默认动作）
        case proxyServer           // 目标就是代理服务器本身，避免二次代理
        case dns                   // DNS 查询（系统会把解析请求归属到发起解析的应用）
        case boundInterface        // 应用把连接绑定到了网卡（通常是 VPN / 代理内核）
        case fakeIP                // 目标是 fake-IP 且没有域名，远程代理无法解析，交还给 TUN 工具

        public var displayName: String {
            switch self {
            case .rule: return L10n.t("Matched rule", "命中规则")
            case .defaultAction: return L10n.t("Default action", "默认动作")
            case .loopback: return L10n.t("Loopback", "环回地址")
            case .localNetwork: return L10n.t("Local network bypass", "局域网绕过")
            case .missingServer: return L10n.t("Proxy server missing", "代理服务器不存在")
            case .udpPolicy: return L10n.t("UDP policy", "UDP 策略")
            case .udpUnsupported: return L10n.t("Proxy can't relay UDP", "代理不支持 UDP")
            case .systemProcess: return L10n.t("System process", "系统进程")
            case .proxyServer: return L10n.t("Proxy server address", "代理服务器地址")
            case .dns: return L10n.t("DNS query", "DNS 查询")
            case .boundInterface: return L10n.t("Bound to an interface", "已绑定网卡")
            case .fakeIP: return L10n.t("Fake IP handed to TUN", "fake-IP 交给 TUN")
            }
        }
    }

    public var verdict: Verdict
    public var reason: Reason
    public var rule: AppRule?

    public init(verdict: Verdict, reason: Reason, rule: AppRule?) {
        self.verdict = verdict
        self.reason = reason
        self.rule = rule
    }
}

public struct RuleEngine: Sendable {
    public static let dnsPort: UInt16 = 53

    public let configuration: ProxyAppXConfig
    private let enabledRules: [AppRule]

    public init(configuration: ProxyAppXConfig) {
        self.configuration = configuration
        self.enabledRules = configuration.rules.filter { $0.enabled && !($0.bundleID.isEmpty && $0.path.isEmpty) }
    }

    // MARK: 匹配

    /// 匹配优先级：签名完全相等 = 3；进程位于规则 bundle 内或路径相等 = 2；签名前缀 `rule.` = 1。
    static func score(rule: AppRule, signingID: String, executablePath: String?) -> Int {
        let sid = signingID.lowercased()
        let rid = rule.bundleID.lowercased()
        if !rid.isEmpty && sid == rid { return 3 }

        if let exe = executablePath?.lowercased(), !rule.path.isEmpty {
            let rp = normalize(rule.path).lowercased()
            if exe == rp || exe.hasPrefix(rp + "/") { return 2 }
        }

        if !rid.isEmpty && sid.hasPrefix(rid + ".") { return 1 }
        return 0
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public func matchRule(signingID: String, executablePath: String?) -> AppRule? {
        var best: (rule: AppRule, score: Int)?
        for rule in enabledRules {
            let s = Self.score(rule: rule, signingID: signingID, executablePath: executablePath)
            guard s > 0 else { continue }
            if let b = best {
                if s > b.score || (s == b.score && rule.bundleID.count > b.rule.bundleID.count) {
                    best = (rule, s)
                }
            } else {
                best = (rule, s)
            }
        }
        return best?.rule
    }

    public func matches(_ app: UnmatchedApp) -> Bool {
        matchRule(signingID: app.signingID, executablePath: app.executablePath) != nil
    }

    // MARK: 决策

    public func decide(_ ctx: FlowContext) -> Decision {
        let settings = configuration.settings
        let isDNS = ctx.destination.port == Self.dnsPort
        let routeAppDNS = isDNS && settings.proxyAppDNS

        if ctx.destination.isLoopback || (ctx.hostname.map { TargetAddress(host: $0, port: 0).isLoopback } ?? false) {
            return Decision(verdict: .direct, reason: .loopback, rule: nil)
        }
        // DNS often targets a LAN router. The upstream proxy will connect to the configured resolver.
        if !routeAppDNS && settings.bypassLAN && ctx.destination.isLocalNetwork {
            return Decision(verdict: .direct, reason: .localNetwork, rule: nil)
        }
        if isProxyServerAddress(ctx) {
            return Decision(verdict: .direct, reason: .proxyServer, rule: nil)
        }
        // 系统 DNS 解析器永远直连，否则整机 DNS 会被阻断。
        if ctx.signingID == "com.apple.mDNSResponder" || (isDNS && ctx.executablePath == "/usr/sbin/mDNSResponder") {
            return Decision(verdict: .direct, reason: .systemProcess, rule: nil)
        }
        if isDNS && (!routeAppDNS || (ctx.signingID.isEmpty && ctx.executablePath?.isEmpty != false)) {
            return Decision(verdict: .direct, reason: .dns, rule: nil)
        }

        let rule = matchRule(signingID: ctx.signingID, executablePath: ctx.executablePath)
        if settings.bypassBoundFlows && ctx.isBound {
            return Decision(verdict: .direct, reason: .boundInterface, rule: rule)
        }
        if rule == nil, settings.defaultAction != .direct, settings.exemptSystemProcesses,
           Self.isSystemProcess(signingID: ctx.signingID, executablePath: ctx.executablePath) {
            return Decision(verdict: .direct, reason: .systemProcess, rule: nil)
        }
        let action = rule?.action ?? settings.defaultAction
        if routeAppDNS && !action.isProxy {
            return Decision(verdict: .direct, reason: .dns, rule: rule)
        }
        let udpPolicy = rule?.udpPolicy ?? settings.defaultUDPPolicy
        let reason: Decision.Reason = rule == nil ? .defaultAction : .rule

        switch action {
        case .direct:
            return Decision(verdict: .direct, reason: reason, rule: rule)
        case .block:
            return Decision(verdict: .block, reason: reason, rule: rule)
        case let .proxy(serverID):
            guard let server = configuration.server(id: serverID) else {
                let v: Decision.Verdict = !routeAppDNS && settings.onProxyFailure == .direct ? .direct : .block
                return Decision(verdict: v, reason: .missingServer, rule: rule)
            }
            if routeAppDNS {
                return Decision(verdict: .proxy(server), reason: .dns, rule: rule)
            }
            if needsFakeIPFallback(ctx, server: server) {
                return Decision(verdict: .direct, reason: .fakeIP, rule: rule)
            }
            guard ctx.transport == .udp else {
                return Decision(verdict: .proxy(server), reason: reason, rule: rule)
            }
            switch udpPolicy {
            case .block:
                return Decision(verdict: .block, reason: .udpPolicy, rule: rule)
            case .direct:
                return Decision(verdict: .direct, reason: .udpPolicy, rule: rule)
            case .proxy:
                if server.canRelayUDP {
                    return Decision(verdict: .proxy(server), reason: reason, rule: rule)
                }
                return Decision(verdict: .block, reason: .udpUnsupported, rule: rule)
            }
        }
    }

    /// 目标是 fake-IP、又拿不到域名时，远程代理收到的只能是 198.18.x.x，必然连不上；
    /// 这时把连接交还给系统，由制造 fake-IP 的 TUN 工具（Clash 等）还原并处理。
    /// 上游代理在本机时（多半就是那个 TUN 工具自己的端口）它能识别 fake-IP，照常转发。
    private func needsFakeIPFallback(_ ctx: FlowContext, server: ProxyServer) -> Bool {
        guard configuration.settings.fakeIPFallback, ctx.destination.isFakeIP else { return false }
        guard upstreamTarget(for: ctx).isFakeIP else { return false }
        return !TargetAddress(host: server.host, port: server.port).isLoopback
    }

    private func isProxyServerAddress(_ ctx: FlowContext) -> Bool {
        configuration.servers.contains { s in
            guard s.port == ctx.destination.port else { return false }
            let h = s.host.lowercased()
            return h == ctx.destination.host.lowercased() || h == ctx.hostname?.lowercased()
        }
    }

    /// Apple 签名且位于系统只读目录下的进程（守护进程、命令行工具等）。
    public static func isSystemProcess(signingID: String, executablePath: String?) -> Bool {
        guard signingID.hasPrefix("com.apple.") else { return false }
        guard let path = executablePath else { return true }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/"].contains { path.hasPrefix($0) }
    }

    /// 计算要交给代理的目标地址：开启 preferHostname 且有域名时用域名（远程解析）。
    /// 目标是 fake-IP 时，只要有域名就一定用域名（fake-IP 对远程代理没有意义）。
    public func upstreamTarget(for ctx: FlowContext) -> TargetAddress {
        let useName = configuration.settings.preferHostname || ctx.destination.isFakeIP
        if useName, let name = ctx.hostname, !name.isEmpty,
           TargetAddress(host: name, port: ctx.destination.port).isIPAddress == false {
            return TargetAddress(host: name, port: ctx.destination.port)
        }
        return ctx.destination
    }
}

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

    public init(signingID: String, executablePath: String?, destination: TargetAddress, hostname: String?, transport: Transport) {
        self.signingID = signingID
        self.executablePath = executablePath
        self.destination = destination
        self.hostname = hostname
        self.transport = transport
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

        public var displayName: String {
            switch self {
            case .rule: return "命中规则"
            case .defaultAction: return "默认动作"
            case .loopback: return "环回地址"
            case .localNetwork: return "局域网绕过"
            case .missingServer: return "代理服务器不存在"
            case .udpPolicy: return "UDP 策略"
            case .udpUnsupported: return "代理不支持 UDP"
            case .systemProcess: return "系统进程"
            case .proxyServer: return "代理服务器地址"
            case .dns: return "DNS 查询"
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

    // MARK: 决策

    public func decide(_ ctx: FlowContext) -> Decision {
        let settings = configuration.settings

        if ctx.destination.isLoopback || (ctx.hostname.map { TargetAddress(host: $0, port: 0).isLoopback } ?? false) {
            return Decision(verdict: .direct, reason: .loopback, rule: nil)
        }
        if settings.bypassLAN && ctx.destination.isLocalNetwork {
            return Decision(verdict: .direct, reason: .localNetwork, rule: nil)
        }
        if isProxyServerAddress(ctx) {
            return Decision(verdict: .direct, reason: .proxyServer, rule: nil)
        }
        // 系统 DNS 解析器永远直连，否则整机 DNS 会被阻断。
        if ctx.signingID == "com.apple.mDNSResponder" {
            return Decision(verdict: .direct, reason: .systemProcess, rule: nil)
        }
        // 系统把 getaddrinfo 等发出的 DNS 查询归属到发起解析的应用本身，
        // 若按应用的 UDP 策略阻断，应用会因无法解析域名而无法联网，所以 DNS 一律直连。
        if ctx.destination.port == Self.dnsPort {
            return Decision(verdict: .direct, reason: .dns, rule: nil)
        }

        let rule = matchRule(signingID: ctx.signingID, executablePath: ctx.executablePath)
        if rule == nil, settings.defaultAction != .direct, settings.exemptSystemProcesses,
           Self.isSystemProcess(signingID: ctx.signingID, executablePath: ctx.executablePath) {
            return Decision(verdict: .direct, reason: .systemProcess, rule: nil)
        }
        let action = rule?.action ?? settings.defaultAction
        let udpPolicy = rule?.udpPolicy ?? settings.defaultUDPPolicy
        let reason: Decision.Reason = rule == nil ? .defaultAction : .rule

        switch action {
        case .direct:
            return Decision(verdict: .direct, reason: reason, rule: rule)
        case .block:
            return Decision(verdict: .block, reason: reason, rule: rule)
        case let .proxy(serverID):
            guard let server = configuration.server(id: serverID) else {
                let v: Decision.Verdict = settings.onProxyFailure == .direct ? .direct : .block
                return Decision(verdict: v, reason: .missingServer, rule: rule)
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
    public func upstreamTarget(for ctx: FlowContext) -> TargetAddress {
        if configuration.settings.preferHostname, let name = ctx.hostname, !name.isEmpty,
           TargetAddress(host: name, port: ctx.destination.port).isIPAddress == false {
            return TargetAddress(host: name, port: ctx.destination.port)
        }
        return ctx.destination
    }
}

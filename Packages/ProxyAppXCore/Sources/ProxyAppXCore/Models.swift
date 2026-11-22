import Foundation

// MARK: - 代理服务器

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case socks5
    case http

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        }
    }

    public var defaultPort: UInt16 {
        switch self {
        case .socks5: return 1080
        case .http: return 8080
        }
    }
}

public struct ProxyServer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProxyProtocol
    public var host: String
    public var port: UInt16
    public var username: String
    /// 在 App 侧落盘时始终为 nil（密码保存在钥匙串），只在下发给扩展时才填充。
    public var password: String?
    /// 仅对 SOCKS5 有意义：服务器是否支持 UDP ASSOCIATE。
    public var supportsUDP: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProxyProtocol,
        host: String,
        port: UInt16,
        username: String = "",
        password: String? = nil,
        supportsUDP: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.supportsUDP = supportsUDP
    }

    public var hasCredentials: Bool { !username.isEmpty }

    public var canRelayUDP: Bool { type == .socks5 && supportsUDP }

    public var endpointDescription: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return "\(type.displayName) \(h):\(port)"
    }

    enum CodingKeys: String, CodingKey { case id, name, type, host, port, username, password, supportsUDP }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(ProxyProtocol.self, forKey: .type) ?? .socks5
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password)
        supportsUDP = try c.decodeIfPresent(Bool.self, forKey: .supportsUDP) ?? false
    }
}

// MARK: - 规则

public enum RuleAction: Codable, Hashable, Sendable {
    case proxy(serverID: UUID)
    case direct
    case block

    public var serverID: UUID? {
        if case let .proxy(id) = self { return id }
        return nil
    }

    public var isProxy: Bool { serverID != nil }
}

public enum UDPPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 阻断 UDP（浏览器会把 QUIC 回落到 TCP，防止泄漏）
    case block
    /// UDP 直连
    case direct
    /// 经 SOCKS5 UDP ASSOCIATE 转发
    case proxy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .block: return L10n.t("Block (recommended)", "阻断（推荐）")
        case .direct: return L10n.t("Direct", "直连")
        case .proxy: return L10n.t("Relay via SOCKS5", "经 SOCKS5 转发")
        }
    }
}

public struct AppRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 代码签名标识。对 .app 来说一般就是 Bundle ID，对命令行工具来说如 `com.apple.curl`。
    public var bundleID: String
    /// .app bundle 的路径，或可执行文件的路径。
    public var path: String
    public var action: RuleAction
    public var udpPolicy: UDPPolicy
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        bundleID: String,
        path: String,
        action: RuleAction,
        udpPolicy: UDPPolicy = .block,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.action = action
        self.udpPolicy = udpPolicy
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, bundleID, path, action, udpPolicy, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action) ?? .direct
        udpPolicy = try c.decodeIfPresent(UDPPolicy.self, forKey: .udpPolicy) ?? .block
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - 全局设置

public enum FailurePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 代理不可用时断开连接（不泄漏）
    case block
    /// 代理不可用时回落直连
    case direct

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .block: return L10n.t("Block the connection (recommended)", "阻断连接（推荐）")
        case .direct: return L10n.t("Fall back to direct", "回落直连")
        }
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    /// 未命中任何规则时的动作。设为 `.proxy` 即「排除模式」。
    public var defaultAction: RuleAction
    /// 默认动作为代理时，UDP 的处理方式。
    public var defaultUDPPolicy: UDPPolicy
    public var onProxyFailure: FailurePolicy
    /// 系统提供了目标域名时，把域名交给代理解析。
    public var preferHostname: Bool
    /// 局域网、私有地址一律直连。
    public var bypassLAN: Bool
    /// 连接加握手的超时时间（秒）。
    public var connectTimeout: Double
    /// 默认动作不是直连时，未被规则显式命中的系统进程（Apple 签名、位于 /System、/usr 等）仍然直连。
    public var exemptSystemProcesses: Bool
    /// 应用绑定到网卡的连接（VPN / 代理内核用来绕开 TUN）一律直连，避免回环。
    public var bypassBoundFlows: Bool
    /// 目标是 fake-IP 且拿不到域名、上游代理又不在本机时，交还给 TUN 工具处理。
    public var fakeIPFallback: Bool
    /// 扩展连接上游代理时不经过其他 VPN / TUN 网卡（utun 等），直接走物理网卡。
    public var upstreamAvoidTunnels: Bool

    public init(
        defaultAction: RuleAction = .direct,
        defaultUDPPolicy: UDPPolicy = .block,
        onProxyFailure: FailurePolicy = .block,
        preferHostname: Bool = true,
        bypassLAN: Bool = true,
        connectTimeout: Double = 10,
        exemptSystemProcesses: Bool = true,
        bypassBoundFlows: Bool = true,
        fakeIPFallback: Bool = true,
        upstreamAvoidTunnels: Bool = false
    ) {
        self.defaultAction = defaultAction
        self.defaultUDPPolicy = defaultUDPPolicy
        self.onProxyFailure = onProxyFailure
        self.preferHostname = preferHostname
        self.bypassLAN = bypassLAN
        self.connectTimeout = connectTimeout
        self.exemptSystemProcesses = exemptSystemProcesses
        self.bypassBoundFlows = bypassBoundFlows
        self.fakeIPFallback = fakeIPFallback
        self.upstreamAvoidTunnels = upstreamAvoidTunnels
    }

    enum CodingKeys: String, CodingKey {
        case defaultAction, defaultUDPPolicy, onProxyFailure, preferHostname, bypassLAN, connectTimeout, exemptSystemProcesses
        case bypassBoundFlows, fakeIPFallback, upstreamAvoidTunnels
    }

    public init(from decoder: Decoder) throws {
        let d = GeneralSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultAction = try c.decodeIfPresent(RuleAction.self, forKey: .defaultAction) ?? d.defaultAction
        defaultUDPPolicy = try c.decodeIfPresent(UDPPolicy.self, forKey: .defaultUDPPolicy) ?? d.defaultUDPPolicy
        onProxyFailure = try c.decodeIfPresent(FailurePolicy.self, forKey: .onProxyFailure) ?? d.onProxyFailure
        preferHostname = try c.decodeIfPresent(Bool.self, forKey: .preferHostname) ?? d.preferHostname
        bypassLAN = try c.decodeIfPresent(Bool.self, forKey: .bypassLAN) ?? d.bypassLAN
        connectTimeout = try c.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? d.connectTimeout
        exemptSystemProcesses = try c.decodeIfPresent(Bool.self, forKey: .exemptSystemProcesses) ?? d.exemptSystemProcesses
        bypassBoundFlows = try c.decodeIfPresent(Bool.self, forKey: .bypassBoundFlows) ?? d.bypassBoundFlows
        fakeIPFallback = try c.decodeIfPresent(Bool.self, forKey: .fakeIPFallback) ?? d.fakeIPFallback
        upstreamAvoidTunnels = try c.decodeIfPresent(Bool.self, forKey: .upstreamAvoidTunnels) ?? d.upstreamAvoidTunnels
    }
}

// MARK: - 完整配置

public struct ProxyAppXConfig: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// App 当前的界面语言；扩展据此生成日志和错误信息的语言。
    public var language: AppLanguage?
    public var servers: [ProxyServer]
    public var rules: [AppRule]
    public var settings: GeneralSettings

    public init(
        servers: [ProxyServer] = [],
        rules: [AppRule] = [],
        settings: GeneralSettings = GeneralSettings()
    ) {
        self.version = Self.currentVersion
        self.servers = servers
        self.rules = rules
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey { case version, language, servers, rules, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        language = try? c.decodeIfPresent(AppLanguage.self, forKey: .language)
        servers = try c.decodeIfPresent([ProxyServer].self, forKey: .servers) ?? []
        rules = try c.decodeIfPresent([AppRule].self, forKey: .rules) ?? []
        settings = try c.decodeIfPresent(GeneralSettings.self, forKey: .settings) ?? GeneralSettings()
    }

    public func server(id: UUID) -> ProxyServer? {
        servers.first { $0.id == id }
    }

    /// 去掉所有密码（用于落盘或导出）。
    public func redacted() -> ProxyAppXConfig {
        var copy = self
        copy.servers = copy.servers.map { var s = $0; s.password = nil; return s }
        return copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProxyAppXConfig {
        try JSONDecoder().decode(ProxyAppXConfig.self, from: data)
    }
}

/// `NETunnelProviderProtocol.providerConfiguration` 里使用的键。
public enum ProviderConfigurationKey {
    public static let configuration = "configuration"
}

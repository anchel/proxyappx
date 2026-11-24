import Foundation

/// App → 扩展的消息（经 `NETunnelProviderSession.sendProviderMessage` 传输，JSON 编码）。
public enum IPCRequest: Codable, Sendable {
    case updateConfiguration(ProxyAppXConfig)
    /// 获取状态。`logsAfter` 为客户端已拿到的最后一条日志 id，只返回更新的日志。
    case status(logsAfter: UInt64?)
    case clearLogs

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> IPCRequest { try JSONDecoder().decode(IPCRequest.self, from: data) }
}

public enum IPCResponse: Codable, Sendable {
    case ok
    case status(StatusSnapshot)
    case error(String)

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> IPCResponse { try JSONDecoder().decode(IPCResponse.self, from: data) }
}

public enum ConnectionVerdict: String, Codable, Sendable {
    case proxy
    case direct
    case block
    /// 代理失败后回落直连
    case fallbackDirect
}

public struct ConnectionSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UInt64
    public var appName: String
    public var signingID: String
    public var executablePath: String?
    public var transport: FlowContext.Transport
    /// 展示用的目标（域名优先）
    public var target: String
    public var verdict: ConnectionVerdict
    public var reason: Decision.Reason
    public var ruleID: UUID?
    public var ruleName: String?
    public var serverName: String?
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var startedAt: Date
    public var endedAt: Date?
    public var error: String?

    public init(
        id: UInt64, appName: String, signingID: String, executablePath: String?,
        transport: FlowContext.Transport, target: String, verdict: ConnectionVerdict,
        reason: Decision.Reason, ruleID: UUID? = nil, ruleName: String?, serverName: String?,
        bytesUp: UInt64 = 0, bytesDown: UInt64 = 0, startedAt: Date = Date(),
        endedAt: Date? = nil, error: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.signingID = signingID
        self.executablePath = executablePath
        self.transport = transport
        self.target = target
        self.verdict = verdict
        self.reason = reason
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.serverName = serverName
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
    }
}

public struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        case debug, info, warning, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public var id: UInt64
    public var date: Date
    public var level: Level
    public var message: String

    public init(id: UInt64, date: Date = Date(), level: Level, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct RuleTraffic: Codable, Hashable, Sendable {
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0

    public init() {}
}

public struct TrafficTotals: Codable, Hashable, Sendable {
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0
    public var proxied: UInt64 = 0
    public var direct: UInt64 = 0
    public var blocked: UInt64 = 0
    public var failed: UInt64 = 0

    public init() {}
}

/// 最近出现过、但没有命中任何规则的进程（按签名标识聚合），方便用户发现 helper 进程并添加规则。
public struct UnmatchedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: String { signingID }
    public var signingID: String
    public var appName: String
    public var executablePath: String?
    public var isSystem: Bool
    public var flowCount: UInt64
    public var lastTarget: String
    public var lastSeen: Date

    public init(signingID: String, appName: String, executablePath: String?, isSystem: Bool,
                flowCount: UInt64, lastTarget: String, lastSeen: Date) {
        self.signingID = signingID
        self.appName = appName
        self.executablePath = executablePath
        self.isSystem = isSystem
        self.flowCount = flowCount
        self.lastTarget = lastTarget
        self.lastSeen = lastSeen
    }
}

public struct StatusSnapshot: Codable, Sendable {
    public var startedAt: Date
    public var extensionVersion: String
    public var ruleCount: Int
    public var active: [ConnectionSnapshot]
    public var recent: [ConnectionSnapshot]
    public var unmatched: [UnmatchedApp]
    public var totals: TrafficTotals
    /// 旧版本扩展不提供按规则统计的流量。
    public var trafficByRule: [UUID: RuleTraffic]?
    public var logs: [LogEntry]

    public init(
        startedAt: Date, extensionVersion: String, ruleCount: Int,
        active: [ConnectionSnapshot], recent: [ConnectionSnapshot], unmatched: [UnmatchedApp] = [],
        totals: TrafficTotals, trafficByRule: [UUID: RuleTraffic]? = nil, logs: [LogEntry]
    ) {
        self.startedAt = startedAt
        self.extensionVersion = extensionVersion
        self.ruleCount = ruleCount
        self.active = active
        self.recent = recent
        self.unmatched = unmatched
        self.totals = totals
        self.trafficByRule = trafficByRule
        self.logs = logs
    }
}

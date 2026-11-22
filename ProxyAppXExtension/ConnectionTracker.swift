import Foundation
import os
import ProxyAppXCore

/// 记录连接、流量统计和日志，供 App 通过 IPC 查询。所有状态只保存在内存中。
final class ConnectionTracker: @unchecked Sendable {
    static let shared = ConnectionTracker()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.proxyappx.extension", category: "proxy")

    let startedAt = Date()
    private var nextConnectionID: UInt64 = 1
    private var nextLogID: UInt64 = 1
    private var active: [UInt64: ConnectionSnapshot] = [:]
    private var recent: [ConnectionSnapshot] = []
    private var unmatched: [String: UnmatchedApp] = [:]
    private var logs: [LogEntry] = []
    private var totals = TrafficTotals()

    private let recentCapacity = 300
    private let unmatchedCapacity = 200
    private let logCapacity = 500

    // MARK: 连接

    /// 登记一个由扩展接管的连接（代理），返回连接 id。
    func begin(_ snapshot: ConnectionSnapshot) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextConnectionID
        nextConnectionID += 1
        var s = snapshot
        s.id = id
        active[id] = s
        totals.proxied += 1
        return id
    }

    /// 记录一个直接结束的决策（命中规则的直连、阻断）。
    func recordImmediate(_ snapshot: ConnectionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        var s = snapshot
        s.id = nextConnectionID
        nextConnectionID += 1
        s.endedAt = s.startedAt
        switch s.verdict {
        case .block: totals.blocked += 1
        default: totals.direct += 1
        }
        appendRecent(s)
    }

    /// 记录未命中规则的直连流量（只做聚合，不进入最近连接列表）。
    func recordUnmatched(signingID: String, name: String, path: String?, isSystem: Bool, target: String) {
        lock.lock()
        defer { lock.unlock() }
        totals.direct += 1
        if var u = unmatched[signingID] {
            u.flowCount += 1
            u.lastTarget = target
            u.lastSeen = Date()
            if u.executablePath == nil { u.executablePath = path }
            unmatched[signingID] = u
            return
        }
        if unmatched.count >= unmatchedCapacity,
           let oldest = unmatched.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            unmatched.removeValue(forKey: oldest)
        }
        unmatched[signingID] = UnmatchedApp(signingID: signingID, appName: name, executablePath: path,
                                            isSystem: isSystem, flowCount: 1, lastTarget: target, lastSeen: Date())
    }

    func markFallback(_ id: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        active[id]?.verdict = .fallbackDirect
    }

    func addBytes(_ id: UInt64, up: Int = 0, down: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        active[id]?.bytesUp += UInt64(up)
        active[id]?.bytesDown += UInt64(down)
        totals.bytesUp += UInt64(up)
        totals.bytesDown += UInt64(down)
    }

    func finish(_ id: UInt64, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard var s = active.removeValue(forKey: id) else { return }
        s.endedAt = Date()
        s.error = error
        if error != nil && s.bytesDown == 0 { totals.failed += 1 }
        appendRecent(s)
    }

    private func appendRecent(_ s: ConnectionSnapshot) {
        recent.append(s)
        if recent.count > recentCapacity { recent.removeFirst(recent.count - recentCapacity) }
    }

    // MARK: 日志

    func log(_ level: LogEntry.Level, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        lock.lock()
        defer { lock.unlock() }
        logs.append(LogEntry(id: nextLogID, level: level, message: message))
        nextLogID += 1
        if logs.count > logCapacity { logs.removeFirst(logs.count - logCapacity) }
    }

    /// 只写系统日志（log stream 可见），不进入 App 的日志列表。
    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private var loggedKeys = Set<String>()

    /// 同一个 key 只记录一次，用于高频但只需提示一次的情况。
    func logOnce(_ level: LogEntry.Level, key: String, _ message: String) {
        lock.lock()
        let inserted = loggedKeys.insert(key).inserted
        if loggedKeys.count > 1000 { loggedKeys.removeAll() }
        lock.unlock()
        if inserted { log(level, message) }
    }

    func clearLogs() {
        lock.lock()
        defer { lock.unlock() }
        logs.removeAll()
        recent.removeAll()
        unmatched.removeAll()
    }

    // MARK: 快照

    func snapshot(logsAfter: UInt64?, ruleCount: Int) -> StatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let newLogs = logsAfter.map { after in logs.filter { $0.id > after } } ?? logs
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return StatusSnapshot(
            startedAt: startedAt,
            extensionVersion: version,
            ruleCount: ruleCount,
            active: active.values.sorted { $0.startedAt > $1.startedAt },
            recent: recent.reversed(),
            unmatched: unmatched.values.sorted { $0.lastSeen > $1.lastSeen },
            totals: totals,
            logs: newLogs
        )
    }
}

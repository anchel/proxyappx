import Foundation
import Network

/// 出口：直连目标或经由代理服务器。
public enum Upstream: Sendable, Equatable {
    case direct
    case proxy(ProxyServer)

    public var label: String {
        switch self {
        case .direct: return "直连"
        case let .proxy(s): return s.name.isEmpty ? s.endpointDescription : s.name
        }
    }
}

/// 线程安全的可变引用盒子。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// 一次性定时器：到期时执行 onFire（例如取消连接），可在到期前解除。
final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var disarmed = false

    init(seconds: TimeInterval, onFire: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldFire = !self.disarmed
            if shouldFire { self.fired = true }
            self.lock.unlock()
            if shouldFire { onFire() }
        }
    }

    /// 返回 true 表示在到期前成功解除；false 表示已经到期。
    func disarm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        disarmed = true
        return true
    }
}

public enum ProxyConnector {
    /// 建立到 `target` 的 TCP 通道。返回时已完成代理握手，可以直接收发应用数据。
    /// 握手阶段多读到的数据保存在连接的缓冲区里，后续 `receive()` 会先返回这些数据。
    public static func connect(
        to target: TargetAddress,
        via upstream: Upstream,
        timeout: TimeInterval,
        queue: DispatchQueue? = nil
    ) async throws -> AsyncConnection {
        let endpoint: NWEndpoint
        switch upstream {
        case .direct:
            endpoint = target.nwEndpoint
        case let .proxy(server):
            endpoint = TargetAddress(host: server.host, port: server.port).nwEndpoint
        }

        let conn = AsyncConnection(
            endpoint: endpoint,
            parameters: AsyncConnection.tcpParameters(connectTimeout: timeout),
            queue: queue
        )
        let deadline = Deadline(seconds: timeout) { conn.cancel() }

        do {
            try await conn.start()
            if case let .proxy(server) = upstream {
                switch server.type {
                case .socks5:
                    _ = try await socks5Handshake(conn, server: server, command: .connect, target: target)
                case .http:
                    try await httpHandshake(conn, server: server, target: target)
                }
            }
            guard deadline.disarm() else { throw ProxyError.timeout }
            return conn
        } catch {
            let timedOut = !deadline.disarm()
            conn.cancel()
            throw timedOut ? ProxyError.timeout : error
        }
    }

    /// SOCKS5 握手，返回服务器应答中的 BND.ADDR:BND.PORT。
    @discardableResult
    static func socks5Handshake(
        _ c: AsyncConnection,
        server: ProxyServer,
        command: SOCKS5.Command,
        target: TargetAddress
    ) async throws -> TargetAddress {
        try await c.send(SOCKS5.greeting(offerUserPass: server.hasCredentials))
        let method = try SOCKS5.parseMethodSelection(try await c.readExactly(2))
        switch method {
        case .noAuth:
            break
        case .userPass:
            guard server.hasCredentials else { throw ProxyError.authenticationRequired }
            try await c.send(try SOCKS5.userPassRequest(username: server.username, password: server.password ?? ""))
            try SOCKS5.parseUserPassReply(try await c.readExactly(2))
        case .noAcceptable:
            throw ProxyError.noAcceptableAuthMethod
        }

        try await c.send(try SOCKS5.request(command, target: target))
        let head = try await c.readExactly(5)
        let rest = try await c.readExactly(try SOCKS5.remainingReplyLength(afterFirstFive: [UInt8](head)))
        return try SOCKS5.parseReply(head + rest)
    }

    static func httpHandshake(_ c: AsyncConnection, server: ProxyServer, target: TargetAddress) async throws {
        try await c.send(HTTPConnect.request(target: target, username: server.username, password: server.password))
        let header = try await c.readUntil(HTTPConnect.headerTerminator, maxLength: HTTPConnect.maxHeaderLength)
        try HTTPConnect.parseResponse(header)
    }

    /// 连通性测试：经代理与目标建立隧道，返回耗时（秒）。
    public static func test(
        server: ProxyServer,
        target: TargetAddress = TargetAddress(host: "www.apple.com", port: 443),
        timeout: TimeInterval = 10
    ) async throws -> TimeInterval {
        let clock = ContinuousClock()
        let start = clock.now
        let conn = try await connect(to: target, via: .proxy(server), timeout: timeout)
        let elapsed = clock.now - start
        conn.cancel()
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// SOCKS5 UDP ASSOCIATE 会话：TCP 控制连接保持存活，数据报经中继地址收发。
public final class SOCKS5UDPAssociation: @unchecked Sendable {
    public let control: AsyncConnection
    public let relay: AsyncDatagramConnection
    public let relayAddress: TargetAddress

    init(control: AsyncConnection, relay: AsyncDatagramConnection, relayAddress: TargetAddress) {
        self.control = control
        self.relay = relay
        self.relayAddress = relayAddress
    }

    public static func open(server: ProxyServer, timeout: TimeInterval, queue: DispatchQueue? = nil) async throws -> SOCKS5UDPAssociation {
        guard server.type == .socks5 else { throw ProxyError.unsupported("HTTP 代理不支持 UDP") }
        let control = AsyncConnection(
            endpoint: TargetAddress(host: server.host, port: server.port).nwEndpoint,
            parameters: AsyncConnection.tcpParameters(connectTimeout: timeout),
            queue: queue
        )
        let relayBox = Box<AsyncDatagramConnection>()
        let deadline = Deadline(seconds: timeout) {
            control.cancel()
            relayBox.value?.cancel()
        }
        do {
            try await control.start()
            let bnd = try await ProxyConnector.socks5Handshake(
                control, server: server, command: .udpAssociate,
                target: TargetAddress(host: "0.0.0.0", port: 0)
            )
            // 服务器返回未指定地址时，中继就在代理服务器本身。
            let unspecified = bnd.host == "0.0.0.0" || bnd.host == "::"
            let relayAddr = unspecified ? TargetAddress(host: server.host, port: bnd.port) : bnd
            let r = AsyncDatagramConnection(endpoint: relayAddr.nwEndpoint, queue: queue)
            relayBox.value = r
            try await r.start()
            guard deadline.disarm() else { throw ProxyError.timeout }
            return SOCKS5UDPAssociation(control: control, relay: r, relayAddress: relayAddr)
        } catch {
            let timedOut = !deadline.disarm()
            control.cancel()
            relayBox.value?.cancel()
            throw timedOut ? ProxyError.timeout : error
        }
    }

    public func send(_ payload: Data, to target: TargetAddress) async throws {
        try await relay.send(try SOCKS5.encapsulateUDP(payload, to: target))
    }

    /// 读取一个来自中继的报文，返回（来源地址，载荷）。
    public func receive() async throws -> (TargetAddress, Data) {
        try SOCKS5.decapsulateUDP(try await relay.receive())
    }

    /// 等待控制连接被代理关闭（关联结束）。
    public func waitForControlClose() async {
        while true {
            do {
                guard try await control.receive() != nil else { return }
            } catch {
                return
            }
        }
    }

    public func close() {
        relay.cancel()
        control.cancel()
    }
}

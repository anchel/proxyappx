import Foundation
import Network

/// 保证 continuation 只 resume 一次。
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func tryMark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

func describe(_ error: Error) -> String {
    if let nw = error as? NWError {
        switch nw {
        case let .posix(code): return String(cString: strerror(code.rawValue))
        case let .dns(code): return "DNS 解析失败（\(code)）"
        case let .tls(status): return "TLS 错误（\(status)）"
        default: return "\(nw)"
        }
    }
    if let p = error as? ProxyError { return p.localizedDescription }
    return error.localizedDescription
}

/// 基于 NWConnection 的 async/await TCP 连接封装，带读缓冲。
///
/// 约定：同一时刻最多一个读者、一个写者（中继的两个方向各占一个），因此不需要加锁。
public final class AsyncConnection: @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue

    private var buffer = Data()
    private var eof = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public convenience init(endpoint: NWEndpoint, parameters: NWParameters, queue: DispatchQueue? = nil) {
        let q = queue ?? DispatchQueue(label: "proxyappx.conn", qos: .userInitiated)
        self.init(connection: NWConnection(to: endpoint, using: parameters), queue: q)
    }

    public static func tcpParameters(connectTimeout: TimeInterval) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let params = NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        return params
    }

    /// 启动连接并等待 `.ready`。`.waiting` 视为失败（不做自动重试）。
    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.tryMark() { cont.resume() }
                case let .waiting(err):
                    if once.tryMark() {
                        cont.resume(throwing: ProxyError.connectionFailed(describe(err)))
                        self?.connection.cancel()
                    }
                case let .failed(err):
                    if once.tryMark() { cont.resume(throwing: ProxyError.connectionFailed(describe(err))) }
                case .cancelled:
                    if once.tryMark() { cont.resume(throwing: ProxyError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func cancel() {
        connection.cancel()
    }

    // MARK: 写

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    /// 半关闭写方向（发送 FIN）。
    public func sendEOF() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    // MARK: 读

    /// 读取至多 `maximumLength` 字节；返回 nil 表示对端已关闭写方向（EOF）。
    public func receive(maximumLength: Int = 64 * 1024) async throws -> Data? {
        if !buffer.isEmpty {
            let n = min(buffer.count, maximumLength)
            return consume(n)
        }
        while true {
            guard let chunk = try await receiveRaw(maximumLength: maximumLength) else { return nil }
            if !chunk.isEmpty { return chunk }
        }
    }

    /// 精确读取 n 字节，不足则抛出 connectionClosed。
    public func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n {
            guard let chunk = try await receiveRaw(maximumLength: max(n - buffer.count, 512)) else {
                throw ProxyError.connectionClosed
            }
            buffer.append(chunk)
        }
        return consume(n)
    }

    /// 读取直到（并包含）分隔符；多读的字节保留在缓冲区。
    public func readUntil(_ delimiter: Data, maxLength: Int) async throws -> Data {
        var searchFrom = 0
        while true {
            if let r = buffer.range(of: delimiter, in: searchFrom..<buffer.count) {
                return consume(r.upperBound)
            }
            if buffer.count > maxLength { throw ProxyError.protocolViolation("响应头过长") }
            searchFrom = max(0, buffer.count - delimiter.count + 1)
            guard let chunk = try await receiveRaw(maximumLength: 4096) else { throw ProxyError.connectionClosed }
            buffer.append(chunk)
        }
    }

    /// 取出握手阶段多读的数据。
    public func takeBuffered() -> Data {
        let d = buffer
        buffer = Data()
        return d
    }

    private func consume(_ n: Int) -> Data {
        let head = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return head
    }

    private func receiveRaw(maximumLength: Int) async throws -> Data? {
        if eof { return nil }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { [weak self] data, _, isComplete, error in
                if isComplete { self?.eof = true }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }
}

/// UDP 连接封装（一条 NWConnection 对应一个远端）。
public final class AsyncDatagramConnection: @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue

    public init(endpoint: NWEndpoint, queue: DispatchQueue? = nil) {
        let params = NWParameters.udp
        params.preferNoProxies = true
        self.queue = queue ?? DispatchQueue(label: "proxyappx.udp", qos: .userInitiated)
        self.connection = NWConnection(to: endpoint, using: params)
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.tryMark() { cont.resume() }
                case let .waiting(err):
                    if once.tryMark() {
                        cont.resume(throwing: ProxyError.connectionFailed(describe(err)))
                        self?.connection.cancel()
                    }
                case let .failed(err):
                    if once.tryMark() { cont.resume(throwing: ProxyError.connectionFailed(describe(err))) }
                case .cancelled:
                    if once.tryMark() { cont.resume(throwing: ProxyError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    /// 读取一个报文；连接被取消时抛错。
    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }

    public func cancel() {
        connection.cancel()
    }
}

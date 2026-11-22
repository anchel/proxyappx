import Foundation
import Network
@testable import ProxyAppXCore

/// 测试用的本地服务器，全部监听 127.0.0.1 上的随机端口。
class TestListener: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.listener")
    private(set) var port: UInt16 = 0

    init(udp: Bool = false) throws {
        let params: NWParameters = udp ? .udp : .tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let c = AsyncConnection(connection: conn, queue: DispatchQueue(label: "test.conn"))
            Task { await self.handle(c) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.tryMark() { cont.resume() }
                case let .failed(e): if once.tryMark() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port!.rawValue
        return port
    }

    func handle(_ c: AsyncConnection) async {}

    func stop() { listener.cancel() }
}

/// TCP 回显服务器。
final class EchoServer: TestListener, @unchecked Sendable {
    override func handle(_ c: AsyncConnection) async {
        do {
            try await c.start()
            while let d = try await c.receive() { try await c.send(d) }
            try await c.sendEOF()
        } catch {}
    }
}

/// 只接受连接、从不应答（用于超时测试）。
final class SilentServer: TestListener, @unchecked Sendable {
    var held: [AsyncConnection] = []
    override func handle(_ c: AsyncConnection) async {
        held.append(c)
        try? await c.start()
    }
}

/// UDP 回显服务器：每个对端一个 NWConnection。
final class UDPEchoServer: TestListener, @unchecked Sendable {
    init() throws { try super.init(udp: true) }

    override func start() async throws -> UInt16 {
        listener.newConnectionHandler = { conn in
            conn.start(queue: DispatchQueue(label: "test.udp"))
            func loop() {
                conn.receiveMessage { data, _, _, err in
                    guard err == nil, let data else { return }
                    conn.send(content: Data("echo:".utf8) + data, completion: .contentProcessed { _ in loop() })
                }
            }
            loop()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.tryMark() { cont.resume() }
                if case let .failed(e) = state, once.tryMark() { cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        return listener.port!.rawValue
    }
}

/// 最小 SOCKS5 服务器：支持无认证 / 用户名密码、CONNECT、UDP ASSOCIATE。
final class MiniSOCKS5Server: TestListener, @unchecked Sendable {
    let credentials: (String, String)?
    private(set) var lastTarget: TargetAddress?
    private var udpServers: [MiniUDPRelay] = []

    init(credentials: (String, String)? = nil) throws {
        self.credentials = credentials
        try super.init()
    }

    override func handle(_ c: AsyncConnection) async {
        do {
            try await c.start()
            let head = [UInt8](try await c.readExactly(2))
            guard head[0] == 5 else { return c.cancel() }
            let methods = [UInt8](try await c.readExactly(Int(head[1])))

            if let (user, pass) = credentials {
                guard methods.contains(2) else {
                    try await c.send(Data([5, 0xFF])); return c.cancel()
                }
                try await c.send(Data([5, 2]))
                let v = [UInt8](try await c.readExactly(2))
                let u = String(decoding: try await c.readExactly(Int(v[1])), as: UTF8.self)
                let pl = [UInt8](try await c.readExactly(1))[0]
                let p = String(decoding: try await c.readExactly(Int(pl)), as: UTF8.self)
                guard u == user, p == pass else {
                    try await c.send(Data([1, 1])); return c.cancel()
                }
                try await c.send(Data([1, 0]))
            } else {
                try await c.send(Data([5, 0]))
            }

            let req = [UInt8](try await c.readExactly(4))
            let target = try await readAddress(c, atyp: req[3])
            lastTarget = target

            switch req[1] {
            case 1: // CONNECT
                let upstream: AsyncConnection
                do {
                    upstream = try await ProxyConnector.connect(to: target, via: .direct, timeout: 5)
                } catch {
                    try await c.send(Data([5, 5, 0, 1, 0, 0, 0, 0, 0, 0])); return c.cancel()
                }
                try await c.send(Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]))
                await pipe(c, upstream)
            case 3: // UDP ASSOCIATE
                let relay = try MiniUDPRelay()
                udpServers.append(relay)
                let port = try await relay.start()
                // 返回 0.0.0.0，让客户端回落到代理服务器地址
                try await c.send(Data([5, 0, 0, 1, 0, 0, 0, 0, UInt8(port >> 8), UInt8(port & 0xFF)]))
                while (try? await c.receive()) != nil {}
                relay.stop()
            default:
                try await c.send(Data([5, 7, 0, 1, 0, 0, 0, 0, 0, 0])); c.cancel()
            }
        } catch {
            c.cancel()
        }
    }

    private func readAddress(_ c: AsyncConnection, atyp: UInt8) async throws -> TargetAddress {
        var raw = [atyp]
        switch atyp {
        case 1: raw += [UInt8](try await c.readExactly(4 + 2))
        case 4: raw += [UInt8](try await c.readExactly(16 + 2))
        default:
            let l = [UInt8](try await c.readExactly(1))
            raw += l + [UInt8](try await c.readExactly(Int(l[0]) + 2))
        }
        return try SOCKS5.decodeAddress(raw, at: 0).0
    }
}

/// SOCKS5 UDP 中继：解封装 → 转发到目标 → 回包重新封装。
final class MiniUDPRelay: TestListener, @unchecked Sendable {
    init() throws { try super.init(udp: true) }

    override func start() async throws -> UInt16 {
        listener.newConnectionHandler = { client in
            let q = DispatchQueue(label: "test.udprelay")
            client.start(queue: q)
            func loop() {
                client.receiveMessage { data, _, _, err in
                    guard err == nil, let data, let (target, payload) = try? SOCKS5.decapsulateUDP(data) else { return }
                    let out = NWConnection(to: target.nwEndpoint, using: .udp)
                    out.start(queue: q)
                    out.send(content: payload, completion: .contentProcessed { _ in })
                    out.receiveMessage { reply, _, _, _ in
                        if let reply, let packet = try? SOCKS5.encapsulateUDP(reply, to: target) {
                            client.send(content: packet, completion: .contentProcessed { _ in })
                        }
                        out.cancel()
                    }
                    loop()
                }
            }
            loop()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.tryMark() { cont.resume() }
                if case let .failed(e) = state, once.tryMark() { cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        return listener.port!.rawValue
    }
}

/// 最小 HTTP CONNECT 代理。`sendEarlyData` 为 true 时，在 200 响应后立即附带一段数据（测试缓冲处理）。
final class MiniHTTPProxy: TestListener, @unchecked Sendable {
    let basicAuth: String?
    let earlyData: Data?
    private(set) var lastRequest: String = ""

    init(basicAuth: String? = nil, earlyData: Data? = nil) throws {
        self.basicAuth = basicAuth
        self.earlyData = earlyData
        try super.init()
    }

    override func handle(_ c: AsyncConnection) async {
        do {
            try await c.start()
            let header = String(decoding: try await c.readUntil(HTTPConnect.headerTerminator, maxLength: 8192), as: UTF8.self)
            lastRequest = header
            let first = header.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3, first[0] == "CONNECT" else { return c.cancel() }

            if let auth = basicAuth, !header.contains("Proxy-Authorization: Basic \(auth)\r\n") {
                try await c.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
                return c.cancel()
            }

            let authority = String(first[1])
            guard let colon = authority.lastIndex(of: ":"), let port = UInt16(authority[authority.index(after: colon)...]) else {
                return c.cancel()
            }
            let target = TargetAddress(host: String(authority[..<colon]), port: port)
            guard let upstream = try? await ProxyConnector.connect(to: target, via: .direct, timeout: 5) else {
                try await c.send(Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
                return c.cancel()
            }
            var response = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
            if let earlyData { response += earlyData }
            try await c.send(response)
            await pipe(c, upstream)
        } catch {
            c.cancel()
        }
    }
}

/// 双向拷贝直到两端都结束。
func pipe(_ a: AsyncConnection, _ b: AsyncConnection) async {
    await withTaskGroup(of: Void.self) { g in
        g.addTask { await copy(from: a, to: b) }
        g.addTask { await copy(from: b, to: a) }
    }
    a.cancel()
    b.cancel()
}

private func copy(from src: AsyncConnection, to dst: AsyncConnection) async {
    do {
        while let d = try await src.receive() { try await dst.send(d) }
        try await dst.sendEOF()
    } catch {
        src.cancel()
        dst.cancel()
    }
}

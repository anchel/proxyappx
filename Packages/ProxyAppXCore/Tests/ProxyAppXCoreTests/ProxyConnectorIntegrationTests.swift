import Network
import XCTest
@testable import ProxyAppXCore

/// 端到端测试：客户端 → 本地测试代理 → 本地回显服务器。
final class ProxyConnectorIntegrationTests: XCTestCase {
    var echo: EchoServer!
    var echoPort: UInt16 = 0

    override func setUp() async throws {
        echo = try EchoServer()
        echoPort = try await echo.start()
    }

    override func tearDown() async throws {
        echo.stop()
    }

    private var echoTarget: TargetAddress { TargetAddress(host: "127.0.0.1", port: echoPort) }

    private func roundTrip(_ c: AsyncConnection, _ text: String) async throws -> String {
        try await c.send(Data(text.utf8))
        var got = Data()
        while got.count < text.utf8.count {
            guard let d = try await c.receive() else { break }
            got += d
        }
        return String(decoding: got, as: UTF8.self)
    }

    func testDirect() async throws {
        let c = try await ProxyConnector.connect(to: echoTarget, via: .direct, timeout: 5)
        defer { c.cancel() }
        let reply = try await roundTrip(c, "hello direct")
        XCTAssertEqual(reply, "hello direct")
    }

    func testSOCKS5NoAuth() async throws {
        let s = try MiniSOCKS5Server()
        let port = try await s.start()
        defer { s.stop() }
        let server = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port)

        let c = try await ProxyConnector.connect(to: echoTarget, via: .proxy(server), timeout: 5)
        defer { c.cancel() }
        let reply = try await roundTrip(c, "hello socks")
        XCTAssertEqual(reply, "hello socks")
        XCTAssertEqual(s.lastTarget, echoTarget)
    }

    func testSOCKS5DomainTargetIsSentAsDomain() async throws {
        let s = try MiniSOCKS5Server()
        let port = try await s.start()
        defer { s.stop() }
        let server = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port)
        let c = try await ProxyConnector.connect(to: TargetAddress(host: "localhost", port: echoPort),
                                                 via: .proxy(server), timeout: 5)
        defer { c.cancel() }
        XCTAssertEqual(s.lastTarget?.host, "localhost")
        let reply = try await roundTrip(c, "via-domain")
        XCTAssertEqual(reply, "via-domain")
    }

    func testSOCKS5UserPass() async throws {
        let s = try MiniSOCKS5Server(credentials: ("alice", "s3cret"))
        let port = try await s.start()
        defer { s.stop() }

        let good = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port, username: "alice", password: "s3cret")
        let c = try await ProxyConnector.connect(to: echoTarget, via: .proxy(good), timeout: 5)
        let reply = try await roundTrip(c, "authed")
        XCTAssertEqual(reply, "authed")
        c.cancel()

        let bad = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port, username: "alice", password: "nope")
        do {
            _ = try await ProxyConnector.connect(to: echoTarget, via: .proxy(bad), timeout: 5)
            XCTFail("应当认证失败")
        } catch {
            XCTAssertEqual(error as? ProxyError, .authenticationFailed)
        }

        let none = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port)
        do {
            _ = try await ProxyConnector.connect(to: echoTarget, via: .proxy(none), timeout: 5)
            XCTFail("应当没有可用认证方式")
        } catch {
            XCTAssertEqual(error as? ProxyError, .noAcceptableAuthMethod)
        }
    }

    func testSOCKS5UpstreamRefused() async throws {
        let s = try MiniSOCKS5Server()
        let port = try await s.start()
        defer { s.stop() }
        let server = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port)
        do {
            _ = try await ProxyConnector.connect(to: TargetAddress(host: "127.0.0.1", port: 1), via: .proxy(server), timeout: 5)
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? ProxyError, .socksReply(5))
        }
    }

    func testHTTPConnect() async throws {
        let p = try MiniHTTPProxy()
        let port = try await p.start()
        defer { p.stop() }
        let server = ProxyServer(name: "h", type: .http, host: "127.0.0.1", port: port)
        let c = try await ProxyConnector.connect(to: echoTarget, via: .proxy(server), timeout: 5)
        defer { c.cancel() }
        let reply = try await roundTrip(c, "hello http")
        XCTAssertEqual(reply, "hello http")
        XCTAssertTrue(p.lastRequest.hasPrefix("CONNECT 127.0.0.1:\(echoPort) HTTP/1.1"))
    }

    func testHTTPConnectKeepsDataSentRightAfterHeaders() async throws {
        let p = try MiniHTTPProxy(earlyData: Data("BANNER".utf8))
        let port = try await p.start()
        defer { p.stop() }
        let server = ProxyServer(name: "h", type: .http, host: "127.0.0.1", port: port)
        let c = try await ProxyConnector.connect(to: echoTarget, via: .proxy(server), timeout: 5)
        defer { c.cancel() }
        var got = Data()
        while got.count < 6 { guard let d = try await c.receive() else { break }; got += d }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "BANNER")
        let reply = try await roundTrip(c, "after")
        XCTAssertEqual(reply, "after")
    }

    func testHTTPBasicAuth() async throws {
        let token = Data("bob:pw".utf8).base64EncodedString()
        let p = try MiniHTTPProxy(basicAuth: token)
        let port = try await p.start()
        defer { p.stop() }

        let good = ProxyServer(name: "h", type: .http, host: "127.0.0.1", port: port, username: "bob", password: "pw")
        let c = try await ProxyConnector.connect(to: echoTarget, via: .proxy(good), timeout: 5)
        c.cancel()

        let bad = ProxyServer(name: "h", type: .http, host: "127.0.0.1", port: port, username: "bob", password: "x")
        do {
            _ = try await ProxyConnector.connect(to: echoTarget, via: .proxy(bad), timeout: 5)
            XCTFail("应当 407")
        } catch {
            XCTAssertEqual(error as? ProxyError, .authenticationFailed)
        }
    }

    func testHandshakeTimeout() async throws {
        let silent = try SilentServer()
        let port = try await silent.start()
        defer { silent.stop() }
        let server = ProxyServer(name: "s", type: .socks5, host: "127.0.0.1", port: port)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await ProxyConnector.connect(to: echoTarget, via: .proxy(server), timeout: 1)
            XCTFail("应当超时")
        } catch {
            XCTAssertEqual(error as? ProxyError, .timeout)
        }
        XCTAssertLessThan(clock.now - start, .seconds(4))
    }

    func testConnectionRefused() async throws {
        let server = ProxyServer(name: "x", type: .socks5, host: "127.0.0.1", port: 1)
        do {
            _ = try await ProxyConnector.connect(to: echoTarget, via: .proxy(server), timeout: 3)
            XCTFail("应当连接失败")
        } catch {
            guard case .connectionFailed = error as? ProxyError else { return XCTFail("\(error)") }
        }
    }

    func testProxyTestReportsLatency() async throws {
        let s = try MiniSOCKS5Server()
        let port = try await s.start()
        defer { s.stop() }
        let server = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port)
        let latency = try await ProxyConnector.test(server: server, target: echoTarget, timeout: 5)
        XCTAssertGreaterThan(latency, 0)
        XCTAssertLessThan(latency, 5)
    }

    func testSOCKS5UDPAssociate() async throws {
        let udpEcho = try UDPEchoServer()
        let udpPort = try await udpEcho.start()
        defer { udpEcho.stop() }
        let s = try MiniSOCKS5Server()
        let port = try await s.start()
        defer { s.stop() }

        let server = ProxyServer(name: "t", type: .socks5, host: "127.0.0.1", port: port, supportsUDP: true)
        let assoc = try await SOCKS5UDPAssociation.open(server: server, timeout: 5)
        defer { assoc.close() }
        XCTAssertEqual(assoc.relayAddress.host, "127.0.0.1")

        let target = TargetAddress(host: "127.0.0.1", port: udpPort)
        try await assoc.send(Data("ping".utf8), to: target)
        let (from, payload) = try await assoc.receive()
        XCTAssertEqual(from, target)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "echo:ping")
    }
}

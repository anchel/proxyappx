import XCTest
@testable import ProxyAppXCore

// A query for example.test A and an answer containing 192.0.2.1.
private let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) +
    Data("example".utf8) + Data([4]) + Data("test".utf8) + Data([0, 0, 1, 0, 1])
private let answer: Data = {
    var data = query
    data[2] = 0x81
    data[3] = 0x80
    data[7] = 1
    data += Data([0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1])
    return data
}()

private final class TestDNSResolver: TestListener, @unchecked Sendable {
    override func handle(_ conn: AsyncConnection) async {
        defer { conn.cancel() }
        do {
            try await conn.start()
            let length = try await conn.readExactly(2)
            let received = try await conn.readExactly(Int(length[0]) << 8 | Int(length[1]))
            guard received == query else { return }
            try await conn.send(Data([0, UInt8(answer.count)]))
            try await conn.send(answer)
        } catch {}
    }
}

final class DNSForwarderTests: XCTestCase {
    func testQueryAndAnswerThroughBothProxyTypes() async throws {
        let dns = try TestDNSResolver()
        let target = TargetAddress(host: "127.0.0.1", port: try await dns.start())
        defer { dns.stop() }
        let socks = try MiniSOCKS5Server()
        let http = try MiniHTTPProxy()
        let servers = [
            ProxyServer(name: "S", type: .socks5, host: "127.0.0.1", port: try await socks.start()),
            ProxyServer(name: "H", type: .http, host: "127.0.0.1", port: try await http.start())
        ]
        defer { socks.stop(); http.stop() }
        for server in servers {
            let received = try await DNSForwarder.reply(to: query, resolver: target, via: server,
                                                        timeout: 3, avoidTunnels: true)
            XCTAssertEqual(received, answer)
        }
        XCTAssertEqual(socks.lastTarget, target)
        XCTAssertTrue(http.lastRequest.hasPrefix("CONNECT \(target) HTTP/"))
    }

    func testReplyTimeoutEvenAfterSuccessfulProxyHandshake() async throws {
        let dns = try SilentServer()
        let target = TargetAddress(host: "127.0.0.1", port: try await dns.start())
        defer { dns.stop() }
        let proxy = try MiniSOCKS5Server()
        let server = ProxyServer(name: "S", type: .socks5, host: "127.0.0.1", port: try await proxy.start())
        defer { proxy.stop() }
        do {
            _ = try await DNSForwarder.reply(to: query, resolver: target, via: server, timeout: 1, avoidTunnels: false)
            XCTFail("Expected a DNS timeout")
        } catch {
            XCTAssertEqual(error as? ProxyError, .timeout)
        }
    }

    func testRejectsNonResponseFromProxyTunnel() async throws {
        // Echo the framed query back with the right ID but without the DNS response flag.
        let echo = try EchoServer()
        let target = TargetAddress(host: "127.0.0.1", port: try await echo.start())
        defer { echo.stop() }
        let proxy = try MiniHTTPProxy()
        let server = ProxyServer(name: "H", type: .http, host: "127.0.0.1", port: try await proxy.start())
        defer { proxy.stop() }
        do {
            _ = try await DNSForwarder.reply(to: query, resolver: target, via: server, timeout: 3, avoidTunnels: false)
            XCTFail("Expected an invalid DNS reply")
        } catch {
            guard case .protocolViolation = error as? ProxyError else { return XCTFail("\(error)") }
        }
    }

    func testTruncationHonorsEDNSAndPreservesTheQuestion() throws {
        let large = answer + Data(repeating: 0, count: 600)
        var truncated = query
        truncated[2] = 0x83
        truncated[3] = 0x80
        XCTAssertEqual(try DNSForwarder.udpReply(large, query: query), truncated)
        var edns = query
        edns[11] = 1
        edns += Data([0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 0]) // OPT with 1232-byte UDP size
        XCTAssertEqual(try DNSForwarder.udpReply(large, query: edns), large)
        XCTAssertEqual(try DNSForwarder.udpReply(large + Data(repeating: 0, count: 1200), query: edns), truncated)
        XCTAssertThrowsError(try DNSForwarder.udpReply(large, query: edns.dropLast()))
    }

    func testResolverConfigurationRoundTrip() throws {
        let resolver = try XCTUnwrap(DNSResolver(rawValue: "2001:db8::1"))
        let settings = GeneralSettings(proxyAppDNS: true, dnsResolver: resolver)
        XCTAssertEqual(try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertThrowsError(try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"dnsResolver":"invalid"}"#.utf8)))
    }
}

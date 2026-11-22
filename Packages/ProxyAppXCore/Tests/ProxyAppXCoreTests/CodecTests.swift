import Network
import XCTest
@testable import ProxyAppXCore

final class TargetAddressTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(TargetAddress(host: "1.2.3.4", port: 1).kind, .ipv4([1, 2, 3, 4]))
        XCTAssertEqual(TargetAddress(host: "example.com", port: 1).kind, .domain("example.com"))
        XCTAssertEqual(TargetAddress(host: "1.2.3", port: 1).kind, .domain("1.2.3"))
        XCTAssertEqual(TargetAddress(host: "256.1.1.1", port: 1).kind, .domain("256.1.1.1"))
        if case .ipv6 = TargetAddress(host: "[2001:db8::1]", port: 1).kind {} else { XCTFail() }
        if case .ipv6 = TargetAddress(host: "fe80::1%en0", port: 1).kind {} else { XCTFail() }
        XCTAssertEqual(TargetAddress(host: "[2001:db8::1]", port: 443).description, "[2001:db8::1]:443")
    }

    func testLocalNetwork() {
        for ip in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.1", "169.254.1.1", "100.64.0.1",
                   "224.0.0.251", "fd00::1", "fe80::1", "::ffff:192.168.1.1", "ff02::fb"] {
            XCTAssertTrue(TargetAddress(host: ip, port: 0).isLocalNetwork, ip)
        }
        for ip in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:4860::8888", "::ffff:8.8.8.8"] {
            XCTAssertFalse(TargetAddress(host: ip, port: 0).isLocalNetwork, ip)
        }
        XCTAssertTrue(TargetAddress(host: "printer.local", port: 0).isLocalNetwork)
        XCTAssertTrue(TargetAddress(host: "::ffff:127.0.0.1", port: 0).isLoopback)
    }

    func testIPv6Formatting() {
        let b = IPAddressParser.ipv6Bytes("2001:0db8:0000:0000:0000:0000:0000:0001")!
        XCTAssertEqual(IPAddressParser.format(ipv6: b), "2001:db8::1")
    }

    func testEndpointConversion() {
        let v4 = TargetAddress(host: "1.2.3.4", port: 80)
        XCTAssertEqual(TargetAddress(endpoint: v4.nwEndpoint), v4)
        let v6 = TargetAddress(host: "2001:db8::1", port: 443)
        XCTAssertEqual(TargetAddress(endpoint: v6.nwEndpoint), v6)
        let name = TargetAddress(host: "example.com", port: 8443)
        XCTAssertEqual(TargetAddress(endpoint: name.nwEndpoint), name)
    }
}

final class SOCKS5CodecTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual([UInt8](SOCKS5.greeting(offerUserPass: false)), [5, 1, 0])
        XCTAssertEqual([UInt8](SOCKS5.greeting(offerUserPass: true)), [5, 2, 0, 2])
    }

    func testMethodSelection() throws {
        XCTAssertEqual(try SOCKS5.parseMethodSelection(Data([5, 0])), .noAuth)
        XCTAssertEqual(try SOCKS5.parseMethodSelection(Data([5, 2])), .userPass)
        XCTAssertThrowsError(try SOCKS5.parseMethodSelection(Data([5, 0xFF]))) {
            XCTAssertEqual($0 as? ProxyError, .noAcceptableAuthMethod)
        }
        XCTAssertThrowsError(try SOCKS5.parseMethodSelection(Data([4, 0])))
    }

    func testUserPass() throws {
        XCTAssertEqual([UInt8](try SOCKS5.userPassRequest(username: "ab", password: "c")), [1, 2, 97, 98, 1, 99])
        XCTAssertThrowsError(try SOCKS5.userPassRequest(username: "", password: "x"))
        XCTAssertNoThrow(try SOCKS5.parseUserPassReply(Data([1, 0])))
        XCTAssertThrowsError(try SOCKS5.parseUserPassReply(Data([1, 1]))) {
            XCTAssertEqual($0 as? ProxyError, .authenticationFailed)
        }
    }

    func testConnectRequestEncoding() throws {
        XCTAssertEqual([UInt8](try SOCKS5.request(.connect, target: TargetAddress(host: "1.2.3.4", port: 443))),
                       [5, 1, 0, 1, 1, 2, 3, 4, 0x01, 0xBB])
        XCTAssertEqual([UInt8](try SOCKS5.request(.connect, target: TargetAddress(host: "ab.c", port: 80))),
                       [5, 1, 0, 3, 4, 97, 98, 46, 99, 0, 80])
        let v6 = [UInt8](try SOCKS5.request(.udpAssociate, target: TargetAddress(host: "::1", port: 53)))
        XCTAssertEqual(v6.count, 3 + 1 + 16 + 2)
        XCTAssertEqual(v6[1], 3)
        XCTAssertEqual(v6[3], 4)
        XCTAssertEqual(v6[19], 1)
        XCTAssertThrowsError(try SOCKS5.encodeAddress(TargetAddress(host: String(repeating: "a", count: 256), port: 1)))
    }

    func testReplyParsing() throws {
        let v4 = Data([5, 0, 0, 1, 10, 0, 0, 1, 0x04, 0x38])
        XCTAssertEqual(try SOCKS5.remainingReplyLength(afterFirstFive: Array(v4.prefix(5))), 5)
        XCTAssertEqual(try SOCKS5.parseReply(v4), TargetAddress(host: "10.0.0.1", port: 1080))

        let dom = Data([5, 0, 0, 3, 3]) + Data("a.b".utf8) + Data([0, 53])
        XCTAssertEqual(try SOCKS5.remainingReplyLength(afterFirstFive: Array(dom.prefix(5))), 5)
        XCTAssertEqual(try SOCKS5.parseReply(dom), TargetAddress(host: "a.b", port: 53))

        XCTAssertThrowsError(try SOCKS5.remainingReplyLength(afterFirstFive: [5, 5, 0, 1, 0])) {
            XCTAssertEqual($0 as? ProxyError, .socksReply(5))
        }
    }

    func testUDPRoundTrip() throws {
        for t in [TargetAddress(host: "8.8.8.8", port: 53), TargetAddress(host: "2001:db8::2", port: 443),
                  TargetAddress(host: "dns.google", port: 853)] {
            let payload = Data((0..<100).map { UInt8($0) })
            let packet = try SOCKS5.encapsulateUDP(payload, to: t)
            XCTAssertEqual(Array(packet.prefix(3)), [0, 0, 0])
            let (addr, body) = try SOCKS5.decapsulateUDP(packet)
            XCTAssertEqual(addr, t)
            XCTAssertEqual(body, payload)
        }
        XCTAssertThrowsError(try SOCKS5.decapsulateUDP(Data([0, 0, 1, 1, 1, 1, 1, 1, 0, 1])))
    }
}

final class HTTPConnectTests: XCTestCase {
    func testRequest() {
        let r = String(decoding: HTTPConnect.request(target: TargetAddress(host: "example.com", port: 443),
                                                     username: nil, password: nil), as: UTF8.self)
        XCTAssertTrue(r.hasPrefix("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"))
        XCTAssertTrue(r.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(r.contains("Proxy-Authorization"))

        let v6 = String(decoding: HTTPConnect.request(target: TargetAddress(host: "::1", port: 80),
                                                      username: "u", password: "p"), as: UTF8.self)
        XCTAssertTrue(v6.hasPrefix("CONNECT [::1]:80 HTTP/1.1"))
        XCTAssertTrue(v6.contains("Proxy-Authorization: Basic dTpw\r\n"))
    }

    func testResponse() {
        XCTAssertNoThrow(try HTTPConnect.parseResponse(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)))
        XCTAssertNoThrow(try HTTPConnect.parseResponse(Data("HTTP/1.0 200 OK\r\nX: y\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPConnect.parseResponse(Data("HTTP/1.1 407 Proxy Auth\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? ProxyError, .authenticationFailed)
        }
        XCTAssertThrowsError(try HTTPConnect.parseResponse(Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))) {
            guard case .httpStatus(502, _) = $0 as? ProxyError else { return XCTFail() }
        }
        XCTAssertThrowsError(try HTTPConnect.parseResponse(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))
    }
}

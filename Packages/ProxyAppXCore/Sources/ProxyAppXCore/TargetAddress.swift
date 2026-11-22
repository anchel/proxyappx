import Foundation
import Network

/// 连接目标：IP 字面量或域名，加端口。
public struct TargetAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case domain(String)
    }

    /// IP 字面量（不带方括号和 scope）或域名。
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        self.host = h
        self.port = port
    }

    public var kind: Kind {
        if let v4 = IPAddressParser.ipv4Bytes(host) { return .ipv4(v4) }
        if let v6 = IPAddressParser.ipv6Bytes(host) { return .ipv6(v6) }
        return .domain(host)
    }

    public var isIPAddress: Bool {
        if case .domain = kind { return false }
        return true
    }

    /// 用于 `host:port` 形式的展示，IPv6 加方括号。
    public var hostForURL: String {
        if case .ipv6 = kind { return "[\(host)]" }
        return host
    }

    public var description: String { "\(hostForURL):\(port)" }

    public var isLoopback: Bool {
        switch kind {
        case let .ipv4(b): return b[0] == 127
        case let .ipv6(b):
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if let mapped = IPAddressParser.mappedIPv4(b) { return mapped[0] == 127 }
            return false
        case let .domain(d):
            let l = d.lowercased()
            return l == "localhost" || l.hasSuffix(".localhost")
        }
    }

    /// 私有地址、链路本地、CGNAT、组播、mDNS（.local）等「局域网」目标。
    public var isLocalNetwork: Bool {
        switch kind {
        case let .ipv4(b): return IPAddressParser.isPrivateIPv4(b)
        case let .ipv6(b):
            if let mapped = IPAddressParser.mappedIPv4(b) { return IPAddressParser.isPrivateIPv4(mapped) }
            if b[0] & 0xFE == 0xFC { return true }               // fc00::/7 ULA
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true } // fe80::/10 链路本地
            if b[0] == 0xFF { return true }                        // 组播
            return false
        case let .domain(d):
            return d.lowercased().hasSuffix(".local")
        }
    }

    // MARK: Network.framework 互转

    public init?(endpoint: NWEndpoint) {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        switch host {
        case let .ipv4(addr):
            self.init(host: IPAddressParser.format(ipv4: [UInt8](addr.rawValue)), port: port.rawValue)
        case let .ipv6(addr):
            self.init(host: IPAddressParser.format(ipv6: [UInt8](addr.rawValue)), port: port.rawValue)
        case let .name(name, _):
            self.init(host: name, port: port.rawValue)
        @unknown default:
            return nil
        }
    }

    public var nwEndpoint: NWEndpoint {
        let p = NWEndpoint.Port(rawValue: port) ?? .any
        switch kind {
        case let .ipv4(b):
            if let a = IPv4Address(Data(b)) { return .hostPort(host: .ipv4(a), port: p) }
        case let .ipv6(b):
            if let a = IPv6Address(Data(b)) { return .hostPort(host: .ipv6(a), port: p) }
        case .domain:
            break
        }
        return .hostPort(host: .name(host, nil), port: p)
    }
}

/// 不依赖 inet_pton 线程安全性的 IP 字面量解析与格式化。
public enum IPAddressParser {
    public static func ipv4Bytes(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    public static func ipv6Bytes(_ raw: String) -> [UInt8]? {
        guard raw.contains(":") else { return nil }
        var s = raw
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) } // 去掉 scope id
        var a = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &a) } == 1
        guard ok else { return nil }
        return withUnsafeBytes(of: &a) { [UInt8]($0) }
    }

    public static func format(ipv4 b: [UInt8]) -> String {
        b.map(String.init).joined(separator: ".")
    }

    public static func format(ipv6 b: [UInt8]) -> String {
        guard b.count == 16 else { return "" }
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { dst in
            for i in 0..<16 { dst[i] = b[i] }
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return "" }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// `::ffff:a.b.c.d` 映射地址的 IPv4 部分。
    public static func mappedIPv4(_ b: [UInt8]) -> [UInt8]? {
        guard b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF else { return nil }
        return Array(b[12..<16])
    }

    public static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (100, 64...127): return true  // CGNAT
        case (127, _): return true
        case (224...239, _): return true   // 组播
        case (255, 255): return b[2] == 255 && b[3] == 255
        default: return false
        }
    }
}

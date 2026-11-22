import Foundation

/// SOCKS5 协议编解码（RFC 1928 / RFC 1929）。只包含纯函数，网络读写由 ProxyConnector 负责。
public enum SOCKS5 {
    public static let version: UInt8 = 0x05

    public enum AuthMethod: UInt8, Sendable {
        case noAuth = 0x00
        case userPass = 0x02
        case noAcceptable = 0xFF
    }

    public enum Command: UInt8, Sendable {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    public enum AddressType: UInt8, Sendable {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    // MARK: 握手

    /// 客户端问候：有凭据时同时提供「无认证」和「用户名/密码」。
    public static func greeting(offerUserPass: Bool) -> Data {
        offerUserPass
            ? Data([version, 0x02, AuthMethod.noAuth.rawValue, AuthMethod.userPass.rawValue])
            : Data([version, 0x01, AuthMethod.noAuth.rawValue])
    }

    /// 解析服务器选择的认证方式（2 字节）。
    public static func parseMethodSelection(_ d: Data) throws -> AuthMethod {
        let b = [UInt8](d)
        guard b.count == 2 else { throw ProxyError.protocolViolation(L10n.t("Bad length of the auth method reply", "认证方式应答长度错误")) }
        guard b[0] == version else { throw ProxyError.protocolViolation(L10n.t("Not a SOCKS5 server (version \(b[0]))", "不是 SOCKS5 服务器（版本 \(b[0])）")) }
        switch b[1] {
        case AuthMethod.noAuth.rawValue: return .noAuth
        case AuthMethod.userPass.rawValue: return .userPass
        case AuthMethod.noAcceptable.rawValue: throw ProxyError.noAcceptableAuthMethod
        default: throw ProxyError.protocolViolation(L10n.t("Server chose an unknown auth method 0x\(String(b[1], radix: 16))", "服务器选择了未知认证方式 0x\(String(b[1], radix: 16))"))
        }
    }

    /// RFC 1929 用户名 / 密码子协商请求。
    public static func userPassRequest(username: String, password: String) throws -> Data {
        let u = Array(username.utf8), p = Array(password.utf8)
        guard (1...255).contains(u.count) else { throw ProxyError.protocolViolation(L10n.t("Username must be 1–255 bytes", "用户名长度须在 1–255 字节")) }
        guard p.count <= 255 else { throw ProxyError.protocolViolation(L10n.t("Password must be at most 255 bytes", "密码长度不能超过 255 字节")) }
        return Data([0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p)
    }

    public static func parseUserPassReply(_ d: Data) throws {
        let b = [UInt8](d)
        guard b.count == 2 else { throw ProxyError.protocolViolation(L10n.t("Bad length of the auth reply", "认证应答长度错误")) }
        guard b[1] == 0x00 else { throw ProxyError.authenticationFailed }
    }

    // MARK: 请求 / 应答

    public static func request(_ cmd: Command, target: TargetAddress) throws -> Data {
        Data([version, cmd.rawValue, 0x00]) + (try encodeAddress(target))
    }

    /// ATYP + ADDR + PORT
    public static func encodeAddress(_ t: TargetAddress) throws -> Data {
        var out = Data()
        switch t.kind {
        case let .ipv4(b):
            out.append(AddressType.ipv4.rawValue)
            out.append(contentsOf: b)
        case let .ipv6(b):
            out.append(AddressType.ipv6.rawValue)
            out.append(contentsOf: b)
        case let .domain(name):
            let bytes = Array(name.utf8)
            guard (1...255).contains(bytes.count) else { throw ProxyError.invalidTarget(L10n.t("Domain name must be 1–255 bytes: \(name)", "域名长度须在 1–255 字节：\(name)")) }
            out.append(AddressType.domain.rawValue)
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(UInt8(t.port >> 8))
        out.append(UInt8(t.port & 0xFF))
        return out
    }

    /// 已读取应答的前 5 个字节（VER REP RSV ATYP + 地址首字节）后，还需要再读多少字节。
    public static func remainingReplyLength(afterFirstFive b: [UInt8]) throws -> Int {
        guard b.count == 5 else { throw ProxyError.protocolViolation(L10n.t("Bad reply header length", "应答头长度错误")) }
        guard b[0] == version else { throw ProxyError.protocolViolation(L10n.t("Bad reply version \(b[0])", "应答版本错误 \(b[0])")) }
        guard b[1] == 0x00 else { throw ProxyError.socksReply(b[1]) }
        switch b[3] {
        case AddressType.ipv4.rawValue: return 4 - 1 + 2
        case AddressType.ipv6.rawValue: return 16 - 1 + 2
        case AddressType.domain.rawValue: return Int(b[4]) + 2
        default: throw ProxyError.protocolViolation(L10n.t("Unknown address type \(b[3])", "未知地址类型 \(b[3])"))
        }
    }

    /// 解析完整应答，返回 BND.ADDR:BND.PORT。
    public static func parseReply(_ d: Data) throws -> TargetAddress {
        let b = [UInt8](d)
        guard b.count >= 5 else { throw ProxyError.protocolViolation(L10n.t("Reply too short", "应答过短")) }
        let need = try remainingReplyLength(afterFirstFive: Array(b[0..<5]))
        guard b.count == 5 + need else { throw ProxyError.protocolViolation(L10n.t("Reply length mismatch", "应答长度不匹配")) }
        let (addr, _) = try decodeAddress(b, at: 3)
        return addr
    }

    /// 从 `offset`（指向 ATYP）开始解析地址，返回地址和消耗的字节数。
    public static func decodeAddress(_ b: [UInt8], at offset: Int) throws -> (TargetAddress, Int) {
        guard offset < b.count else { throw ProxyError.protocolViolation(L10n.t("Missing address", "地址缺失")) }
        var i = offset + 1
        let host: String
        switch b[offset] {
        case AddressType.ipv4.rawValue:
            guard b.count >= i + 4 + 2 else { throw ProxyError.protocolViolation(L10n.t("IPv4 address too short", "IPv4 地址过短")) }
            host = IPAddressParser.format(ipv4: Array(b[i..<i + 4]))
            i += 4
        case AddressType.ipv6.rawValue:
            guard b.count >= i + 16 + 2 else { throw ProxyError.protocolViolation(L10n.t("IPv6 address too short", "IPv6 地址过短")) }
            host = IPAddressParser.format(ipv6: Array(b[i..<i + 16]))
            i += 16
        case AddressType.domain.rawValue:
            guard b.count > i else { throw ProxyError.protocolViolation(L10n.t("Missing domain length", "域名长度缺失")) }
            let len = Int(b[i]); i += 1
            guard b.count >= i + len + 2 else { throw ProxyError.protocolViolation(L10n.t("Domain name too short", "域名过短")) }
            host = String(decoding: b[i..<i + len], as: UTF8.self)
            i += len
        default:
            throw ProxyError.protocolViolation(L10n.t("Unknown address type \(b[offset])", "未知地址类型 \(b[offset])"))
        }
        let port = UInt16(b[i]) << 8 | UInt16(b[i + 1])
        i += 2
        return (TargetAddress(host: host, port: port), i - offset)
    }

    // MARK: UDP 封装

    /// +----+------+------+----------+----------+----------+
    /// |RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
    /// +----+------+------+----------+----------+----------+
    public static func encapsulateUDP(_ payload: Data, to target: TargetAddress) throws -> Data {
        Data([0x00, 0x00, 0x00]) + (try encodeAddress(target)) + payload
    }

    public static func decapsulateUDP(_ datagram: Data) throws -> (TargetAddress, Data) {
        let b = [UInt8](datagram)
        guard b.count >= 4 else { throw ProxyError.protocolViolation(L10n.t("UDP datagram too short", "UDP 报文过短")) }
        guard b[2] == 0x00 else { throw ProxyError.unsupported(L10n.t("UDP fragmentation is not supported", "不支持 UDP 分片")) }
        let (addr, used) = try decodeAddress(b, at: 3)
        return (addr, Data(b[(3 + used)...]))
    }

    public static func replyDescription(_ code: UInt8) -> String {
        switch code {
        case 0x01: return L10n.t("general server failure", "服务器一般性错误")
        case 0x02: return L10n.t("connection not allowed by ruleset", "规则不允许连接")
        case 0x03: return L10n.t("network unreachable", "网络不可达")
        case 0x04: return L10n.t("host unreachable", "主机不可达")
        case 0x05: return L10n.t("connection refused", "连接被拒绝")
        case 0x06: return L10n.t("TTL expired", "TTL 过期")
        case 0x07: return L10n.t("command not supported", "不支持的命令")
        case 0x08: return L10n.t("address type not supported", "不支持的地址类型")
        default: return L10n.t("unknown error 0x\(String(code, radix: 16))", "未知错误 0x\(String(code, radix: 16))")
        }
    }
}

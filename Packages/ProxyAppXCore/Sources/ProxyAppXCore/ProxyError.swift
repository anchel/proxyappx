import Foundation

public enum ProxyError: Error, LocalizedError, Equatable, Sendable {
    case timeout
    case connectionFailed(String)
    case connectionClosed
    case protocolViolation(String)
    case authenticationRequired
    case authenticationFailed
    case noAcceptableAuthMethod
    case socksReply(UInt8)
    case httpStatus(Int, String)
    case invalidTarget(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: return L10n.t("Connection timed out", "连接超时")
        case let .connectionFailed(m): return L10n.t("Cannot connect: \(m)", "无法连接：\(m)")
        case .connectionClosed: return L10n.t("Connection closed by the peer", "连接被对端关闭")
        case let .protocolViolation(m): return L10n.t("Protocol error: \(m)", "协议错误：\(m)")
        case .authenticationRequired: return L10n.t("The proxy requires authentication, but no username and password are configured", "代理要求认证，但未配置用户名和密码")
        case .authenticationFailed: return L10n.t("Proxy authentication failed (wrong username or password)", "代理认证失败（用户名或密码错误）")
        case .noAcceptableAuthMethod: return L10n.t("The proxy accepts none of the offered authentication methods", "代理不支持可用的认证方式")
        case let .socksReply(code): return L10n.t("SOCKS5 error: \(SOCKS5.replyDescription(code))", "SOCKS5 错误：\(SOCKS5.replyDescription(code))")
        case let .httpStatus(code, line): return L10n.t("HTTP proxy returned \(code): \(line)", "HTTP 代理返回 \(code)：\(line)")
        case let .invalidTarget(m): return L10n.t("Invalid target: \(m)", "目标地址无效：\(m)")
        case let .unsupported(m): return L10n.t("Unsupported: \(m)", "不支持：\(m)")
        }
    }
}

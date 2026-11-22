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
        case .timeout: return "连接超时"
        case let .connectionFailed(m): return "无法连接：\(m)"
        case .connectionClosed: return "连接被对端关闭"
        case let .protocolViolation(m): return "协议错误：\(m)"
        case .authenticationRequired: return "代理要求认证，但未配置用户名和密码"
        case .authenticationFailed: return "代理认证失败（用户名或密码错误）"
        case .noAcceptableAuthMethod: return "代理不支持可用的认证方式"
        case let .socksReply(code): return "SOCKS5 错误：\(SOCKS5.replyDescription(code))"
        case let .httpStatus(code, line): return "HTTP 代理返回 \(code)：\(line)"
        case let .invalidTarget(m): return "目标地址无效：\(m)"
        case let .unsupported(m): return "不支持：\(m)"
        }
    }
}

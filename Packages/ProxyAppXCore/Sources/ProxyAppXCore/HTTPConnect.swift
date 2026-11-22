import Foundation

/// HTTP CONNECT 隧道编解码。
public enum HTTPConnect {
    public static let headerTerminator = Data("\r\n\r\n".utf8)
    public static let maxHeaderLength = 16 * 1024

    public static func request(target: TargetAddress, username: String?, password: String?) -> Data {
        let authority = target.description // IPv6 自动加方括号
        var lines = [
            "CONNECT \(authority) HTTP/1.1",
            "Host: \(authority)",
            "User-Agent: ProxyAppX/1.0",
            "Proxy-Connection: Keep-Alive",
        ]
        if let u = username, !u.isEmpty {
            let token = Data("\(u):\(password ?? "")".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// 解析响应头（包含结尾的 `\r\n\r\n`）。2xx 视为成功。
    public static func parseResponse(_ header: Data) throws {
        guard let text = String(data: header, encoding: .utf8) ?? String(data: header, encoding: .isoLatin1) else {
            throw ProxyError.protocolViolation(L10n.t("Cannot decode the HTTP response", "无法解码 HTTP 响应"))
        }
        let statusLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else {
            throw ProxyError.protocolViolation(L10n.t("Not an HTTP proxy: \(statusLine.prefix(80))", "不是 HTTP 代理：\(statusLine.prefix(80))"))
        }
        switch code {
        case 200..<300:
            return
        case 407:
            throw ProxyError.authenticationFailed
        default:
            throw ProxyError.httpStatus(code, String(statusLine.prefix(120)))
        }
    }
}

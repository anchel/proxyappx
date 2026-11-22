import Darwin
import Foundation
import Security

/// 根据 audit token 解析来源进程的磁盘路径和展示名称，带缓存。
///
/// audit token 中包含 pid 和 pidversion，同一进程实例的 token 不变，因此可以安全缓存。
final class ProcessResolver: @unchecked Sendable {
    struct Info: Sendable {
        let path: String?
        let name: String
    }

    private let lock = NSLock()
    private var cache: [Data: Info] = [:]
    private let capacity = 2048

    func resolve(auditToken: Data?, signingID: String) -> Info {
        guard let token = auditToken, !token.isEmpty else {
            return Info(path: nil, name: Self.fallbackName(signingID))
        }

        lock.lock()
        if let hit = cache[token] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let rawPath = Self.codePath(auditToken: token) ?? Self.pidPath(auditToken: token)
        let path = rawPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        let info = Info(path: path, name: path.map(Self.displayName(forPath:)) ?? Self.fallbackName(signingID))

        lock.lock()
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[token] = info
        lock.unlock()
        return info
    }

    /// 通过 Security 框架获取代码路径（对 bundle 返回 .app 路径，对命令行工具返回可执行文件路径）。
    private static func codePath(auditToken: Data) -> String? {
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    /// 兜底：audit_token_t 的第 6 个 32 位字段是 pid，用 proc_pidpath 获取可执行文件路径。
    private static func pidPath(auditToken: Data) -> String? {
        guard auditToken.count >= MemoryLayout<audit_token_t>.size else { return nil }
        let pid: pid_t = auditToken.withUnsafeBytes { raw in
            raw.load(fromByteOffset: 5 * MemoryLayout<UInt32>.size, as: pid_t.self)
        }
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 取路径中最外层的 .app 名称；没有 .app 时取文件名。
    static func displayName(forPath path: String) -> String {
        let comps = path.split(separator: "/")
        if let app = comps.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return comps.last.map(String.init) ?? path
    }

    static func fallbackName(_ signingID: String) -> String {
        signingID.split(separator: ".").last.map(String.init) ?? signingID
    }
}

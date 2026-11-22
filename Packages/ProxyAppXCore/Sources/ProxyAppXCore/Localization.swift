import Foundation

/// 界面语言。
///
/// App 界面用 String Catalog 本地化；核心库和系统扩展里的少量文案（错误信息、日志）
/// 用 `L10n.t(_:_:)` 在中英文之间切换。扩展以 root 运行，拿不到用户的语言偏好，
/// 所以由 App 把当前语言放进 `ProxyAppXConfig.language` 下发给它。
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// 根据本地化标识（如 `Bundle.main.preferredLocalizations.first`）判断。
    public init(localization: String?) {
        self = (localization?.lowercased().hasPrefix("zh") ?? false) ? .simplifiedChinese : .english
    }
}

public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: AppLanguage = .english

    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    /// 按当前语言返回英文或中文文案。
    public static func t(_ english: @autoclosure () -> String, _ chinese: @autoclosure () -> String) -> String {
        language == .simplifiedChinese ? chinese() : english()
    }
}

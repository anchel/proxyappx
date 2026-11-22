import AppKit
import Foundation

/// 界面语言偏好。通过 App 自己的 `AppleLanguages` 覆盖实现，重新启动后生效；
/// 也可以在「系统设置 › 通用 › 语言与地区 › 应用程序」中为 ProxyAppX 单独设置。
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 当前保存的偏好（只看 App 自己域里的覆盖，不看全局语言设置）。
    static var saved: LanguagePreference {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        return first.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// 本次启动时生效的偏好，用来判断是否需要重新启动。
    static let atLaunch = saved

    func save() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese: UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// 重新启动 App 以应用新的语言。
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

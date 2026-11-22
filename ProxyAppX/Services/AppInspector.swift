import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

/// 从 .app 或可执行文件中读取名称、签名标识、图标。
struct InspectedApp: Hashable, Identifiable {
    var id: String { path }
    let name: String
    let bundleID: String
    let path: String
    let isBundle: Bool
}

enum AppInspector {
    static func inspect(url: URL) -> InspectedApp? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if resolved.pathExtension == "app", let bundle = Bundle(url: resolved) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? resolved.deletingPathExtension().lastPathComponent
            let id = bundle.bundleIdentifier ?? signingIdentifier(path: path) ?? ""
            return InspectedApp(name: name, bundleID: id, path: path, isBundle: true)
        }

        // 命令行工具或其他可执行文件
        let id = signingIdentifier(path: path) ?? ""
        return InspectedApp(name: resolved.lastPathComponent, bundleID: id, path: path, isBundle: false)
    }

    /// 读取代码签名标识（ad-hoc 签名也有）。
    static func signingIdentifier(path: String) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    static func icon(forPath path: String) -> NSImage {
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    /// 从进程路径推出所属 .app（取最外层），用于从「未匹配应用」创建规则。
    static func outermostAppBundle(of path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return comps[...i].joined(separator: "/")
    }

    static func runningApps() -> [InspectedApp] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> InspectedApp? in
                guard let url = app.bundleURL else { return nil }
                return inspect(url: url)
            }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.path).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func pickApplications() -> [InspectedApp] {
        let panel = NSOpenPanel()
        panel.title = "选择要代理的应用"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(inspect(url:))
    }

    @MainActor
    static func pickExecutables() -> [InspectedApp] {
        let panel = NSOpenPanel()
        panel.title = "选择命令行工具或可执行文件"
        panel.message = "提示：按 ⌘⇧G 可以输入路径，例如 /usr/bin/curl 或 /opt/homebrew/bin/git"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(inspect(url:))
    }
}

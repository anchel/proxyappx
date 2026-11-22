import Foundation
import Observation
import SystemExtensions

/// 负责安装 / 卸载 / 查询系统扩展。
@MainActor
@Observable
final class ExtensionManager {
    enum State: Equatable {
        case unknown
        case notInstalled
        case activating
        case awaitingApproval
        case needsReboot
        case installed(version: String)
        case failed(String)

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .unknown: return String(localized: "Checking…")
            case .notInstalled: return String(localized: "Not installed")
            case .activating: return String(localized: "Installing…")
            case .awaitingApproval: return String(localized: "Waiting for your approval in System Settings")
            case .needsReboot: return String(localized: "Restart your Mac to finish")
            case let .installed(v): return String(localized: "Enabled (\(v))")
            case .failed: return String(localized: "Installation failed")
            }
        }
    }

    private(set) var state: State = .unknown

    let extensionIdentifier: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "ProxyAppXExtensionBundleIdentifier") as? String,
           !id.isEmpty, !id.contains("$(") {
            return id
        }
        return (Bundle.main.bundleIdentifier ?? "com.proxyappx.app") + ".extension"
    }()

    /// App 包内自带的扩展的 CFBundleVersion。
    var bundledExtensionVersion: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    @ObservationIgnored private lazy var delegate = RequestDelegate(owner: self)
    @ObservationIgnored private var lastRequestWasActivation = true

    /// 已安装后的回调（用于接着创建代理配置）。
    @ObservationIgnored var onInstalled: (() -> Void)?

    func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func activate() {
        lastRequestWasActivation = true
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        lastRequestWasActivation = false
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: 委托回调

    fileprivate func handle(found properties: [OSSystemExtensionProperties]) {
        let mine = properties.filter { $0.bundleIdentifier == extensionIdentifier && !$0.isUninstalling }
        if let enabled = mine.first(where: \.isEnabled) {
            // App 自带的扩展比已安装的新（或不同）时，自动请求替换。
            if let bundled = bundledExtensionVersion, bundled != enabled.bundleVersion,
               !mine.contains(where: { $0.bundleVersion == bundled }) {
                activate()
                return
            }
            state = .installed(version: "\(enabled.bundleShortVersion) (\(enabled.bundleVersion))")
            onInstalled?()
        } else if mine.contains(where: \.isAwaitingUserApproval) {
            state = .awaitingApproval
        } else if case .activating = state {
            // 安装中，等待结果
        } else {
            state = .notInstalled
        }
    }

    fileprivate func handleFinished(_ result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            if lastRequestWasActivation {
                let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                state = .installed(version: "\(short) (\(bundledExtensionVersion ?? "?"))")
                onInstalled?()
            } else {
                state = .notInstalled
            }
        case .willCompleteAfterReboot:
            state = .needsReboot
        @unknown default:
            refresh()
        }
    }

    fileprivate func handleNeedsApproval() {
        state = .awaitingApproval
    }

    fileprivate func handleFailure(_ error: Error) {
        state = .failed(Self.describe(error))
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: ns.code) else {
            return error.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return String(localized: "Move ProxyAppX.app to the Applications folder (/Applications) first, then open it again.")
        case .missingEntitlement:
            return String(localized: "The system extension entitlement is missing. Check the signing configuration (Config/Signing.xcconfig).")
        case .codeSignatureInvalid:
            return String(localized: "Invalid code signature. The system extension must be signed with a valid certificate and a provisioning profile that includes the Network Extension capability.")
        case .extensionNotFound:
            return String(localized: "The system extension was not found inside the app. Rebuild it.")
        case .requestCanceled:
            return String(localized: "The request was canceled.")
        case .authorizationRequired:
            return String(localized: "Authorization is required. Allow it in System Settings.")
        case .validationFailed:
            return String(localized: "The system extension failed validation (signature, Info.plist or entitlements do not match).")
        default:
            return String(localized: "\(error.localizedDescription) (code \(ns.code))")
        }
    }
}

/// OSSystemExtensionRequestDelegate 需要 NSObject，单独放一个转发对象。
private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    weak var owner: ExtensionManager?

    init(owner: ExtensionManager) {
        self.owner = owner
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { owner?.handleNeedsApproval() }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated { owner?.handleFinished(result) }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { owner?.handleFailure(error) }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated { owner?.handle(found: properties) }
    }
}

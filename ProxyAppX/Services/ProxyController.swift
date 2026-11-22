import Foundation
import NetworkExtension
import Observation
import ProxyAppXCore

/// 管理系统中的透明代理配置（NETransparentProxyManager），负责启停和与扩展通信。
@MainActor
@Observable
final class ProxyController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var lastError: String?
    private(set) var isBusy = false

    @ObservationIgnored private var manager: NETransparentProxyManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored let providerBundleIdentifier: String

    /// 会话被系统意外断开（如扩展更新、扩展崩溃）且用户期望开启时调用，由上层负责重新启动。
    @ObservationIgnored var onUnexpectedDisconnect: (() -> Void)?
    @ObservationIgnored private var userRequestedStop = false
    @ObservationIgnored private var autoRestarts: [Date] = []

    /// 用户期望的开关状态（重启 App 后恢复）。
    var wantsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "proxyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "proxyEnabled") }
    }

    var isRunning: Bool { status == .connected }
    var isTransitioning: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    var statusTitle: String {
        switch status {
        case .invalid: return String(localized: "Not configured")
        case .disconnected: return String(localized: "Off")
        case .connecting: return String(localized: "Starting…")
        case .connected: return String(localized: "Running")
        case .reasserting: return String(localized: "Reconnecting…")
        case .disconnecting: return String(localized: "Stopping…")
        @unknown default: return String(localized: "Unknown")
        }
    }

    init(providerBundleIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let conn = note.object as? NEVPNConnection,
                      conn === self.manager?.connection else { return }
                let previous = self.status
                self.status = conn.status
                if conn.status == .disconnected, previous != .disconnected, previous != .invalid {
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: 加载

    func load() async {
        do {
            let all = try await NETransparentProxyManager.loadAllFromPreferences()
            manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier }
            status = manager?.connection.status ?? .invalid
        } catch {
            lastError = String(localized: "Failed to read the proxy configuration: \(error.localizedDescription)")
        }
    }

    // MARK: 启停

    func start(with configuration: ProxyAppXConfig) async {
        guard status != .connected, status != .connecting else { return }
        userRequestedStop = false
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        do {
            let data = try Self.withLanguage(configuration).encoded()
            let m = try await saveManager(configurationData: data)
            guard let session = m.connection as? NETunnelProviderSession else {
                throw NSError(domain: "ProxyAppX", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Invalid session type")])
            }
            try session.startTunnel(options: [ProviderConfigurationKey.configuration: data as NSData])
            wantsEnabled = true
        } catch {
            lastError = String(localized: "Failed to start: \(Self.describe(error))")
        }
    }

    func stop() {
        wantsEnabled = false
        stopSession()
    }

    /// 只停止会话，不改变用户记住的开关状态。
    func stopSession() {
        userRequestedStop = true
        manager?.connection.stopVPNTunnel()
    }

    /// 非用户主动停止的断开：短暂延迟后自动重连，60 秒内最多 5 次，避免扩展反复崩溃时死循环。
    private func handleDisconnect() {
        guard wantsEnabled, !userRequestedStop else { return }
        let now = Date()
        autoRestarts = autoRestarts.filter { now.timeIntervalSince($0) < 60 }
        guard autoRestarts.count < 5 else {
            lastError = String(localized: "The proxy session keeps disconnecting, so automatic reconnection has stopped. Check the logs, then turn it on again.")
            return
        }
        autoRestarts.append(now)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.wantsEnabled, !self.userRequestedStop, self.status == .disconnected else { return }
            self.onUnexpectedDisconnect?()
        }
    }

    /// 把新配置持久化到系统，并在运行中时热更新到扩展。
    func apply(_ configuration: ProxyAppXConfig) async {
        guard manager != nil else { return }
        do {
            let data = try Self.withLanguage(configuration).encoded()
            _ = try await saveManager(configurationData: data)
            if isRunning {
                let response = try await send(.updateConfiguration(Self.withLanguage(configuration)))
                if case let .error(message) = response { lastError = message }
            }
        } catch {
            lastError = String(localized: "Failed to update the configuration: \(Self.describe(error))")
        }
    }

    /// 从系统中移除代理配置。
    func removeConfiguration() async {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
        do {
            try await m.removeFromPreferences()
            manager = nil
            status = .invalid
        } catch {
            lastError = String(localized: "Failed to remove the configuration: \(Self.describe(error))")
        }
    }

    // MARK: IPC

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
            throw NSError(domain: "ProxyAppX", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "The extension is not running")])
        }
        let payload = try request.encoded()
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data else {
                        cont.resume(throwing: NSError(domain: "ProxyAppX", code: 3,
                                                                                    userInfo: [NSLocalizedDescriptionKey: String(localized: "The extension did not respond")]))
                        return
                    }
                    do {
                        cont.resume(returning: try IPCResponse.decode(data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: 内部

    /// 带上 App 当前的界面语言，让扩展用同一种语言写日志。
    private static func withLanguage(_ configuration: ProxyAppXConfig) -> ProxyAppXConfig {
        var c = configuration
        c.language = L10n.language
        return c
    }

    private func saveManager(configurationData: Data) async throws -> NETransparentProxyManager {
        let m = manager ?? NETransparentProxyManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "ProxyAppX"
        proto.providerConfiguration = [ProviderConfigurationKey.configuration: configurationData as NSData]
        m.protocolConfiguration = proto
        m.localizedDescription = String(localized: "ProxyAppX Per-App Proxy")
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        status = m.connection.status
        return m
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: ns.code) {
            switch code {
            case .configurationInvalid: return String(localized: "Invalid configuration")
            case .configurationDisabled: return String(localized: "The configuration is disabled")
            case .connectionFailed: return String(localized: "The extension failed to start")
            case .configurationStale: return String(localized: "The configuration is out of date. Try again.")
            case .configurationReadWriteFailed: return String(localized: "Cannot read or write the system configuration. Did you deny the request to add a proxy configuration?")
            case .configurationUnknown: return String(localized: "Unknown configuration error")
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}

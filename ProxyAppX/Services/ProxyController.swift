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
        case .invalid: return "未配置"
        case .disconnected: return "已停止"
        case .connecting: return "正在启动…"
        case .connected: return "运行中"
        case .reasserting: return "正在重连…"
        case .disconnecting: return "正在停止…"
        @unknown default: return "未知"
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
            lastError = "读取代理配置失败：\(error.localizedDescription)"
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
            let data = try configuration.encoded()
            let m = try await saveManager(configurationData: data)
            guard let session = m.connection as? NETunnelProviderSession else {
                throw NSError(domain: "ProxyAppX", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的会话类型"])
            }
            try session.startTunnel(options: [ProviderConfigurationKey.configuration: data as NSData])
            wantsEnabled = true
        } catch {
            lastError = "启动失败：\(Self.describe(error))"
        }
    }

    func stop() {
        userRequestedStop = true
        wantsEnabled = false
        manager?.connection.stopVPNTunnel()
    }

    /// 非用户主动停止的断开：短暂延迟后自动重连，60 秒内最多 5 次，避免扩展反复崩溃时死循环。
    private func handleDisconnect() {
        guard wantsEnabled, !userRequestedStop else { return }
        let now = Date()
        autoRestarts = autoRestarts.filter { now.timeIntervalSince($0) < 60 }
        guard autoRestarts.count < 5 else {
            lastError = "代理会话反复断开，已停止自动重连。请查看日志后手动启用。"
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
            let data = try configuration.encoded()
            _ = try await saveManager(configurationData: data)
            if isRunning {
                let response = try await send(.updateConfiguration(configuration))
                if case let .error(message) = response { lastError = message }
            }
        } catch {
            lastError = "更新配置失败：\(Self.describe(error))"
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
            lastError = "移除配置失败：\(Self.describe(error))"
        }
    }

    // MARK: IPC

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
            throw NSError(domain: "ProxyAppX", code: 2, userInfo: [NSLocalizedDescriptionKey: "扩展未运行"])
        }
        let payload = try request.encoded()
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data else {
                        cont.resume(throwing: NSError(domain: "ProxyAppX", code: 3,
                                                      userInfo: [NSLocalizedDescriptionKey: "扩展无响应"]))
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

    private func saveManager(configurationData: Data) async throws -> NETransparentProxyManager {
        let m = manager ?? NETransparentProxyManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "ProxyAppX"
        proto.providerConfiguration = [ProviderConfigurationKey.configuration: configurationData as NSData]
        m.protocolConfiguration = proto
        m.localizedDescription = "ProxyAppX 按应用代理"
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
            case .configurationInvalid: return "配置无效"
            case .configurationDisabled: return "配置已被禁用"
            case .connectionFailed: return "扩展启动失败"
            case .configurationStale: return "配置已过期，请重试"
            case .configurationReadWriteFailed: return "无法读写系统配置（是否拒绝了「添加代理配置」的请求？）"
            case .configurationUnknown: return "未知配置错误"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}

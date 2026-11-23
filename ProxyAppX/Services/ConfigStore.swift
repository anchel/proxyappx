import Foundation
import Observation
import ProxyAppXCore

/// 配置的唯一数据源：JSON 落盘（不含密码），密码存钥匙串。
@MainActor
@Observable
final class ConfigStore {
    private(set) var configuration: ProxyAppXConfig
    private(set) var lastSaveError: String?

    /// 配置变更回调（用于下发给扩展），已做防抖。
    @ObservationIgnored var onChange: ((ProxyAppXConfig) -> Void)?
    @ObservationIgnored private var pendingApply: Task<Void, Never>?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyAppX", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    init() {
        var cfg = (try? Data(contentsOf: Self.fileURL)).flatMap { try? ProxyAppXConfig.decode($0) } ?? ProxyAppXConfig()
        cfg.servers = cfg.servers.map { s in
            var s = s
            s.password = Keychain.password(for: s.id)
            return s
        }
        configuration = cfg
    }

    // MARK: 服务器

    func upsertServer(_ server: ProxyServer) {
        mutate { cfg in
            if let i = cfg.servers.firstIndex(where: { $0.id == server.id }) {
                cfg.servers[i] = server
            } else {
                cfg.servers.append(server)
            }
        }
        Keychain.setPassword(server.password, for: server.id)
    }

    /// 删除服务器；引用它的规则改为直连，默认动作若引用它也改为直连。返回受影响的规则数。
    @discardableResult
    func deleteServer(_ id: UUID) -> Int {
        var affected = 0
        mutate { cfg in
            cfg.servers.removeAll { $0.id == id }
            for i in cfg.rules.indices where cfg.rules[i].action.serverID == id {
                cfg.rules[i].action = .direct
                affected += 1
            }
            if cfg.settings.defaultAction.serverID == id { cfg.settings.defaultAction = .direct }
        }
        Keychain.deletePassword(for: id)
        return affected
    }

    func rulesUsing(server id: UUID) -> [AppRule] {
        configuration.rules.filter { $0.action.serverID == id }
    }

    // MARK: 规则

    func upsertRule(_ rule: AppRule) {
        mutate { cfg in
            if let i = cfg.rules.firstIndex(where: { $0.id == rule.id }) {
                cfg.rules[i] = rule
            } else {
                cfg.rules.append(rule)
            }
        }
    }

    func deleteRules(_ ids: Set<UUID>) {
        mutate { $0.rules.removeAll { ids.contains($0.id) } }
    }

    func setRulesAction(_ action: RuleAction, for ids: Set<AppRule.ID>) {
        mutate { cfg in
            if let serverID = action.serverID, cfg.server(id: serverID) == nil { return }
            for i in cfg.rules.indices where ids.contains(cfg.rules[i].id) {
                cfg.rules[i].action = action
            }
        }
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        mutate { cfg in
            if let i = cfg.rules.firstIndex(where: { $0.id == id }) { cfg.rules[i].enabled = enabled }
        }
    }

    func existingRule(bundleID: String, path: String) -> AppRule? {
        configuration.rules.first {
            (!bundleID.isEmpty && $0.bundleID == bundleID) || (!path.isEmpty && $0.path == path)
        }
    }

    // MARK: 设置

    func updateSettings(_ body: (inout GeneralSettings) -> Void) {
        mutate { body(&$0.settings) }
    }

    // MARK: 导入 / 导出

    func exportData() throws -> Data {
        try configuration.redacted().encoded()
    }

    /// 导入会替换现有配置；导入文件中的密码（如有）写入钥匙串。
    func importData(_ data: Data) throws {
        let imported = try ProxyAppXConfig.decode(data)
        let old = configuration.servers.map(\.id)
        old.forEach(Keychain.deletePassword(for:))
        for s in imported.servers { Keychain.setPassword(s.password, for: s.id) }
        mutate { $0 = imported }
    }

    // MARK: 内部

    private func mutate(_ body: (inout ProxyAppXConfig) -> Void) {
        var cfg = configuration
        body(&cfg)
        guard cfg != configuration else { return }
        configuration = cfg
        persist()
        scheduleApply()
    }

    private func persist() {
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configuration.redacted().encoded().write(to: url, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.onChange?(self.configuration)
        }
    }
}

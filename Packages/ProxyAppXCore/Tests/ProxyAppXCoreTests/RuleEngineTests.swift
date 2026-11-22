import XCTest
@testable import ProxyAppXCore

final class RuleEngineTests: XCTestCase {
    let socks = ProxyServer(name: "S5", type: .socks5, host: "10.0.0.1", port: 1080, supportsUDP: true)
    let http = ProxyServer(name: "H", type: .http, host: "proxy.example.com", port: 8080)

    func ctx(_ sid: String, _ path: String? = nil, ip: String = "93.184.216.34", port: UInt16 = 443,
             host: String? = nil, udp: Bool = false) -> FlowContext {
        FlowContext(signingID: sid, executablePath: path, destination: TargetAddress(host: ip, port: port),
                    hostname: host, transport: udp ? .udp : .tcp)
    }

    func engine(rules: [AppRule], settings: GeneralSettings = GeneralSettings()) -> RuleEngine {
        RuleEngine(configuration: ProxyAppXConfig(servers: [socks, http], rules: rules, settings: settings))
    }

    func testExactSigningIDMatch() {
        let rule = AppRule(name: "Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app",
                           action: .proxy(serverID: socks.id))
        let d = engine(rules: [rule]).decide(ctx("com.google.Chrome"))
        XCTAssertEqual(d.verdict, .proxy(socks))
        XCTAssertEqual(d.reason, .rule)
        XCTAssertEqual(d.rule?.id, rule.id)
    }

    func testHelperProcessMatchedBySigningPrefix() {
        let rule = AppRule(name: "Chrome", bundleID: "com.google.Chrome", path: "", action: .proxy(serverID: socks.id))
        let d = engine(rules: [rule]).decide(ctx("com.google.Chrome.helper"))
        XCTAssertEqual(d.verdict, .proxy(socks))
    }

    func testHelperProcessMatchedByBundlePath() {
        let rule = AppRule(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app",
                           action: .proxy(serverID: http.id))
        let exe = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        let d = engine(rules: [rule]).decide(ctx("com.tinyspeck.slackmacgap.helper.Renderer-x", exe))
        XCTAssertEqual(d.verdict, .proxy(http))

        // 路径大小写不敏感、规则路径带尾部斜杠
        let rule2 = AppRule(name: "Slack", bundleID: "x.y", path: "/applications/slack.app/", action: .block)
        XCTAssertEqual(engine(rules: [rule2]).decide(ctx("other", exe)).verdict, .block)
    }

    func testSiblingPathIsNotMatched() {
        let rule = AppRule(name: "Foo", bundleID: "com.foo", path: "/Applications/Foo.app", action: .block)
        let d = engine(rules: [rule]).decide(ctx("com.foobar", "/Applications/Foo.app.bak/Contents/MacOS/x"))
        XCTAssertEqual(d.verdict, .direct)
        XCTAssertEqual(d.reason, .defaultAction)
    }

    func testCommandLineToolMatchedByExactPath() {
        let rule = AppRule(name: "curl", bundleID: "com.apple.curl", path: "/usr/bin/curl", action: .proxy(serverID: socks.id))
        let e = engine(rules: [rule])
        XCTAssertEqual(e.decide(ctx("something-else", "/usr/bin/curl")).verdict, .proxy(socks))
        XCTAssertEqual(e.decide(ctx("com.apple.curl", nil)).verdict, .proxy(socks))
        XCTAssertEqual(e.decide(ctx("com.apple.curlx", "/usr/bin/curlx")).verdict, .direct)
    }

    func testMostSpecificRuleWins() {
        let chrome = AppRule(name: "Chrome", bundleID: "com.google.Chrome", path: "", action: .proxy(serverID: socks.id))
        let canary = AppRule(name: "Canary", bundleID: "com.google.Chrome.canary", path: "", action: .block)
        let e = engine(rules: [chrome, canary])
        XCTAssertEqual(e.decide(ctx("com.google.Chrome.canary")).verdict, .block)
        XCTAssertEqual(e.decide(ctx("com.google.Chrome.canary.helper")).verdict, .block)
        XCTAssertEqual(e.decide(ctx("com.google.Chrome.helper")).verdict, .proxy(socks))
    }

    func testExactMatchBeatsPathMatch() {
        let byPath = AppRule(name: "A", bundleID: "com.a", path: "/Applications/A.app", action: .block)
        let exact = AppRule(name: "B", bundleID: "com.b.helper", path: "", action: .proxy(serverID: socks.id))
        let d = engine(rules: [byPath, exact]).decide(ctx("com.b.helper", "/Applications/A.app/Contents/MacOS/helper"))
        XCTAssertEqual(d.rule?.id, exact.id)
    }

    func testDisabledRuleIgnored() {
        let rule = AppRule(name: "X", bundleID: "com.x", path: "", action: .block, enabled: false)
        XCTAssertEqual(engine(rules: [rule]).decide(ctx("com.x")).verdict, .direct)
    }

    func testDefaultActionExclusionMode() {
        let settings = GeneralSettings(defaultAction: .proxy(serverID: socks.id))
        let exclude = AppRule(name: "WeChat", bundleID: "com.tencent.xinWeChat", path: "", action: .direct)
        let e = engine(rules: [exclude], settings: settings)
        XCTAssertEqual(e.decide(ctx("com.random.app")).verdict, .proxy(socks))
        XCTAssertEqual(e.decide(ctx("com.random.app")).reason, .defaultAction)
        XCTAssertEqual(e.decide(ctx("com.tencent.xinWeChat")).verdict, .direct)
    }

    func testSystemProcessesExemptFromDefaultProxy() {
        let settings = GeneralSettings(defaultAction: .proxy(serverID: socks.id))
        let e = engine(rules: [], settings: settings)
        XCTAssertEqual(e.decide(ctx("com.apple.trustd", "/usr/libexec/trustd")).reason, .systemProcess)
        XCTAssertEqual(e.decide(ctx("com.apple.Safari", "/Applications/Safari.app")).verdict, .proxy(socks))
        // 显式规则优先于系统进程豁免
        let curl = AppRule(name: "curl", bundleID: "com.apple.curl", path: "/usr/bin/curl", action: .proxy(serverID: socks.id))
        XCTAssertEqual(engine(rules: [curl], settings: settings).decide(ctx("com.apple.curl", "/usr/bin/curl")).verdict, .proxy(socks))
        // 关闭豁免后系统进程也走默认动作
        var off = settings
        off.exemptSystemProcesses = false
        XCTAssertEqual(engine(rules: [], settings: off).decide(ctx("com.apple.trustd", "/usr/libexec/trustd")).verdict, .proxy(socks))
    }

    func testMDNSResponderAlwaysDirect() {
        let rule = AppRule(name: "x", bundleID: "com.apple.mDNSResponder", path: "", action: .block)
        let d = engine(rules: [rule], settings: GeneralSettings(defaultAction: .block))
            .decide(ctx("com.apple.mDNSResponder", "/usr/sbin/mDNSResponder", ip: "8.8.8.8", port: 53, udp: true))
        XCTAssertEqual(d.verdict, .direct)
    }

    func testDNSQueriesAttributedToAppAreNeverBlocked() {
        // 回归：UDP 策略为阻断时，系统归属到该应用的 DNS 查询曾被阻断，导致应用无法解析域名。
        let rule = AppRule(name: "curl", bundleID: "com.apple.curl", path: "/usr/bin/curl",
                           action: .proxy(serverID: socks.id), udpPolicy: .block)
        let e = engine(rules: [rule])
        let udp = e.decide(ctx("com.apple.curl", "/usr/bin/curl", ip: "223.5.5.5", port: 53, udp: true))
        XCTAssertEqual(udp.verdict, .direct)
        XCTAssertEqual(udp.reason, .dns)
        XCTAssertEqual(e.decide(ctx("com.apple.curl", "/usr/bin/curl", ip: "223.5.5.5", port: 53)).reason, .dns)
        let blocked = engine(rules: [AppRule(name: "x", bundleID: "com.x", path: "", action: .block)])
        XCTAssertEqual(blocked.decide(ctx("com.x", ip: "8.8.8.8", port: 53, udp: true)).verdict, .direct)
        // 其他 UDP 仍按策略阻断
        XCTAssertEqual(e.decide(ctx("com.apple.curl", "/usr/bin/curl", ip: "1.1.1.1", port: 443, udp: true)).verdict, .block)
    }

    func testConnectionToProxyServerItselfIsDirect() {
        let rule = AppRule(name: "X", bundleID: "com.x", path: "", action: .proxy(serverID: socks.id))
        let e = engine(rules: [rule], settings: GeneralSettings(bypassLAN: false))
        XCTAssertEqual(e.decide(ctx("com.x", ip: "10.0.0.1", port: 1080)).reason, .proxyServer)
        XCTAssertEqual(e.decide(ctx("com.x", ip: "1.2.3.4", port: 8080, host: "proxy.example.com")).reason, .proxyServer)
        XCTAssertEqual(e.decide(ctx("com.x", ip: "10.0.0.1", port: 443)).verdict, .proxy(socks))
    }

    func testLoopbackAlwaysDirect() {
        let rule = AppRule(name: "X", bundleID: "com.x", path: "", action: .block)
        let e = engine(rules: [rule])
        XCTAssertEqual(e.decide(ctx("com.x", ip: "127.0.0.1")).reason, .loopback)
        XCTAssertEqual(e.decide(ctx("com.x", ip: "::1")).reason, .loopback)
        XCTAssertEqual(e.decide(ctx("com.x", ip: "1.2.3.4", host: "localhost")).reason, .loopback)
    }

    func testLANBypassToggle() {
        let rule = AppRule(name: "X", bundleID: "com.x", path: "", action: .proxy(serverID: socks.id))
        XCTAssertEqual(engine(rules: [rule]).decide(ctx("com.x", ip: "192.168.1.10")).reason, .localNetwork)
        let off = engine(rules: [rule], settings: GeneralSettings(bypassLAN: false))
        XCTAssertEqual(off.decide(ctx("com.x", ip: "192.168.1.10")).verdict, .proxy(socks))
    }

    func testUDPPolicies() {
        func rule(_ p: UDPPolicy, server: ProxyServer) -> AppRule {
            AppRule(name: "X", bundleID: "com.x", path: "", action: .proxy(serverID: server.id), udpPolicy: p)
        }
        XCTAssertEqual(engine(rules: [rule(.block, server: socks)]).decide(ctx("com.x", udp: true)).verdict, .block)
        XCTAssertEqual(engine(rules: [rule(.direct, server: socks)]).decide(ctx("com.x", udp: true)).verdict, .direct)
        XCTAssertEqual(engine(rules: [rule(.proxy, server: socks)]).decide(ctx("com.x", udp: true)).verdict, .proxy(socks))
        let viaHTTP = engine(rules: [rule(.proxy, server: http)]).decide(ctx("com.x", udp: true))
        XCTAssertEqual(viaHTTP.verdict, .block)
        XCTAssertEqual(viaHTTP.reason, .udpUnsupported)
        // TCP 不受 UDP 策略影响
        XCTAssertEqual(engine(rules: [rule(.block, server: socks)]).decide(ctx("com.x")).verdict, .proxy(socks))
    }

    func testMissingServerUsesFailurePolicy() {
        let rule = AppRule(name: "X", bundleID: "com.x", path: "", action: .proxy(serverID: UUID()))
        XCTAssertEqual(engine(rules: [rule]).decide(ctx("com.x")).verdict, .block)
        let open = engine(rules: [rule], settings: GeneralSettings(onProxyFailure: .direct))
        let d = open.decide(ctx("com.x"))
        XCTAssertEqual(d.verdict, .direct)
        XCTAssertEqual(d.reason, .missingServer)
    }

    func testUpstreamTargetPrefersHostname() {
        let e = engine(rules: [])
        let c = ctx("a", ip: "1.2.3.4", port: 443, host: "example.com")
        XCTAssertEqual(e.upstreamTarget(for: c), TargetAddress(host: "example.com", port: 443))
        XCTAssertEqual(e.upstreamTarget(for: ctx("a", ip: "1.2.3.4", host: nil)).host, "1.2.3.4")
        XCTAssertEqual(e.upstreamTarget(for: ctx("a", ip: "1.2.3.4", host: "5.6.7.8")).host, "1.2.3.4")
        let off = engine(rules: [], settings: GeneralSettings(preferHostname: false))
        XCTAssertEqual(off.upstreamTarget(for: c).host, "1.2.3.4")
    }
}

final class ModelsTests: XCTestCase {
    func testConfigurationRoundTripAndRedaction() throws {
        let s = ProxyServer(name: "S", type: .socks5, host: "h", port: 1, username: "u", password: "secret")
        let cfg = ProxyAppXConfig(
            servers: [s],
            rules: [AppRule(name: "A", bundleID: "a", path: "/A.app", action: .proxy(serverID: s.id), udpPolicy: .proxy)],
            settings: GeneralSettings(defaultAction: .block, onProxyFailure: .direct)
        )
        let decoded = try ProxyAppXConfig.decode(try cfg.encoded())
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.servers[0].password, "secret")

        let redacted = cfg.redacted()
        XCTAssertNil(redacted.servers[0].password)
        let text = String(decoding: try redacted.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
    }

    func testDecodingToleratesMissingFields() throws {
        let json = #"{"servers":[{"host":"1.1.1.1","port":1080}],"rules":[{"bundleID":"com.x"}]}"#
        let cfg = try ProxyAppXConfig.decode(Data(json.utf8))
        XCTAssertEqual(cfg.servers[0].type, .socks5)
        XCTAssertEqual(cfg.rules[0].action, .direct)
        XCTAssertTrue(cfg.rules[0].enabled)
        XCTAssertEqual(cfg.settings, GeneralSettings())
    }

    func testIPCRoundTrip() throws {
        let req = IPCRequest.status(logsAfter: 42)
        guard case let .status(after) = try IPCRequest.decode(try req.encoded()) else { return XCTFail() }
        XCTAssertEqual(after, 42)

        let snap = StatusSnapshot(startedAt: Date(), extensionVersion: "1.0", ruleCount: 1, active: [], recent: [],
                                  totals: TrafficTotals(), logs: [LogEntry(id: 1, level: .warning, message: "m")])
        guard case let .status(s) = try IPCResponse.decode(try IPCResponse.status(snap).encoded()) else { return XCTFail() }
        XCTAssertEqual(s.logs.first?.message, "m")
    }
}

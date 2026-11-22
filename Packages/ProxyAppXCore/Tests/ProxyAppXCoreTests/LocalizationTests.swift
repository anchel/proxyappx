import XCTest
@testable import ProxyAppXCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.language = .english
    }

    func testLanguageFromLocalization() {
        XCTAssertEqual(AppLanguage(localization: "zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(localization: "zh_CN"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(localization: "en"), .english)
        XCTAssertEqual(AppLanguage(localization: "ja"), .english)
        XCTAssertEqual(AppLanguage(localization: nil), .english)
    }

    func testMessagesFollowLanguage() {
        L10n.language = .english
        XCTAssertEqual(ProxyError.timeout.errorDescription, "Connection timed out")
        XCTAssertEqual(ProxyError.socksReply(5).errorDescription, "SOCKS5 error: connection refused")
        XCTAssertEqual(UDPPolicy.block.displayName, "Block (recommended)")
        XCTAssertEqual(Decision.Reason.fakeIP.displayName, "Fake IP handed to TUN")

        L10n.language = .simplifiedChinese
        XCTAssertEqual(ProxyError.timeout.errorDescription, "连接超时")
        XCTAssertEqual(ProxyError.socksReply(5).errorDescription, "SOCKS5 错误：连接被拒绝")
        XCTAssertEqual(FailurePolicy.direct.displayName, "回落直连")
        XCTAssertEqual(Upstream.direct.label, "直连")
    }

    func testConfigurationCarriesLanguage() throws {
        var cfg = ProxyAppXConfig()
        XCTAssertNil(try ProxyAppXConfig.decode(try cfg.encoded()).language)
        cfg.language = .simplifiedChinese
        XCTAssertEqual(try ProxyAppXConfig.decode(try cfg.encoded()).language, .simplifiedChinese)
        // 未知取值不影响解析
        let json = #"{"language":"fr","servers":[]}"#
        XCTAssertNil(try ProxyAppXConfig.decode(Data(json.utf8)).language)
    }
}

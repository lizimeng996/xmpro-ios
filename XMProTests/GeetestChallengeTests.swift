
import XCTest
import Foundation
import WebKit
@testable import XMPro

final class GeetestChallengeTests: XCTestCase {
    private func fields() -> [String: Any] {
        [
            "captcha_id": GeetestChallenge.captchaID,
            "lot_number": "fixture-lot",
            "pass_token": "fixture-pass",
            "gen_time": "1",
            "captcha_output": "fixture-output"
        ]
    }

    private func parse(_ value: [String: Any]) throws -> [String: String]? {
        GeetestChallenge.parseChallenge(
            payload: try B1JSON.encode(value),
            captchaID: GeetestChallenge.captchaID
        )
    }

    func testExactFieldsAndTypes() throws {
        XCTAssertEqual(try parse(fields())?.count, 5)
        for key in GeetestChallenge.fields {
            var missing = fields()
            missing.removeValue(forKey: key)
            XCTAssertNil(try parse(missing))
            var wrongType = fields()
            wrongType[key] = 1
            XCTAssertNil(try parse(wrongType))
        }
        var extra = fields()
        extra["extra"] = "x"
        XCTAssertNil(try parse(extra))
        XCTAssertNil(GeetestChallenge.parseChallenge(payload: nil, captchaID: "x"))
        XCTAssertNil(GeetestChallenge.parseChallenge(payload: "[]", captchaID: "x"))
    }

    func testInvalidCharactersAndLength() throws {
        for value in ["", "a b", "a\n", "\u{7f}", "中文", String(repeating: "x", count: 8193)] {
            var input = fields()
            input["lot_number"] = value
            XCTAssertNil(try parse(input))
        }
        var boundary = fields()
        boundary["lot_number"] = String(repeating: "~", count: 8192)
        XCTAssertNotNil(try parse(boundary))
    }

    func testCaptchaIDCaseInsensitive() throws {
        var input = fields()
        input["captcha_id"] = GeetestChallenge.captchaID.uppercased()
        XCTAssertNotNil(try parse(input))
        input["captcha_id"] = "wrong"
        XCTAssertNil(try parse(input))
    }

    func testAllowedDomainsAndSubdomains() throws {
        for domain in ["geetest.com", "geevisit.com", "gsensebot.com"] {
            for prefix in ["", "static.", "a.b."] {
                let url = try XCTUnwrap(URL(string: "https://\(prefix)\(domain)/v4"))
                XCTAssertTrue(GeetestChallenge.allowed(url: url))
            }
        }
        for value in [
            "https://evilgeetest.com/",
            "https://geetest.com.evil.invalid/",
            "https://example.invalid/"
        ] {
            XCTAssertFalse(GeetestChallenge.allowed(url: try XCTUnwrap(URL(string: value))))
        }
    }

    func testSchemePortAndUserInfo() throws {
        for value in [
            "http://geetest.com/",
            "file:///geetest.com",
            "https://geetest.com:444/",
            "https://user@geetest.com/",
            "https://user:password@geetest.com/"
        ] {
            XCTAssertFalse(GeetestChallenge.allowed(url: try XCTUnwrap(URL(string: value))))
        }
        XCTAssertTrue(GeetestChallenge.allowed(
            url: try XCTUnwrap(URL(string: "https://geetest.com:443/"))
        ))
    }

    func testHtmlCSPBridgeAndEscaping() {
        let input = "\"</script>&\u{2028}\n"
        let html = GeetestChallenge.html(captchaID: input, nonce: input)
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("https://static.geetest.com/v4/gt4.js"))
        XCTAssertTrue(html.contains("messageHandlers.xmlyCaptcha"))
        XCTAssertTrue(html.contains("product:'bind'"))
        XCTAssertTrue(html.contains("language:'zho'"))
        XCTAssertTrue(html.contains("\\u003c"))
        XCTAssertTrue(html.contains("\\u2028"))
        XCTAssertFalse(html.contains(input))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 1)
        // 逐指令核对 CSP 来源集合：按分号解析后对每条指令的完整来源集合
        // 做等值断言（G-m2-R：此前 contains 前缀匹配检不出 style/font 被
        // 恢复为三域名族的回归；等值断言下追加任一来源即失败）。
        let csp = Self.cspDirectives(from: html)
        let threeFamilies: Set<String> = [
            "https://geetest.com", "https://*.geetest.com",
            "https://geevisit.com", "https://*.geevisit.com",
            "https://gsensebot.com", "https://*.gsensebot.com"
        ]
        let geetestOnly: Set<String> = [
            "https://geetest.com", "https://*.geetest.com"
        ]
        XCTAssertEqual(Set(csp.keys), [
            "default-src", "script-src", "connect-src", "img-src",
            "style-src", "font-src", "frame-src",
            "object-src", "base-uri", "form-action"
        ])
        XCTAssertEqual(csp["default-src"], ["'none'"])
        XCTAssertEqual(csp["script-src"], Set(["'unsafe-inline'"]).union(threeFamilies))
        XCTAssertEqual(csp["connect-src"], threeFamilies)
        XCTAssertEqual(csp["img-src"], Set(["data:", "blob:"]).union(threeFamilies))
        XCTAssertEqual(csp["style-src"], Set(["'unsafe-inline'"]).union(geetestOnly))
        XCTAssertEqual(csp["font-src"], Set(["data:"]).union(geetestOnly))
        XCTAssertEqual(csp["frame-src"], threeFamilies)
        XCTAssertEqual(csp["object-src"], ["'none'"])
        XCTAssertEqual(csp["base-uri"], ["'none'"])
        XCTAssertEqual(csp["form-action"], ["'none'"])
    }

    /// 从生成的 HTML 中提取 CSP，按 `;` 切分指令，返回指令名 → 来源集合。
    private static func cspDirectives(from html: String) -> [String: Set<String>] {
        guard let start = html.range(of: "default-src "),
              let end = html[start.lowerBound...].range(of: "\">") else {
            XCTFail("HTML 中未找到 CSP")
            return [:]
        }
        let csp = String(html[start.lowerBound..<end.lowerBound])
        var result: [String: Set<String>] = [:]
        for part in csp.split(separator: ";") {
            let tokens = part.split(separator: " ").map(String.init)
            guard let name = tokens.first else { continue }
            result[name] = Set(tokens.dropFirst())
        }
        return result
    }

    func testNonceIsRandomBase64URL() {
        let first = GeetestChallenge.newNonce()
        let second = GeetestChallenge.newNonce()
        XCTAssertTrue(first != second)
        for value in [first, second] {
            XCTAssertTrue(ProtocolBytes.fullMatch(#"^[A-Za-z0-9_-]{43}$"#, value))
            XCTAssertEqual(ProtocolBytes.decodeBase64URL(value)?.count, 32)
        }
    }

    func testNavigationPolicyAllowsInitialSubframesAndBlocksExternalSilently() throws {
        let documentURL = try XCTUnwrap(
            URL(string: "https://appassets.androidplatform.net/xmpro-captcha/testnonce/index.html")
        )
        let aboutBlank = try XCTUnwrap(URL(string: "about:blank"))
        let aboutSrcdoc = try XCTUnwrap(URL(string: "about:srcdoc"))
        let fragmentURL = try XCTUnwrap(
            URL(string: "https://appassets.androidplatform.net/xmpro-captcha/testnonce/index.html#step")
        )
        let otherFragmentURL = try XCTUnwrap(
            URL(string: "https://appassets.androidplatform.net/xmpro-captcha/other/index.html#step")
        )
        let geetestSubframe = try XCTUnwrap(URL(string: "https://gcaptcha4.geetest.com/verify"))
        let geetestMain = try XCTUnwrap(URL(string: "https://www.geetest.com/"))
        let externalURL = try XCTUnwrap(URL(string: "https://example.invalid/"))
        let httpGeetest = try XCTUnwrap(URL(string: "http://geetest.com/"))
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/a"))

        // 首次主框架装载
        XCTAssertEqual(
            GeetestNavigationPolicy.decide(
                url: documentURL,
                targetFrameIsMain: true,
                navigationType: .other,
                documentURL: documentURL,
                acceptedInitialNavigation: false
            ),
            .allowInitial
        )
        XCTAssertEqual(
            GeetestNavigationPolicy.decide(
                url: aboutBlank,
                targetFrameIsMain: true,
                navigationType: .other,
                documentURL: documentURL,
                acceptedInitialNavigation: false
            ),
            .allowInitial
        )
        XCTAssertEqual(
            GeetestNavigationPolicy.decide(
                url: externalURL,
                targetFrameIsMain: true,
                navigationType: .other,
                documentURL: documentURL,
                acceptedInitialNavigation: false
            ),
            .cancel
        )

        // 首次装载之后的主框架导航：仅允许同页锚点，禁止重载与外跳
        for blockedMain in [documentURL, aboutBlank, externalURL, geetestMain, otherFragmentURL] {
            XCTAssertEqual(
                GeetestNavigationPolicy.decide(
                    url: blockedMain,
                    targetFrameIsMain: true,
                    navigationType: .other,
                    documentURL: documentURL,
                    acceptedInitialNavigation: true
                ),
                .cancel
            )
        }
        XCTAssertEqual(
            GeetestNavigationPolicy.decide(
                url: fragmentURL,
                targetFrameIsMain: true,
                navigationType: .linkActivated,
                documentURL: documentURL,
                acceptedInitialNavigation: true
            ),
            .allowSameDocumentFragment
        )

        // 子框架：允许白名单 HTTPS 与本地空白子框架，禁止非白名单 URL
        for allowedSubframe in [geetestSubframe, aboutBlank, aboutSrcdoc] {
            XCTAssertEqual(
                GeetestNavigationPolicy.decide(
                    url: allowedSubframe,
                    targetFrameIsMain: false,
                    navigationType: .other,
                    documentURL: documentURL,
                    acceptedInitialNavigation: true
                ),
                .allowSubframe
            )
        }
        for blockedSubframe in [externalURL, httpGeetest, fileURL] {
            XCTAssertEqual(
                GeetestNavigationPolicy.decide(
                    url: blockedSubframe,
                    targetFrameIsMain: false,
                    navigationType: .other,
                    documentURL: documentURL,
                    acceptedInitialNavigation: true
                ),
                .cancel
            )
        }

        // 新窗口（targetFrame == nil）统一静默取消
        for targetBlankURL in [geetestMain, externalURL, aboutBlank] {
            XCTAssertEqual(
                GeetestNavigationPolicy.decide(
                    url: targetBlankURL,
                    targetFrameIsMain: nil,
                    navigationType: .linkActivated,
                    documentURL: documentURL,
                    acceptedInitialNavigation: true
                ),
                .cancel
            )
        }
    }

    @MainActor
    func testContentRuleListCompilesCleanly() async throws {
        let json = try B1JSON.encode(GeetestNavigationPolicy.contentRuleListRules())
        let identifier = "xmpro-test-captcha-\(UUID().uuidString)"
        let compiled: (WKContentRuleList?, Error?) = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                continuation.resume(returning: (list, error))
            }
        }
        XCTAssertNil(compiled.1)
        XCTAssertNotNil(compiled.0)
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

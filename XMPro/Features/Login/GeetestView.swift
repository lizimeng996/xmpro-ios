// 需在 Mac 工程中为 App target 链接 WebKit framework（执行侧处理 .xcodeproj）。

import SwiftUI
import WebKit

// iOS 16 公共 WKWebView API 不支持拦截 https scheme 并合成本地 HTTP 响应。
// 本文件采用 loadHTMLString + CSP + 内容规则 + 导航拒绝的公共 API 实现。
// TODO(Mac)：本地 https 文档响应 / HTTP 403 的精确语义尚未实现；
// 不得把此替代方案标记为已满足 Android shouldInterceptRequest 的全部契约。
// 禁止通过私有 KVC、注册 https WKURLSchemeHandler 或 URLProtocol 假装实现。

struct GeetestView: View {
    private let captchaID: String
    private let onDismiss: () -> Void
    private let onSuccess: ([String: String]) -> Void

    @State private var nonce = GeetestChallenge.newNonce()
    @State private var ready = false
    @State private var error: String?
    @State private var finished = false

    init(
        captchaID: String,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping ([String: String]) -> Void
    ) {
        self.captchaID = captchaID
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("安全验证").font(.headline)
            if let error {
                Text(error).foregroundColor(.red)
            } else {
                Text(ready
                     ? "请完成下方验证后返回登录。"
                     : "正在加载安全验证…")
                CaptchaWebView(
                    captchaID: captchaID,
                    nonce: nonce,
                    onEvent: receive,
                    onError: { message in
                        guard !finished else { return }
                        error = message
                    }
                )
                .frame(height: 380)
            }
            Button("关闭", action: dismissOnce)
        }
        .padding()
        .onDisappear(perform: dismissOnce)
    }

    private func dismissOnce() {
        guard !finished else { return }
        finished = true
        onDismiss()
    }

    private func receive(kind: String, payload: String?) {
        guard !finished, error == nil else { return }
        switch kind {
        case "ready":
            ready = true
        case "success":
            guard let fields = GeetestChallenge.parseChallenge(
                payload: payload, captchaID: captchaID
            ) else {
                error = "安全验证结果无效，请关闭后重新验证。"
                return
            }
            finished = true
            onSuccess(fields)
        case "close":
            dismissOnce()
        case "error":
            error = "安全验证未完成，请关闭后重试，或使用 Cookie 登录。"
        default:
            break
        }
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let captchaID: String
    let nonce: String
    let onEvent: (String, String?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            nonce: nonce,
            onEvent: onEvent,
            onError: onError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(
            context.coordinator, name: "xmlyCaptcha"
        )

        // WebKit 默认支持 DOM storage；使用临时 store，不持久化挑战。
        // 公共 API 没有 Android allowContentAccess 开关；
        // 不加载文件，并在内容规则和导航代理中拒绝 file/content。
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.prepare(webView, captchaID: captchaID)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopped = true
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: "xmlyCaptcha"
        )
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject,
                             WKScriptMessageHandler,
                             WKNavigationDelegate,
                             WKUIDelegate {
        private let nonce: String
        private let documentURL: URL
        private let onEvent: (String, String?) -> Void
        private let onError: (String) -> Void
        var stopped = false
        private var acceptedInitialNavigation = false

        init(
            nonce: String,
            onEvent: @escaping (String, String?) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.nonce = nonce
            documentURL = URL(
                string: "https://appassets.androidplatform.net/xmpro-captcha/\(nonce)/index.html"
            )!
            self.onEvent = onEvent
            self.onError = onError
        }

        func prepare(_ webView: WKWebView, captchaID: String) {
            // 先阻止所有网络资源，再仅豁免严格域名/端口白名单。
            // data/blob 仅用于 GeeTest 图像，与 HTML CSP 保持一致。
            // url-filter 使用受限正则语法，不支持 `|` 分支：每个域名与
            // 每个 scheme 各写一条独立规则（G-B1；见 WebKit bug 207539）。
            var rules: [[String: Any]] = [
                [
                    "trigger": ["url-filter": ".*"],
                    "action": ["type": "block"]
                ]
            ]
            for domain in ["geetest\\.com", "geevisit\\.com", "gsensebot\\.com"] {
                rules.append([
                    "trigger": [
                        "url-filter":
                            "^https://([a-z0-9-]+\\.)*\(domain)(:443)?/",
                        "url-filter-is-case-sensitive": false
                    ],
                    "action": ["type": "ignore-previous-rules"]
                ])
            }
            for scheme in ["data:", "blob:"] {
                rules.append([
                    "trigger": [
                        "url-filter": "^\(scheme)",
                        "resource-type": ["image"]
                    ],
                    "action": ["type": "ignore-previous-rules"]
                ])
            }
            guard let json = try? B1JSON.encode(rules) else {
                fail()
                return
            }
            let identifier = "xmpro-captcha-\(nonce)"
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self, weak webView] list, _ in
                DispatchQueue.main.async {
                    guard let list else {
                        // 编译失败：store 内无规则可清理；视图仍在才报失败。
                        guard let self, !self.stopped else { return }
                        self.fail()
                        return
                    }
                    guard let self, !self.stopped, let webView else {
                        // 视图已关闭：编译出的规则仍在 store 中，须立即清除，
                        // 否则每次挑战的残留规则会一直占用 store。
                        WKContentRuleListStore.default().removeContentRuleList(
                            forIdentifier: identifier
                        ) { _ in }
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    // HTML 来自内存；不向 appassets 发起网络请求。
                    webView.loadHTMLString(
                        GeetestChallenge.html(captchaID: captchaID, nonce: self.nonce),
                        baseURL: self.documentURL
                    )
                    WKContentRuleListStore.default().removeContentRuleList(
                        forIdentifier: identifier
                    ) { _ in }
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard !stopped,
                  message.name == "xmlyCaptcha",
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  body["nonce"] as? String == nonce,
                  let kind = body["kind"] as? String else {
                return
            }
            onEvent(kind, body["payload"] as? String)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard !stopped, let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // loadHTMLString 在 WebKit 版本间可能报告 about:blank；
            // 仅允许第一次主框架的本地装载，后续导航全部校验。
            if !acceptedInitialNavigation,
               navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .other,
               url == documentURL || url.absoluteString == "about:blank" {
                acceptedInitialNavigation = true
                decisionHandler(.allow)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == true,
               url == documentURL {
                // 不允许 reload 等路径真的请求远程 appassets 文档。
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != true,
               GeetestChallenge.allowed(url: url) {
                // GeeTest 挑战 UI 在子框架中加载；只放行白名单内的子框架导航。
                decisionHandler(.allow)
                return
            }
            // 按题设：任何导航到非文档 URL 都进入错误态。
            // 子资源由 CSP / 内容规则处理，不走此导航豁免。
            onError("安全验证不允许跳转。")
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            onError("安全验证不允许跳转。")
            return nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail()
        }

        private func fail() {
            guard !stopped else { return }
            onError("安全验证未完成，请关闭后重试，或使用 Cookie 登录。")
        }
    }
}

// TODO 汇总：
// 1. iOS 公共 WebKit 无法满足指定 https 本地拦截和合成 403 响应。
// 2. 子框架导航已按 GeetestChallenge.allowed 放行，GeeTest 挑战 UI
//    不再被导航代理整段拦截；实际渲染仍需 Mac 真机验证。
// 3. WKWebView 没有与 Android 第三方 Cookie 开关完全等价的公开配置；
//    nonPersistent 仅保证隔离持久化，不能声称彻底禁用第三方 Cookie。
// 4. CSP / WKContentRuleList 用平台声明式规则表达 GeetestChallenge.allowed
//    的同一网络白名单；不是一个可对所有子资源调用 Swift allowed 的拦截器。

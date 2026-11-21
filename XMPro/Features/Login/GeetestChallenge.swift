
import Foundation

enum GeetestChallenge {
    // 字段与 captchaId 的唯一定义在协议层（ProtocolConfig）；
    // 本类型只作别名，避免 Services/Features 两份定义漂移。
    static let captchaID = ProtocolConfig.captchaID
    static let fields = ProtocolConfig.geeTestFields

    static func parseChallenge(
        payload: String?,
        captchaID: String
    ) -> [String: String]? {
        guard let payload,
              payload.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(
                  with: Data(payload.utf8)
              ) as? [String: Any],
              object.count == fields.count else {
            return nil
        }
        var result: [String: String] = [:]
        for field in fields {
            guard let value = object[field] as? String,
                  ProtocolBytes.fullMatch(#"^[\x21-\x7e]{1,8192}$"#, value) else {
                return nil
            }
            result[field] = value
        }
        guard result["captcha_id"]?.lowercased() == captchaID.lowercased() else {
            return nil
        }
        return result
    }

    static func allowed(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else {
            return false
        }
        return ["geetest.com", "geevisit.com", "gsensebot.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func newNonce() -> String {
        ProtocolBytes.newNonce()
    }

    private static func quoted(_ value: String) -> String {
        // JSON 字符串转义之外，再转义 HTML script 结束标记及 JS 行分隔符。
        let data = try! JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func html(captchaID: String, nonce: String) -> String {
        let id = quoted(captchaID)
        let token = quoted(nonce)
        let hosts = [
            "https://geetest.com", "https://*.geetest.com",
            "https://geevisit.com", "https://*.geevisit.com",
            "https://gsensebot.com", "https://*.gsensebot.com"
        ].joined(separator: " ")
        // style/font 只允许 GeeTest 域名族（与 Kotlin CSP 一致）；
        // 其余指令沿用三域名族（含 D3 已接受的裸顶级域名）。
        let geetestHosts = "https://geetest.com https://*.geetest.com"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' \(hosts); connect-src \(hosts); img-src data: blob: \(hosts); style-src 'unsafe-inline' \(geetestHosts); font-src data: \(geetestHosts); frame-src \(hosts); object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta http-equiv="Cache-Control" content="no-store">
        <style>body{font:15px sans-serif;text-align:center;padding:16px;color:#333}</style>
        </head><body><p id="status">正在加载安全验证…</p>
        <script>
        (function(){
          var nonce=\(token);
          function emit(kind,payload){
            var bridge=window.webkit&&window.webkit.messageHandlers.xmlyCaptcha;
            if(bridge) bridge.postMessage({
              nonce:nonce,kind:kind,payload:payload?JSON.stringify(payload):null
            });
          }
          function fail(){
            document.getElementById('status').textContent='安全验证加载失败，请关闭后重试';
            emit('error');
          }
          function start(){
            if(typeof initGeetest4!=='function'){fail();return;}
            initGeetest4({
              captchaId:\(id),product:'bind',language:'zho',protocol:'https://',
              onError:fail,offlineCb:fail
            },function(captcha){
              captcha.onReady(function(){
                document.getElementById('status').textContent='请完成安全验证';
                emit('ready');captcha.showCaptcha();
              }).onSuccess(function(){
                var v=captcha.getValidate();
                if(!v){fail();return;}
                var out={captcha_id:\(id)};
                ['lot_number','pass_token','gen_time','captcha_output'].forEach(function(k){
                  out[k]=v[k];
                });
                emit('success',out);
              }).onError(fail).onClose(function(){emit('close');});
            });
          }
          var script=document.createElement('script');
          script.src='https://static.geetest.com/v4/gt4.js';
          script.onload=start;script.onerror=fail;
          document.head.appendChild(script);
        })();
        </script></body></html>
        """
    }
}

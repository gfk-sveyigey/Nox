import CryptoKit
import Foundation
import NoxCore

extension YouTubeParser {
    // MARK: - InnerTube 客户端

    /// 一个 InnerTube 客户端指纹。
    struct ClientProfile {
        let name: String
        let version: String
        /// `X-Youtube-Client-Name` 头用的数字 ID
        let numericID: String
        let userAgent: String
        let androidSdkVersion: Int?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?

        /// WEB 客户端：版本号 / UA 都取页面里的值。
        static let web = ClientProfile(
            name: "WEB",
            version: "",
            numericID: "1",
            userAgent: "",
            androidSdkVersion: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil
        )

        /// iOS 客户端：返回可直接下载的直链，且通常不要求 PO token。
        static let ios = ClientProfile(
            name: "IOS",
            version: "19.29.1",
            numericID: "5",
            userAgent: "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)",
            androidSdkVersion: nil,
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.1.0.22B83"
        )

        /// Android VR 客户端：返回直链、且通常不要求 PO token，是最稳的一条。
        static let androidVR = ClientProfile(
            name: "ANDROID_VR",
            version: "1.60.19",
            numericID: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; GB) gzip",
            androidSdkVersion: 32,
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12"
        )

        /// 电视内嵌客户端：同样常返回直链。
        static let tv = ClientProfile(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            numericID: "85",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            androidSdkVersion: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil
        )
    }

    /// 从 App 端发起一次 InnerTube player 请求；任何失败都返回 nil，交给下一个来源。
    static func innerTubeResponse(
        profile: ClientProfile,
        videoID: String,
        page: WebPageContext
    ) async -> [String: Any]? {
        let isWeb = profile.name == "WEB"

        // WEB 沿用页面里的版本号与 UA；官方客户端用各自固定的指纹。
        let version = isWeb
            ? await pageString(page, script: clientVersionScript, fallback: fallbackClientVersion)
            : profile.version

        let userAgent = isWeb
            ? await pageString(page, script: userAgentScript, fallback: fallbackUserAgent)
            : profile.userAgent

        // 带上页面的 visitorData / 登录 Cookie，请求才像同一个会话。
        let visitorData = await pageString(page, script: visitorDataScript, fallback: "")

        // 关键：youtubei/v1/player 必须带 key=，否则 YouTube 直接返回 400。
        // 少了它，App 端的 iOS / ANDROID VR / TV 来源全都拿不到数据，
        // 只能退回页面里那份带 signatureCipher 的响应，于是报「需要签名解密」。
        let apiKey = await pageString(page, script: apiKeyScript, fallback: fallbackAPIKey)

        guard let endpoint = URL(string:
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=" + apiKey) else {
            return nil
        }

        var client: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": version,
            "hl": Self.languageHint
        ]
        if !isWeb {
            client["userAgent"] = profile.userAgent
            if let model = profile.deviceModel { client["deviceModel"] = model }
            if let osName = profile.osName { client["osName"] = osName }
            if let osVersion = profile.osVersion { client["osVersion"] = osVersion }
            if let sdk = profile.androidSdkVersion { client["androidSdkVersion"] = sdk }
        }
        if !visitorData.isEmpty { client["visitorData"] = visitorData }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=" + videoID, forHTTPHeaderField: "Referer")
        request.setValue(profile.numericID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // 只有 WEB 客户端用浏览器 Cookie 认证：官方客户端走各自的凭证，混用反而可能被拒。
        if isWeb, let cookie = await page.cookieHeader(matching: page.pageURL), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

            // 关键：带上 SAPISIDHASH。YouTube 的网页端 API 靠它确认请求来自已登录的网页；
            // 只带 Cookie 不带这个头，会被当成未登录，弹「请登录，以便我们确认你不是聊天机器人」。
            if let authorization = Self.sapisidAuthorization(cookieHeader: cookie) {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        var context: [String: Any] = ["client": client]
        if profile.name.hasPrefix("TVHTML5") {
            context["thirdParty"] = ["embedUrl": "https://www.youtube.com/"]
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": context
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            LogStore.shared.warning("youtube innertube " + profile.name + ": 请求失败")
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            LogStore.shared.warning("youtube innertube " + profile.name + ": HTTP " + String(http.statusCode))
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    /// 由 SAPISID Cookie 生成网页端用的 `Authorization: SAPISIDHASH <时间戳>_<sha1>`。
    ///
    /// 算法：`sha1("<unix 秒> <SAPISID> https://www.youtube.com")`，时间戳与哈希用下划线连接。
    /// 优先用 `SAPISID`（对应 `SAPISIDHASH`），退而用 `__Secure-3PAPISID`（对应 `SAPISID3HASH`）；
    /// 两者都没有时返回 nil，退化为未登录请求。
    static func sapisidAuthorization(cookieHeader: String) -> String? {
        var cookieValues: [String: String] = [:]
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            cookieValues[name] = String(parts[1])
        }

        let candidates: [(header: String, cookie: String)] = [
            ("SAPISIDHASH", "SAPISID"),
            ("SAPISID3HASH", "__Secure-3PAPISID")
        ]

        guard let match = candidates.first(where: { !(cookieValues[$0.cookie] ?? "").isEmpty }),
              let secret = cookieValues[match.cookie] else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(secret) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return "\(match.header) \(timestamp)_\(hex)"
    }

    /// 响应里是否有 streamingData（有就说明视频本身可播放）。
    static func hasStreamingData(_ response: [String: Any]) -> Bool {
        // 注意 JSON 的 null 会变成 NSNull：必须判断真的是字典，否则 null 会被当成「有数据」。
        response["streamingData"] is [String: Any]
    }

    /// streamingData 里是否至少有一条能直接用（带 url，或 signatureCipher 不含 s）。
    static func hasDirectURL(_ response: [String: Any]) -> Bool {
        guard let streaming = response["streamingData"] as? [String: Any] else { return false }

        let all = (streaming["formats"] as? [[String: Any]] ?? [])
            + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])

        return all.contains { ($0["mimeType"] as? String) != nil && mediaURL(from: $0) != nil }
    }

    /// 取格式的直链。
    ///
    /// - 优先用 url；
    /// - signatureCipher / cipher 只有在**不含 s 参数**时才等价于直链，可以直接用；
    /// - 带 s 的签名需要用播放器脚本解密，本实现没有引入那段逻辑，返回 nil 跳过。
    static func mediaURL(from format: [String: Any]) -> URL? {
        if let value = format["url"] as? String, !value.isEmpty, let url = URL(string: value) {
            return url
        }

        guard let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
              !cipher.isEmpty,
              let components = URLComponents(string: "?" + cipher) else {
            return nil
        }

        let items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "s" }),
              let raw = items.first(where: { $0.name == "url" })?.value,
              let url = URL(string: raw) else {
            return nil
        }

        return url
    }

    /// 在页面里执行：用播放器脚本（base.js）把 signatureCipher 解密成直链。
    ///
    /// 解密函数必须从 base.js 里按结构抽出来（签名函数 + 它调用的辅助对象），
    /// 用 JS 的正则和花括号配对来做，比在 Swift 里容易得多；而且这段跑在页面里
    /// 可以直接命中浏览器已缓存的 base.js。
    static let decipherScript = #"""
var debug = [];
var out = [];

function isIdentChar(ch) {
  return /[A-Za-z0-9_$]/.test(ch);
}

function braceBlock(src, start) {
  var depth = 0;
  for (var i = start; i < src.length && i < start + 300000; i++) {
    var ch = src.charAt(i);
    if (ch === "{") { depth++; }
    else if (ch === "}") {
      depth--;
      if (depth === 0) { return src.substring(start, i + 1); }
    }
  }
  return null;
}

function objectTexts(src, name) {
  var found = [];
  var from = 0;
  while (found.length < 60) {
    var idx = src.indexOf(name, from);
    if (idx < 0) { break; }
    from = idx + 1;
    if (idx > 0 && isIdentChar(src.charAt(idx - 1))) { continue; }
    var j = idx + name.length;
    while (j < src.length && /\s/.test(src.charAt(j))) { j++; }
    if (src.charAt(j) !== "=") { continue; }
    j++;
    while (j < src.length && /\s/.test(src.charAt(j))) { j++; }
    if (src.charAt(j) !== "{") { continue; }
    var text = braceBlock(src, j);
    if (text) { found.push(text); }
  }
  return found;
}

function hasMethods(text, names) {
  for (var i = 0; i < names.length; i++) {
    var esc = names[i].replace(/[^A-Za-z0-9_]/g, "\\$&");
    var re = new RegExp("(?:^|[,{\\s])" + esc + "\\s*[:(]");
    if (!re.test(text)) { return false; }
  }
  return true;
}

function candidateFunctions(src) {
  var list = [];
  var patterns = [
    /(?:^|[^A-Za-z0-9_$])([A-Za-z0-9_$]{1,6})\s*=\s*function\s*\(\s*([A-Za-z0-9_$]+)\s*\)\s*\{([\s\S]{0,8000}?)return\s+\2\.join\(\s*""\s*\)/g,
    /function\s+([A-Za-z0-9_$]{1,6})\s*\(\s*([A-Za-z0-9_$]+)\s*\)\s*\{([\s\S]{0,8000}?)return\s+\2\.join\(\s*""\s*\)/g
  ];
  for (var p = 0; p < patterns.length && list.length < 40; p++) {
    var re = patterns[p];
    var m;
    while ((m = re.exec(src)) !== null) {
      list.push({ name: m[1], arg: m[2], body: m[3] });
      if (list.length >= 40) { break; }
    }
  }
  return list;
}

function buildFromCandidate(cand, src) {
  var callRe = /([A-Za-z0-9_$]+)\s*\.\s*([A-Za-z0-9_$]+)\s*\(\s*[A-Za-z0-9_$]+\s*(?:,\s*(\d+)\s*)?\)/g;
  var calls = [];
  var objName = null;
  var c;
  while ((c = callRe.exec(cand.body)) !== null) {
    if (objName === null) { objName = c[1]; }
    else if (objName !== c[1]) { continue; }
    calls.push([c[2], c[3] ? parseInt(c[3], 10) : 0]);
  }
  if (!objName || !calls.length) { return null; }

  var names = [];
  for (var i = 0; i < calls.length; i++) {
    if (names.indexOf(calls[i][0]) < 0) { names.push(calls[i][0]); }
  }

  var candidates = objectTexts(src, objName);
  for (var k = 0; k < candidates.length; k++) {
    if (!hasMethods(candidates[k], names)) { continue; }
    try {
      var obj = eval("(" + candidates[k] + ")");
      if (obj) { return { obj: obj, calls: calls }; }
    } catch (e) {}
  }
  return null;
}

function decipherOne(cipher, dec) {
  var params;
  try { params = new URLSearchParams(cipher); } catch (e) { return null; }
  var sig = params.get("s");
  var url = params.get("url");
  var sp = params.get("sp") || "signature";
  if (!url) { return null; }
  if (!sig) { return url; }
  var chars = sig.split("");
  for (var i = 0; i < dec.calls.length; i++) {
    var fn = dec.obj[dec.calls[i][0]];
    if (typeof fn === "function") { fn(chars, dec.calls[i][1]); }
  }
  return url + "&" + sp + "=" + encodeURIComponent(chars.join(""));
}

try {
  if (!ciphers || !ciphers.length) { return { urls: [], debug: "no ciphers" }; }

  var jsUrl = null;
  try {
    if (window.ytcfg && typeof window.ytcfg.get === "function") {
      jsUrl = window.ytcfg.get("PLAYER_JS_URL");
    }
    if (!jsUrl && window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.assets) {
      jsUrl = window.ytInitialPlayerResponse.assets.js;
    }
  } catch (e) { jsUrl = null; }
  debug.push("jsUrl=" + (jsUrl ? "ok" : "missing"));
  if (!jsUrl) { return { urls: [], debug: debug.join(" | ") }; }

  var srcText = null;
  try {
    srcText = await fetch(new URL(jsUrl, location.origin).href).then(function (r) { return r.text(); });
  } catch (e) {
    debug.push("fetch error: " + (e && e.message ? e.message : String(e)));
    srcText = null;
  }
  if (!srcText) { return { urls: [], debug: debug.join(" | ") }; }
  debug.push("base.js len=" + srcText.length);

  var cands = candidateFunctions(srcText);
  debug.push("signature candidates=" + cands.length);
  var dec = null;
  for (var ci = 0; ci < cands.length; ci++) {
    dec = buildFromCandidate(cands[ci], srcText);
    if (dec) { debug.push("using " + cands[ci].name); break; }
  }
  if (!dec) { return { urls: out, debug: debug.join(" | ") }; }

  for (var k = 0; k < ciphers.length; k++) {
    out.push(decipherOne(ciphers[k], dec));
  }
  return { urls: out, debug: debug.join(" | ") };
} catch (err) {
  return { urls: [], debug: "exception: " + (err && err.message ? err.message : String(err)) };
}
"""#
    /// 把响应里带 signatureCipher 的格式在页面里解密成直链，返回补好 url 的新响应。
    ///
    /// 解密在页面里完成（见 decipherScript）；这段是收集 cipher、调用、再写回结果。
    static func responseAddingDecipheredURLs(
        _ response: [String: Any],
        page: WebPageContext
    ) async -> [String: Any]? {
        guard let streaming = response["streamingData"] as? [String: Any] else { return nil }

        var groups: [[[String: Any]]] = [
            streaming["formats"] as? [[String: Any]] ?? [],
            streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        ]

        // 收集需要解密的 cipher，并记住它在哪个数组的哪一项。
        var ciphers: [String] = []
        var slots: [(group: Int, index: Int)] = []

        for group in groups.indices {
            for index in groups[group].indices {
                guard let cipher = cipherString(from: groups[group][index]) else { continue }
                ciphers.append(cipher)
                slots.append((group, index))
            }
        }

        guard !ciphers.isEmpty else { return nil }

        let raw: Any?
        do {
            raw = try await page.evaluateAsync(decipherScript, arguments: ["ciphers": ciphers])
        } catch {
            LogStore.shared.warning("youtube decipher: 页面执行失败 " + error.localizedDescription)
            return nil
        }

        guard let result = raw as? [String: Any] else {
            LogStore.shared.warning("youtube decipher: 页面没有返回结果")
            return nil
        }
        if let debug = result["debug"] as? String, !debug.isEmpty {
            LogStore.shared.info("youtube decipher: " + debug)
        }

        guard let results = result["urls"] as? [Any] else { return nil }

        guard results.count == ciphers.count else { return nil }

        var resolved = 0
        for (offset, slot) in slots.enumerated() {
            guard let value = results[offset] as? String, !value.isEmpty else { continue }
            groups[slot.group][slot.index]["url"] = value
            resolved += 1
        }

        guard resolved > 0 else { return nil }

        var newStreaming = streaming
        newStreaming["formats"] = groups[0]
        newStreaming["adaptiveFormats"] = groups[1]

        var newResponse = response
        newResponse["streamingData"] = newStreaming
        return newResponse
    }

    /// 取格式里**需要解密**的签名串；不需要解密时返回 nil。
    ///
    /// JSON 的 null 会变成 NSNull，所以不能直接判断 format["url"] == nil：
    /// 页面来源的响应里 url 恒为 null，那种写法会让解密永远收不到 cipher
    /// （解密分支被跳过，最后只报「需要签名解密」）。
    static func cipherString(from format: [String: Any]) -> String? {
        if let url = format["url"] as? String, !url.isEmpty { return nil }

        guard let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
              !cipher.isEmpty else {
            return nil
        }

        return cipher
    }


}

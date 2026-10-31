import Foundation
import UIKit
import WebKit
import NoxCore
import NoxParsing

extension VideoParser {
    /// 注入到每个页面：抓 YouTube 播放时请求的 googlevideo 直链。
    ///
    /// YouTube 自己在播放时会去请求**已经签好名**的 `videoplayback` 地址，
    /// 把这些地址记下来，就等于拿到了可以直接下载的直链 —— 不需要签名解密，
    /// 也不需要 PO token。根目录新脚本（ytx-direct-downloader）在独立客户端的
    /// 请求被风控时，靠的就是「让用户先播放几秒，再抓页面自己的媒体请求」这条路。
    ///
    /// 脚本只记 YouTube 域，其他站点上就是个空转的钩子。
    static func youtubeMediaUserScript() -> WKUserScript {
        let source = #"""
(function () {
  if (window.top !== window) { return; }
  if (window.__noxYTMediaHook) { return; }
  window.__noxYTMediaHook = true;

  var list = window.__noxYTMedia = window.__noxYTMedia || [];
  var seen = Object.create(null);

  function remember(raw) {
    if (!raw) { return; }
    var url;
    try { url = new URL(String(raw), location.href); } catch (e) { return; }
    var host = url.hostname.toLowerCase();
    if (host !== 'googlevideo.com' && host.slice(-16) !== '.googlevideo.com') { return; }
    if (url.pathname.toLowerCase().indexOf('videoplayback') < 0) { return; }
    if (url.searchParams.has('sq')) { return; }
    var itag = Number(url.searchParams.get('itag') || url.searchParams.get('fmt') || 0);
    if (!itag) { return; }
    ['range', 'rn', 'rbuf'].forEach(function (name) { url.searchParams.delete(name); });
    var xtags = url.searchParams.get('xtags') || '';
    var id = url.searchParams.get('id') || url.pathname;
    var key = itag + ':' + xtags + ':' + id;
    var now = Date.now();
    if (seen[key] && now - seen[key] < 8000) { return; }
    seen[key] = now;
    list.push({
      url: url.href,
      itag: itag,
      xtags: xtags,
      mime: String(url.searchParams.get('mime') || '').toLowerCase(),
      clen: Number(url.searchParams.get('clen') || 0)
    });
    if (list.length > 300) { list.splice(0, list.length - 300); }
  }

  function hooked(fn) { return !!(fn && fn.__noxYTMediaHooked); }

  try {
    var originalFetch = window.fetch;
    if (typeof originalFetch === 'function' && !hooked(originalFetch)) {
      var wrappedFetch = function (input) {
        try { remember(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
        var result = originalFetch.apply(this, arguments);
        try {
          Promise.resolve(result).then(function (response) {
            try { remember(response && response.url); } catch (e) {}
            return response;
          });
        } catch (e) {}
        return result;
      };
      wrappedFetch.__noxYTMediaHooked = true;
      window.fetch = wrappedFetch;
    }
  } catch (e) {}

  try {
    var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
    if (proto && typeof proto.open === 'function' && !hooked(proto.open)) {
      var originalOpen = proto.open;
      var wrappedOpen = function (method, url) {
        try { remember(url); } catch (e) {}
        return originalOpen.apply(this, arguments);
      };
      wrappedOpen.__noxYTMediaHooked = true;
      proto.open = wrappedOpen;
    }
  } catch (e) {}

  window.__noxYTMediaRead = function () {
    try {
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) { remember(entries[i].name); }
    } catch (e) {}
    return window.__noxYTMedia || [];
  };
})();
"""#

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

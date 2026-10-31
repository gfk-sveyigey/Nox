import Foundation
import UIKit
import WebKit
import NoxCore
import NoxParsing

extension VideoParser {
    static func pageURLUserScript() -> WKUserScript {
        let source = [
            "(function () {",
            "  if (window.top !== window) { return; }",
            "  if (window.__noxURLHook) { return; }",
            "  window.__noxURLHook = true;",
            "  var last = location.href;",
            "  var lastPath = location.pathname + location.search;",
            "  var navAt = 0;          // 最近一次 URL 变化的时间",
            "  var startedAt = 0;      // 这一轮「同文档加载」开始的时间",
            "  var loadingTimer = null;",
            "  var lastResourceAt = 0;",
            "  var minVisibleMs = 900; // 太短的提示会一闪而过，等于没有提示",
            "  var quietMs = 600;      // 连续这么久没有新的资源请求，就算这一轮结束",
            "  var maxMs = 8000;       // 兜底：再慢也不让提示一直亮着",
            "  var relightMs = 2500;   // 换页后这段时间内到达的资源请求，算作这次换页的",
            "  // 资源请求既刷新「还在加载」的时间戳，也能在慢站点上把提示重新点亮。",
            "  try {",
            "    var observer = new PerformanceObserver(function () {",
            "      lastResourceAt = Date.now();",
            "      if (loadingTimer === null && Date.now() - navAt < relightMs) { beginSameDocumentLoad(); }",
            "    });",
            "    observer.observe({ entryTypes: ['resource'] });",
            "  } catch (e) {}",
            "  function post(name, value) {",
            "    try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {}",
            "  }",
            "  function reportLoading(loading) {",
            "    post('\(PageLoadingBridge.handlerName)', loading ? 1 : 0);",
            "  }",
            "  // SPA 换页不触发导航回调、也拿不到进度：用「path/query 变了」当作开始，",
            "  // 用「连续一段时间没有新的资源请求」当作结束（另加最短显示时间与 8 秒兜底）。",
            "  function beginSameDocumentLoad() {",
            "    if (loadingTimer !== null) { return; }",
            "    startedAt = Date.now();",
            "    lastResourceAt = startedAt;",
            "    reportLoading(true);",
            "    loadingTimer = setInterval(function () {",
            "      var now = Date.now();",
            "      var elapsed = now - startedAt;",
            "      if (elapsed > maxMs || (elapsed > minVisibleMs && now - lastResourceAt > quietMs)) {",
            "        clearInterval(loadingTimer);",
            "        loadingTimer = null;",
            "        reportLoading(false);",
            "      }",
            "    }, 200);",
            "  }",
            "  function report() {",
            "    if (location.href === last) { return; }",
            "    last = location.href;",
            "    navAt = Date.now();",
            "    post('\(PageURLBridge.handlerName)', String(location.href));",
            "    var path = location.pathname + location.search;",
            "    if (path !== lastPath) {",
            "      lastPath = path;",
            "      beginSameDocumentLoad();",
            "    }",
            "  }",
            "  ['pushState', 'replaceState'].forEach(function (name) {",
            "    var original = history[name];",
            "    if (typeof original !== 'function') { return; }",
            "    history[name] = function () {",
            "      var result = original.apply(this, arguments);",
            "      report();",
            "      return result;",
            "    };",
            "  });",
            "  window.addEventListener('popstate', report);",
            "  window.addEventListener('hashchange', report);",
            "  setInterval(report, 800);",
            "})();"
        ].joined(separator: "\n")

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

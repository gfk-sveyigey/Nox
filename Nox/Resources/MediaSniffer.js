/*
 * MediaSniffer.js — Nox 内置 WKWebView 嗅探脚本
 *
 * 由用户脚本「媒体嗅探器 Media Sniffer Pro v1.0.7」剪裁而来：
 *   - 移除：面板 UI / 虚拟列表 / i18n / 翻译 / Cookie / Storage / Aria2 /
 *           自动更新 / 插件系统 / 选区翻译 / 所有 GM_* API / Tampermonkey 头
 *   - 保留并重写：URL 安全校验、类型识别、DOM 扫描、iframe 递归、
 *                 hls.js / dash.js / video.js 实例提取、XHR+fetch 网络钩子
 *   - 新增：结果经 window.webkit.messageHandlers.noxSniffer 回传原生
 *
 * 与浏览器版的差异：
 *   - 不判断 window.top，配合 WKUserScript(forMainFrameOnly: false) 在跨域
 *     iframe 中同样运行并上报（浏览器 @noframes 做不到）
 *   - 网络结果按 LRU 上限缓存，避免长会话内存膨胀
 *   - 不下载、不解密：m3u8 的抓取/解密/合并交给原生 HLSDownloader
 */
(function () {
    'use strict';

    var HANDLER = 'noxSniffer';
    var MAX_HITS = 4000;
    var FLUSH_DELAY = 400;
    var MUTATION_DELAY = 900;
    var BACKGROUND_LIMIT = 1500;

    if (window.__MS_SNIFFER_INSTALLED__) {
        try { if (window.__MS_SNIFF__) window.__MS_SNIFF__(true); } catch (e) {}
        return;
    }
    window.__MS_SNIFFER_INSTALLED__ = true;

    var KINDS = { image: 1, video: 1, audio: 1, m3u8: 1, stream: 1 };

    // ---------------------------------------------------------------- 工具

    function isStr(x) { return typeof x === 'string'; }
    function now() { return Date.now(); }

    function throttle(fn, wait) {
        var last = 0;
        var timer = null;
        return function () {
            var context = this;
            var args = arguments;
            var gap = wait - (now() - last);

            if (gap <= 0) {
                last = now();
                fn.apply(context, args);
            } else if (!timer) {
                timer = setTimeout(function () {
                    last = now();
                    timer = null;
                    fn.apply(context, args);
                }, gap);
            }
        };
    }

    // ------------------------------------------------- URL 安全 / 归类

    function isSafeUrl(url) {
        if (!isStr(url)) return false;

        var value = url.trim();
        if (!value) return false;

        var lower = value.toLowerCase();
        if (lower.indexOf('javascript:') === 0 || lower.indexOf('vbscript:') === 0) return false;
        if (lower.indexOf('data:') === 0) return /^data:(image|video|audio)\//.test(lower);
        if (lower.indexOf('blob:') === 0 || lower.indexOf('file:') === 0) return true;

        try {
            var parsed = new URL(value, location.href);
            return parsed.protocol === 'http:' || parsed.protocol === 'https:';
        } catch (e) {
            return false;
        }
    }

    function absUrl(url) {
        try {
            return new URL(url, location.href).href;
        } catch (e) {
            return isStr(url) ? url.trim() : '';
        }
    }

    function guessKind(url) {
        if (!isStr(url)) return '';

        var path = url.toLowerCase().split('?')[0].split('#')[0];

        if (/\.(png|jpe?g|gif|webp|bmp|svg|avif|ico|tiff?)$/.test(path)) return 'image';
        if (/\.(mp4|webm|ogg|ogv|mov|mkv|avi|flv|f4v|ts|m2ts|m4v|3gp|mpeg|mpg|rm|rmvb|wmv|asf|vob)$/.test(path)) return 'video';
        if (/\.(mp3|wav|flac|aac|oga|opus|m4a|wma|amr|ape|mid)$/.test(path)) return 'audio';
        if (/\.m3u8?(\?|#|$)/.test(path)) return 'm3u8';

        return '';
    }

    // 网络钩子里出现的 .ts / .m2ts 属于 HLS 分片，逐个上报只会淹没列表
    function isHLSSegment(url) {
        return /\.(ts|m2ts)(\?|#|$)/i.test(url);
    }

    // -------------------------------------------------- 收集与上报

    var pending = [];
    var seen = Object.create(null);
    var seenOrder = [];

    function remember(key) {
        if (seen[key]) return false;

        seen[key] = 1;
        seenOrder.push(key);

        if (seenOrder.length > MAX_HITS) {
            var evicted = seenOrder.splice(0, seenOrder.length - MAX_HITS);
            for (var i = 0; i < evicted.length; i++) delete seen[evicted[i]];
        }

        return true;
    }

    function collect(url, kind, source, title) {
        if (!isStr(url) || url.length < 6) return;

        var absolute = absUrl(url);
        if (!isSafeUrl(absolute)) return;

        var resolved = KINDS[kind] ? kind : guessKind(absolute);
        if (!KINDS[resolved]) return;
        if (!remember(resolved + '|' + absolute)) return;

        pending.push({
            url: absolute,
            kind: resolved,
            source: source || 'dom',
            title: title || ''
        });

        scheduleFlush();
    }

    function collectStream(element) {
        if (!remember('stream|' + location.href)) return;

        pending.push({
            url: location.href,
            kind: 'stream',
            source: 'dom',
            title: document.title || '',
            live: true
        });

        scheduleFlush();
    }

    function post(items) {
        try {
            var handlers = window.webkit && window.webkit.messageHandlers;
            var bridge = handlers && handlers[HANDLER];
            if (!bridge) return;

            bridge.postMessage({
                type: 'resources',
                pageURL: location.href,
                frame: window.top !== window.self,
                items: items
            });
        } catch (e) {}
    }

    function flush() {
        if (!pending.length) return 0;

        var batch = pending.splice(0, pending.length);
        post(batch);
        return batch.length;
    }

    var scheduleFlush = throttle(flush, FLUSH_DELAY);

    // ------------------------------------------------------------ DOM

    function scanImages() {
        var images = document.getElementsByTagName('img');

        for (var i = 0; i < images.length; i++) {
            var node = images[i];
            var src = node.currentSrc ||
                      node.getAttribute('src') ||
                      node.getAttribute('data-src') ||
                      node.getAttribute('data-original') ||
                      node.getAttribute('data-lazy-src') || '';
            collect(src, 'image', 'dom', node.getAttribute('alt') || '');
        }

        var links = document.querySelectorAll('a[href]');

        for (var j = 0; j < links.length; j++) {
            var href = links[j].getAttribute('href') || '';
            if (/\.(png|jpe?g|gif|webp|bmp|svg|avif)(\?|#|$)/i.test(href)) {
                collect(href, 'image', 'dom', '');
            }
        }
    }

    // 只在主动全量扫描时跑，避免每次 DOM 变动都遍历上千个节点
    function scanBackgrounds() {
        var all = document.getElementsByTagName('*');
        var limit = Math.min(all.length, BACKGROUND_LIMIT);

        for (var i = 0; i < limit; i++) {
            var background;
            try {
                background = getComputedStyle(all[i]).backgroundImage;
            } catch (e) {
                continue;
            }

            if (!background || background === 'none' || background.indexOf('url(') < 0) continue;

            var match = background.match(/url\(\s*(["']?)([^"')]+)\1\s*\)/);
            if (match && match[2]) collect(match[2].trim(), 'image', 'dom', '');
        }
    }

    function mediaSource(element) {
        if (!element) return '';

        var src = element.getAttribute('src') ||
                  element.getAttribute('data-src') ||
                  element.getAttribute('data-original') ||
                  element.getAttribute('data-url') || '';
        if (src) return src;

        try {
            if (element.currentSrc) return element.currentSrc;
        } catch (e) {}

        return '';
    }

    function scanMedia() {
        var nodes = document.querySelectorAll('video, video source, audio, audio source');
        var streamSeen = false;

        for (var i = 0; i < nodes.length; i++) {
            var element = nodes[i];
            var fallback = element.tagName === 'AUDIO' ? 'audio' : 'video';

            var src = mediaSource(element);
            if (src) collect(src, guessKind(src) || fallback, 'dom', '');

            // MediaStream / Blob：地址不可下载，只上报「存在实时流」
            if (!streamSeen) {
                try {
                    if (element.srcObject) {
                        streamSeen = true;
                        collectStream(element);
                    }
                } catch (e) {}
            }
        }
    }

    function scanText() {
        try {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            var pattern = /https?:\/\/[^\s"'<>]+\.m3u8?[^\s"'<>]*/gi;
            var node;

            while ((node = walker.nextNode()) !== null) {
                var text = node.textContent;
                if (!text || text.indexOf('.m3u8') < 0) continue;

                var matches = text.match(pattern);
                if (!matches) continue;

                for (var i = 0; i < matches.length; i++) collect(matches[i], 'm3u8', 'dom', '');
            }
        } catch (e) {}
    }

    function scanFrames(win, depth) {
        if (!win || depth > 2) return;

        try {
            var frames = win.document.querySelectorAll('iframe, frame');

            for (var i = 0; i < frames.length; i++) {
                var child = null;
                try {
                    child = frames[i].contentWindow;
                } catch (e) {
                    continue;
                }

                if (!child || child === win) continue;

                try {
                    var nodes = child.document.querySelectorAll('video, video source, audio, audio source, a[href]');

                    for (var j = 0; j < nodes.length; j++) {
                        var element = nodes[j];
                        var src = mediaSource(element) || element.getAttribute('href') || '';
                        if (!src) continue;

                        var kind = guessKind(src);
                        if (kind) collect(src, kind, 'frame', '');
                    }
                } catch (e) {
                    // 跨域 iframe 的 document 不可读，但它自己会注入脚本并上报
                }

                scanFrames(child, depth + 1);
            }
        } catch (e) {}
    }

    // ------------------------------------------- 播放器实例（hls/dash/videojs）

    function scanPlayers() {
        try {
            if (window.hls && window.hls.url) collect(window.hls.url, 'm3u8', 'player', '');

            var videos = document.querySelectorAll('video');

            for (var i = 0; i < videos.length; i++) {
                var instance = videos[i].hls ||
                               videos[i]._hls ||
                               (videos[i].player && videos[i].player.hls) || null;

                if (instance && instance.url) collect(instance.url, 'm3u8', 'player', '');
            }

            if (window.Hls && window.Hls.instances) {
                for (var key in window.Hls.instances) {
                    if (!Object.prototype.hasOwnProperty.call(window.Hls.instances, key)) continue;

                    var globalInstance = window.Hls.instances[key];
                    if (globalInstance && globalInstance.url) collect(globalInstance.url, 'm3u8', 'player', '');
                }
            }
        } catch (e) {}

        try {
            if (window.dashjs || (window.Player && window.Player.prototype)) {
                var dashVideos = document.querySelectorAll('video');

                for (var d = 0; d < dashVideos.length; d++) {
                    var player = dashVideos[d].dashPlayer || dashVideos[d]._dashjsPlayer;
                    if (!player) continue;

                    var source = '';
                    try {
                        if (typeof player.getSource === 'function') source = player.getSource();
                        if (!source && typeof player.getManifest === 'function') {
                            var manifest = player.getManifest();
                            if (manifest && manifest.url) source = manifest.url;
                        }
                    } catch (e) {}

                    if (!source) continue;
                    collect(source, /\.mpd(\?|#|$)/i.test(source) ? 'video' : (guessKind(source) || 'video'), 'player', '');
                }
            }
        } catch (e) {}

        try {
            if (window.videojs && typeof window.videojs === 'function') {
                var targets = document.querySelectorAll('.video-js, video');

                for (var t = 0; t < targets.length; t++) {
                    var element = targets[t];
                    var id = element.id || (element.getAttribute && element.getAttribute('data-player-id'));
                    var vjs = null;

                    try {
                        if (element.player && typeof element.player.currentSrc === 'function') vjs = element.player;
                        if (!vjs && id && window.videojs.getPlayer) vjs = window.videojs.getPlayer(id);
                        if (!vjs && id && window.videojs.players) vjs = window.videojs.players[id];
                    } catch (e) {}

                    if (!vjs || typeof vjs.currentSrc !== 'function') continue;

                    var vsrc = '';
                    var vtype = '';
                    try { vsrc = vjs.currentSrc(); } catch (e) {}
                    try { if (typeof vjs.currentType === 'function') vtype = vjs.currentType(); } catch (e) {}

                    if (!vsrc) continue;

                    var isHls = /\.m3u8?(\?|#|$)/i.test(vsrc) ||
                                vtype === 'application/x-mpegURL' ||
                                vtype === 'application/vnd.apple.mpegurl';

                    collect(vsrc, isHls ? 'm3u8' : (guessKind(vsrc) || 'video'), 'player', '');
                }
            }
        } catch (e) {}
    }

    // -------------------------------------------------------- 网络钩子

    function installNetworkHook() {
        try {
            var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;

            if (proto && typeof proto.open === 'function' && !proto.__msPatched) {
                var originalOpen = proto.open;

                proto.open = function (method, url) {
                    try {
                        var value = url == null ? '' : String(url);

                        if (value && !isHLSSegment(value)) {
                            collect(value, guessKind(value), 'network', '');
                        }
                    } catch (e) {}

                    return originalOpen.apply(this, arguments);
                };

                proto.__msPatched = true;
            }
        } catch (e) {}

        try {
            if (typeof window.fetch === 'function' && !window.fetch.__msPatched) {
                var originalFetch = window.fetch;

                var patched = function (input, init) {
                    try {
                        var url = isStr(input) ? input : (input && input.url ? input.url : '');

                        if (url && !isHLSSegment(url)) {
                            collect(url, guessKind(url), 'network', '');
                        }
                    } catch (e) {}

                    return originalFetch.apply(this, arguments);
                };

                patched.__msPatched = true;
                window.fetch = patched;
            }
        } catch (e) {}
    }

    // ------------------------------------------------------ DOM 变动监听

    var mutationTimer = null;

    function installMutationObserver() {
        try {
            var observer = new MutationObserver(function (mutations) {
                var interesting = false;

                for (var i = 0; i < mutations.length && !interesting; i++) {
                    var added = mutations[i].addedNodes;
                    if (!added) continue;

                    for (var j = 0; j < added.length; j++) {
                        var node = added[j];
                        if (node.nodeType !== 1) continue;

                        var tag = node.tagName;
                        if (tag === 'IMG' || tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE' ||
                            tag === 'IFRAME' || tag === 'EMBED' || tag === 'SCRIPT' || tag === 'LINK') {
                            interesting = true;
                            break;
                        }

                        if (node.querySelector &&
                            node.querySelector('img, video, audio, source, iframe, embed')) {
                            interesting = true;
                            break;
                        }
                    }
                }

                if (!interesting || mutationTimer) return;

                mutationTimer = setTimeout(function () {
                    mutationTimer = null;
                    scan(false);
                }, MUTATION_DELAY);
            });

            observer.observe(document.documentElement || document.body, {
                childList: true,
                subtree: true
            });
        } catch (e) {}
    }

    // ------------------------------------------------------------- 入口

    function scan(deep) {
        try { scanMedia(); } catch (e) {}
        try { scanPlayers(); } catch (e) {}
        try { scanImages(); } catch (e) {}
        try { scanText(); } catch (e) {}
        try { scanFrames(window, 0); } catch (e) {}
        if (deep === true) { try { scanBackgrounds(); } catch (e) {} }

        scheduleFlush();
    }

    // 供原生在 didFinish / 用户点击「解析视频」时主动触发
    window.__MS_SNIFF__ = function (deep) {
        scan(deep === true);
        return flush();
    };

    installNetworkHook();
    installMutationObserver();

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { scan(true); }, { once: true });
    } else {
        scan(true);
    }

    window.addEventListener('load', function () { scan(true); }, { once: true });

    // 部分站点在 load 之后才挂载播放器
    setTimeout(function () { scan(false); }, 1500);
    setTimeout(function () { scan(false); }, 4000);
})();
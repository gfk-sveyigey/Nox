// ==UserScript==
// @name         Youtube和X（Twitter）直连下载（免跳转第三方）
// @namespace    haiwaidao.local.ytx-downloader
// @version      0.1.28
// @description  YouTube/X direct downloader. No third-party parser service. High-resolution YouTube streams are remuxed locally in the browser.
// @license      MIT
// @homepageURL  https://github.com/SamProjects/ytx-direct-downloader
// @supportURL   https://github.com/SamProjects/ytx-direct-downloader/issues
// @match        https://www.youtube.com/*
// @match        https://m.youtube.com/*
// @match        https://x.com/*
// @match        https://twitter.com/*
// @grant        GM_xmlhttpRequest
// @grant        GM_download
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        unsafeWindow
// @connect      youtube.com
// @connect      *.youtube.com
// @connect      youtubei.googleapis.com
// @connect      googlevideo.com
// @connect      *.googlevideo.com
// @connect      video.twimg.com
// @require      https://cdn.jsdelivr.net/gh/SamProjects/ytx-direct-downloader@b2662e6248cef0f78b3e669a86de8a1c85eadc67/vendor/ytx-youtube-runtime.js#sha256=HmXkSFsTLaqDmxYI4RtL3FU14CMV7ao8Oe/Y5AecVlk=
// @require      https://cdn.jsdelivr.net/gh/SamProjects/ytx-direct-downloader@b2662e6248cef0f78b3e669a86de8a1c85eadc67/vendor/ytx-mediabunny-runtime.js#sha256=nu/HO+3jfR+AKYkHQGrcgzM0tgqDS7+ifYAS7/UeGhU=
// @run-at       document-start
// @downloadURL https://update.greasyfork.org/scripts/592315/Youtube%E5%92%8CX%EF%BC%88Twitter%EF%BC%89%E7%9B%B4%E8%BF%9E%E4%B8%8B%E8%BD%BD%EF%BC%88%E5%85%8D%E8%B7%B3%E8%BD%AC%E7%AC%AC%E4%B8%89%E6%96%B9%EF%BC%89.user.js
// @updateURL https://update.greasyfork.org/scripts/592315/Youtube%E5%92%8CX%EF%BC%88Twitter%EF%BC%89%E7%9B%B4%E8%BF%9E%E4%B8%8B%E8%BD%BD%EF%BC%88%E5%85%8D%E8%B7%B3%E8%BD%AC%E7%AC%AC%E4%B8%89%E6%96%B9%EF%BC%89.meta.js
// ==/UserScript==
(() => {
  // src/i18n.js
  function usesChineseLanguage(browser = globalThis.navigator) {
    const language = browser?.language || browser?.languages?.[0] || "en";
    return /^zh(?:[-_]|$)/i.test(language);
  }
  var isChinese = usesChineseLanguage();

  // src/range-download.js
  function boundedRangeFetch(fetchFn, chunkSize = 4 * 1024 * 1024) {
    return async (input, init = {}) => {
      const headers = new Headers(input instanceof Request ? input.headers : void 0);
      new Headers(init.headers).forEach((value, name) => headers.set(name, value));
      const match = headers.get("range")?.match(/^bytes=(\d+)-(\d*)$/i);
      if (!match || String(init.method || (input instanceof Request ? input.method : "GET")).toUpperCase() !== "GET") {
        return fetchFn(input, init);
      }
      const start = Number(match[1]);
      const end = Math.min(match[2] ? Number(match[2]) : Infinity, start + chunkSize - 1);
      headers.set("range", `bytes=${start}-${end}`);
      const response = await fetchFn(input, { ...init, headers });
      if (response.status === 206) {
        const range = response.headers.get("content-range")?.match(/^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/i);
        if (!range || Number(range[1]) !== start || Number(range[2]) < start || Number(range[2]) > end || range[3] !== "*" && Number(range[3]) <= Number(range[2])) {
          throw new Error("Invalid media range response.");
        }
        const bytes = await response.arrayBuffer();
        if (bytes.byteLength !== Number(range[2]) - start + 1) throw new Error("Incomplete media range.");
        const result = new Response(bytes, { status: response.status, statusText: response.statusText, headers: response.headers });
        Object.defineProperty(result, "url", { value: response.url });
        return result;
      }
      return response;
    };
  }
  async function downloadRanges({
    url,
    fileHandle,
    task,
    fetchFn,
    waitForTask,
    concurrency = 4,
    chunkSize = 4 * 1024 * 1024,
    onProgress
  }) {
    let controller = new AbortController();
    task.controller = controller;
    let fatal = null;
    let writer;
    let written = 0;
    let total = 0;
    let writeQueue = Promise.resolve();
    let validator = null;
    const checkpoint = async () => {
      await waitForTask(task);
      if (fatal) throw fatal;
      if (controller.signal.aborted) {
        controller = new AbortController();
        task.controller = controller;
      }
    };
    const request = async (start, end) => {
      let attempts = 0;
      while (true) {
        await checkpoint();
        const signal = controller.signal;
        try {
          const headers = { Range: `bytes=${start}-${end}` };
          if (validator) headers["If-Range"] = validator;
          const response = await fetchFn(url, { headers, signal });
          if ([408, 429, 500, 502, 503, 504].includes(response.status)) {
            throw new TypeError(`Retryable HTTP ${response.status}`);
          }
          return response;
        } catch (error) {
          if (fatal || task.cancelRequested) throw fatal || error;
          if (signal.aborted) continue;
          if (!(error instanceof TypeError || error?.name === "TimeoutError") || attempts++ >= 3) throw error;
          await new Promise((resolve) => {
            const done = () => {
              clearTimeout(timer);
              signal.removeEventListener("abort", done);
              resolve();
            };
            const timer = setTimeout(done, Math.min(1e3 * 2 ** (attempts - 1), 8e3));
            signal.addEventListener("abort", done, { once: true });
            if (signal.aborted) done();
          });
        }
      }
    };
    const readRange = async (response, start, requestedEnd, expectedTotal = null) => {
      if (response.status !== 206) throw new Error(`Media download failed (HTTP ${response.status}); expected partial content.`);
      const match = response.headers.get("content-range")?.match(/^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/i);
      if (response.status !== 206 || !match) throw new Error("Invalid HTTP range response.");
      const rangeStart = Number(match[1]);
      const rangeEnd = Number(match[2]);
      const rangeTotal = match[3] === "*" ? null : Number(match[3]);
      if (![rangeStart, rangeEnd].every(Number.isSafeInteger) || rangeStart !== start || rangeEnd < start || rangeEnd > requestedEnd || rangeTotal !== null && (!Number.isSafeInteger(rangeTotal) || rangeTotal <= rangeEnd) || expectedTotal !== null && (rangeTotal !== expectedTotal || rangeEnd !== requestedEnd)) {
        throw new Error("Media range or file size changed during download.");
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length !== rangeEnd - rangeStart + 1) throw new Error("Incomplete media range.");
      return { bytes, total: rangeTotal };
    };
    const write = (start, bytes) => {
      writeQueue = writeQueue.then(async () => {
        await checkpoint();
        await writer.write({ type: "write", position: start, data: bytes });
        written += bytes.length;
        onProgress?.({ loaded: written, total, ratio: total ? Math.min(written / total, 0.999) : null });
      });
      return writeQueue;
    };
    try {
      const probe = await request(0, chunkSize - 1);
      let first;
      if (probe.status === 200) {
        first = new Uint8Array(await probe.arrayBuffer());
        if (!first.length) throw new Error("Empty media response.");
        total = first.length;
      } else {
        const range = await readRange(probe, 0, chunkSize - 1);
        if (range.total === null) return false;
        first = range.bytes;
        total = range.total;
        const etag = probe.headers.get("etag");
        validator = etag && !etag.startsWith("W/") ? etag : probe.headers.get("last-modified");
      }
      await checkpoint();
      writer = await fileHandle.createWritable();
      await write(0, first);
      let next = first.length;
      const worker = async () => {
        try {
          while (true) {
            await checkpoint();
            if (next >= total) return;
            const start = next;
            const end = Math.min(total - 1, start + chunkSize - 1);
            next = end + 1;
            const response = await request(start, end);
            const { bytes } = await readRange(response, start, end, total);
            await write(start, bytes);
          }
        } catch (error) {
          fatal ||= error;
          controller.abort();
          throw error;
        }
      };
      const results = await Promise.allSettled(Array.from(
        { length: Math.min(Math.max(1, Math.floor(concurrency)), 8, Math.ceil((total - next) / chunkSize)) },
        worker
      ));
      const failed = results.find((result) => result.status === "rejected");
      if (failed) throw failed.reason;
      await checkpoint();
      if (written !== total) throw new Error("Downloaded file is incomplete.");
      await writer.close();
      writer = null;
      onProgress?.({ loaded: written, total, ratio: 1 });
      return true;
    } catch (error) {
      fatal ||= error;
      controller.abort();
      await writeQueue.catch(() => {
      });
      if (writer) await writer.abort().catch(() => {
      });
      throw error;
    } finally {
      if (task.controller === controller) task.controller = null;
    }
  }

  // src/runtime.greasy.js
  var runtime = globalThis.__YTX_YOUTUBE_RUNTIME__;
  if (!runtime) {
    throw new Error("YT + X Direct Downloader libraries were not loaded.");
  }
  var Innertube = runtime.Innertube;
  var Parser = runtime.Parser;
  var Platform = runtime.Platform;
  var YTNodes = runtime.YTNodes;
  var SabrStream = runtime.SabrStream;

  // src/media-runtime.greasy.js
  var runtime2 = globalThis.__YTX_MEDIABUNNY_RUNTIME__;
  if (!runtime2) {
    throw new Error("YT + X Direct Downloader media library was not loaded.");
  }
  var ALL_FORMATS = runtime2.ALL_FORMATS;
  var HLS_FORMATS = runtime2.HLS_FORMATS;
  var Input = runtime2.Input;
  var Output = runtime2.Output;
  var UrlSource = runtime2.UrlSource;
  var EncodedPacketSink = runtime2.EncodedPacketSink;
  var EncodedVideoPacketSource = runtime2.EncodedVideoPacketSource;
  var EncodedAudioPacketSource = runtime2.EncodedAudioPacketSource;
  var Mp4OutputFormat = runtime2.Mp4OutputFormat;
  var WebMOutputFormat = runtime2.WebMOutputFormat;
  var StreamTarget = runtime2.StreamTarget;
  var ReadableStreamSource = runtime2.ReadableStreamSource;

  // src/main.js
  (() => {
    "use strict";
    const APP = "ytx-local-downloader";
    const PLAYER_EVAL_POLICY = `${APP}-player-eval`;
    const BUTTON_CLASS = `${APP}-context-button`;
    const PANEL_ID = `${APP}-panel`;
    const STYLE_ID = `${APP}-style`;
    const CONCURRENCY_KEY = `${APP}-concurrency`;
    function normalizeConcurrency(value) {
      const count = Number(value);
      return Number.isInteger(count) && count >= 1 && count <= 8 ? count : 4;
    }
    function loadConcurrency() {
      try {
        return normalizeConcurrency(GM_getValue(CONCURRENCY_KEY, 4));
      } catch {
        return 4;
      }
    }
    const state = {
      downloadConcurrency: loadConcurrency(),
      youtubePromise: null,
      youtubeInfo: /* @__PURE__ */ new Map(),
      youtubeUrlCache: /* @__PURE__ */ new WeakMap(),
      youtubeSessionClient: null,
      youtubeSessionPoToken: "",
      youtubeEvalEnvironment: null,
      youtubeMedia: /* @__PURE__ */ new Map(),
      youtubeFormatMetadata: /* @__PURE__ */ new Map(),
      youtubeNavigationStartedAt: 0,
      youtubeNetworkCaptureInstalled: false,
      xMedia: /* @__PURE__ */ new Map(),
      xNetworkCaptureInstalled: false,
      lastHref: location.href,
      busy: false,
      downloadQueue: [],
      downloadHistory: [],
      downloadWorkerActive: false,
      currentDownload: null,
      nextDownloadId: 1,
      activeAnchor: null,
      activeYoutubeVideoId: null,
      activeXContext: null,
      xButtonContexts: /* @__PURE__ */ new WeakMap(),
      xContexts: /* @__PURE__ */ new Set(),
      panelResizeObserver: null,
      panelDragCleanup: null,
      panelPosition: null,
      panelDetached: false,
      activationInstalled: false,
      ensureScheduled: false,
      domObserver: null,
      lastActivationAt: 0,
      lastActivationButton: null
    };
    function isAllowedNetworkUrl(rawUrl) {
      let url;
      try {
        url = new URL(String(rawUrl));
      } catch {
        return false;
      }
      if (url.protocol !== "https:") return false;
      const host = url.hostname.toLowerCase();
      return host === "youtube.com" || host.endsWith(".youtube.com") || host === "youtubei.googleapis.com" || host === "googlevideo.com" || host.endsWith(".googlevideo.com") || host === "video.twimg.com";
    }
    function assertAllowedNetworkUrl(rawUrl) {
      if (!isAllowedNetworkUrl(rawUrl)) {
        throw new Error(`Blocked non-whitelisted URL: ${rawUrl}`);
      }
    }
    async function bodyToGmData(body) {
      if (body == null) return void 0;
      if (typeof body === "string") return body;
      if (body instanceof URLSearchParams) return body.toString();
      if (body instanceof ArrayBuffer) return body;
      if (ArrayBuffer.isView(body)) {
        return body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
      }
      if (body instanceof Blob) return await body.arrayBuffer();
      if (body instanceof ReadableStream) return await new Response(body).arrayBuffer();
      if (body instanceof FormData) {
        throw new Error("FormData requests are intentionally unsupported by gmFetch.");
      }
      return body;
    }
    function mergeHeaders(baseHeaders, overrideHeaders) {
      const headers = new Headers(baseHeaders || void 0);
      if (overrideHeaders) {
        new Headers(overrideHeaders).forEach((value, key) => headers.set(key, value));
      }
      return headers;
    }
    function headersToObject(headers) {
      const obj = {};
      headers.forEach((value, key) => {
        obj[key] = value;
      });
      return obj;
    }
    function parseResponseHeaders(raw) {
      const headers = new Headers();
      String(raw || "").split(/\r?\n/).forEach((line) => {
        const p = line.indexOf(":");
        if (p <= 0) return;
        const key = line.slice(0, p).trim();
        const value = line.slice(p + 1).trim();
        if (!key) return;
        try {
          headers.append(key, value);
        } catch {
        }
      });
      return headers;
    }
    async function normalizeFetchRequest(input, init2 = {}) {
      let url;
      let method;
      let headers;
      let body;
      let signal;
      if (input instanceof Request) {
        url = input.url;
        method = String(init2.method || input.method || "GET").toUpperCase();
        headers = mergeHeaders(input.headers, init2.headers);
        signal = init2.signal || input.signal;
        if (method !== "GET" && method !== "HEAD") {
          if (Object.prototype.hasOwnProperty.call(init2, "body")) {
            body = await bodyToGmData(init2.body);
          } else {
            body = await input.clone().arrayBuffer();
          }
        }
      } else {
        url = input instanceof URL ? input.href : String(input);
        method = String(init2.method || "GET").toUpperCase();
        headers = new Headers(init2.headers || void 0);
        signal = init2.signal;
        if (method !== "GET" && method !== "HEAD") {
          body = await bodyToGmData(init2.body);
        }
      }
      assertAllowedNetworkUrl(url);
      return { url, method, headers, body, signal };
    }
    async function gmFetch(input, init2 = {}) {
      const request = await normalizeFetchRequest(input, init2);
      if (request.signal?.aborted) {
        throw new DOMException("The operation was aborted.", "AbortError");
      }
      return await new Promise((resolve, reject) => {
        let settled = false;
        let abortListener = null;
        const finish = (fn, value) => {
          if (settled) return;
          settled = true;
          if (abortListener && request.signal) {
            request.signal.removeEventListener("abort", abortListener);
          }
          fn(value);
        };
        const xhr = GM_xmlhttpRequest({
          method: request.method,
          url: request.url,
          headers: headersToObject(request.headers),
          data: request.body,
          responseType: "arraybuffer",
          timeout: 6e4,
          anonymous: false,
          onload(response) {
            try {
              const status = Number(response.status);
              if (!Number.isFinite(status) || status < 100 || status > 599) {
                throw new Error(`Invalid HTTP status: ${response.status}`);
              }
              const headers = parseResponseHeaders(response.responseHeaders);
              const noBody = request.method === "HEAD" || [204, 205, 304].includes(status);
              const body = noBody ? null : response.response;
              const result = new Response(body, {
                status,
                statusText: response.statusText || "",
                headers
              });
              try {
                Object.defineProperty(result, "url", {
                  configurable: true,
                  value: response.finalUrl || request.url
                });
              } catch {
              }
              finish(resolve, result);
            } catch (error) {
              finish(reject, error);
            }
          },
          onerror(error) {
            finish(reject, new TypeError(`Network request failed: ${request.url}`, { cause: error }));
          },
          ontimeout() {
            finish(reject, new DOMException(`Network timeout: ${request.url}`, "TimeoutError"));
          },
          onabort() {
            finish(reject, new DOMException("The operation was aborted.", "AbortError"));
          }
        });
        if (request.signal) {
          abortListener = () => xhr.abort();
          request.signal.addEventListener("abort", abortListener, { once: true });
          if (request.signal.aborted) abortListener();
        }
      });
    }
    function sanitizeFilename(value) {
      return String(value || "video").replace(/[\\/:*?"<>|\x00-\x1f]/g, "_").replace(/\s+/g, " ").trim().replace(/[. ]+$/g, "").slice(0, 170) || "video";
    }
    function getXTweetContext(anchor = state.activeAnchor) {
      const article = anchor?.article?.matches?.('article, [role="article"], [data-testid="tweet"]') ? anchor.article : anchor?.closest?.('article, [role="article"], [data-testid="tweet"]') || null;
      const links = article ? [...article.querySelectorAll("a[href]")] : [];
      const hrefs = links.map((link) => link.href).filter(Boolean);
      const statusHref = hrefs.find((href) => /\/status(?:es)?\/\d+/i.test(href)) || location.href;
      const statusMatch = statusHref.match(/\/status(?:es)?\/(\d+)/i);
      const authorFromStatus = statusHref.match(/\/([^/?#]+)\/status(?:es)?\/\d+/i)?.[1] || "";
      const userName = article?.querySelector('[data-testid="User-Name"]');
      const authorHref = [...userName?.querySelectorAll("a[href]") || []].map((link) => link.href).find((href) => !/\/status(?:es)?\/\d+/i.test(href));
      const authorFromUser = authorHref?.match(/\/([^/?#]+)\/?(?:\?|#|$)/)?.[1] || "";
      const tweetText = article?.querySelector('[data-testid="tweetText"]')?.textContent?.trim() || "";
      return {
        article,
        tweetId: statusMatch?.[1] || "",
        authorId: authorFromStatus && authorFromStatus !== "i" ? authorFromStatus : authorFromUser,
        tweetText
      };
    }
    function getXUrlFilename(rawUrl) {
      try {
        const url = new URL(String(rawUrl));
        const queryCandidate = ["filename", "file", "name"].map((key) => url.searchParams.get(key) || "").find((value) => value);
        const pathCandidate = decodeURIComponent(url.pathname.split("/").pop() || "");
        const candidate = queryCandidate || pathCandidate;
        const stem = candidate.replace(/\.(?:mp4|webm|mov|m4s|m3u8)$/i, "");
        if (!stem || /^(?:mp4|webm|mov|m4s|m3u8|video|vid|file|stream)$/i.test(stem)) return "";
        return sanitizeFilename(stem);
      } catch {
        return "";
      }
    }
    function truncateFilename(value, maxLength = 96) {
      if (!String(value || "").trim()) return "";
      const cleaned = sanitizeFilename(value).replace(/\.(?:mp4|webm|mov|m4s|m3u8)$/i, "").trim();
      return sanitizeFilename(cleaned.slice(0, maxLength));
    }
    function getXDownloadName(item, analysis, extension, index = 0, context = state.activeXContext) {
      const tweetContext = getXTweetContext(context || void 0);
      const tweetTitle = truncateFilename(tweetContext.tweetText, 96);
      const fallback = [tweetContext.authorId || "x-user", tweetContext.tweetId || "tweet"].join("_");
      let base = tweetTitle || truncateFilename(analysis?.suggestedName, 96) || fallback;
      if (index > 0) base += `_video${index + 1}`;
      const clean = truncateFilename(base, 120);
      return `${clean || "x-video"}.${extension}`;
    }
    function formatBytes(value) {
      const n = Number(value);
      if (!Number.isFinite(n) || n <= 0) return isChinese ? "\u672A\u77E5\u5927\u5C0F" : "Unknown size";
      if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(2)} GB`;
      if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(2)} MB`;
      return `${(n / 1024).toFixed(1)} KB`;
    }
    function createDownloadAbortError() {
      return new DOMException(isChinese ? "\u4E0B\u8F7D\u4EFB\u52A1\u5DF2\u53D6\u6D88\u3002" : "Download cancelled.", "AbortError");
    }
    function renderDownloadTasks() {
      const container = panel()?.querySelector('[data-role="tasks"]');
      if (!container) return;
      const tasks = state.downloadHistory.slice(-8);
      container.replaceChildren();
      container.hidden = tasks.length === 0;
      if (!tasks.length) return;
      const title = document.createElement("div");
      title.className = "ytx-tasks-title";
      title.textContent = isChinese ? `\u4E0B\u8F7D\u961F\u5217\uFF08${state.downloadQueue.filter((task) => task.status === "queued").length} \u4E2A\u7B49\u5F85\u4E2D\uFF09` : `Download queue (${state.downloadQueue.filter((task) => task.status === "queued").length} waiting)`;
      container.appendChild(title);
      const labels = {
        queued: isChinese ? "\u7B49\u5F85\u4E2D" : "Queued",
        running: isChinese ? "\u8FDB\u884C\u4E2D" : "Running",
        paused: isChinese ? "\u5DF2\u6682\u505C" : "Paused",
        completed: isChinese ? "\u5DF2\u5B8C\u6210" : "Completed",
        failed: isChinese ? "\u5931\u8D25" : "Failed",
        cancelled: isChinese ? "\u5DF2\u53D6\u6D88" : "Cancelled"
      };
      for (const task of tasks.slice().reverse()) {
        const row = document.createElement("div");
        row.className = "ytx-task";
        const line = document.createElement("div");
        line.className = "ytx-task-line";
        const name = document.createElement("div");
        name.className = "ytx-task-name";
        name.title = task.label;
        name.textContent = task.label;
        const stateLabel = document.createElement("div");
        stateLabel.className = "ytx-task-state";
        stateLabel.textContent = labels[task.status] || task.status;
        line.append(name, stateLabel);
        row.appendChild(line);
        if (task.progressText) {
          const progress = document.createElement("div");
          progress.className = "ytx-task-progress";
          progress.textContent = task.progressText;
          row.appendChild(progress);
        }
        if (["queued", "running", "paused"].includes(task.status)) {
          const actions = document.createElement("div");
          actions.className = "ytx-task-actions";
          if (task.status === "paused" || task.status === "queued") {
            const pauseButton = document.createElement("button");
            pauseButton.type = "button";
            pauseButton.textContent = task.status === "paused" ? isChinese ? "\u7EE7\u7EED" : "Resume" : isChinese ? "\u6682\u505C" : "Pause";
            pauseButton.onclick = (event) => {
              event.stopPropagation();
              if (task.status === "paused") resumeDownloadTask(task);
              else pauseDownloadTask(task);
            };
            actions.appendChild(pauseButton);
          } else if (task.pauseSupported !== false) {
            const pauseButton = document.createElement("button");
            pauseButton.type = "button";
            pauseButton.textContent = isChinese ? "\u6682\u505C" : "Pause";
            pauseButton.onclick = (event) => {
              event.stopPropagation();
              pauseDownloadTask(task);
            };
            actions.appendChild(pauseButton);
          }
          const cancelButton = document.createElement("button");
          cancelButton.type = "button";
          cancelButton.textContent = isChinese ? "\u53D6\u6D88" : "Cancel";
          cancelButton.onclick = (event) => {
            event.stopPropagation();
            cancelDownloadTask(task);
          };
          actions.appendChild(cancelButton);
          row.appendChild(actions);
        }
        container.appendChild(row);
      }
    }
    function setDownloadTaskProgress(task, text) {
      task.progressText = text;
      if (state.currentDownload === task) setStatus(text);
      renderDownloadTasks();
    }
    async function waitForDownloadTask(task) {
      if (!task) return;
      if (task.cancelRequested) throw createDownloadAbortError();
      while (task.paused && !task.cancelRequested) {
        task.status = "paused";
        renderDownloadTasks();
        await new Promise((resolve) => {
          task.resumeWaiters ||= [];
          task.resumeWaiters.push(resolve);
        });
      }
      if (task.cancelRequested) throw createDownloadAbortError();
    }
    function pauseDownloadTask(task) {
      if (!task || !["queued", "running"].includes(task.status)) return;
      if (task.status === "running" && task.pauseSupported === false) {
        setStatus(isChinese ? "\u5F53\u524D\u4E0B\u8F7D\u65B9\u5F0F\u4E0D\u652F\u6301\u6682\u505C\uFF0C\u53EA\u80FD\u53D6\u6D88\uFF1B\u6D4F\u89C8\u5668\u5185\u4E0B\u8F7D\u4EFB\u52A1\u652F\u6301\u6682\u505C\u3002" : "This download method supports cancellation only. Local browser downloads also support pause.", "error");
        return;
      }
      task.paused = true;
      task.status = "paused";
      try {
        task.controller?.abort?.();
      } catch {
      }
      renderDownloadTasks();
    }
    function resumeDownloadTask(task) {
      if (!task || task.status !== "paused") return;
      task.paused = false;
      task.status = state.currentDownload === task ? "running" : "queued";
      const waiters = task.resumeWaiters || [];
      task.resumeWaiters = [];
      waiters.forEach((resolve) => resolve());
      renderDownloadTasks();
      void pumpDownloadQueue();
    }
    function cleanupDownloadTask(task) {
      if (!task || task.cleanupDone) return;
      task.cleanupDone = true;
      try {
        task.cleanup?.();
      } catch {
      }
    }
    function cancelDownloadTask(task) {
      if (!task || ["completed", "failed", "cancelled"].includes(task.status)) return;
      task.cancelRequested = true;
      task.paused = false;
      try {
        task.controller?.abort?.();
      } catch {
      }
      try {
        task.cancel?.();
      } catch {
      }
      if (state.currentDownload !== task) cleanupDownloadTask(task);
      if (task.status !== "running") {
        task.status = "cancelled";
        task.progressText = isChinese ? "\u4EFB\u52A1\u5DF2\u53D6\u6D88" : "Task cancelled";
      }
      const waiters = task.resumeWaiters || [];
      task.resumeWaiters = [];
      waiters.forEach((resolve) => resolve());
      renderDownloadTasks();
      void pumpDownloadQueue();
    }
    function enqueueDownload(label, run, options = {}) {
      const task = {
        id: state.nextDownloadId++,
        concurrency: state.downloadConcurrency,
        label,
        run,
        status: "queued",
        progressText: isChinese ? "\u7B49\u5F85\u961F\u5217\u6267\u884C\u2026\u2026" : "Waiting in queue...",
        pauseSupported: options.pauseSupported !== false,
        paused: false,
        cancelRequested: false,
        resumeWaiters: [],
        controller: null,
        cancel: null,
        cleanup: options.cleanup || null,
        cleanupDone: false
      };
      state.downloadQueue.push(task);
      state.downloadHistory.push(task);
      if (state.downloadHistory.length > 20) state.downloadHistory.splice(0, state.downloadHistory.length - 20);
      renderDownloadTasks();
      void pumpDownloadQueue();
      return task;
    }
    async function pumpDownloadQueue() {
      if (state.downloadWorkerActive) return;
      state.downloadWorkerActive = true;
      state.busy = true;
      try {
        while (true) {
          const task = state.downloadQueue.find((entry) => entry.status === "queued");
          if (!task) break;
          state.currentDownload = task;
          task.status = "running";
          task.progressText = isChinese ? "\u6B63\u5728\u542F\u52A8\u2026\u2026" : "Starting...";
          renderDownloadTasks();
          try {
            await task.run(task);
            task.status = task.cancelRequested ? "cancelled" : "completed";
            task.progressText = task.cancelRequested ? isChinese ? "\u4EFB\u52A1\u5DF2\u53D6\u6D88" : "Task cancelled" : isChinese ? "\u4EFB\u52A1\u5DF2\u5B8C\u6210" : "Task completed";
          } catch (error) {
            if (task.cancelRequested || error?.name === "AbortError") {
              task.status = "cancelled";
              task.progressText = isChinese ? "\u4EFB\u52A1\u5DF2\u53D6\u6D88" : "Task cancelled";
            } else {
              task.status = "failed";
              task.progressText = isChinese ? `\u5931\u8D25\uFF1A${error?.message || error}` : `Failed: ${error?.message || error}`;
              setStatus(task.progressText, "error");
            }
          } finally {
            cleanupDownloadTask(task);
            task.controller = null;
            task.cancel = null;
            task.run = null;
            state.downloadQueue = state.downloadQueue.filter((entry) => entry !== task);
            state.currentDownload = null;
            renderDownloadTasks();
          }
        }
      } finally {
        state.currentDownload = null;
        state.downloadWorkerActive = false;
        state.busy = false;
        renderDownloadTasks();
      }
    }
    function mimeContainer(mimeType) {
      const mime = String(mimeType || "").toLowerCase();
      if (mime.startsWith("video/mp4") || mime.startsWith("audio/mp4")) return "mp4";
      if (mime.startsWith("video/webm") || mime.startsWith("audio/webm")) return "webm";
      return null;
    }
    function codecLabel(mimeType) {
      const text = String(mimeType || "");
      const codecs = text.match(/codecs="([^"]+)"/i)?.[1] || "";
      const lower = codecs.toLowerCase();
      if (lower.includes("av01")) return `AV1${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("vp09") || lower.includes("vp9")) return `VP9${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("vp8")) return `VP8${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("avc1") || lower.includes("avc3")) return `H.264${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("hev1") || lower.includes("hvc1")) return `H.265${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("mp4a")) return `AAC${codecs ? ` (${codecs})` : ""}`;
      if (lower.includes("opus")) return "Opus";
      if (lower.includes("vorbis")) return "Vorbis";
      return codecs || (isChinese ? "\u672A\u77E5\u7F16\u7801" : "Unknown codec");
    }
    function isYoutubeHost() {
      return /(^|\.)youtube\.com$/i.test(location.hostname);
    }
    function isXHost() {
      return /(^|\.)(x|twitter)\.com$/i.test(location.hostname);
    }
    function getYoutubeVideoId() {
      try {
        const url = new URL(location.href);
        if (url.pathname === "/watch") return url.searchParams.get("v");
        const shorts = url.pathname.match(/^\/shorts\/([\w-]{6,})/);
        if (shorts) return shorts[1];
        const live = url.pathname.match(/^\/live\/([\w-]{6,})/);
        if (live) return live[1];
      } catch {
      }
      return null;
    }
    function isDrmFormat(format) {
      return Array.isArray(format?.drm_families) && format.drm_families.length > 0;
    }
    function hasYoutubeFormatSource(format) {
      return [format?.url, format?.signature_cipher, format?.cipher].some(
        (value) => typeof value === "string" && value.trim().length > 0
      );
    }
    function showError(error) {
      console.error(`[${APP}]`, error);
      const message = error?.message || String(error);
      setStatus(isChinese ? `\u5931\u8D25\uFF1A${message}` : `Failed: ${message}`, "error");
    }
    function getYoutubeEvalEnvironment() {
      if (state.youtubeEvalEnvironment) return state.youtubeEvalEnvironment;
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : document.defaultView || globalThis;
      const candidates = [
        { scope: globalThis, name: "userscript" },
        { scope: pageWindow, name: "page" }
      ].filter((candidate, index, all) => candidate.scope && all.findIndex((item) => item.scope === candidate.scope) === index);
      const hasTrustedTypes = candidates.some((candidate) => candidate.scope?.trustedTypes?.createPolicy);
      let lastError = null;
      for (const candidate of candidates) {
        const evaluate = candidate.scope?.eval;
        if (typeof evaluate !== "function") continue;
        const trustedTypes = candidate.scope?.trustedTypes;
        if (trustedTypes?.createPolicy) {
          try {
            const policy = trustedTypes.createPolicy(PLAYER_EVAL_POLICY, {
              createScript(value) {
                return String(value);
              }
            });
            state.youtubeEvalEnvironment = { evaluate, scope: candidate.scope, policy, trustedTypes, name: candidate.name };
            return state.youtubeEvalEnvironment;
          } catch (error) {
            lastError = error;
          }
        } else if (!hasTrustedTypes) {
          state.youtubeEvalEnvironment = { evaluate, scope: candidate.scope, policy: null, trustedTypes: null, name: candidate.name };
          return state.youtubeEvalEnvironment;
        }
      }
      throw new Error(isChinese ? `YouTube \u9875\u9762\u62D2\u7EDD\u521B\u5EFA TrustedScript \u7B56\u7565\uFF1A${lastError?.message || lastError || (isChinese ? "\u6CA1\u6709\u53EF\u7528\u7684 Trusted Types \u73AF\u5883" : "No available Trusted Types environment")}` : `YouTube refused to create a TrustedScript policy: ${lastError?.message || lastError || (isChinese ? "\u6CA1\u6709\u53EF\u7528\u7684 Trusted Types \u73AF\u5883" : "No available Trusted Types environment")}`);
    }
    Platform.shim.eval = async (data) => {
      if (!data || typeof data.output !== "string") {
        throw new Error("YouTube player evaluator received invalid data.");
      }
      const source = `(function ytxYoutubePlayerTransform() {
"use strict";
${data.output}
})()`;
      const environment = getYoutubeEvalEnvironment();
      const trustedSource = environment.policy ? environment.policy.createScript(source) : source;
      if (environment.trustedTypes?.isScript && !environment.trustedTypes.isScript(trustedSource)) {
        throw new Error(isChinese ? `TrustedScript \u521B\u5EFA\u5931\u8D25\uFF08\u6267\u884C\u73AF\u5883\uFF1A${environment.name}\uFF09\u3002` : `Failed to create TrustedScript (environment: ${environment.name}).`);
      }
      return Reflect.apply(environment.evaluate, environment.scope, [trustedSource]);
    };
    if (!Parser.hasParser("PlayerErrorCommand")) {
      class PlayerErrorCommand {
        static type = "PlayerErrorCommand";
        constructor(data) {
          this.command = {
            click_tracking_params: data?.command?.clickTrackingParams || "",
            auth_required_command: data?.command?.authRequiredCommand ? new YTNodes.NavigationEndpoint(data.command.authRequiredCommand) : null
          };
        }
      }
      Parser.addRuntimeParser("PlayerErrorCommand", PlayerErrorCommand);
    }
    function readJsonObjectAt(text, start) {
      let depth = 0;
      let inString = false;
      let escaped = false;
      for (let index = start; index < text.length; index += 1) {
        const character = text[index];
        if (inString) {
          if (escaped) escaped = false;
          else if (character === "\\") escaped = true;
          else if (character === '"') inString = false;
          continue;
        }
        if (character === '"') {
          inString = true;
        } else if (character === "{") {
          depth += 1;
        } else if (character === "}") {
          depth -= 1;
          if (depth === 0) {
            try {
              return JSON.parse(text.slice(start, index + 1));
            } catch {
              return null;
            }
          }
        }
      }
      return null;
    }
    function getYoutubePlayerResponseFromPage(videoId) {
      const candidates = [];
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : window;
      try {
        const player = pageWindow.document.getElementById("movie_player");
        if (typeof player?.getPlayerResponse === "function") {
          candidates.push(player.getPlayerResponse());
        }
      } catch {
      }
      for (const scope of [pageWindow, globalThis]) {
        try {
          candidates.push(
            scope.ytInitialPlayerResponse,
            scope.ytplayer?.config?.args?.player_response,
            scope.ytplayer?.config?.player_response
          );
        } catch {
        }
      }
      const accept = (candidate) => {
        if (typeof candidate === "string") {
          try {
            candidate = JSON.parse(candidate);
          } catch {
            return null;
          }
        }
        if (!candidate || typeof candidate !== "object") return null;
        return candidate.videoDetails?.videoId === videoId ? candidate : null;
      };
      for (const candidate of candidates) {
        const response = accept(candidate);
        if (response) return response;
      }
      const markers = [
        "ytInitialPlayerResponse =",
        "ytInitialPlayerResponse=",
        "player_response:"
      ];
      for (const script of document.scripts) {
        const text = script.textContent || "";
        if (!text.includes("ytInitialPlayerResponse") && !text.includes("player_response")) continue;
        for (const marker of markers) {
          const markerIndex = text.indexOf(marker);
          if (markerIndex < 0) continue;
          const objectStart = text.indexOf("{", markerIndex + marker.length);
          if (objectStart < 0) continue;
          const response = accept(readJsonObjectAt(text, objectStart));
          if (response) return response;
        }
      }
      return null;
    }
    function readableYoutubeText(value) {
      if (typeof value === "string") return value;
      if (typeof value?.text === "string") return value.text;
      return "";
    }
    function youtubePlayabilityText(info) {
      const playability = info?.playability_status;
      if (!playability) return isChinese ? "\u6CA1\u6709 playabilityStatus" : "Missing playabilityStatus";
      const status = playability.status || "UNKNOWN";
      const reason = readableYoutubeText(playability.reason);
      const errorScreen = playability.error_screen;
      const detail = readableYoutubeText(errorScreen?.subreason) || readableYoutubeText(errorScreen?.reason);
      return [status, reason || detail].filter(Boolean).join(isChinese ? "\uFF1A" : ": ");
    }
    function parsePageYoutubeInfo(youtube, playerResponse) {
      const parsed = Parser.parseResponse(playerResponse);
      return {
        ...parsed,
        actions: youtube?.actions,
        basic_info: parsed.video_details || {},
        source: "page"
      };
    }
    function rememberYoutubeFormatMetadata(videoId, info) {
      if (!videoId || !info?.streaming_data) return;
      let metadata = state.youtubeFormatMetadata.get(videoId);
      if (!metadata) {
        metadata = /* @__PURE__ */ new Map();
        state.youtubeFormatMetadata.set(videoId, metadata);
      }
      const formats = [
        ...info.streaming_data.formats || [],
        ...info.streaming_data.adaptive_formats || []
      ];
      for (const format of formats) {
        if (!format?.itag) continue;
        metadata.set(String(format.itag), format);
        if (format.xtags) metadata.set(`${format.itag}:${format.xtags}`, format);
      }
    }
    const YOUTUBE_CLIENT_NAME_IDS = {
      iOS: 5,
      WEB: 1,
      MWEB: 2,
      WEB_KIDS: 76,
      WEB_REMIX: 67,
      ANDROID: 3,
      ANDROID_CREATOR: 14,
      ANDROID_MUSIC: 21,
      ANDROID_VR: 28,
      VISIONOS: 101,
      TVHTML5: 7,
      TVHTML5_SIMPLY: 74,
      TVHTML5_SIMPLY_EMBEDDED_PLAYER: 85,
      WEB_EMBEDDED_PLAYER: 56,
      WEB_CREATOR: 62
    };
    function youtubeSabrFormatFromFormat(format) {
      if (!format?.itag) return null;
      return {
        itag: Number(format.itag),
        lastModified: String(format.last_modified_ms || format.last_modified || "0"),
        xtags: format.xtags || void 0,
        width: Number(format.width || 0) || void 0,
        height: Number(format.height || 0) || void 0,
        contentLength: Number(format.content_length || 0) || void 0,
        audioTrackId: format.audio_track?.id || format.audio_track_id || void 0,
        mimeType: format.mime_type || void 0,
        quality: format.quality || void 0,
        qualityLabel: format.quality_label || void 0,
        averageBitrate: Number(format.average_bitrate || 0) || void 0,
        bitrate: Number(format.bitrate || format.average_bitrate || 0) || 0,
        audioQuality: format.audio_quality || void 0,
        approxDurationMs: Number(format.approx_duration_ms || 0) || 0,
        language: format.language || null,
        isDubbed: Boolean(format.is_dubbed),
        isAutoDubbed: Boolean(format.is_auto_dubbed),
        isDescriptive: Boolean(format.is_descriptive),
        isSecondary: Boolean(format.is_secondary),
        isOriginal: Boolean(format.is_original)
      };
    }
    function selectYoutubeSabrAudioFormat(info, videoFormat) {
      const container = mimeContainer(videoFormat?.mime_type);
      const candidates = (info?.streaming_data?.adaptive_formats || []).filter((format) => {
        if (!format?.has_audio || format.has_video || format.is_type_otf || isDrmFormat(format)) return false;
        if (!format.mime_type) return false;
        return !container || mimeContainer(format.mime_type) === container;
      }).sort((a, b) => Number(b.bitrate || b.average_bitrate || 0) - Number(a.bitrate || a.average_bitrate || 0));
      return candidates[0] || null;
    }
    function getYoutubeSabrFormatPairs(info) {
      const streaming = info?.streaming_data;
      if (!streaming?.server_abr_streaming_url) return [];
      const pairs = [];
      const seen = /* @__PURE__ */ new Set();
      for (const rawVideo of [
        ...streaming.adaptive_formats || [],
        ...streaming.formats || []
      ]) {
        if (!rawVideo?.has_video || rawVideo.is_type_otf || isDrmFormat(rawVideo)) continue;
        if (!rawVideo.mime_type || !mimeContainer(rawVideo.mime_type)) continue;
        const rawAudio = selectYoutubeSabrAudioFormat(info, rawVideo);
        if (!rawAudio) continue;
        const video = youtubeSabrFormatFromFormat(rawVideo);
        const audio = youtubeSabrFormatFromFormat(rawAudio);
        if (!video || !audio) continue;
        const key = `${video.itag}:${video.xtags || ""}`;
        if (seen.has(key)) continue;
        seen.add(key);
        pairs.push({ video, audio, rawVideo, rawAudio });
      }
      pairs.sort(
        (a, b) => Number(b.video.height || 0) - Number(a.video.height || 0) || Number(b.video.qualityLabel?.endsWith?.("60") ? 60 : 0) - Number(a.video.qualityLabel?.endsWith?.("60") ? 60 : 0) || Number(b.video.bitrate || 0) - Number(a.video.bitrate || 0)
      );
      return pairs;
    }
    function scoreYoutubeSabrInfo(info) {
      const pairs = getYoutubeSabrFormatPairs(info);
      if (!pairs.length) return -1;
      const best = pairs[0].video;
      return Number(best.height || 0) * 1e12 + Number(best.bitrate || 0);
    }
    function scoreYoutubeInfo(info) {
      let best = -1;
      for (const format of getYoutubeVideoFormats(info)) {
        if (!mimeContainer(format.mime_type)) continue;
        if (!format.has_audio && !selectYoutubeAudioFormat(info, format)) continue;
        const height = Number(format.height || 0);
        const fps = Number(format.fps || 0);
        const bitrate = Number(format.bitrate || format.average_bitrate || 0);
        const score = height * 1e12 + fps * 1e9 + bitrate;
        if (score > best) best = score;
      }
      return best;
    }
    async function getYoutubeClient() {
      if (!state.youtubePromise) {
        const cookie = (() => {
          try {
            return document.cookie || "";
          } catch {
            return "";
          }
        })();
        state.youtubePromise = Innertube.create({
          fetch: gmFetch,
          cookie: cookie || void 0,
          retrieve_player: true,
          generate_session_locally: true,
          enable_session_cache: false,
          user_agent: navigator.userAgent,
          lang: (navigator.language || "en").split("-")[0]
        }).catch((error) => {
          state.youtubePromise = null;
          throw error;
        });
      }
      const youtube = await state.youtubePromise;
      state.youtubeSessionClient = youtube?.session?.context?.client || state.youtubeSessionClient;
      state.youtubeSessionPoToken = youtube?.session?.po_token || state.youtubeSessionPoToken;
      return youtube;
    }
    async function loadYoutubeInfo(videoId, force = false) {
      if (!force && state.youtubeInfo.has(videoId)) {
        return state.youtubeInfo.get(videoId);
      }
      const errors = [];
      const candidates = [];
      const sabrCandidates = [];
      let youtube = null;
      const addCandidate = (info, client) => {
        const score = scoreYoutubeInfo(info);
        if (score < 0) {
          errors.push(isChinese ? `${client}: ${youtubePlayabilityText(info)}\uFF1B\u6CA1\u6709\u53EF\u4E0B\u8F7D\u7684\u89C6\u9891/\u97F3\u9891\u7EC4\u5408` : `${client}: ${youtubePlayabilityText(info)}; no downloadable video/audio pair`);
          return;
        }
        candidates.push({ info, client, score });
      };
      const addSabrCandidate = (info, client) => {
        const score = scoreYoutubeSabrInfo(info);
        if (score >= 0) sabrCandidates.push({ info, client, score });
      };
      try {
        youtube = await getYoutubeClient();
      } catch (error) {
        errors.push(isChinese ? `\u5BA2\u6237\u7AEF\u521D\u59CB\u5316\uFF1A${error?.message || error}` : `Client initialization: ${error?.message || error}`);
      }
      const pageResponse = getYoutubePlayerResponseFromPage(videoId);
      if (pageResponse) {
        try {
          const info = parsePageYoutubeInfo(youtube, pageResponse);
          rememberYoutubeFormatMetadata(videoId, info);
          addSabrCandidate(info, "PAGE");
          const streaming = info.streaming_data;
          const pageFormats = [
            ...streaming?.adaptive_formats || [],
            ...streaming?.formats || []
          ];
          if (pageFormats.some(hasYoutubeFormatSource)) {
            addCandidate(info, "PAGE");
          } else {
            errors.push(isChinese ? `PAGE: ${youtubePlayabilityText(info)}\uFF1B\u8FD4\u56DE\u7684\u683C\u5F0F\u6CA1\u6709\u53EF\u89E3\u7801 URL\uFF0C\u53EF\u80FD\u662F SABR \u6D41` : `PAGE: ${youtubePlayabilityText(info)}; formats have no decipherable URL and may use SABR`);
          }
        } catch (error) {
          errors.push(`PAGE: ${error?.message || error}`);
        }
      }
      const clients = [
        "ANDROID_VR",
        "ANDROID",
        "TV_SIMPLY",
        "TV_EMBEDDED",
        "WEB_EMBEDDED",
        "WEB",
        "TV",
        "IOS",
        "MWEB"
      ];
      if (youtube) {
        const results = await Promise.all(clients.map(async (client) => {
          try {
            return { client, info: await youtube.getBasicInfo(videoId, { client }) };
          } catch (error) {
            return { client, error };
          }
        }));
        for (const result of results) {
          if (result.error) {
            errors.push(`${result.client}: ${result.error?.message || result.error}`);
            continue;
          }
          rememberYoutubeFormatMetadata(videoId, result.info);
          addSabrCandidate(result.info, result.client);
          const streaming = result.info.streaming_data;
          const formats = [
            ...streaming?.adaptive_formats || [],
            ...streaming?.formats || []
          ];
          if (formats.some(hasYoutubeFormatSource)) {
            addCandidate(result.info, result.client);
          } else {
            errors.push(isChinese ? `${result.client}: ${youtubePlayabilityText(result.info)}\uFF1B\u8FD4\u56DE\u7684\u683C\u5F0F\u6CA1\u6709\u53EF\u89E3\u7801 URL\uFF0C\u53EF\u80FD\u662F SABR \u6D41` : `${result.client}: ${youtubePlayabilityText(result.info)}; formats have no decipherable URL and may use SABR`);
          }
        }
      }
      if (candidates.length) {
        candidates.sort((a, b) => b.score - a.score);
        const best = candidates[0];
        sabrCandidates.sort((a, b) => b.score - a.score);
        const bestSabr = sabrCandidates[0] || null;
        const result = {
          info: best.info,
          client: best.client,
          sabrInfo: bestSabr?.info || null,
          sabrClient: bestSabr?.client || ""
        };
        state.youtubeInfo.set(videoId, result);
        return result;
      }
      if (sabrCandidates.length) {
        sabrCandidates.sort((a, b) => b.score - a.score);
        const bestSabr = sabrCandidates[0];
        const result = {
          info: bestSabr.info,
          client: bestSabr.client,
          sabrInfo: bestSabr.info,
          sabrClient: bestSabr.client
        };
        state.youtubeInfo.set(videoId, result);
        return result;
      }
      const pageTitle = document.title.replace(/\s*-\s*YouTube\s*$/i, "");
      const capturedBaseInfo = {
        basic_info: { id: videoId, title: pageTitle },
        streaming_data: { formats: [], adaptive_formats: [] }
      };
      const capturedFallback = mergeCapturedYoutubeFormats(videoId, capturedBaseInfo);
      if (scoreYoutubeInfo(capturedFallback.info) >= 0) {
        const result = {
          info: capturedFallback.info,
          client: isChinese ? "\u5F53\u524D\u7F51\u9875\u64AD\u653E\u5668" : "Current page player",
          sabrInfo: null,
          sabrClient: ""
        };
        state.youtubeInfo.set(videoId, result);
        return result;
      }
      if (!youtube) {
        throw new Error(isChinese ? `YouTube \u5BA2\u6237\u7AEF\u521D\u59CB\u5316\u5931\u8D25\u3002${errors.length ? `
${errors.join("\n")}` : ""}` : `YouTube client initialization failed.${errors.length ? `
${errors.join("\n")}` : ""}`);
      }
      const loginRequired = errors.some((message) => /LOGIN_REQUIRED|确认你的年龄|确认您的年龄/.test(message));
      const hint = loginRequired ? isChinese ? "YouTube \u62D2\u7EDD\u4E86\u811A\u672C\u7684\u72EC\u7ACB\u5BA2\u6237\u7AEF\u8BF7\u6C42\uFF1B\u7F51\u9875\u767B\u5F55\u72B6\u6001\u4E0D\u4F1A\u81EA\u52A8\u4F20\u7ED9\u8BE5\u5BA2\u6237\u7AEF\u3002\u8BF7\u8BA9\u5F53\u524D\u89C6\u9891\u64AD\u653E 2\uFF5E3 \u79D2\uFF0C\u4F7F\u811A\u672C\u6355\u83B7\u5DF2\u767B\u5F55\u64AD\u653E\u5668\u7684\u5A92\u4F53\u8BF7\u6C42\uFF0C\u7136\u540E\u70B9\u51FB\u201C\u5237\u65B0\u201D\u3002" : "YouTube rejected the userscript's standalone client request; the page sign-in session is not automatically shared with that client. Play the current video for 2\u20133 seconds so the script can capture the signed-in player's media requests, then click Refresh." : isChinese ? "\u8BF7\u5148\u786E\u8BA4\u5F53\u524D\u7F51\u9875\u80FD\u6B63\u5E38\u64AD\u653E\u8BE5\u89C6\u9891\uFF0C\u518D\u5237\u65B0\u91CD\u8BD5\u3002" : "Confirm that the video plays on this page, then refresh and try again.";
      throw new Error(isChinese ? `\u65E0\u6CD5\u53D6\u5F97 YouTube \u5A92\u4F53\u4FE1\u606F\u3002${hint}${errors.length ? `
${errors.join("\n")}` : ""}` : `Could not retrieve YouTube media information.${hint}${errors.length ? `
${errors.join("\n")}` : ""}`);
    }
    function getYoutubeVideoFormats(info) {
      const streaming = info.streaming_data;
      if (!streaming) return [];
      const all = [
        ...streaming.formats || [],
        ...streaming.adaptive_formats || []
      ];
      const seen = /* @__PURE__ */ new Set();
      const result = [];
      for (const format of all) {
        if (!format?.has_video) continue;
        if (format.is_type_otf) continue;
        if (isDrmFormat(format)) continue;
        if (!hasYoutubeFormatSource(format)) continue;
        if (!format.mime_type) continue;
        if (seen.has(format.itag)) continue;
        seen.add(format.itag);
        result.push(format);
      }
      result.sort((a, b) => {
        return (b.height || 0) - (a.height || 0) || (b.fps || 0) - (a.fps || 0) || (b.bitrate || 0) - (a.bitrate || 0);
      });
      return result;
    }
    function hasYoutubeSabrStreaming(info) {
      const streaming = info?.streaming_data;
      if (!streaming) return false;
      if (typeof streaming.server_abr_streaming_url === "string" && streaming.server_abr_streaming_url) {
        return true;
      }
      const all = [
        ...streaming.formats || [],
        ...streaming.adaptive_formats || []
      ];
      return all.some((format) => !hasYoutubeFormatSource(format) && !isDrmFormat(format));
    }
    function selectYoutubeAudioFormat(info, videoFormat) {
      const container = mimeContainer(videoFormat.mime_type);
      if (!container) return null;
      const candidates = (info.streaming_data?.adaptive_formats || []).filter((format) => {
        if (!format?.has_audio || format.has_video) return false;
        if (format.is_type_otf || isDrmFormat(format)) return false;
        if (!hasYoutubeFormatSource(format)) return false;
        return mimeContainer(format.mime_type) === container;
      });
      candidates.sort((a, b) => {
        const score = (f) => {
          let value = Number(f.bitrate || f.average_bitrate || 0);
          if (f.audio_track?.audio_is_default) value += 1e10;
          if (f.is_original) value += 1e9;
          if (f.is_drc) value -= 2e9;
          if (f.is_vb) value -= 1e9;
          return value;
        };
        return score(b) - score(a);
      });
      return candidates[0] || null;
    }
    async function decipherYoutubeFormat(info, format) {
      if (!hasYoutubeFormatSource(format)) {
        throw new Error(isChinese ? `itag ${format?.itag || "?"} \u6CA1\u6709\u53EF\u89E3\u7801 URL\uFF1BYouTube \u8FD4\u56DE\u7684\u662F SABR/\u5206\u6BB5\u6D41\u3002` : `itag ${format?.itag || "?"} has no decipherable URL; YouTube returned a SABR/segmented stream.`);
      }
      if (!format || typeof format.decipher !== "function") {
        throw new Error(isChinese ? `itag ${format?.itag || "?"} \u4E0D\u662F\u53EF\u89E3\u7801\u7684 YouTube \u683C\u5F0F\u5BF9\u8C61\u3002` : `itag ${format?.itag || "?"} is not a decipherable YouTube format object.`);
      }
      const cached = state.youtubeUrlCache.get(format);
      if (cached) return await cached;
      const task = (async () => {
        const player = info.actions?.session?.player || (await getYoutubeClient()).session.player;
        let url;
        try {
          url = await format.decipher(player);
        } catch (error) {
          if (String(error?.message || error).includes("No valid URL to decipher")) {
            throw new Error(isChinese ? `itag ${format.itag || "?"} \u6CA1\u6709\u53EF\u89E3\u7801 URL\uFF1BYouTube \u8FD4\u56DE\u7684\u662F SABR/\u5206\u6BB5\u6D41\u3002` : `itag ${format.itag || "?"} has no decipherable URL; YouTube returned a SABR/segmented stream.`);
          }
          throw error;
        }
        if (!url) throw new Error(isChinese ? `itag ${format.itag || "?"} \u6CA1\u6709\u53EF\u7528\u4E0B\u8F7D URL\u3002` : `itag ${format.itag || "?"} has no download URL.`);
        assertAllowedNetworkUrl(url);
        const host = new URL(url).hostname.toLowerCase();
        if (!(host === "googlevideo.com" || host.endsWith(".googlevideo.com"))) {
          throw new Error(isChinese ? `YouTube \u5A92\u4F53 URL \u4E0D\u5728 googlevideo.com\uFF1A${host}` : `YouTube media URL is outside googlevideo.com: ${host}`);
        }
        return url;
      })();
      state.youtubeUrlCache.set(format, task);
      try {
        return await task;
      } catch (error) {
        state.youtubeUrlCache.delete(format);
        throw error;
      }
    }
    const YOUTUBE_ITAG_FALLBACKS = /* @__PURE__ */ new Map([
      [18, ["muxed", "mp4", 360, 30]],
      [22, ["muxed", "mp4", 720, 30]],
      [133, ["video", "mp4", 240, 30]],
      [134, ["video", "mp4", 360, 30]],
      [135, ["video", "mp4", 480, 30]],
      [136, ["video", "mp4", 720, 30]],
      [137, ["video", "mp4", 1080, 30]],
      [138, ["video", "mp4", 2160, 30]],
      [160, ["video", "mp4", 144, 30]],
      [264, ["video", "mp4", 1440, 30]],
      [266, ["video", "mp4", 2160, 30]],
      [298, ["video", "mp4", 720, 60]],
      [299, ["video", "mp4", 1080, 60]],
      [399, ["video", "mp4", 1080, 30]],
      [400, ["video", "mp4", 1440, 30]],
      [401, ["video", "mp4", 2160, 30]],
      [139, ["audio", "mp4", 0, 0]],
      [140, ["audio", "mp4", 0, 0]],
      [141, ["audio", "mp4", 0, 0]],
      [242, ["video", "webm", 240, 30]],
      [243, ["video", "webm", 360, 30]],
      [244, ["video", "webm", 480, 30]],
      [247, ["video", "webm", 720, 30]],
      [248, ["video", "webm", 1080, 30]],
      [271, ["video", "webm", 1440, 30]],
      [272, ["video", "webm", 2160, 30]],
      [278, ["video", "webm", 144, 30]],
      [302, ["video", "webm", 720, 60]],
      [303, ["video", "webm", 1080, 60]],
      [308, ["video", "webm", 1440, 60]],
      [313, ["video", "webm", 2160, 30]],
      [315, ["video", "webm", 2160, 60]],
      [330, ["video", "webm", 144, 60]],
      [331, ["video", "webm", 240, 60]],
      [332, ["video", "webm", 360, 60]],
      [333, ["video", "webm", 480, 60]],
      [334, ["video", "webm", 720, 60]],
      [335, ["video", "webm", 1080, 60]],
      [336, ["video", "webm", 1440, 60]],
      [337, ["video", "webm", 2160, 60]],
      [249, ["audio", "webm", 0, 0]],
      [250, ["audio", "webm", 0, 0]],
      [251, ["audio", "webm", 0, 0]]
    ]);
    function youtubeMediaKindFromUrl(url, itag) {
      const mime = String(url.searchParams.get("mime") || "").toLowerCase();
      if (mime.startsWith("video/")) return "video";
      if (mime.startsWith("audio/")) return "audio";
      return YOUTUBE_ITAG_FALLBACKS.get(itag)?.[0] || null;
    }
    function rememberYoutubeMedia(rawUrl, startTime = performance.now()) {
      if (!isYoutubeHost()) return;
      let url;
      try {
        url = new URL(String(rawUrl));
      } catch {
        return;
      }
      const host = url.hostname.toLowerCase();
      if (!(host === "googlevideo.com" || host.endsWith(".googlevideo.com"))) return;
      if (!url.pathname.toLowerCase().includes("videoplayback")) return;
      const seenAt = Number(startTime) || performance.now();
      if (seenAt + 100 < state.youtubeNavigationStartedAt) return;
      if (url.searchParams.has("sq")) return;
      const itag = Number(url.searchParams.get("itag") || url.searchParams.get("fmt") || 0);
      if (!itag) return;
      const kind = youtubeMediaKindFromUrl(url, itag);
      if (!kind) return;
      for (const parameter of ["range", "rn", "rbuf"]) {
        url.searchParams.delete(parameter);
      }
      const videoId = getYoutubeVideoId();
      if (!videoId) return;
      const xtags = url.searchParams.get("xtags") || "";
      const mediaId = url.searchParams.get("id") || url.pathname;
      const key = `${videoId}:${mediaId}:${itag}:${xtags}`;
      state.youtubeMedia.set(key, {
        url: url.href,
        videoId,
        itag,
        xtags,
        kind,
        seenAt
      });
      if (state.youtubeMedia.size > 200) {
        const oldest = [...state.youtubeMedia.entries()].sort((a, b) => a[1].seenAt - b[1].seenAt).slice(0, state.youtubeMedia.size - 200);
        oldest.forEach(([entryKey]) => state.youtubeMedia.delete(entryKey));
      }
    }
    function scanPerformanceForYoutubeMedia() {
      for (const entry of performance.getEntriesByType("resource")) {
        rememberYoutubeMedia(entry.name, entry.startTime);
      }
    }
    function getRequestUrl(input) {
      if (typeof input === "string") return input;
      if (input instanceof URL) return input.href;
      if (typeof input?.url === "string") return input.url;
      return "";
    }
    function installYoutubeNetworkCapture() {
      if (!isYoutubeHost() || state.youtubeNetworkCaptureInstalled) return;
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : document.defaultView || globalThis;
      let installed = false;
      const hookMarker = "__ytxLocalDownloaderMediaHook__";
      try {
        const originalFetch = pageWindow.fetch;
        if (typeof originalFetch === "function") {
          const wrappedFetch = function ytxMediaFetch(input, ...init2) {
            try {
              rememberYoutubeMedia(getRequestUrl(input));
            } catch {
            }
            const result = Reflect.apply(originalFetch, this, [input, ...init2]);
            return Promise.resolve(result).then((response) => {
              try {
                rememberYoutubeMedia(response?.url);
              } catch {
              }
              return response;
            });
          };
          Object.defineProperty(wrappedFetch, hookMarker, { value: true });
          pageWindow.fetch = wrappedFetch;
          installed = true;
        }
      } catch {
      }
      try {
        const xhrPrototype = pageWindow.XMLHttpRequest?.prototype;
        const originalOpen = xhrPrototype?.open;
        if (xhrPrototype && typeof originalOpen === "function") {
          const wrappedOpen = function ytxMediaXhrOpen(method, url, ...rest) {
            try {
              rememberYoutubeMedia(getRequestUrl(url));
            } catch {
            }
            return Reflect.apply(originalOpen, this, [method, url, ...rest]);
          };
          Object.defineProperty(wrappedOpen, hookMarker, { value: true });
          xhrPrototype.open = wrappedOpen;
          installed = true;
        }
      } catch {
      }
      state.youtubeNetworkCaptureInstalled = installed;
    }
    function installXNetworkCapture() {
      if (!isXHost() || state.xNetworkCaptureInstalled) return;
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : document.defaultView || globalThis;
      let installed = false;
      const hookMarker = "__ytxLocalDownloaderXMediaHook__";
      try {
        const originalFetch = pageWindow.fetch;
        if (typeof originalFetch === "function" && !originalFetch[hookMarker]) {
          const wrappedFetch = function ytxXMediaFetch(input, ...init2) {
            try {
              rememberXMedia(getRequestUrl(input));
            } catch {
            }
            const result = Reflect.apply(originalFetch, this, [input, ...init2]);
            return Promise.resolve(result).then((response) => {
              try {
                rememberXMedia(response?.url);
              } catch {
              }
              return response;
            });
          };
          Object.defineProperty(wrappedFetch, hookMarker, { value: true });
          pageWindow.fetch = wrappedFetch;
          installed = true;
        }
      } catch {
      }
      try {
        const xhrPrototype = pageWindow.XMLHttpRequest?.prototype;
        const originalOpen = xhrPrototype?.open;
        if (xhrPrototype && typeof originalOpen === "function" && !originalOpen[hookMarker]) {
          const wrappedOpen = function ytxXMediaXhrOpen(method, url, ...rest) {
            try {
              rememberXMedia(getRequestUrl(url));
            } catch {
            }
            return Reflect.apply(originalOpen, this, [method, url, ...rest]);
          };
          Object.defineProperty(wrappedOpen, hookMarker, { value: true });
          xhrPrototype.open = wrappedOpen;
          installed = true;
        }
      } catch {
      }
      state.xNetworkCaptureInstalled = installed;
    }
    function capturedYoutubeFormat(videoId, media) {
      const metadata = state.youtubeFormatMetadata.get(videoId);
      const source = metadata?.get(`${media.itag}:${media.xtags}`) || metadata?.get(String(media.itag));
      const fallback = YOUTUBE_ITAG_FALLBACKS.get(media.itag) || [media.kind, "mp4", 0, 0];
      const kind = source?.has_video && source?.has_audio ? "muxed" : source?.has_video ? "video" : source?.has_audio ? "audio" : fallback[0];
      const container = mimeContainer(source?.mime_type) || fallback[1];
      const mimeType = source?.mime_type || `${kind === "audio" ? "audio" : "video"}/${container}`;
      return {
        ...source || {},
        itag: media.itag,
        url: media.url,
        mime_type: mimeType,
        width: Number(source?.width || 0) || void 0,
        height: Number(source?.height || fallback[2] || 0) || void 0,
        fps: Number(source?.fps || fallback[3] || 0) || void 0,
        content_length: Number(source?.content_length || new URL(media.url).searchParams.get("clen") || 0) || void 0,
        has_video: kind === "video" || kind === "muxed",
        has_audio: kind === "audio" || kind === "muxed",
        is_type_otf: false,
        ytx_captured: true,
        async decipher() {
          return this.url;
        }
      };
    }
    function mergeCapturedYoutubeFormats(videoId, info) {
      scanPerformanceForYoutubeMedia();
      const recent = [...state.youtubeMedia.values()].filter((media) => media.videoId === videoId).sort((a, b) => b.seenAt - a.seenAt);
      if (!recent.length) return { info, capturedCount: 0, observedCount: 0, capturedSummary: "" };
      const byTrack = /* @__PURE__ */ new Map();
      for (const media of recent) {
        const key = `${media.itag}:${media.xtags}`;
        if (!byTrack.has(key)) byTrack.set(key, capturedYoutubeFormat(videoId, media));
      }
      const captured = [...byTrack.values()];
      const capturedSummary = captured.slice().sort((a, b) => (b.height || 0) - (a.height || 0) || (b.bitrate || 0) - (a.bitrate || 0)).slice(0, 10).map((format) => {
        const quality = format.has_video ? format.quality_label || (format.height ? `${format.height}p` : isChinese ? "\u89C6\u9891" : "Video") : isChinese ? "\u97F3\u9891" : "Audio";
        return `${quality}/itag ${format.itag}`;
      }).join("\u3001");
      const streaming = info.streaming_data || {};
      const formats = [...streaming.formats || []];
      const adaptive = [...streaming.adaptive_formats || []];
      const existingSources = new Set(
        [...formats, ...adaptive].filter(hasYoutubeFormatSource).map((format) => `${format.itag}:${format.xtags || ""}`)
      );
      let capturedCount = 0;
      for (const format of captured) {
        const key = `${format.itag}:${format.xtags || ""}`;
        if (existingSources.has(key)) continue;
        if (format.has_video && format.has_audio) formats.push(format);
        else adaptive.push(format);
        existingSources.add(key);
        capturedCount += 1;
      }
      return {
        info: {
          ...info,
          streaming_data: {
            ...streaming,
            formats,
            adaptive_formats: adaptive
          }
        },
        capturedCount,
        observedCount: captured.length,
        capturedSummary
      };
    }
    function normalizeXMediaUrl(rawUrl) {
      let url;
      try {
        url = new URL(String(rawUrl));
      } catch {
        return null;
      }
      if (url.hostname.toLowerCase() !== "video.twimg.com") return null;
      if (url.searchParams.has("sq") || url.searchParams.has("segment")) return null;
      ["range", "rn", "rbuf"].forEach((key) => url.searchParams.delete(key));
      const path = url.pathname.toLowerCase();
      const type = path.includes(".m3u8") ? "hls" : path.includes(".mp4") ? "mp4" : null;
      if (!type) return null;
      return { url: url.href, type };
    }
    function rememberXMedia(rawUrl, startTime = performance.now(), associate = true) {
      const normalized = normalizeXMediaUrl(rawUrl);
      if (!normalized) return;
      const entry = {
        url: normalized.url,
        type: normalized.type,
        seenAt: Number(startTime) || performance.now()
      };
      state.xMedia.set(normalized.url, entry);
      if (associate) associateXMediaWithActiveContext(entry);
      if (state.xMedia.size > 300) {
        const oldest = [...state.xMedia.entries()].sort((a, b) => a[1].seenAt - b[1].seenAt).slice(0, state.xMedia.size - 300);
        oldest.forEach(([key]) => state.xMedia.delete(key));
      }
    }
    function scanPerformanceForXMedia() {
      for (const entry of performance.getEntriesByType("resource")) {
        rememberXMedia(entry.name, entry.startTime, false);
      }
    }
    try {
      const mediaObserver = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          rememberYoutubeMedia(entry.name, entry.startTime);
          rememberXMedia(entry.name, entry.startTime);
        }
      });
      mediaObserver.observe({ type: "resource", buffered: true });
    } catch {
    }
    installYoutubeNetworkCapture();
    installXNetworkCapture();
    function getRecentXMedia() {
      scanPerformanceForXMedia();
      return [...state.xMedia.values()].sort((a, b) => b.seenAt - a.seenAt);
    }
    function getXMediaFamilyKey(rawUrl) {
      try {
        const path = new URL(String(rawUrl)).pathname;
        const match = path.match(/\/(amplify_video|ext_tw_video|tweet_video)(?:_thumb)?\/(\d+)/i);
        return match ? `${match[1].toLowerCase()}/${match[2]}` : "";
      } catch {
        return "";
      }
    }
    function getXMediaDimensions(rawUrl) {
      try {
        const match = new URL(String(rawUrl)).pathname.match(
          /(?:^|\/)(\d{2,5})x(\d{2,5})(?:\/|$)/i
        );
        return match ? { width: Number(match[1]), height: Number(match[2]) } : null;
      } catch {
        return null;
      }
    }
    function getXContextActivity(context) {
      let best = null;
      const viewportWidth = Math.max(0, window.innerWidth);
      const viewportHeight = Math.max(0, window.innerHeight);
      const now = performance.now();
      for (const video of getXContextVideoElements(context)) {
        if (!video.isConnected) continue;
        const rect = video.getBoundingClientRect();
        const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
        const visibleArea = visibleWidth * visibleHeight;
        if (!visibleArea) continue;
        const playing = !video.paused && video.readyState > 0;
        const recentlyActive = context.lastActiveAt > 0 && now - context.lastActiveAt < 3e4;
        const score = (playing ? 1e9 : recentlyActive ? 5e8 : 0) + visibleArea;
        if (!best || score > best.score) best = { score, video };
      }
      return best;
    }
    function associateXMediaWithActiveContext(entry) {
      let active = null;
      for (const context of state.xContexts) {
        const activity = getXContextActivity(context);
        if (activity && (!active || activity.score > active.activity.score)) {
          active = { context, activity };
        }
      }
      if (!active || active.activity.score < 5e8) return;
      active.context.capturedMediaUrls.add(entry.url);
      active.context.lastMediaAt = performance.now();
    }
    function getXContextVideoElements(context) {
      const elements = /* @__PURE__ */ new Set();
      const player = context?.player;
      if (player?.matches?.("video")) elements.add(player);
      player?.querySelectorAll?.("video").forEach((video) => elements.add(video));
      if (!elements.size) {
        for (const video of context?.videoElements || []) elements.add(video);
        if (context?.article?.querySelectorAll) {
          context.article.querySelectorAll("video").forEach((video) => elements.add(video));
        }
      }
      return [...elements].filter((video) => video?.tagName === "VIDEO");
    }
    function getXVideoReferenceValues(video) {
      const values = [
        video.currentSrc,
        video.src,
        video.getAttribute("src"),
        video.getAttribute("data-src"),
        video.getAttribute("data-url"),
        video.poster,
        video.getAttribute("poster"),
        video.getAttribute("data-poster")
      ];
      video.querySelectorAll?.("source[src], source[data-src]").forEach((source) => {
        values.push(source.src, source.getAttribute("src"), source.getAttribute("data-src"));
      });
      return values.filter(Boolean);
    }
    function getXVideoSourceUrls(video) {
      const urls = /* @__PURE__ */ new Set();
      for (const value of getXVideoReferenceValues(video)) {
        const normalized = normalizeXMediaUrl(value);
        if (normalized) urls.add(normalized.url);
      }
      return urls;
    }
    function getXContextReferenceValues(context) {
      const values = [];
      const root = context?.player;
      if (!root) return values;
      values.push(
        root.getAttribute?.("data-url"),
        root.getAttribute?.("data-src"),
        root.getAttribute?.("poster")
      );
      root.querySelectorAll?.("img[src], img[data-src], [data-url], [data-src]").forEach((element) => {
        values.push(
          element.currentSrc,
          element.src,
          element.getAttribute("src"),
          element.getAttribute("data-src"),
          element.getAttribute("data-url")
        );
      });
      return values.filter(Boolean);
    }
    function getXMediaForContext(context) {
      const media = getRecentXMedia();
      if (!context) return media;
      if (context.mediaUrls?.size && context.player && !context.player.isConnected) {
        return media.filter((item) => context.mediaUrls.has(item.url));
      }
      const videos = getXContextVideoElements(context);
      const sourceUrls = /* @__PURE__ */ new Set();
      const familyKeys = /* @__PURE__ */ new Set();
      const dimensions = [];
      for (const video of videos) {
        const referenceValues = getXVideoReferenceValues(video);
        getXVideoSourceUrls(video).forEach((url) => {
          sourceUrls.add(url);
        });
        for (const value of referenceValues) {
          const family = getXMediaFamilyKey(value);
          if (family) familyKeys.add(family);
        }
        const rect = video.getBoundingClientRect?.();
        const width = Number(video.videoWidth || video.clientWidth || rect?.width || 0);
        const height = Number(video.videoHeight || video.clientHeight || rect?.height || 0);
        if (width > 0 && height > 0) dimensions.push({ width, height });
      }
      for (const value of getXContextReferenceValues(context)) {
        const family = getXMediaFamilyKey(value);
        if (family) familyKeys.add(family);
      }
      const scored = media.map((item) => {
        let score = 0;
        if (sourceUrls.has(item.url)) score = 1e3;
        if (context.capturedMediaUrls?.has(item.url)) score = Math.max(score, 900);
        const family = getXMediaFamilyKey(item.url);
        if (family && familyKeys.has(family)) score = Math.max(score, 800);
        const itemDimensions = getXMediaDimensions(item.url);
        if (itemDimensions && dimensions.some(
          (size) => size.width === itemDimensions.width && size.height === itemDimensions.height || Math.abs(
            size.width / size.height - itemDimensions.width / itemDimensions.height
          ) < 0.04
        )) {
          score = Math.max(score, 350);
        }
        return { item, score };
      }).filter(({ score }) => score > 0).sort((a, b) => b.score - a.score || b.item.seenAt - a.item.seenAt).map(({ item }) => item);
      const activity = getXContextActivity(context);
      const captureSince = context.lastActiveAt > 0 ? context.lastActiveAt - 6e4 : Number(context.createdAt || 0);
      const activeRecent = activity && activity.score >= 5e8 && captureSince > 0 ? media.filter((item) => item.seenAt >= captureSince).slice(0, 40) : [];
      if (scored.length || activeRecent.length) {
        const selected = [
          ...scored,
          ...activeRecent.filter((item) => !scored.some((entry) => entry.url === item.url))
        ];
        selected.sort((a, b) => {
          const typeScore = (item) => item.type === "hls" ? 1 : 0;
          return typeScore(b) - typeScore(a) || b.seenAt - a.seenAt;
        });
        context.mediaUrls = new Set(selected.map((item) => item.url));
        return selected;
      }
      if (context.mediaUrls?.size) {
        return media.filter((item) => context.mediaUrls.has(item.url));
      }
      return [];
    }
    function readAscii(bytes, start, length) {
      return String.fromCharCode(...bytes.slice(start, start + length));
    }
    function scanMp4Boxes(bytes) {
      const boxes = /* @__PURE__ */ new Set();
      const completeBoxes = /* @__PURE__ */ new Set();
      let offset = 0;
      let complete = true;
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      while (offset + 8 <= bytes.length) {
        let size = view.getUint32(offset);
        const type = readAscii(bytes, offset + 4, 4);
        boxes.add(type);
        if (size === 1) {
          if (offset + 16 > bytes.length) {
            complete = false;
            break;
          }
          const high = view.getUint32(offset + 8);
          const low = view.getUint32(offset + 12);
          size = high * 2 ** 32 + low;
        } else if (size === 0) {
          size = bytes.length - offset;
        }
        if (!Number.isSafeInteger(size) || size < 8 || offset + size > bytes.length) {
          complete = false;
          break;
        }
        completeBoxes.add(type);
        offset += size;
      }
      if (offset !== bytes.length) complete = false;
      return { boxes, complete, completeBoxes };
    }
    function parseContentRange(value) {
      const match = String(value || "").match(/^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/i);
      if (!match) return null;
      return {
        start: Number(match[1]),
        end: Number(match[2]),
        total: match[3] === "*" ? null : Number(match[3])
      };
    }
    function parseContentDispositionFilename(value) {
      const text = String(value || "");
      const encoded = text.match(/filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i)?.[1];
      const plain = text.match(/filename\s*=\s*"([^"]+)"/i)?.[1] || text.match(/filename\s*=\s*([^;]+)/i)?.[1];
      const candidate = encoded || plain;
      if (!candidate) return "";
      try {
        return sanitizeFilename(decodeURIComponent(candidate.trim().replace(/^"|"$/g, "")));
      } catch {
        return sanitizeFilename(candidate.trim().replace(/^"|"$/g, ""));
      }
    }
    async function inspectXMp4(url) {
      assertAllowedNetworkUrl(url);
      const response = await gmFetch(url, {
        headers: { Range: "bytes=0-524287" }
      });
      if (!response.ok && response.status !== 206) {
        throw new Error(isChinese ? `\u65E0\u6CD5\u8BFB\u53D6 X MP4 \u5934\u90E8\uFF08HTTP ${response.status}\uFF09\u3002` : `Cannot read X MP4 header (HTTP ${response.status}).`);
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length < 16) throw new Error(isChinese ? "X MP4 \u5934\u90E8\u8FC7\u77ED\uFF0C\u65E0\u6CD5\u8BC6\u522B\u3002" : "X MP4 header is too short to identify.");
      const scanned = scanMp4Boxes(bytes);
      const boxes = scanned.boxes;
      const majorBrand = readAscii(bytes, 8, 4).toLowerCase();
      const compatibleBrands = [];
      for (let offset = 16; offset + 4 <= Math.min(bytes.length, 128); offset += 4) {
        compatibleBrands.push(readAscii(bytes, offset, 4).toLowerCase());
      }
      const contentRange = parseContentRange(response.headers.get("content-range"));
      const contentLength = Number(response.headers.get("content-length"));
      const totalBytes = contentRange?.total || (Number.isFinite(contentLength) ? contentLength : null);
      const hasCompleteMdat = scanned.completeBoxes.has("mdat");
      const hasMediaData = boxes.has("moof") || hasCompleteMdat || boxes.has("mdat") && (response.status === 200 || totalBytes == null || totalBytes > bytes.length);
      return {
        boxes,
        bytesRead: bytes.length,
        totalBytes: Number.isFinite(totalBytes) && totalBytes > 0 ? totalBytes : null,
        probeComplete: scanned.complete,
        hasMoov: boxes.has("moov"),
        hasMdat: boxes.has("mdat"),
        hasCompleteMdat,
        hasMediaData,
        suggestedName: parseContentDispositionFilename(response.headers.get("content-disposition")),
        fragmented: boxes.has("sidx") || boxes.has("moof") || majorBrand === "dash" || compatibleBrands.includes("dash"),
        majorBrand
      };
    }
    const gmMediaFetch = boundedRangeFetch(gmFetch);
    function createRemoteInput(url, formats = ALL_FORMATS, concurrency = state.downloadConcurrency) {
      assertAllowedNetworkUrl(url);
      return new Input({
        source: new UrlSource(url, {
          fetchFn: gmMediaFetch,
          maxCacheSize: 16 * 1024 * 1024,
          parallelism: concurrency,
          getRetryDelay(previousAttempts) {
            return previousAttempts >= 4 ? null : Math.min(2 ** previousAttempts, 8);
          }
        }),
        formats
      });
    }
    async function chooseOutputForTracks(videoTrack, audioTrack, preferredKind = null) {
      const [videoCodec, audioCodec] = await Promise.all([
        videoTrack.getCodec(),
        audioTrack.getCodec()
      ]);
      if (!videoCodec || !audioCodec) {
        throw new Error(isChinese ? `\u65E0\u6CD5\u8BC6\u522B\u7F16\u7801\uFF1Avideo=${videoCodec}, audio=${audioCodec}` : `Unrecognized codecs: video=${videoCodec}, audio=${audioCodec}`);
      }
      const candidates = preferredKind === "webm" ? [new WebMOutputFormat(), new Mp4OutputFormat()] : [new Mp4OutputFormat(), new WebMOutputFormat()];
      for (const format of candidates) {
        const videoOk = format.getSupportedVideoCodecs().includes(videoCodec);
        const audioOk = format.getSupportedAudioCodecs().includes(audioCodec);
        if (videoOk && audioOk) {
          return {
            format,
            extension: format instanceof WebMOutputFormat ? "webm" : "mp4",
            videoCodec,
            audioCodec
          };
        }
      }
      throw new Error(isChinese ? `\u6CA1\u6709\u53EF\u76F4\u63A5\u5C01\u88C5 ${videoCodec} + ${audioCodec} \u7684 MP4/WebM \u5BB9\u5668\u3002` : `No MP4/WebM container supports remuxing ${videoCodec} + ${audioCodec} directly.`);
    }
    async function remuxTracksToFile({
      videoTrack,
      audioTrack,
      inputs,
      fileHandle,
      preferredKind,
      expectedBytes = 0,
      onProgress,
      task = null
    }) {
      const [videoConfig, audioConfig, outputChoice] = await Promise.all([
        videoTrack.getDecoderConfig(),
        audioTrack.getDecoderConfig(),
        chooseOutputForTracks(videoTrack, audioTrack, preferredKind)
      ]);
      if (!videoConfig) throw new Error(isChinese ? "\u65E0\u6CD5\u8BFB\u53D6\u89C6\u9891\u8F68 DecoderConfig\u3002" : "Cannot read video DecoderConfig.");
      if (!audioConfig) throw new Error(isChinese ? "\u65E0\u6CD5\u8BFB\u53D6\u97F3\u9891\u8F68 DecoderConfig\u3002" : "Cannot read audio DecoderConfig.");
      const videoSource = new EncodedVideoPacketSource(outputChoice.videoCodec);
      const audioSource = new EncodedAudioPacketSource(outputChoice.audioCodec);
      const writable = await fileHandle.createWritable();
      const target = new StreamTarget(writable, {
        chunked: true,
        chunkSize: 2 ** 20
      });
      const output = new Output({
        format: outputChoice.format,
        target
      });
      output.addVideoTrack(videoSource);
      output.addAudioTrack(audioSource);
      let maxWritten = 0;
      let lastUi = 0;
      const stopWriteListener = target.on("write", ({ end }) => {
        maxWritten = Math.max(maxWritten, Number(end) || 0);
        const now = performance.now();
        if (now - lastUi < 150) return;
        lastUi = now;
        if (typeof onProgress === "function") {
          const ratio = expectedBytes > 0 ? Math.min(maxWritten / expectedBytes, 0.995) : null;
          onProgress({ bytes: maxWritten, ratio });
        }
      });
      const videoSink = new EncodedPacketSink(videoTrack);
      const audioSink = new EncodedPacketSink(audioTrack);
      const copyTrack = async (sink, source, decoderConfig) => {
        let first = true;
        for await (const packet of sink.packets()) {
          await waitForDownloadTask(task);
          if (first) {
            await source.add(packet, { decoderConfig });
            first = false;
          } else {
            await source.add(packet);
          }
        }
        source.close();
      };
      try {
        await waitForDownloadTask(task);
        await output.start();
        await Promise.all([
          copyTrack(videoSink, videoSource, videoConfig),
          copyTrack(audioSink, audioSource, audioConfig)
        ]);
        await output.finalize();
        if (typeof onProgress === "function") {
          onProgress({ bytes: maxWritten, ratio: 1 });
        }
        return outputChoice;
      } catch (error) {
        try {
          if (output.state === "pending" || output.state === "started" || output.state === "finalizing") {
            await output.cancel();
          }
        } catch {
        }
        throw error;
      } finally {
        try {
          stopWriteListener?.();
        } catch {
        }
        for (const input of inputs || []) {
          try {
            input.dispose();
          } catch {
          }
        }
      }
    }
    async function remuxYoutubeFormat(info, videoFormat, audioFormat, fileHandle, onProgress, task = null) {
      const [videoUrl, audioUrl] = await Promise.all([
        decipherYoutubeFormat(info, videoFormat),
        decipherYoutubeFormat(info, audioFormat)
      ]);
      const videoInput = createRemoteInput(videoUrl, ALL_FORMATS, task?.concurrency);
      const audioInput = createRemoteInput(audioUrl, ALL_FORMATS, task?.concurrency);
      let videoTrack;
      let audioTrack;
      try {
        [videoTrack, audioTrack] = await Promise.all([
          videoInput.getPrimaryVideoTrack(),
          audioInput.getPrimaryAudioTrack()
        ]);
      } catch (error) {
        videoInput.dispose();
        audioInput.dispose();
        throw error;
      }
      if (!videoTrack || !audioTrack) {
        videoInput.dispose();
        audioInput.dispose();
        if (!videoTrack) throw new Error(isChinese ? "YouTube \u89C6\u9891\u6D41\u4E2D\u627E\u4E0D\u5230\u89C6\u9891\u8F68\u3002" : "No video track found in the YouTube video stream.");
        throw new Error(isChinese ? "YouTube \u97F3\u9891\u6D41\u4E2D\u627E\u4E0D\u5230\u97F3\u9891\u8F68\u3002" : "No audio track found in the YouTube audio stream.");
      }
      return await remuxTracksToFile({
        videoTrack,
        audioTrack,
        inputs: [videoInput, audioInput],
        fileHandle,
        preferredKind: mimeContainer(videoFormat.mime_type),
        expectedBytes: Number(videoFormat.content_length || 0) + Number(audioFormat.content_length || 0),
        onProgress,
        task
      });
    }
    function youtubeSabrClientInfo(info) {
      const client = info?.actions?.session?.context?.client || state.youtubeSessionClient || {};
      const clientName = typeof client.clientName === "number" ? client.clientName : YOUTUBE_CLIENT_NAME_IDS[client.clientName] || YOUTUBE_CLIENT_NAME_IDS.WEB;
      const screenWidth = Number(window.screen?.width || window.innerWidth || 0) || void 0;
      const screenHeight = Number(window.screen?.height || window.innerHeight || 0) || void 0;
      const pixelRatio = Number(window.devicePixelRatio);
      const validPixelRatio = Number.isFinite(pixelRatio) && pixelRatio > 0 && pixelRatio <= 2147483647;
      return {
        clientName,
        clientVersion: client.clientVersion || "2.20260623.01.00",
        acceptLanguage: client.hl || navigator.language || "en-US",
        acceptRegion: client.gl || "US",
        osName: client.osName || navigator.userAgentData?.platform || navigator.platform || "Windows",
        osVersion: client.osVersion || "",
        screenWidthPoints: screenWidth,
        screenHeightPoints: screenHeight,
        windowWidthPoints: Number(window.innerWidth || 0) || void 0,
        windowHeightPoints: Number(window.innerHeight || 0) || void 0,
        // SABR uses int32 for the legacy density and float for the exact ratio.
        // Fractional display/browser scaling (e.g. 1.5) must not reach int32.
        screenPixelDensity: validPixelRatio ? Math.max(1, Math.round(pixelRatio)) : void 0,
        screenDensityFloat: validPixelRatio ? pixelRatio : void 0,
        utcOffsetMinutes: String(-(/* @__PURE__ */ new Date()).getTimezoneOffset()),
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || ""
      };
    }
    async function decipherYoutubeServerAbrUrl(info, rawUrl) {
      const player = info?.actions?.session?.player || (await getYoutubeClient()).session.player;
      if (!player || typeof player.decipher !== "function") {
        throw new Error(isChinese ? "YouTube SABR \u7F3A\u5C11\u53EF\u7528\u7684 player URL \u89E3\u7801\u5668\u3002" : "YouTube SABR has no available player URL decipherer.");
      }
      const url = await player.decipher(rawUrl);
      if (!url) throw new Error(isChinese ? "YouTube SABR \u6CA1\u6709\u8FD4\u56DE\u53EF\u7528\u7684\u670D\u52A1\u5668\u5730\u5740\u3002" : "YouTube SABR returned no server URL.");
      assertAllowedNetworkUrl(url);
      return url;
    }
    async function youtubeSabrFetch(input, init2 = {}) {
      assertAllowedNetworkUrl(getRequestUrl(input));
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : document.defaultView || globalThis;
      const nativeFetch = pageWindow?.fetch;
      if (typeof nativeFetch === "function") {
        try {
          return await Reflect.apply(nativeFetch, pageWindow, [input, init2]);
        } catch {
        }
      }
      const client = state.youtubeSessionClient || {};
      const headers = new Headers(init2.headers || void 0);
      headers.set("origin", "https://www.youtube.com");
      headers.set("referer", "https://www.youtube.com/");
      if (client.visitorData) headers.set("x-goog-visitor-id", client.visitorData);
      if (client.clientName) {
        headers.set("x-youtube-client-name", String(
          typeof client.clientName === "number" ? client.clientName : YOUTUBE_CLIENT_NAME_IDS[client.clientName] || YOUTUBE_CLIENT_NAME_IDS.WEB
        ));
      }
      if (client.clientVersion) headers.set("x-youtube-client-version", client.clientVersion);
      return await gmFetch(input, { ...init2, headers });
    }
    async function remuxYoutubeSabrFormat(info, pair, fileHandle, onProgress, task = null) {
      const rawServerUrl = info?.streaming_data?.server_abr_streaming_url;
      const ustreamerConfig = info?.player_config?.media_common_config?.media_ustreamer_request_config?.video_playback_ustreamer_config;
      if (!rawServerUrl) throw new Error(isChinese ? "YouTube SABR \u7F3A\u5C11 serverAbrStreamingUrl\u3002" : "YouTube SABR is missing serverAbrStreamingUrl.");
      if (!ustreamerConfig) throw new Error(isChinese ? "YouTube SABR \u7F3A\u5C11\u64AD\u653E\u5668 Ustreamer \u914D\u7F6E\u3002" : "YouTube SABR is missing the player Ustreamer configuration.");
      const serverUrl = await decipherYoutubeServerAbrUrl(info, rawServerUrl);
      const durationSeconds = Number(
        info.basic_info?.duration || info.basic_info?.length_seconds || info.video_details?.length_seconds || 0
      );
      const formatPairs = getYoutubeSabrFormatPairs(info);
      const sabr = new SabrStream({
        fetch: youtubeSabrFetch,
        serverAbrStreamingUrl: serverUrl,
        videoPlaybackUstreamerConfig: ustreamerConfig,
        clientInfo: youtubeSabrClientInfo(info),
        poToken: info?.actions?.session?.po_token || state.youtubeSessionPoToken || void 0,
        durationMs: durationSeconds > 0 ? durationSeconds * 1e3 : void 0,
        formats: formatPairs.flatMap((item) => [item.video, item.audio])
      });
      let sabrFinished = false;
      sabr.on("finish", () => {
        sabrFinished = true;
      });
      const { videoStream, audioStream } = await sabr.start({
        videoFormat: pair.video,
        audioFormat: pair.audio,
        preferMP4: true,
        preferH264: true,
        maxRetries: 6
      });
      const videoInput = new Input({
        source: new ReadableStreamSource(videoStream, { maxCacheSize: 64 * 1024 * 1024 }),
        formats: ALL_FORMATS
      });
      const audioInput = new Input({
        source: new ReadableStreamSource(audioStream, { maxCacheSize: 32 * 1024 * 1024 }),
        formats: ALL_FORMATS
      });
      try {
        const [videoTrack, audioTrack] = await Promise.all([
          videoInput.getPrimaryVideoTrack(),
          audioInput.getPrimaryAudioTrack()
        ]);
        if (!videoTrack) throw new Error(isChinese ? "SABR \u89C6\u9891\u6D41\u4E2D\u627E\u4E0D\u5230\u89C6\u9891\u8F68\u3002" : "No video track found in the SABR video stream.");
        if (!audioTrack) throw new Error(isChinese ? "SABR \u97F3\u9891\u6D41\u4E2D\u627E\u4E0D\u5230\u97F3\u9891\u8F68\u3002" : "No audio track found in the SABR audio stream.");
        return await remuxTracksToFile({
          videoTrack,
          audioTrack,
          inputs: [videoInput, audioInput],
          fileHandle,
          preferredKind: mimeContainer(pair.rawVideo?.mime_type),
          expectedBytes: Number(pair.video.contentLength || 0) + Number(pair.audio.contentLength || 0),
          onProgress,
          task
        });
      } finally {
        try {
          videoInput.dispose();
        } catch {
        }
        try {
          audioInput.dispose();
        } catch {
        }
        if (!sabrFinished) {
          try {
            sabr.abort();
          } catch {
          }
        }
      }
    }
    async function analyzeXHls(url) {
      const input = createRemoteInput(url, HLS_FORMATS);
      try {
        const videoTracks = await input.getVideoTracks();
        if (!videoTracks.length) throw new Error(isChinese ? "HLS \u4E2D\u6CA1\u6709\u89C6\u9891\u8F68\u3002" : "No video track found in HLS.");
        const enriched = await Promise.all(videoTracks.map(async (track) => ({
          track,
          width: await track.getDisplayWidth(),
          height: await track.getDisplayHeight(),
          bitrate: await track.getAverageBitrate() || await track.getBitrate() || 0
        })));
        enriched.sort(
          (a, b) => (b.height || 0) - (a.height || 0) || (b.width || 0) - (a.width || 0) || (b.bitrate || 0) - (a.bitrate || 0)
        );
        const selectedVideo = enriched[0];
        const audioTrack = await selectedVideo.track.getPrimaryPairableAudioTrack() || (await input.getAudioTracks())[0] || null;
        if (!audioTrack) throw new Error(isChinese ? "HLS \u4E2D\u627E\u4E0D\u5230\u4E0E\u89C6\u9891\u5339\u914D\u7684\u97F3\u9891\u8F68\u3002" : "No matching audio track found in HLS.");
        const output = await chooseOutputForTracks(selectedVideo.track, audioTrack, "mp4");
        return {
          input,
          videoTrack: selectedVideo.track,
          audioTrack,
          width: selectedVideo.width,
          height: selectedVideo.height,
          bitrate: selectedVideo.bitrate,
          extension: output.extension,
          videoCodec: output.videoCodec,
          audioCodec: output.audioCodec
        };
      } catch (error) {
        try {
          input.dispose();
        } catch {
        }
        throw error;
      }
    }
    async function analyzeXMp4(url, relatedUrls = []) {
      const inputs = [];
      try {
        const header = await inspectXMp4(url);
        if (!header.hasMediaData) {
          throw new Error("X MP4 is only an initialization/partial segment; refresh after the video starts playing.");
        }
        const input = createRemoteInput(url, ALL_FORMATS);
        inputs.push(input);
        const videoTrack = await input.getPrimaryVideoTrack();
        if (!videoTrack) throw new Error(isChinese ? "X MP4 \u4E2D\u627E\u4E0D\u5230\u89C6\u9891\u8F68\u3002" : "No video track found in X MP4.");
        let audioTrack = await input.getPrimaryAudioTrack();
        let pairedInput = null;
        if (!audioTrack) {
          for (const candidateUrl of relatedUrls) {
            if (candidateUrl === url) continue;
            let candidateHeader;
            try {
              candidateHeader = await inspectXMp4(candidateUrl);
            } catch {
              continue;
            }
            if (!candidateHeader.hasMediaData) continue;
            const candidateInput = createRemoteInput(candidateUrl, ALL_FORMATS);
            try {
              const [candidateAudio, candidateVideos] = await Promise.all([
                candidateInput.getPrimaryAudioTrack(),
                candidateInput.getVideoTracks()
              ]);
              if (candidateAudio && candidateVideos.length === 0) {
                audioTrack = candidateAudio;
                pairedInput = candidateInput;
                inputs.push(candidateInput);
                break;
              }
            } catch {
            }
            if (pairedInput !== candidateInput) candidateInput.dispose();
          }
        }
        if (!audioTrack) {
          throw new Error(isChinese ? "X MP4 \u53EA\u6709\u89C6\u9891\u8F68\uFF0C\u672A\u627E\u5230\u53EF\u914D\u5BF9\u7684\u97F3\u9891\u8F68\uFF1B\u8BF7\u64AD\u653E\u89C6\u9891\u540E\u5237\u65B0\uFF0C\u6216\u4F7F\u7528\u68C0\u6D4B\u5230\u7684 HLS \u5165\u53E3\u3002" : "X MP4 contains video only, with no matching audio track. Play the video and refresh, or use the detected HLS source.");
        }
        const [width, height, videoCodec, audioCodec] = await Promise.all([
          videoTrack.getDisplayWidth(),
          videoTrack.getDisplayHeight(),
          videoTrack.getCodec(),
          audioTrack.getCodec()
        ]);
        if (!header.fragmented && !pairedInput && header.hasMoov && header.hasMdat && (header.hasCompleteMdat || header.totalBytes == null || header.totalBytes > header.bytesRead)) {
          inputs.forEach((entry) => entry.dispose());
          return {
            mode: "direct",
            width,
            height,
            videoCodec,
            audioCodec,
            totalBytes: header.totalBytes,
            suggestedName: header.suggestedName
          };
        }
        const output = await chooseOutputForTracks(videoTrack, audioTrack, "mp4");
        return {
          mode: "remux",
          inputs,
          videoTrack,
          audioTrack,
          width,
          height,
          videoCodec,
          audioCodec,
          totalBytes: header.totalBytes,
          extension: output.extension,
          suggestedName: header.suggestedName,
          fragmented: header.fragmented,
          paired: Boolean(pairedInput)
        };
      } catch (error) {
        inputs.forEach((entry) => {
          try {
            entry.dispose();
          } catch {
          }
        });
        throw error;
      }
    }
    function getSavePickerWindow() {
      const pageWindow = typeof unsafeWindow !== "undefined" ? unsafeWindow : window;
      return typeof pageWindow.showSaveFilePicker === "function" ? pageWindow : null;
    }
    async function pickSaveFile(suggestedName, extension) {
      const pickerWindow = getSavePickerWindow();
      if (!pickerWindow) {
        throw new Error(isChinese ? "\u5F53\u524D\u6D4F\u89C8\u5668\u4E0D\u652F\u6301 File System Access API\u30021080p+ \u6D4F\u89C8\u5668\u5185\u5408\u5E76\u5EFA\u8BAE\u4F7F\u7528\u6700\u65B0\u7248 Chrome/Edge\u3002" : "This browser does not support the File System Access API. Use a current Chrome/Edge version for local 1080p+ merging.");
      }
      const mime = extension === "webm" ? "video/webm" : "video/mp4";
      return await Reflect.apply(pickerWindow.showSaveFilePicker, pickerWindow, [{
        suggestedName,
        types: [{
          description: extension.toUpperCase(),
          accept: { [mime]: [`.${extension}`] }
        }]
      }]);
    }
    async function downloadRemoteToFile(url, fileHandle, task, expectedBytes = 0, onProgress) {
      assertAllowedNetworkUrl(url);
      const requestUrl = new URL(url);
      ["range", "rn", "rbuf"].forEach((parameter) => requestUrl.searchParams.delete(parameter));
      const handled = await downloadRanges({
        url: requestUrl.href,
        fileHandle,
        task,
        fetchFn: gmFetch,
        waitForTask: waitForDownloadTask,
        concurrency: task.concurrency,
        onProgress
      });
      if (handled) return;
      const writer = await fileHandle.createWritable();
      const chunkSize = 4 * 1024 * 1024;
      let position = 0;
      let total = Number(expectedBytes) > 0 ? Number(expectedBytes) : 0;
      let closed = false;
      const report = () => {
        if (typeof onProgress !== "function") return;
        onProgress({
          loaded: position,
          total,
          ratio: total > 0 ? Math.min(position / total, 1) : null
        });
      };
      try {
        while (true) {
          await waitForDownloadTask(task);
          if (total > 0 && position >= total) break;
          const end = total > 0 ? Math.min(total - 1, position + chunkSize - 1) : position + chunkSize - 1;
          const controller = new AbortController();
          task.controller = controller;
          let response;
          try {
            response = await gmFetch(requestUrl.href, {
              headers: { Range: `bytes=${position}-${end}` },
              signal: controller.signal
            });
          } catch (error) {
            if (task.paused && !task.cancelRequested && error?.name === "AbortError") {
              await waitForDownloadTask(task);
              continue;
            }
            throw error;
          } finally {
            if (task.controller === controller) task.controller = null;
          }
          const contentRange = parseContentRange(response.headers.get("content-range"));
          if (response.status === 416 && contentRange?.total != null && position >= contentRange.total) {
            total = contentRange.total;
            break;
          }
          if (!response.ok && response.status !== 206) {
            throw new Error(isChinese ? `\u4E0B\u8F7D\u5A92\u4F53\u5931\u8D25\uFF08HTTP ${response.status}\uFF09\u3002` : `Media download failed (HTTP ${response.status}).`);
          }
          const bytes = new Uint8Array(await response.arrayBuffer());
          await waitForDownloadTask(task);
          if (!bytes.length) throw new Error(isChinese ? "\u4E0B\u8F7D\u8FD4\u56DE\u4E86\u7A7A\u6570\u636E\u3002" : "The download returned empty data.");
          if (response.status === 200) {
            if (position !== 0) throw new Error(isChinese ? "\u5A92\u4F53\u670D\u52A1\u5668\u672A\u652F\u6301\u65AD\u70B9\u7EED\u4F20\uFF0C\u65E0\u6CD5\u7EE7\u7EED\u6682\u505C\u540E\u7684\u4E0B\u8F7D\u3002" : "The media server does not support range requests; the paused download cannot resume.");
            total = bytes.length;
            await writer.write(bytes);
            position = bytes.length;
            report();
            break;
          }
          if (contentRange?.start != null && contentRange.start !== position) {
            throw new Error(isChinese ? `\u5A92\u4F53\u5206\u7247\u8D77\u70B9\u5F02\u5E38\uFF1A\u671F\u671B ${position}\uFF0C\u5B9E\u9645 ${contentRange.start}\u3002` : `Unexpected media range start: expected ${position}, received ${contentRange.start}.`);
          }
          if (contentRange?.total != null) total = contentRange.total;
          await writer.write({ type: "write", position, data: bytes });
          position += bytes.length;
          if (!total && bytes.length < chunkSize) total = position;
          report();
        }
        await writer.close();
        closed = true;
        report();
      } catch (error) {
        if (!closed) {
          try {
            await writer.abort();
          } catch {
          }
        }
        throw error;
      }
    }
    function directDownload(url, name, onProgress, task = null) {
      assertAllowedNetworkUrl(url);
      return new Promise((resolve, reject) => {
        const fail = (error) => {
          const code = error?.error || "not_succeeded";
          const hints = {
            not_enabled: isChinese ? "Tampermonkey \u4E0B\u8F7D\u529F\u80FD\u672A\u542F\u7528" : "Tampermonkey downloads are disabled",
            not_whitelisted: isChinese ? "\u6587\u4EF6\u6269\u5C55\u540D\u672A\u5217\u5165 Tampermonkey \u4E0B\u8F7D\u767D\u540D\u5355" : "The file extension is not allowed in Tampermonkey download settings",
            not_permitted: isChinese ? "Tampermonkey \u6CA1\u6709\u6D4F\u89C8\u5668\u4E0B\u8F7D\u6743\u9650" : "Tampermonkey lacks browser download permission",
            not_supported: isChinese ? "\u5F53\u524D\u6D4F\u89C8\u5668\u6216\u4E0B\u8F7D\u6A21\u5F0F\u4E0D\u652F\u6301 GM_download" : "This browser or download mode does not support GM_download",
            not_succeeded: isChinese ? "\u4E0B\u8F7D\u6CA1\u6709\u6210\u529F\u542F\u52A8\u6216\u5DF2\u5931\u8D25" : "The download failed to start or failed during transfer"
          };
          reject(new Error(isChinese ? `\u76F4\u63A5\u4E0B\u8F7D\u5931\u8D25\uFF1A${hints[code] || code}${error?.details ? isChinese ? `\uFF1B${error.details}` : `; ${error.details}` : ""}` : `Direct download failed: ${hints[code] || code}${error?.details ? isChinese ? `\uFF1B${error.details}` : `; ${error.details}` : ""}`));
        };
        try {
          const download = GM_download({
            url,
            name,
            saveAs: true,
            conflictAction: "uniquify",
            onprogress(event) {
              if (typeof onProgress !== "function") return;
              const loaded = Number(event?.loaded || 0);
              const total = Number(event?.total || 0);
              onProgress({
                loaded,
                total,
                ratio: total > 0 ? Math.min(loaded / total, 1) : null
              });
            },
            onload(details) {
              resolve(details);
            },
            onerror: fail,
            ontimeout(error) {
              fail({ error: "not_succeeded", details: error?.details || (isChinese ? "\u4E0B\u8F7D\u8D85\u65F6" : "Download timed out") });
            }
          });
          if (task) task.cancel = () => download?.abort?.();
        } catch (error) {
          fail({ error: error?.message || "not_succeeded", details: error?.details });
        }
      });
    }
    function injectStyle() {
      if (document.getElementById(STYLE_ID)) return;
      const style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = `
      .${BUTTON_CLASS} {
        display: inline-flex !important; align-items: center !important; justify-content: center !important;
        flex: 0 0 auto !important; width: auto !important; min-width: 0 !important;
        min-height: 36px !important; padding: 0 14px !important; margin: 0 !important;
        position: relative !important; inset: auto !important;
        border: 0 !important; border-radius: 18px !important;
        background: #f1f1f1 !important; color: #0f0f0f !important;
        font: 600 13px/1.2 Arial,sans-serif !important;
        cursor: pointer !important; white-space: nowrap !important; box-shadow: none !important;
        appearance: none !important; opacity: 1 !important; visibility: visible !important;
      }
      .${BUTTON_CLASS}:hover { background: #d9d9d9 !important; }
      .ytx-youtube-shorts-slot {
        position: fixed !important; z-index: 2147483000 !important;
        display: flex !important; align-items: flex-start !important; justify-content: center !important;
        width: 72px !important; height: 72px !important; margin: 0 !important; padding: 0 !important;
        pointer-events: none !important; opacity: 1 !important; visibility: visible !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button {
        flex-direction: column !important; gap: 4px !important; width: 72px !important;
        min-height: 68px !important; padding: 0 !important; border-radius: 0 !important;
        background: transparent !important; color: #0f0f0f !important;
        font: 500 12px/1.2 Roboto,Arial,sans-serif !important;
        pointer-events: auto !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button:hover { background: transparent !important; }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-icon {
        display: inline-flex !important; align-items: center !important; justify-content: center !important;
        width: 48px !important; height: 48px !important; padding: 0 !important; border-radius: 50% !important;
        background: #f2f2f2 !important;
        color: inherit !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-icon svg {
        width: 24px !important; height: 24px !important; fill: currentColor !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-label {
        display: block !important; width: 72px !important; overflow: hidden !important;
        color: inherit !important; font: 500 12px/1.15 Roboto,Arial,sans-serif !important;
        text-align: center !important; text-overflow: ellipsis !important; white-space: nowrap !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-label.long {
        font-size: 10px !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-label.tiny {
        font-size: 9px !important;
      }
      .${BUTTON_CLASS}.ytx-youtube-shorts-button:hover .ytx-shorts-download-icon {
        background: #e5e5e5 !important;
      }
      html[dark] .${BUTTON_CLASS}.ytx-youtube-shorts-button { color: #fff !important; }
      html[dark] .${BUTTON_CLASS}.ytx-youtube-shorts-button .ytx-shorts-download-icon {
        background: #272727 !important;
      }
      html[dark] .${BUTTON_CLASS}.ytx-youtube-shorts-button:hover .ytx-shorts-download-icon {
        background: #3f3f3f !important;
      }
      .${BUTTON_CLASS}.ytx-x-button {
        min-height: 34px !important; border-radius: 17px !important;
        background: #1d9bf0 !important; color: #fff !important;
      }
      .${BUTTON_CLASS}.ytx-x-button:hover { background: #1687d4 !important; }
      .ytx-x-download-slot {
        display: flex !important; justify-content: flex-end !important; align-items: center !important;
        flex: 0 0 auto !important; width: 100% !important; min-height: 38px !important;
        margin: 6px 0 2px !important; padding: 0 4px !important;
        position: relative !important; z-index: 2 !important; box-sizing: border-box !important;
      }
      #${PANEL_ID} {
        position: fixed !important; left: 20px; top: 20px; width: 460px;
        max-width: calc(100vw - 16px); max-height: min(72vh, 720px);
        margin: 0 !important; overflow: auto; box-sizing: border-box; padding: 14px;
        border: 1px solid rgba(255,255,255,.14); border-radius: 12px;
        background: #141414; color: #eee; z-index: 2147483647 !important;
        box-shadow: 0 10px 38px rgba(0,0,0,.5);
        font: 13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;
        isolation: isolate; opacity: 1 !important; pointer-events: auto !important;
      }
      #${PANEL_ID} * { box-sizing: border-box; }
      #${PANEL_ID} .ytx-head {
        position: sticky; top: -14px; z-index: 10;
        display:flex; align-items:center; gap:8px;
        margin: -14px -14px 10px; padding: 14px;
        border-bottom: 1px solid #383838; border-radius: 12px 12px 0 0;
        background: #141414; box-shadow: 0 5px 10px rgba(0,0,0,.18);
        cursor:move; user-select:none; touch-action:none;
      }
      #${PANEL_ID} .ytx-title { font-size:15px; font-weight:700; flex:1; }
      #${PANEL_ID} .ytx-settings { margin:0 0 10px; padding:10px; border-radius:8px; background:#222; }
      #${PANEL_ID} .ytx-settings label { display:flex; align-items:center; justify-content:space-between; gap:10px; }
      #${PANEL_ID} .ytx-settings select { padding:5px 8px; border:1px solid #555; border-radius:6px; background:#333; color:#fff; }
      #${PANEL_ID} .ytx-settings-note { margin-top:6px; color:#aaa; font-size:11px; }
      #${PANEL_ID} button { border:0; border-radius:7px; padding:7px 10px; cursor:pointer; background:#333; color:#fff; }
      #${PANEL_ID} button:hover { background:#444; }
      #${PANEL_ID} .ytx-format { padding:10px; margin:7px 0; border-radius:8px; background:#292929; cursor:pointer; }
      #${PANEL_ID} .ytx-format:hover { background:#363636; }
      #${PANEL_ID} .ytx-primary { font-weight:650; font-size:14px; }
      #${PANEL_ID} .ytx-secondary { color:#aaa; margin-top:3px; font-size:12px; word-break:break-word; }
      #${PANEL_ID} .ytx-tip { color:#aaa; padding:8px 1px; }
      #${PANEL_ID} .ytx-status { margin:9px 0 2px; padding:9px; border-radius:7px; background:#222; white-space:pre-wrap; }
      #${PANEL_ID} .ytx-status.error { color:#ff9f9f; }
      #${PANEL_ID} .ytx-status.ok { color:#9fffb5; }
      #${PANEL_ID} .ytx-tasks { margin-top:10px; padding-top:9px; border-top:1px solid #383838; }
      #${PANEL_ID} .ytx-tasks-title { color:#bbb; font-weight:650; margin-bottom:6px; }
      #${PANEL_ID} .ytx-task { padding:8px; margin:5px 0; border-radius:7px; background:#222; }
      #${PANEL_ID} .ytx-task-line { display:flex; align-items:center; gap:7px; }
      #${PANEL_ID} .ytx-task-name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      #${PANEL_ID} .ytx-task-state { color:#aaa; font-size:11px; white-space:nowrap; }
      #${PANEL_ID} .ytx-task-progress { color:#aaa; margin-top:3px; font-size:11px; word-break:break-word; }
      #${PANEL_ID} .ytx-task-actions { display:flex; gap:5px; margin-top:6px; }
      #${PANEL_ID} .ytx-task-actions button { padding:4px 7px; font-size:11px; }
      #${PANEL_ID} .ytx-security { margin-top:12px; padding-top:9px; border-top:1px solid #383838; color:#888; font-size:11px; }
      #${PANEL_ID} .ytx-loading { padding:18px 4px; color:#bbb; }
    `;
      (document.head || document.documentElement).appendChild(style);
    }
    function panel() {
      return document.getElementById(PANEL_ID);
    }
    function panelBody() {
      return panel()?.querySelector('[data-role="body"]') || null;
    }
    function setBodyMessage(body, className, text) {
      const message = document.createElement("div");
      message.className = className;
      message.textContent = text;
      body.replaceChildren(message);
      return message;
    }
    function clearPanelDrag() {
      state.panelDragCleanup?.();
      state.panelDragCleanup = null;
    }
    function removePanel() {
      const p = panel();
      state.panelResizeObserver?.disconnect();
      state.panelResizeObserver = null;
      clearPanelDrag();
      try {
        p?.hidePopover?.();
      } catch {
      }
      p?.remove();
      state.activeAnchor = null;
      state.activeYoutubeVideoId = null;
      state.activeXContext = null;
      state.panelPosition = null;
      state.panelDetached = false;
    }
    function getPanelViewportMetrics(p) {
      const padding = 8;
      const viewportWidth = Math.max(0, window.innerWidth);
      const viewportHeight = Math.max(0, window.innerHeight);
      const maxWidth = Math.max(240, viewportWidth - padding * 2);
      const maxHeight = Math.max(160, viewportHeight - padding * 2);
      p.style.maxWidth = `${Math.round(maxWidth)}px`;
      p.style.maxHeight = `${Math.round(maxHeight)}px`;
      const width = Math.min(p.offsetWidth || 460, maxWidth);
      const height = Math.min(p.offsetHeight || 320, maxHeight);
      return {
        padding,
        width,
        height,
        maxLeft: Math.max(padding, viewportWidth - width - padding),
        maxTop: Math.max(padding, viewportHeight - height - padding)
      };
    }
    function clampPanelPosition(p, left, top) {
      const metrics = getPanelViewportMetrics(p);
      const safeLeft = Number.isFinite(left) ? left : metrics.padding;
      const safeTop = Number.isFinite(top) ? top : metrics.padding;
      return {
        left: Math.min(Math.max(metrics.padding, safeLeft), metrics.maxLeft),
        top: Math.min(Math.max(metrics.padding, safeTop), metrics.maxTop)
      };
    }
    function applyPanelPosition(p, left, top) {
      const position = clampPanelPosition(p, left, top);
      p.style.left = `${Math.round(position.left)}px`;
      p.style.top = `${Math.round(position.top)}px`;
      state.panelPosition = position;
      return position;
    }
    function positionPanel(anchor = state.activeAnchor) {
      const p = panel();
      if (!p) return;
      if (state.panelDetached && state.panelPosition) {
        applyPanelPosition(p, state.panelPosition.left, state.panelPosition.top);
        return;
      }
      if (!anchor?.getBoundingClientRect) {
        if (state.panelPosition) {
          applyPanelPosition(p, state.panelPosition.left, state.panelPosition.top);
        }
        return;
      }
      const rect = anchor.getBoundingClientRect();
      const { width, height, padding, maxLeft, maxTop } = getPanelViewportMetrics(p);
      const gap = 8;
      const viewportHeight = Math.max(0, window.innerHeight);
      const viewportWidth = Math.max(0, window.innerWidth);
      let left = rect.right - width;
      if (left < padding) left = rect.left;
      left = Math.min(Math.max(padding, left), maxLeft);
      const belowTop = rect.bottom + gap;
      const belowSpace = viewportHeight - belowTop - padding;
      const aboveTop = rect.top - height - gap;
      const aboveSpace = rect.top - gap - padding;
      let top;
      if (belowSpace >= height) {
        top = belowTop;
      } else if (aboveTop >= padding) {
        top = aboveTop;
      } else {
        top = belowSpace >= aboveSpace ? belowTop : aboveTop;
      }
      top = Math.min(Math.max(padding, top), maxTop);
      applyPanelPosition(p, Math.min(left, viewportWidth - width - padding), top);
    }
    function installPanelDrag(p, head) {
      let drag = null;
      const stopDragging = () => {
        drag = null;
        window.removeEventListener("pointermove", move, true);
        window.removeEventListener("pointerup", stopDragging, true);
        window.removeEventListener("pointercancel", stopDragging, true);
      };
      const move = (event) => {
        if (!drag || event.pointerId !== drag.pointerId) return;
        applyPanelPosition(
          p,
          drag.left + event.clientX - drag.startX,
          drag.top + event.clientY - drag.startY
        );
        if (event.cancelable) event.preventDefault();
      };
      const startDragging = (event) => {
        if (event.button !== 0 || event.target.closest?.("button")) return;
        const rect = p.getBoundingClientRect();
        state.panelDetached = true;
        state.panelPosition = { left: rect.left, top: rect.top };
        drag = {
          pointerId: event.pointerId,
          startX: event.clientX,
          startY: event.clientY,
          left: rect.left,
          top: rect.top
        };
        window.addEventListener("pointermove", move, true);
        window.addEventListener("pointerup", stopDragging, true);
        window.addEventListener("pointercancel", stopDragging, true);
        if (p.setPointerCapture) {
          try {
            p.setPointerCapture(event.pointerId);
          } catch {
          }
        }
        event.preventDefault();
      };
      head.addEventListener("pointerdown", startDragging);
      state.panelDragCleanup = () => {
        stopDragging();
        head.removeEventListener("pointerdown", startDragging);
      };
    }
    function setStatus(text, type = "") {
      const p = panel();
      if (!p) return;
      let status = p.querySelector('[data-role="status"]');
      if (!status) {
        status = document.createElement("div");
        status.dataset.role = "status";
        p.appendChild(status);
      }
      status.className = `ytx-status ${type}`.trim();
      status.textContent = text;
    }
    function makePanelShell(title, anchor, xContext = null) {
      removePanel();
      state.activeAnchor = anchor || null;
      state.activeXContext = xContext;
      const p = document.createElement("div");
      p.id = PANEL_ID;
      if ("popover" in p) p.setAttribute("popover", "manual");
      const head = document.createElement("div");
      head.className = "ytx-head";
      head.title = isChinese ? "\u6309\u4F4F\u6807\u9898\u680F\u62D6\u52A8\u4E0B\u8F7D\u6846" : "Drag the title bar to move this panel";
      const titleElement = document.createElement("div");
      titleElement.className = "ytx-title";
      titleElement.textContent = title;
      const refreshButton = document.createElement("button");
      refreshButton.type = "button";
      refreshButton.dataset.role = "refresh";
      refreshButton.textContent = isChinese ? "\u5237\u65B0" : "Refresh";
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.dataset.role = "close";
      closeButton.textContent = isChinese ? "\u5173\u95ED" : "Close";
      const body = document.createElement("div");
      body.dataset.role = "body";
      const tasks = document.createElement("div");
      tasks.dataset.role = "tasks";
      tasks.className = "ytx-tasks";
      tasks.hidden = true;
      const security = document.createElement("div");
      security.className = "ytx-security";
      security.textContent = isChinese ? "\u8FD0\u884C\u65F6\u7F51\u7EDC\u767D\u540D\u5355\uFF1AYouTube / googlevideo.com / video.twimg.com\uFF1B\u65E0\u7B2C\u4E09\u65B9\u89E3\u6790\u7AD9\u3001\u5E7F\u544A\u3001\u7EDF\u8BA1\u3001\u8FD4\u5229\u94FE\u63A5\u3002" : "Runtime network allowlist: YouTube / googlevideo.com / video.twimg.com. No third-party parsing services, ads, analytics, or affiliate links.";
      head.append(titleElement, refreshButton, closeButton);
      const settings = document.createElement("div");
      settings.className = "ytx-settings";
      const concurrencyLabel = document.createElement("label");
      concurrencyLabel.textContent = isChinese ? "\u5355\u6587\u4EF6\u4E0B\u8F7D\u5E76\u53D1\u6570" : "Single-file download connections";
      const concurrencySelect = document.createElement("select");
      concurrencySelect.dataset.role = "concurrency";
      for (let count = 1; count <= 8; count += 1) {
        const option = document.createElement("option");
        option.value = String(count);
        option.textContent = isChinese ? `${count} \u8DEF${count === 1 ? "\uFF08\u4E32\u884C\uFF09" : ""}` : `${count}${count === 1 ? " (sequential)" : ""}`;
        concurrencySelect.appendChild(option);
      }
      concurrencySelect.value = String(state.downloadConcurrency);
      concurrencySelect.onchange = () => {
        state.downloadConcurrency = normalizeConcurrency(concurrencySelect.value);
        try {
          GM_setValue(CONCURRENCY_KEY, state.downloadConcurrency);
        } catch {
        }
        void refreshPanel().catch(showError);
      };
      concurrencyLabel.appendChild(concurrencySelect);
      const settingsNote = document.createElement("div");
      settingsNote.className = "ytx-settings-note";
      settingsNote.textContent = isChinese ? "\u9ED8\u8BA4 4 \u8DEF\uFF0C\u8BBE\u7F6E\u81EA\u52A8\u4FDD\u5B58\uFF0C\u5BF9\u65B0\u4EFB\u52A1\u751F\u6548\u3002\u666E\u901A\u76F4\u94FE\u5206\u5757\u5E76\u53D1\uFF1B\u5408\u5E76\u65F6\u4E3A\u6BCF\u4E2A\u5A92\u4F53\u6E90\u7684\u8BFB\u53D6\u5E76\u53D1\u4E0A\u9650\u3002SABR \u548C Tampermonkey \u76F4\u63A5\u4E0B\u8F7D\u4E0D\u9002\u7528\u3002" : "Default: 4. Saved for new tasks. Direct files use concurrent ranges; remux uses this read limit per source. Excludes SABR and Tampermonkey direct downloads.";
      settings.append(concurrencyLabel, settingsNote);
      p.append(head, settings, body, tasks, security);
      closeButton.onclick = () => {
        removePanel();
      };
      refreshButton.onclick = () => refreshPanel(true);
      (document.body || document.documentElement).appendChild(p);
      if (typeof p.showPopover === "function") {
        try {
          p.showPopover();
        } catch {
        }
      }
      installPanelDrag(p, head);
      renderDownloadTasks();
      positionPanel(anchor);
      if (typeof ResizeObserver === "function") {
        const observer = new ResizeObserver(() => {
          if (panel() !== p) {
            observer.disconnect();
            return;
          }
          positionPanel();
        });
        observer.observe(p);
        state.panelResizeObserver = observer;
      }
      return p;
    }
    function createFormatRow(primary, secondary, onClick) {
      const row = document.createElement("div");
      row.className = "ytx-format";
      const primaryElement = document.createElement("div");
      primaryElement.className = "ytx-primary";
      primaryElement.textContent = primary;
      const secondaryElement = document.createElement("div");
      secondaryElement.className = "ytx-secondary";
      secondaryElement.textContent = secondary;
      row.append(primaryElement, secondaryElement);
      row.addEventListener("click", onClick);
      return row;
    }
    async function renderYoutube(force = false) {
      const id = state.activeYoutubeVideoId || getYoutubeVideoId();
      const body = panelBody();
      if (!body) return;
      if (!id) {
        setBodyMessage(body, "ytx-tip", isChinese ? "\u8BF7\u5148\u6253\u5F00 YouTube \u89C6\u9891/Shorts \u9875\u9762\u3002" : "Open a YouTube video or Shorts page first.");
        return;
      }
      setBodyMessage(body, "ytx-loading", isChinese ? "\u6B63\u5728\u8BFB\u53D6 YouTube \u5A92\u4F53\u4FE1\u606F\u2026\u2026" : "Loading YouTube media information...");
      setStatus("");
      try {
        const loaded = await loadYoutubeInfo(id, force);
        const merged = mergeCapturedYoutubeFormats(id, loaded.info);
        const { info, capturedCount, observedCount, capturedSummary } = merged;
        const sabrInfo = loaded.sabrInfo || null;
        const sabrPairs = getYoutubeSabrFormatPairs(sabrInfo);
        const client = loaded.client;
        const formats = getYoutubeVideoFormats(info);
        const title = sanitizeFilename(info.basic_info?.title || document.title.replace(/\s*-\s*YouTube\s*$/i, ""));
        body.replaceChildren();
        const tip = document.createElement("div");
        tip.className = "ytx-tip";
        tip.textContent = isChinese ? `InnerTube client: ${client}\uFF1B\u64AD\u653E\u5668\u8BF7\u6C42\u6355\u83B7${state.youtubeNetworkCaptureInstalled ? isChinese ? "\u5DF2\u542F\u7528" : "enabled" : isChinese ? "\u4E0D\u53EF\u7528" : "unavailable"}${observedCount ? isChinese ? `\uFF1B\u89C2\u5BDF\u5230 ${observedCount} \u6761\u5A92\u4F53\u8F68\uFF0C\u65B0\u589E ${capturedCount} \u6761` : `; observed ${observedCount} media tracks, added ${capturedCount} tracks` : ""}${sabrPairs.length ? isChinese ? `\uFF1BSABR \u672C\u5730\u8F68\u9053 ${sabrPairs.length} \u6761` : `; local SABR tracks: ${sabrPairs.length} tracks` : ""}\u30021080p \u4EE5\u4E0A\u901A\u5E38\u662F\u72EC\u7ACB\u89C6\u9891\u8F68\uFF0C\u70B9\u51FB\u540E\u4F1A\u81EA\u52A8\u9009\u62E9\u540C\u5BB9\u5668\u7684\u6700\u9AD8\u8D28\u91CF\u97F3\u9891\u5E76\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5408\u5E76\u3002` : `InnerTube client: ${client}; player request capture: ${state.youtubeNetworkCaptureInstalled ? isChinese ? "\u5DF2\u542F\u7528" : "enabled" : isChinese ? "\u4E0D\u53EF\u7528" : "unavailable"}${observedCount ? isChinese ? `\uFF1B\u89C2\u5BDF\u5230 ${observedCount} \u6761\u5A92\u4F53\u8F68\uFF0C\u65B0\u589E ${capturedCount} \u6761` : `; observed ${observedCount} media tracks, added ${capturedCount} tracks` : ""}${sabrPairs.length ? isChinese ? `\uFF1BSABR \u672C\u5730\u8F68\u9053 ${sabrPairs.length} \u6761` : `; local SABR tracks: ${sabrPairs.length} tracks` : ""}. Resolutions above 1080p usually use separate video tracks. Clicking selects the highest-quality compatible audio and merges it losslessly in your browser.`;
        body.appendChild(tip);
        if (!formats.length && !sabrPairs.length) {
          body.appendChild(document.createTextNode(
            hasYoutubeSabrStreaming(info) ? isChinese ? "YouTube \u5F53\u524D\u53EA\u8FD4\u56DE SABR/\u5206\u6BB5\u6D41\uFF0C\u6CA1\u6709\u53EF\u76F4\u63A5\u89E3\u7801\u7684\u5A92\u4F53 URL\uFF1B\u5F53\u524D\u7248\u672C\u4E0D\u4F1A\u628A\u5B83\u4F2A\u88C5\u6210\u53EF\u4E0B\u8F7D\u9879\u3002" : "YouTube returned only SABR/segmented streams with no directly decipherable media URL. These cannot be listed as downloadable formats in this version." : isChinese ? "\u6CA1\u6709\u627E\u5230\u53EF\u7528\u89C6\u9891\u683C\u5F0F\u3002" : "No available video formats found."
          ));
          return;
        }
        const highestHeight = Math.max(
          0,
          ...formats.map((format) => Number(format.height || 0)),
          ...sabrPairs.map((pair) => Number(pair.video.height || 0))
        );
        if (highestHeight <= 360) {
          const captureHint = document.createElement("div");
          captureHint.className = "ytx-tip";
          captureHint.textContent = isChinese ? `\u4ECD\u53EA\u6709 360p\uFF1A\u8BF7\u5148\u5728 YouTube \u64AD\u653E\u5668\u4E2D\u624B\u52A8\u9009\u62E9 4K/\u6700\u9AD8\u753B\u8D28\u5E76\u64AD\u653E 3\uFF5E5 \u79D2\uFF0C\u518D\u70B9\u51FB\u201C\u5237\u65B0\u201D\uFF1B\u811A\u672C\u4F1A\u6355\u83B7\u5B9E\u9645 googlevideo \u89C6\u9891\u8F68\u548C\u97F3\u9891\u8F68\u3002${capturedSummary ? isChinese ? ` \u5F53\u524D\u89C2\u5BDF\uFF1A${capturedSummary}` : ` Currently observed: ${capturedSummary}` : isChinese ? " \u5F53\u524D\u6CA1\u6709\u89C2\u5BDF\u5230\u53EF\u8BC6\u522B\u7684 videoplayback itag\u3002" : " No recognizable videoplayback itag observed yet."}` : `Only 360p available: select 4K or the highest quality in the YouTube player, play for 3\u20135 seconds, then click Refresh. The script will capture the actual googlevideo video and audio tracks.${capturedSummary ? isChinese ? ` \u5F53\u524D\u89C2\u5BDF\uFF1A${capturedSummary}` : ` Currently observed: ${capturedSummary}` : isChinese ? " \u5F53\u524D\u6CA1\u6709\u89C2\u5BDF\u5230\u53EF\u8BC6\u522B\u7684 videoplayback itag\u3002" : " No recognizable videoplayback itag observed yet."}`;
          body.appendChild(captureHint);
        }
        const directItags = new Set(formats.map((format) => Number(format.itag)));
        const sabrOnlyPairs = sabrPairs.filter((pair) => !directItags.has(Number(pair.video.itag)));
        for (const pair of sabrOnlyPairs) {
          const rawVideo = pair.rawVideo;
          const container = mimeContainer(rawVideo.mime_type) || "mp4";
          const quality = pair.video.qualityLabel || (pair.video.height ? `${pair.video.height}p` : `itag ${pair.video.itag}`);
          const fps = rawVideo.fps ? `${rawVideo.fps}fps` : "";
          const size = formatBytes(pair.video.contentLength);
          const codec = codecLabel(rawVideo.mime_type);
          const primary = [quality, fps, container.toUpperCase(), isChinese ? "SABR \u672C\u5730\u5408\u5E76" : "SABR local merge"].filter(Boolean).join(" \xB7 ");
          const secondary = isChinese ? `${codec} \xB7 ${size} \xB7 itag ${pair.video.itag} \xB7 YouTube Server ABR\uFF0C\u6D4F\u89C8\u5668\u5185\u5408\u5E76\u97F3\u9891` : `${codec} \xB7 ${size} \xB7 itag ${pair.video.itag} \xB7 YouTube Server ABR, audio merged locally in your browser`;
          const row = createFormatRow(primary, secondary, async () => {
            try {
              const fileHandle = await pickSaveFile(
                `${title} [${quality}${fps ? ` ${fps}` : ""}].${container}`,
                container
              );
              enqueueDownload(`${title} [${quality}${fps ? ` ${fps}` : ""}].${container}`, async (task) => {
                setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u901A\u8FC7 YouTube SABR \u62C9\u53D6 ${quality} \u89C6\u9891\u548C\u97F3\u9891\u2026\u2026` : `Fetching via YouTube SABR: ${quality} video and audio...`);
                await remuxYoutubeSabrFormat(sabrInfo, pair, fileHandle, ({ bytes, ratio }) => {
                  if (ratio == null) {
                    setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u6D4F\u89C8\u5668\u5185\u5408\u5E76 SABR \u6D41\u2026\u2026
\u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Merging SABR streams locally...
Written: ${formatBytes(bytes)}`);
                  } else {
                    setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u6D4F\u89C8\u5668\u5185\u5408\u5E76 SABR \u6D41\u2026\u2026
${(ratio * 100).toFixed(1)}% \xB7 \u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Merging SABR streams locally...
${(ratio * 100).toFixed(1)}% \xB7 Written: ${formatBytes(bytes)}`);
                  }
                }, task);
                setDownloadTaskProgress(task, isChinese ? "\u5B8C\u6210\uFF1ASABR \u89C6\u9891\u548C\u97F3\u9891\u5DF2\u7ECF\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5408\u5E76\u5E76\u5199\u5165\u6587\u4EF6\u3002" : "Complete: SABR video and audio merged losslessly and saved.");
              });
            } catch (error) {
              if (error?.name !== "AbortError") showError(error);
            }
          });
          body.appendChild(row);
        }
        const preparedFormats = [];
        let rejectedFormatError = null;
        for (const format of formats) {
          const container = mimeContainer(format.mime_type);
          if (!container) continue;
          const hasSeparateAudio = !format.has_audio;
          const audio = hasSeparateAudio ? selectYoutubeAudioFormat(info, format) : null;
          if (hasSeparateAudio && !audio) continue;
          try {
            await decipherYoutubeFormat(info, format);
            if (audio) await decipherYoutubeFormat(info, audio);
            preparedFormats.push({ format, audio });
          } catch (error) {
            rejectedFormatError = error;
          }
        }
        if (!preparedFormats.length && !sabrOnlyPairs.length) {
          body.appendChild(document.createTextNode(
            rejectedFormatError?.message || (isChinese ? "YouTube \u8FD4\u56DE\u7684\u683C\u5F0F\u65E0\u6CD5\u89E3\u7801\uFF0C\u53EF\u80FD\u662F SABR/\u5206\u6BB5\u6D41\uFF1B\u6CA1\u6709\u6253\u5F00\u4FDD\u5B58\u5BF9\u8BDD\u6846\u3002" : "The YouTube format cannot be deciphered and may use SABR/segmented streaming. The save dialog was not opened.")
          ));
          return;
        }
        for (const { format, audio } of preparedFormats) {
          const container = mimeContainer(format.mime_type);
          if (!container) continue;
          const hasSeparateAudio = !format.has_audio;
          const quality = format.quality_label || (format.height ? `${format.height}p` : `itag ${format.itag}`);
          const fps = format.fps ? `${format.fps}fps` : "";
          const size = formatBytes(format.content_length);
          const codec = codecLabel(format.mime_type);
          const mode = hasSeparateAudio ? isChinese ? `\u6D4F\u89C8\u5668\u5185\u5408\u5E76 + ${codecLabel(audio.mime_type)}` : `Local merge + ${codecLabel(audio.mime_type)}` : isChinese ? "\u81EA\u5E26\u97F3\u9891\uFF0C\u76F4\u63A5\u4E0B\u8F7D" : "Includes audio, direct download";
          const flags = [format.ytx_captured ? isChinese ? "\u64AD\u653E\u5668\u6355\u83B7" : "Captured from player" : "", format.is_sr ? "SR" : "", format.is_drc ? "DRC" : ""].filter(Boolean).join(" ");
          const primary = [quality, fps, container.toUpperCase(), flags].filter(Boolean).join(" \xB7 ");
          const secondary = `${codec} \xB7 ${size} \xB7 itag ${format.itag} \xB7 ${mode}`;
          const row = createFormatRow(primary, secondary, async () => {
            try {
              if (hasSeparateAudio) {
                const extension = container;
                const fileHandle = await pickSaveFile(
                  `${title} [${quality}${fps ? ` ${fps}` : ""}].${extension}`,
                  extension
                );
                enqueueDownload(`${title} [${quality}${fps ? ` ${fps}` : ""}].${extension}`, async (task) => {
                  setDownloadTaskProgress(task, isChinese ? "\u6B63\u5728\u89E3\u6790 YouTube \u7B7E\u540D\u5E76\u51C6\u5907\u5A92\u4F53\u6D41\u2026\u2026" : "Deciphering YouTube signatures and preparing streams...");
                  await remuxYoutubeFormat(info, format, audio, fileHandle, ({ bytes, ratio }) => {
                    if (ratio == null) {
                      setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5408\u5E76\u2026\u2026
\u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Merging losslessly in your browser...
Written: ${formatBytes(bytes)}`);
                    } else {
                      setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5408\u5E76\u2026\u2026
${(ratio * 100).toFixed(1)}% \xB7 \u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Merging losslessly in your browser...
${(ratio * 100).toFixed(1)}% \xB7 Written: ${formatBytes(bytes)}`);
                    }
                  }, task);
                  setDownloadTaskProgress(task, isChinese ? "\u5B8C\u6210\uFF1A\u89C6\u9891\u548C\u97F3\u9891\u5DF2\u7ECF\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5408\u5E76\u5E76\u5199\u5165\u6587\u4EF6\u3002" : "Complete: video and audio merged losslessly and saved.");
                });
              } else {
                const name = `${title} [${quality}].${container}`;
                let fileHandle = null;
                if (getSavePickerWindow()) {
                  fileHandle = await pickSaveFile(name, container);
                }
                enqueueDownload(name, async (task) => {
                  const url = await decipherYoutubeFormat(info, format);
                  if (fileHandle) {
                    setDownloadTaskProgress(task, isChinese ? "\u6B63\u5728\u4E0B\u8F7D YouTube \u5A92\u4F53\u2026\u2026" : "Downloading YouTube media...");
                    await downloadRemoteToFile(url, fileHandle, task, Number(format.content_length || 0), ({ loaded: loaded2, total, ratio }) => {
                      setDownloadTaskProgress(task, ratio == null ? isChinese ? `\u6B63\u5728\u4E0B\u8F7D YouTube \u5A92\u4F53\u2026\u2026
\u5DF2\u63A5\u6536 ${formatBytes(loaded2)}` : `Downloading YouTube media...
Received: ${formatBytes(loaded2)}` : isChinese ? `\u6B63\u5728\u4E0B\u8F7D YouTube \u5A92\u4F53\u2026\u2026
${(ratio * 100).toFixed(1)}% \xB7 ${formatBytes(loaded2)} / ${formatBytes(total)}` : `Downloading YouTube media...
${(ratio * 100).toFixed(1)}% \xB7 ${formatBytes(loaded2)} / ${formatBytes(total)}`);
                    });
                  } else {
                    task.pauseSupported = false;
                    setDownloadTaskProgress(task, isChinese ? "\u6B63\u5728\u901A\u8FC7 Tampermonkey \u4E0B\u8F7D\u2026\u2026" : "Downloading via Tampermonkey...");
                    await directDownload(url, name, ({ loaded: loaded2, ratio }) => {
                      setDownloadTaskProgress(task, ratio == null ? isChinese ? `Tampermonkey \u6B63\u5728\u4E0B\u8F7D\u2026\u2026
\u5DF2\u63A5\u6536 ${formatBytes(loaded2)}` : `Tampermonkey is downloading...
Received: ${formatBytes(loaded2)}` : isChinese ? `Tampermonkey \u6B63\u5728\u4E0B\u8F7D\u2026\u2026
${(ratio * 100).toFixed(1)}% \xB7 \u5DF2\u63A5\u6536 ${formatBytes(loaded2)}` : `Tampermonkey is downloading...
${(ratio * 100).toFixed(1)}% \xB7 Received: ${formatBytes(loaded2)}`);
                    }, task);
                  }
                  setDownloadTaskProgress(task, isChinese ? "\u4E0B\u8F7D\u5B8C\u6210\uFF1A\u6587\u4EF6\u5DF2\u4FDD\u5B58\u5230\u672C\u673A\u3002" : "Download complete: file saved locally.");
                });
              }
            } catch (error) {
              if (error?.name !== "AbortError") showError(error);
            }
          });
          body.appendChild(row);
        }
      } catch (error) {
        body.replaceChildren();
        showError(error);
      }
    }
    async function renderX(context = state.activeXContext) {
      const body = panelBody();
      if (!body) return;
      setBodyMessage(body, "ytx-loading", isChinese ? "\u6B63\u5728\u68C0\u67E5\u5F53\u524D\u9875\u9762\u5DF2\u7ECF\u52A0\u8F7D\u7684 X \u89C6\u9891\u8D44\u6E90\u2026\u2026" : "Checking X video resources loaded on this page...");
      setStatus("");
      const media = getXMediaForContext(context);
      if (!media.length) {
        setBodyMessage(body, "ytx-tip", isChinese ? "\u8FD8\u6CA1\u6709\u68C0\u6D4B\u5230\u4E0E\u5F53\u524D\u70B9\u51FB\u89C6\u9891\u5BF9\u5E94\u7684 video.twimg.com \u5A92\u4F53\u3002\u8BF7\u5148\u64AD\u653E\u8FD9\u6761\u89C6\u9891 1\uFF5E2 \u79D2\uFF0C\u518D\u70B9\u201C\u5237\u65B0\u201D\uFF1B\u811A\u672C\u4E0D\u4F1A\u6539\u7528\u9875\u9762\u4E2D\u5176\u4ED6\u89C6\u9891\u7684\u8D44\u6E90\u3002" : "No video.twimg.com media detected for the selected video yet. Play this video for 1\u20132 seconds, then click Refresh. Other videos on the page will not be used.");
        return;
      }
      body.replaceChildren();
      const tip = document.createElement("div");
      tip.className = "ytx-tip";
      tip.textContent = context ? isChinese ? "\u53EA\u663E\u793A\u4E0E\u5F53\u524D\u70B9\u51FB\u89C6\u9891\u5BF9\u5E94\u7684\u53EF\u7528\u8D44\u6E90\u3002\u521D\u59CB\u5316\u7247\u6BB5\u3001\u5355\u72EC\u97F3\u9891\u3001\u65E0\u89C6\u9891\u8F68\u7684 HLS \u6E05\u5355\u548C\u64AD\u653E\u5668\u4E34\u65F6\u8BF7\u6C42\u4F1A\u81EA\u52A8\u9690\u85CF\u3002" : "Only available sources for the selected video are shown. Initialization segments, audio-only sources, HLS playlists without video, and temporary player requests are hidden." : isChinese ? "\u53EA\u663E\u793A\u53EF\u7528\u7684\u89C6\u9891\u6E90\u3002\u521D\u59CB\u5316\u7247\u6BB5\u3001\u5355\u72EC\u97F3\u9891\u3001\u65E0\u89C6\u9891\u8F68\u7684 HLS \u6E05\u5355\u548C\u64AD\u653E\u5668\u4E34\u65F6\u8BF7\u6C42\u4F1A\u81EA\u52A8\u9690\u85CF\u3002" : "Only available video sources are shown. Initialization segments, audio-only sources, HLS playlists without video, and temporary player requests are hidden.";
      body.appendChild(tip);
      const latest = media.slice(0, 12);
      const mp4Urls = latest.filter((entry) => entry.type === "mp4").map((entry) => entry.url);
      let hiddenCount = 0;
      for (const [itemIndex, item] of latest.entries()) {
        if (item.type === "mp4") {
          const label = item.url.match(/\/(\d+)x(\d+)\//)?.slice(1).join("\xD7") || "MP4";
          const placeholder2 = createFormatRow(isChinese ? `X \xB7 ${label} \xB7 MP4\uFF08\u5206\u6790\u4E2D\u2026\uFF09` : `X \xB7 ${label} \xB7 MP4 (analyzing...)`, isChinese ? "\u6B63\u5728\u786E\u8BA4\u662F\u5426\u4E3A\u5B8C\u6574 MP4\u3001DASH/fMP4 \u6216\u89C6\u9891\u5206\u7247\u3002" : "Checking whether this is a complete MP4, DASH/fMP4, or a media segment.", () => {
          });
          body.appendChild(placeholder2);
          try {
            const analysis = await analyzeXMp4(item.url, mp4Urls);
            const primary = `X \xB7 ${analysis.width || "?"}\xD7${analysis.height || "?"} \xB7 ${analysis.mode === "direct" ? "MP4" : isChinese ? "\u672C\u5730\u5C01\u88C5" : "Local remux"}`;
            if (analysis.mode === "direct") {
              const row = createFormatRow(primary, isChinese ? `${analysis.videoCodec || (isChinese ? "\u89C6\u9891" : "Video")} + ${analysis.audioCodec || (isChinese ? "\u97F3\u9891" : "Audio")} \xB7 \u5DF2\u786E\u8BA4\u662F\u5B8C\u6574 MP4\uFF0C\u76F4\u63A5\u4E0B\u8F7D` : `${analysis.videoCodec || (isChinese ? "\u89C6\u9891" : "Video")} + ${analysis.audioCodec || (isChinese ? "\u97F3\u9891" : "Audio")} \xB7 Complete MP4 verified, direct download`, async () => {
                try {
                  const downloadName = getXDownloadName(item, analysis, "mp4", itemIndex, context);
                  let fileHandle = null;
                  if (getSavePickerWindow()) {
                    fileHandle = await pickSaveFile(downloadName, "mp4");
                  }
                  enqueueDownload(downloadName, async (task) => {
                    if (fileHandle) {
                      setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u4E0B\u8F7D ${downloadName}\u2026` : `Downloading ${downloadName}...`);
                      await downloadRemoteToFile(item.url, fileHandle, task, Number(analysis.totalBytes || 0), ({ loaded, total, ratio }) => {
                        setDownloadTaskProgress(task, ratio == null ? isChinese ? `\u6B63\u5728\u4E0B\u8F7D ${downloadName}\u2026
\u5DF2\u63A5\u6536 ${formatBytes(loaded)}` : `Downloading ${downloadName}...
Received: ${formatBytes(loaded)}` : isChinese ? `\u6B63\u5728\u4E0B\u8F7D ${downloadName}\u2026
${(ratio * 100).toFixed(1)}% \xB7 ${formatBytes(loaded)} / ${formatBytes(total)}` : `Downloading ${downloadName}...
${(ratio * 100).toFixed(1)}% \xB7 ${formatBytes(loaded)} / ${formatBytes(total)}`);
                      });
                    } else {
                      task.pauseSupported = false;
                      setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u901A\u8FC7 Tampermonkey \u4E0B\u8F7D ${downloadName}\u2026` : `Downloading via Tampermonkey: ${downloadName}...`);
                      await directDownload(item.url, downloadName, ({ loaded, ratio }) => {
                        setDownloadTaskProgress(task, ratio == null ? isChinese ? `Tampermonkey \u6B63\u5728\u4E0B\u8F7D\u2026
\u5DF2\u63A5\u6536 ${formatBytes(loaded)}` : `Tampermonkey is downloading...
Received: ${formatBytes(loaded)}` : isChinese ? `Tampermonkey \u6B63\u5728\u4E0B\u8F7D\u2026\u2026
${(ratio * 100).toFixed(1)}% \xB7 \u5DF2\u63A5\u6536 ${formatBytes(loaded)}` : `Tampermonkey is downloading...
${(ratio * 100).toFixed(1)}% \xB7 Received: ${formatBytes(loaded)}`);
                      }, task);
                    }
                    setDownloadTaskProgress(task, isChinese ? `\u4E0B\u8F7D\u5B8C\u6210\uFF1A${downloadName}` : `Download complete: ${downloadName}`);
                  });
                } catch (error) {
                  if (error?.name !== "AbortError") showError(error);
                }
              });
              placeholder2.replaceWith(row);
              continue;
            }
            const reason = [
              analysis.fragmented ? "DASH/fMP4" : "",
              analysis.paired ? isChinese ? "\u89C6\u9891/\u97F3\u9891\u8DE8\u8D44\u6E90\u914D\u5BF9" : "Video/audio paired across sources" : ""
            ].filter(Boolean).join(" + ");
            const primaryText = `${primary}${reason ? ` \xB7 ${reason}` : ""}`;
            const secondary = isChinese ? `${analysis.videoCodec || (isChinese ? "\u89C6\u9891" : "Video")} + ${analysis.audioCodec || (isChinese ? "\u97F3\u9891" : "Audio")} \xB7 \u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5C01\u88C5` : `${analysis.videoCodec || (isChinese ? "\u89C6\u9891" : "Video")} + ${analysis.audioCodec || (isChinese ? "\u97F3\u9891" : "Audio")} \xB7 Lossless local remux`;
            placeholder2.replaceWith(createFormatRow(primaryText, secondary, async () => {
              try {
                const downloadName = getXDownloadName(item, analysis, "mp4", itemIndex, context);
                const fileHandle = await pickSaveFile(downloadName, "mp4");
                enqueueDownload(downloadName, async (task) => {
                  setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u8BFB\u53D6 X ${reason || "MP4"} \u5E76\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5C01\u88C5\u2026\u2026` : `Reading X ${reason || "MP4"} and remuxing losslessly in your browser...`);
                  await remuxTracksToFile({
                    videoTrack: analysis.videoTrack,
                    audioTrack: analysis.audioTrack,
                    inputs: analysis.inputs,
                    fileHandle,
                    preferredKind: "mp4",
                    expectedBytes: 0,
                    onProgress: ({ bytes }) => {
                      setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u8BFB\u53D6 X ${reason || "MP4"} \u5E76\u5C01\u88C5\u2026\u2026
\u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Reading X ${reason || "MP4"} and remuxing...
Written: ${formatBytes(bytes)}`);
                    },
                    task
                  });
                  setDownloadTaskProgress(task, isChinese ? "\u5B8C\u6210\uFF1AX \u89C6\u9891\u548C\u97F3\u9891\u5DF2\u5728\u6D4F\u89C8\u5668\u5185\u5C01\u88C5\u4E3A\u53EF\u64AD\u653E\u6587\u4EF6\u3002" : "Complete: X video and audio remuxed into a playable file.");
                }, { cleanup: () => analysis.inputs.forEach((input) => input.dispose()) });
              } catch (error) {
                if (error?.name !== "AbortError") showError(error);
              }
            }));
          } catch (error) {
            hiddenCount += 1;
            placeholder2.remove();
            console.debug(`[${APP}] Ignored unusable X MP4 resource`, error?.message || error);
          }
          continue;
        }
        const placeholder = createFormatRow(isChinese ? "X \xB7 HLS\uFF08\u5206\u6790\u4E2D\u2026\uFF09" : "X \xB7 HLS (analyzing...)", item.url, () => {
        });
        body.appendChild(placeholder);
        try {
          const analysis = await analyzeXHls(item.url);
          const primary = `X \xB7 ${analysis.width || "?"}\xD7${analysis.height || "?"} \xB7 ${analysis.extension.toUpperCase()}`;
          const secondary = isChinese ? `${analysis.videoCodec} + ${analysis.audioCodec} \xB7 \u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5C01\u88C5` : `${analysis.videoCodec} + ${analysis.audioCodec} \xB7 Lossless local remux`;
          placeholder.querySelector(".ytx-primary").textContent = primary;
          placeholder.querySelector(".ytx-secondary").textContent = secondary;
          placeholder.onclick = null;
          placeholder.replaceWith(createFormatRow(primary, secondary, async () => {
            try {
              const downloadName = getXDownloadName(item, analysis, analysis.extension, itemIndex, context);
              const fileHandle = await pickSaveFile(downloadName, analysis.extension);
              enqueueDownload(downloadName, async (task) => {
                setDownloadTaskProgress(task, isChinese ? "\u6B63\u5728\u8BFB\u53D6 X HLS \u5206\u7247\u5E76\u5728\u6D4F\u89C8\u5668\u5185\u65E0\u635F\u5C01\u88C5\u2026\u2026" : "Reading X HLS segments and remuxing losslessly in your browser...");
                await remuxTracksToFile({
                  videoTrack: analysis.videoTrack,
                  audioTrack: analysis.audioTrack,
                  inputs: [analysis.input],
                  fileHandle,
                  preferredKind: analysis.extension,
                  expectedBytes: 0,
                  onProgress: ({ bytes }) => {
                    setDownloadTaskProgress(task, isChinese ? `\u6B63\u5728\u8BFB\u53D6 X HLS \u5E76\u5C01\u88C5\u2026\u2026
\u5DF2\u5199\u5165 ${formatBytes(bytes)}` : `Reading and remuxing X HLS...
Written: ${formatBytes(bytes)}`);
                  },
                  task
                });
                setDownloadTaskProgress(task, isChinese ? "\u5B8C\u6210\uFF1AX \u89C6\u9891\u5DF2\u5199\u5165\u672C\u5730\u6587\u4EF6\u3002" : "Complete: X video saved locally.");
              }, { cleanup: () => analysis.input.dispose() });
            } catch (error) {
              if (error?.name !== "AbortError") showError(error);
            }
          }));
        } catch (error) {
          hiddenCount += 1;
          placeholder.remove();
          console.debug(`[${APP}] Ignored unusable X HLS resource`, error?.message || error);
        }
      }
      if (hiddenCount) {
        tip.textContent = isChinese ? `\u53EA\u663E\u793A\u53EF\u7528\u7684\u89C6\u9891\u6E90\uFF1B\u5DF2\u81EA\u52A8\u9690\u85CF ${hiddenCount} \u4E2A\u521D\u59CB\u5316\u7247\u6BB5\u3001\u5355\u72EC\u97F3\u9891\u6216\u4E0D\u53EF\u89E3\u6790\u7684\u64AD\u653E\u5668\u8BF7\u6C42\u3002` : `Only available video sources are shown; hidden ${hiddenCount} initialization segments, audio-only sources, or unparseable player requests.`;
      }
      if (!body.querySelector(".ytx-format")) {
        const empty = document.createElement("div");
        empty.className = "ytx-tip";
        empty.textContent = isChinese ? "\u5F53\u524D\u6CA1\u6709\u627E\u5230\u53EF\u72EC\u7ACB\u8BFB\u53D6\u7684\u89C6\u9891\u6E90\u3002\u8BF7\u786E\u8BA4\u89C6\u9891\u5DF2\u64AD\u653E\uFF0C\u7136\u540E\u70B9\u51FB\u201C\u5237\u65B0\u201D\uFF1B\u64AD\u653E\u5668\u4EA7\u751F\u7684\u65E0\u6548\u5206\u7247\u4E0D\u4F1A\u663E\u793A\u3002" : "No independently readable video source found. Play the video, then click Refresh. Invalid player segments are hidden.";
        body.appendChild(empty);
      }
    }
    async function refreshPanel(forceYoutube = false) {
      if (!panel()) return;
      if (isYoutubeHost()) await renderYoutube(forceYoutube);
      else if (isXHost()) await renderX(state.activeXContext);
      positionPanel();
    }
    function togglePanel(anchor, xContext = null, youtubeVideoId = null) {
      if (panel() && state.activeAnchor === anchor) {
        removePanel();
        return;
      }
      removePanel();
      state.activeYoutubeVideoId = youtubeVideoId;
      makePanelShell(isYoutubeHost() ? isChinese ? "YouTube \u76F4\u63A5\u4E0B\u8F7D" : "YouTube Direct Download" : isChinese ? "X \u76F4\u63A5\u4E0B\u8F7D" : "X Direct Download", anchor, xContext);
      void refreshPanel(false).catch((error) => showError(error));
    }
    function findContextButtonFromEvent(event) {
      const path = typeof event.composedPath === "function" ? event.composedPath() : [];
      for (const node of path) {
        if (node?.nodeType === 1 && node.matches?.(`.${BUTTON_CLASS}[data-ytx-action]`)) {
          return node;
        }
      }
      return event.target?.closest?.(`.${BUTTON_CLASS}[data-ytx-action]`) || null;
    }
    function handleContextButtonActivation(event) {
      const button = findContextButtonFromEvent(event);
      if (!button) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const now = Date.now();
      if (event.type === "click" && state.lastActivationButton === button && now - state.lastActivationAt < 600) {
        return;
      }
      state.lastActivationAt = now;
      state.lastActivationButton = button;
      const youtubeVideoId = button.dataset.ytxAction === "youtube" ? button.dataset.ytxYoutubeVideoId || getYoutubeVideoId() : null;
      togglePanel(
        button,
        button.dataset.ytxAction === "x" ? getXButtonContext(button) : null,
        youtubeVideoId
      );
    }
    function installContextButtonActivation() {
      if (state.activationInstalled) return;
      state.activationInstalled = true;
      window.addEventListener("pointerup", handleContextButtonActivation, true);
      window.addEventListener("click", handleContextButtonActivation, true);
    }
    function createContextButton(label, title, className, action) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `${BUTTON_CLASS} ${className || ""}`.trim();
      button.dataset.ytxDownloadButton = "true";
      button.dataset.ytxAction = action;
      button.setAttribute("aria-label", title);
      button.textContent = label;
      button.title = title;
      return button;
    }
    function getVisibleElementMetrics(element) {
      const rect = element.getBoundingClientRect();
      const visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));
      const visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));
      return {
        element,
        rect,
        visibleArea: visibleWidth * visibleHeight,
        distance: Math.hypot(
          rect.left + rect.width / 2 - window.innerWidth / 2,
          rect.top + rect.height / 2 - window.innerHeight / 2
        )
      };
    }
    function pickVisibleYoutubeShortsMount(elements) {
      return [...new Set(elements)].map(getVisibleElementMetrics).filter(({ element, rect, visibleArea }) => element.isConnected && rect.width > 0 && rect.height > 0 && visibleArea > 0 && getComputedStyle(element).visibility !== "hidden").sort((a, b) => b.visibleArea - a.visibleArea || a.distance - b.distance)[0]?.element || null;
    }
    function findYoutubeShortsActionBarFromControls() {
      const controls = document.querySelectorAll([
        'ytd-reel-video-renderer button[aria-label*="\u5206\u4EAB"]',
        'ytd-reel-video-renderer button[aria-label*="Share"]',
        'ytd-reel-video-renderer button[aria-label*="\u6DF7\u526A"]',
        'ytd-reel-video-renderer button[aria-label*="Remix"]',
        'ytd-shorts button[aria-label*="\u5206\u4EAB"]',
        'ytd-shorts button[aria-label*="Share"]'
      ].join(","));
      const candidates = [];
      for (const control of controls) {
        let ancestor = control.parentElement;
        for (let depth = 0; ancestor && depth < 7; depth += 1, ancestor = ancestor.parentElement) {
          const rect = ancestor.getBoundingClientRect();
          const buttonCount = ancestor.querySelectorAll('button, [role="button"]').length;
          if (rect.width <= 180 && rect.height >= 120 && buttonCount >= 3) {
            candidates.push(ancestor);
            break;
          }
        }
      }
      return pickVisibleYoutubeShortsMount(candidates);
    }
    function findActiveYoutubeShortsMount() {
      const directCandidates = [...document.querySelectorAll([
        "ytd-reel-video-renderer reel-action-bar-view-model",
        "ytd-reel-video-renderer #actions",
        'ytd-reel-video-renderer [class*="ReelActionBar"]',
        "ytd-shorts reel-action-bar-view-model",
        "ytd-shorts #actions",
        'ytd-shorts [class*="ReelActionBar"]'
      ].join(","))].filter((element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.width <= 180 && rect.height >= 120;
      });
      const direct = pickVisibleYoutubeShortsMount(directCandidates);
      if (direct) return direct;
      const inferred = findYoutubeShortsActionBarFromControls();
      if (inferred) return inferred;
      const viewportCenterX = window.innerWidth / 2;
      const viewportCenterY = window.innerHeight / 2;
      const reel = [...document.querySelectorAll("ytd-reel-video-renderer")].map((reel2) => {
        const measurable = reel2.querySelector("#short-video-container, video, ytd-player") || reel2;
        const rect = measurable.getBoundingClientRect();
        const visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));
        const visibleArea = visibleWidth * visibleHeight;
        const distance = Math.hypot(
          rect.left + rect.width / 2 - viewportCenterX,
          rect.top + rect.height / 2 - viewportCenterY
        );
        return { reel: reel2, rect, visibleArea, distance };
      }).filter(({ rect, visibleArea }) => rect.width > 0 && rect.height > 0 && visibleArea > 0).sort((a, b) => b.visibleArea - a.visibleArea || a.distance - b.distance)[0]?.reel || null;
      return reel?.querySelector('reel-action-bar-view-model, #actions, [class*="ReelActionBar"]') || null;
    }
    function createYoutubeShortsButton(videoId) {
      const title = isChinese ? "\u4E0B\u8F7D\u5F53\u524D YouTube Shorts \u89C6\u9891" : "Download this YouTube Short";
      const button = createContextButton("", title, "ytx-youtube-button ytx-youtube-shorts-button", "youtube");
      button.removeAttribute("title");
      button.dataset.ytxYoutubeVideoId = videoId;
      const icon = document.createElement("span");
      icon.className = "ytx-shorts-download-icon";
      icon.setAttribute("aria-hidden", "true");
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("viewBox", "0 0 24 24");
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.setAttribute("d", "M11 4h2v9.17l3.59-3.58L18 11l-6 6-6-6 1.41-1.41L11 13.17V4zm-5 15h12v2H6v-2z");
      svg.appendChild(path);
      icon.appendChild(svg);
      const label = document.createElement("span");
      label.className = "ytx-shorts-download-label";
      label.textContent = isChinese ? "\u76F4\u63A5\u4E0B\u8F7D" : "Direct Download";
      if (label.textContent.length > 14) label.classList.add("tiny");
      else if (label.textContent.length > 6) label.classList.add("long");
      button.append(icon, label);
      return button;
    }
    function positionYoutubeShortsSlot(slot, mount) {
      const mountRect = mount.getBoundingClientRect();
      const slotWidth = 72;
      const slotHeight = 72;
      const left = mountRect.left + (mountRect.width - slotWidth) / 2;
      const visibleControls = [...mount.children].map((element) => element.getBoundingClientRect()).filter((rect) => rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < window.innerHeight).sort((a, b) => a.top - b.top);
      const firstControlRect = visibleControls[0] || mountRect;
      const preferredTop = firstControlRect.top - slotHeight - 4;
      slot.style.left = `${Math.round(Math.max(0, Math.min(window.innerWidth - slotWidth, left)))}px`;
      slot.style.top = `${Math.round(Math.max(0, Math.min(window.innerHeight - slotHeight, preferredTop)))}px`;
    }
    function mountYoutubeShortsButton(mount, button) {
      const slot = document.createElement("div");
      slot.className = "ytx-youtube-shorts-slot";
      slot.dataset.ytxShortsOverlay = "true";
      slot.appendChild(button);
      document.body.appendChild(slot);
      positionYoutubeShortsSlot(slot, mount);
      return slot;
    }
    function ensureYoutubeButton() {
      if (!document.body) return;
      injectStyle();
      const videoId = getYoutubeVideoId();
      const isShortsPage = /^\/shorts\//.test(location.pathname);
      const existingButtons = [...document.querySelectorAll(`.${BUTTON_CLASS}.ytx-youtube-button`)];
      const existingShortsSlots = [...document.querySelectorAll(".ytx-youtube-shorts-slot")];
      if (isShortsPage) {
        const mount2 = findActiveYoutubeShortsMount();
        if (!mount2 || !videoId) {
          existingButtons.forEach((button2) => button2.remove());
          existingShortsSlots.forEach((slot) => slot.remove());
          return;
        }
        const existing2 = existingButtons.find((button2) => button2.closest(".ytx-youtube-shorts-slot"));
        const existingSlot = existing2?.closest(".ytx-youtube-shorts-slot") || null;
        existingButtons.filter((button2) => button2 !== existing2).forEach((button2) => button2.remove());
        existingShortsSlots.filter((slot) => slot !== existingSlot).forEach((slot) => slot.remove());
        if (existing2) {
          existing2.dataset.ytxYoutubeVideoId = videoId;
          positionYoutubeShortsSlot(existingSlot, mount2);
          return;
        }
        mountYoutubeShortsButton(mount2, createYoutubeShortsButton(videoId));
        return;
      }
      existingShortsSlots.forEach((slot) => slot.remove());
      const selectors = [
        "ytd-watch-metadata #top-level-buttons-computed",
        "#below #top-level-buttons-computed",
        "ytd-watch-metadata #actions-inner",
        "#below #actions-inner"
      ];
      const mount = selectors.map((selector) => document.querySelector(selector)).find(Boolean);
      if (!mount) {
        existingButtons.forEach((button2) => button2.remove());
        return;
      }
      const existing = existingButtons.find((button2) => mount.contains(button2));
      existingButtons.filter((button2) => button2 !== existing).forEach((button2) => button2.remove());
      if (existing) {
        if (videoId) existing.dataset.ytxYoutubeVideoId = videoId;
        return;
      }
      const button = createContextButton(isChinese ? "\u2193 \u9AD8\u6E05\u4E0B\u8F7D" : "\u2193 HD Download", isChinese ? "\u5728\u5F53\u524D YouTube \u89C6\u9891\u4E0B\u65B9\u6253\u5F00\u4E0B\u8F7D\u9009\u9879" : "Open download options for this YouTube video", "ytx-youtube-button", "youtube");
      if (videoId) button.dataset.ytxYoutubeVideoId = videoId;
      mount.appendChild(button);
    }
    function findXActionBar(article) {
      if (!article) return null;
      const action = article.querySelector(
        '[data-testid="reply"], [data-testid="retweet"], [data-testid="like"], [data-testid="unlike"]'
      );
      return action?.closest?.('[role="group"]') || null;
    }
    function bindXContextActivity(context) {
      context.boundVideos ||= /* @__PURE__ */ new WeakSet();
      for (const video of getXContextVideoElements(context)) {
        if (context.boundVideos.has(video)) continue;
        const markActive = () => {
          context.lastActiveAt = performance.now();
        };
        video.addEventListener("play", markActive, { passive: true });
        video.addEventListener("playing", markActive, { passive: true });
        if (!video.paused) markActive();
        context.boundVideos.add(video);
      }
    }
    function createXButtonContext(button, player, article) {
      const context = {
        button,
        player,
        article,
        videoElements: [],
        boundVideos: /* @__PURE__ */ new WeakSet(),
        capturedMediaUrls: /* @__PURE__ */ new Set(),
        mediaUrls: /* @__PURE__ */ new Set(),
        lastActiveAt: 0,
        lastMediaAt: 0,
        createdAt: performance.now()
      };
      context.videoElements = getXContextVideoElements(context);
      state.xContexts.add(context);
      bindXContextActivity(context);
      return context;
    }
    function updateXButtonContext(button, player, article) {
      let context = state.xButtonContexts.get(button);
      if (!context || context.player !== player || context.article !== article) {
        context = createXButtonContext(button, player, article);
        state.xButtonContexts.set(button, context);
      } else {
        context.videoElements = getXContextVideoElements(context);
        bindXContextActivity(context);
      }
      return context;
    }
    function getXButtonContext(button) {
      let context = state.xButtonContexts.get(button);
      if (!context) {
        context = updateXButtonContext(
          button,
          null,
          button.closest?.('article, [role="article"], [data-testid="tweet"]') || null
        );
      }
      context.videoElements = getXContextVideoElements(context);
      bindXContextActivity(context);
      return context;
    }
    function ensureXButtons() {
      if (!document.body) return;
      injectStyle();
      const tweetSelector = 'article, [role="article"], [data-testid="tweet"]';
      const players = /* @__PURE__ */ new Set([
        ...document.querySelectorAll('[data-testid="videoPlayer"], [data-testid="videoComponent"]'),
        ...[...document.querySelectorAll("video")].map((video) => video.closest('[data-testid="videoPlayer"], [data-testid="videoComponent"]') || video.parentElement).filter(Boolean)
      ]);
      for (const player of players) {
        const article = player.closest(tweetSelector);
        const existingSlot = article?.querySelector(".ytx-x-download-slot") || (player.nextElementSibling?.matches?.(".ytx-x-download-slot") ? player.nextElementSibling : null);
        const existingButton = existingSlot?.querySelector(`.${BUTTON_CLASS}.ytx-x-button`);
        if (existingButton) {
          updateXButtonContext(existingButton, player, article);
          continue;
        }
        const slot = document.createElement("div");
        slot.className = "ytx-x-download-slot";
        slot.dataset.ytxVideoDownload = "true";
        const button = createContextButton(isChinese ? "\u2193 \u89C6\u9891\u4E0B\u8F7D" : "\u2193 Download Video", isChinese ? "\u5728\u8FD9\u6761 X \u89C6\u9891\u4E0B\u65B9\u6253\u5F00\u4E0B\u8F7D\u9009\u9879" : "Open download options for this X video", "ytx-x-button", "x");
        slot.appendChild(button);
        updateXButtonContext(button, player, article);
        const actionBar = findXActionBar(article);
        if (actionBar?.parentElement) {
          actionBar.parentElement.insertBefore(slot, actionBar);
        } else if (article) {
          let topLevelMedia = player;
          while (topLevelMedia.parentElement && topLevelMedia.parentElement !== article) {
            topLevelMedia = topLevelMedia.parentElement;
          }
          topLevelMedia.insertAdjacentElement("afterend", slot);
        } else {
          player.insertAdjacentElement("afterend", slot);
        }
      }
      for (const slot of document.querySelectorAll(".ytx-x-download-slot")) {
        const owner = slot.closest(tweetSelector);
        const previous = slot.previousElementSibling;
        const hasPlayer = Boolean(
          previous?.matches?.('[data-testid="videoPlayer"], [data-testid="videoComponent"]') || previous?.querySelector?.('video, [data-testid="videoPlayer"], [data-testid="videoComponent"]') || owner?.querySelector('video, [data-testid="videoPlayer"], [data-testid="videoComponent"]')
        );
        if (!hasPlayer) slot.remove();
      }
    }
    function removeContextButtonsForOtherHost() {
      if (!isYoutubeHost()) {
        document.querySelectorAll(`.${BUTTON_CLASS}.ytx-youtube-button`).forEach((button) => button.remove());
        document.querySelectorAll(".ytx-youtube-shorts-slot").forEach((slot) => slot.remove());
      }
      if (!isXHost()) {
        document.querySelectorAll(".ytx-x-download-slot").forEach((slot) => slot.remove());
      }
    }
    function ensureContextButtons() {
      document.getElementById(`${APP}-button`)?.remove();
      removeContextButtonsForOtherHost();
      if (isYoutubeHost()) ensureYoutubeButton();
      else if (isXHost()) ensureXButtons();
    }
    function scheduleEnsureContextButtons() {
      if (state.ensureScheduled) return;
      state.ensureScheduled = true;
      requestAnimationFrame(() => {
        state.ensureScheduled = false;
        try {
          handleLocationChange();
          ensureContextButtons();
        } catch (error) {
          console.error(`[${APP}] Failed to mount context buttons`, error);
        }
      });
    }
    function observeDynamicPage() {
      if (state.domObserver || !document.body) return;
      state.domObserver = new MutationObserver(() => scheduleEnsureContextButtons());
      state.domObserver.observe(document.body, {
        childList: true,
        subtree: true
      });
      window.addEventListener("popstate", scheduleEnsureContextButtons);
      window.addEventListener("yt-navigate-finish", scheduleEnsureContextButtons);
      window.addEventListener("resize", () => positionPanel());
    }
    function handleLocationChange() {
      if (location.href === state.lastHref) return;
      state.lastHref = location.href;
      const keepXPanel = isXHost() && Boolean(panel());
      if (!keepXPanel) removePanel();
      if (isYoutubeHost()) {
        state.youtubeNavigationStartedAt = performance.now();
        state.youtubeMedia.clear();
      }
      if (isXHost()) {
        state.xMedia.clear();
        if (keepXPanel) {
          state.activeAnchor = null;
          void refreshPanel(false).catch((error) => showError(error));
        }
      }
    }
    function init() {
      if (!isYoutubeHost() && !isXHost()) return;
      ensureContextButtons();
      installYoutubeNetworkCapture();
      installXNetworkCapture();
      scanPerformanceForYoutubeMedia();
      scanPerformanceForXMedia();
      observeDynamicPage();
      setInterval(() => {
        handleLocationChange();
        ensureContextButtons();
      }, 1e3);
    }
    installContextButtonActivation();
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", init, { once: true });
    } else {
      init();
    }
  })();
})();

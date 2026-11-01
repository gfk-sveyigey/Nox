# Nox 单文件解析插件规范

> 状态：**草案 v1，导入与管理已实现**
>
> 已实现：单文件解析、元数据校验、包内插件加载、用户导入 / 更新 / 删除 / 导出、导入覆盖确认、拖动排序与动态注册表刷新、隐藏 `WKWebView` 运行时，以及 `page.eval` / `page.title` / `cookies` / `http` / `crypto` / `log` Bridge。Pornhub 已迁为包内插件。
>
> 未实现：签名校验、插件市场 / 自动更新。
>
> 本文定义单文件 `.noxplugin` 的格式、站点匹配规则、JavaScript API、安装 / 更新 / 删除流程和安全边界。实现前可以继续调整字段，但已经写入插件的字段应尽量保持向后兼容。

## 1. 目标

- 一个 `.noxplugin` 文件就是一个完整插件
- 插件包含元数据、匹配规则、权限声明、解析代码和可选签名
- 用户可以通过「文件」App 或分享菜单导入
- 导入 / 删除后立即生效，不需要重启 App
- 插件不包含原生二进制代码，不依赖动态库签名
- 插件只能访问显式声明的能力，不能直接读写文件系统

## 2. 非目标

- 不加载 `.framework` / `.dylib` 等原生代码
- 不提供每个插件独立进程
- 不允许插件直接访问 App 内部对象、数据库或下载文件
- v1 不支持插件间互相调用或依赖

## 3. 文件格式

### 3.1 基本约定

| 项目 | 规定 |
|---|---|
| 扩展名 | `.noxplugin` |
| 编码 | UTF-8，允许带 BOM |
| 文件大小 | 不超过 512 KiB |
| 元数据大小 | 不超过 32 KiB |
| 文件结构 | 元数据头 + JavaScript + 可选签名尾 |
| UTI | `com.aholic.nox.plugin`（建议） |
| MIME | `application/x-nox-plugin`（建议） |

文件仍然是纯文本，可以直接用文本编辑器打开和修改。

### 3.2 元数据头

文件开头必须有一个 `NoxPlugin` 注释块，内部是严格 JSON：

```js
/* ==NoxPlugin==
{
  "apiVersion": 1,
  "id": "com.example.example-site",
  "name": "Example Site",
  "version": "1.0.0",
  "minAppVersion": "1.4.0",
  "match": {
    "schemes": ["https"],
    "hosts": ["example.com"],
    "pathPrefixes": ["/video/"]
  },
  "permissions": ["page.eval"]
}
==NoxPlugin== */
```

规则：

- 标记必须完整匹配
- JSON 不允许注释、尾逗号和未加引号的键
- 导入时解析元数据并用 `new Function(source)` **只编译、不执行**插件代码
- 元数据或 JavaScript 语法校验失败的文件不能安装

### 3.3 JavaScript 主体

元数据头之后是插件代码。代码在受限运行时中执行，必须且只能调用一次：

```js
Nox.register({
  async parse(ctx) {
    // ...
  }
});
```

- 不允许使用 `import` / `require` / CommonJS
- 不建议在顶层执行网络请求或重计算
- `parse` 可以返回普通值或 Promise
- 返回结果必须是 JSON 可序列化数据

### 3.4 可选签名尾

签名块必须位于文件最后：

```js
/* ==NoxSignature==
{
  "alg": "Ed25519",
  "keyId": "nox-official-1",
  "value": "<base64-signature>"
}
==NoxSignature== */
```

签名规则：

- 签名对象是签名块起始标记之前的**原始 UTF-8 字节**
- 不对换行、空格或 JSON 做规范化
- v1 目前只识别并移除签名块，**不校验签名**
- 导入界面会明确提示「当前未验证插件签名，请只导入可信来源」
- 签名校验、公钥分发和 `keyId` 轮换留待后续版本
- 正式插件仓库上线前必须补上签名校验

### 3.5 完整文件示意

```text
元数据头
JavaScript 主体
可选签名尾
```

## 4. 元数据字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `apiVersion` | integer | 是 | 当前固定为 `1` |
| `id` | string | 是 | 稳定唯一 ID，启用状态和更新都依赖它 |
| `name` | string | 是 | 设置页显示名称 |
| `localizedNames` | object | 否 | 例如 `{"zh-Hans":"示例"}` |
| `version` | string | 是 | SemVer，例如 `1.2.0` |
| `minAppVersion` | string | 否 | 低于该版本时拒绝加载 |
| `author` | string | 否 | 作者 |
| `homepage` | string | 否 | 插件主页 |
| `description` | string | 否 | 一句话说明 |
| `icon` | string | 否 | SF Symbol 名称，默认 `puzzlepiece.extension` |
| `priority` | integer | 否 | 越大越先匹配，默认 `0` |
| `match` | object | 是 | 站点匹配规则 |
| `permissions` | string[] | 是 | 能力声明，未知权限直接拒绝安装 |
| `network` | string[] | 否 | `http` 权限允许访问的域名 |

### 4.1 `id` 规则

- 长度 3–64
- 只允许小写字母、数字、`.`、`_`、`-`
- 建议使用反向域名：`com.example.site`
- 发布后不能修改，否则用户保存的启用状态会丢失
- 从内置解析器迁移的插件保留历史 ID（例如 Pornhub 使用 `pornhub`），避免用户已有开关状态失效
- `sniffer`（通用 Sniffer）和 `youtube`（原生解析器）为保留 ID，插件不可使用
- 包内单文件插件默认隐藏，连续点击「解析来源」标题十次可以恢复显示
- 用户导入插件与包内插件同 ID 时，导入版本覆盖包内版本；删除导入版本后不会回落到包内版本

### 4.2 `match` 规则

```json
{
  "schemes": ["https"],
  "hosts": ["example.com", "*.example.net"],
  "pathPrefixes": ["/video/", "/watch"],
  "pathRegex": ["^/v/\\d+"],
  "requiredQueryKeys": ["id"]
}
```

语义：

- `schemes`：任一匹配即可；省略时默认 `["https"]`
- `hosts`：任一匹配即可；`example.com` 同时匹配其子域名
- `*.example.net`：只匹配子域名
- `pathPrefixes`：任一前缀匹配即可；省略表示不限制路径
- `pathRegex`：任一正则匹配即可；使用 ICU 正则语法
- `requiredQueryKeys`：必须全部存在，值可以为空
- 不同字段之间是 AND 关系

`claimsHost` 由 `match.hosts` 自动推导，不需要插件实现。这样 App 可以在不启动插件运行时的情况下判断「当前页面是否属于某个站点」。

### 4.3 `permissions`

| 权限 | 能力 |
|---|---|
| `page.eval` | 在主浏览器页面中执行 JavaScript |
| `page.title` | 读取页面标题 |
| `cookies` | 读取指定 URL 的 Cookie 头 |
| `http` | 通过原生 Bridge 发起 HTTP 请求 |
| `crypto` | 使用 SHA-1 / SHA-256 / HMAC / Base64 工具 |
| `log` | 写入插件日志 |

未声明的权限调用会直接抛错。`crypto` 和 `log` 也可以在 v1 中默认允许，但建议仍然显式声明。

### 4.4 `network`

`http` 权限只允许访问这里列出的域名：

```json
{
  "permissions": ["http"],
  "network": ["example.com", "*.examplecdn.com"]
}
```

规则与 `match.hosts` 相同：

- `example.com` 匹配自身和子域名
- `*.examplecdn.com` 只匹配子域名
- 不允许 `*` 全局通配
- 重定向后的地址也必须命中允许列表
- 未声明 `network` 时，`http` 请求一律拒绝

## 5. JavaScript API

### 5.1 `Nox`

| 成员 | 说明 |
|---|---|
| `Nox.apiVersion` | 当前运行时 API 版本 |
| `Nox.register(definition)` | 注册插件，必须调用一次 |
| `Nox.log(message)` | 等同 `ctx.log("info", message)` |

`definition` 目前只有一个必需成员：

```js
{
  async parse(ctx) {
    return { variants: [] };
  }
}
```

v1 不支持在 JavaScript 中实现 `canHandle` / `claimsHost`，站点匹配完全由元数据完成。

### 5.2 `ctx`

| 成员 | 类型 | 说明 |
|---|---|---|
| `ctx.url` | string | 当前页面完整 URL |
| `ctx.host` | string | 当前页面 host |
| `ctx.path` | string | path |
| `ctx.query` | object | 查询参数，重复键取最后一个 |
| `ctx.userAgent` | string \| null | 浏览器 User-Agent |
| `ctx.appVersion` | string | Nox 版本 |
| `ctx.locale` | string | 当前 App 语言 |
| `ctx.log(level, message)` | function | 写日志 |
| `ctx.sleep(ms)` | function | 等待，最大 5000 ms |
| `ctx.page` | object | 主页面能力 |
| `ctx.cookies(url?)` | function | 读取 Cookie 头 |
| `ctx.http` | object | HTTP 请求 |
| `ctx.crypto` | object | 哈希 / HMAC / Base64 工具（需 `crypto` 权限） |

### 5.3 `ctx.page`

```js
const value = await ctx.page.eval(script);
const title = await ctx.page.title();
```

`ctx.page.eval(script)`：

- 在主浏览器的页面主世界中执行
- `script` 必须是自包含表达式或 IIFE
- 支持返回 Promise；运行时会等待它完成
- 返回值必须是 JSON 可序列化数据
- 默认超时 10 秒
- 未声明 `page.eval` 权限时抛错

示例：

```js
const info = await ctx.page.eval(`
  (() => {
    const video = document.querySelector("video");
    return {
      title: document.title,
      src: video ? (video.currentSrc || video.src || "") : ""
    };
  })()
`);
```

### 5.4 `ctx.cookies`

```js
const cookieHeader = await ctx.cookies(url);
```

- `url` 省略时使用当前页面地址
- 返回 `"name=value; name2=value2"`，没有 Cookie 时返回空字符串
- 需要 `cookies` 权限
- 只返回与目标 host 匹配的 Cookie

### 5.5 `ctx.http`

```js
const response = await ctx.http.request({
  url: "https://example.com/manifest.json",
  method: "GET",
  headers: {
    "Referer": ctx.url,
    "User-Agent": ctx.userAgent
  },
  body: "",
  responseType: "text",
  timeoutMs: 20000,
  useCookies: false
});
```

参数：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `url` | string | 必填 | 必须是绝对 http/https URL |
| `method` | string | `GET` | 支持 GET / POST / PUT / PATCH / DELETE |
| `headers` | object | `{}` | 请求头 |
| `body` | string | `""` | 文本请求体 |
| `responseType` | string | `text` | `text` 或 `base64` |
| `timeoutMs` | integer | `20000` | 1000–30000 |
| `useCookies` | boolean | `false` | 是否自动附加 Cookie |

返回：

```js
{
  status: 200,
  url: "https://...",
  headers: {},
  body: "..."
}
```

- `responseType: "base64"` 时 `body` 是 Base64 字符串
- 非 2xx 不会自动抛错，由插件自行判断
- 目标 host 必须命中 `network`
- 默认单次最大响应 16 MiB
- 每次解析最多 50 个请求

便捷方法：

```js
await ctx.http.get(url, options);
await ctx.http.post(url, body, options);
```

### 5.6 `ctx.crypto`

| 方法 | 说明 |
|---|---|
| `ctx.crypto.sha1(text)` | SHA-1 十六进制 |
| `ctx.crypto.sha256(text)` | SHA-256 十六进制 |
| `ctx.crypto.hmacSha1(key, text)` | HMAC-SHA1 十六进制 |
| `ctx.crypto.hmacSha256(key, text)` | HMAC-SHA256 十六进制 |
| `ctx.crypto.base64Encode(text)` | Base64 编码 |
| `ctx.crypto.base64Decode(text)` | Base64 解码为 UTF-8 文本 |

需要 `crypto` 权限。哈希与 HMAC 返回小写十六进制；`base64Decode` 遇到非法 Base64 或非 UTF-8 内容时抛错。

### 5.7 错误

插件可以直接抛错：

```js
throw new Error("页面中没有找到视频信息");
```

App 会把它转换成解析失败提示，并记录到日志。不要返回 `null` 表示失败；必须抛出错误。

## 6. 解析返回值

`parse(ctx)` 必须返回：

```js
{
  title: "可选标题",
  variants: [
    {
      quality: "1080p",
      format: "mp4",
      url: "https://..."
    }
  ]
}
```

规则：

- `title` 可省略；省略时使用页面标题
- `variants` 必须是非空数组，最多 100 项
- `quality` 和 `format` 必须是字符串，可以为空字符串
- `url` 必须是绝对 http/https URL
- v1 不支持每个清晰度单独指定请求头
- 下载时 App 会继续使用当前页面的 Cookie、Referer 和 User-Agent

## 7. 超时与资源限制

| 项目 | 限制 |
|---|---:|
| 文件大小 | 512 KiB |
| 元数据大小 | 32 KiB |
| 页面脚本单次执行 | 10 秒 |
| HTTP 单次请求 | 20 秒（最大 30 秒） |
| 单次解析总时长 | 30 秒 |
| 单次解析 HTTP 请求数 | 50 |
| 单次 HTTP 响应 | 16 MiB |
| 单次解析总下载量 | 32 MiB |
| 返回清晰度数量 | 100 |
| 单次解析日志行数 | 200 |
| 同一插件并发解析 | 1 |

超过限制时终止当前插件运行时并返回解析失败；不应影响主浏览器页面和其他插件。

## 8. 安装、更新与删除

### 8.1 安装

入口有四个：

1. 「文件」App / AirDrop 中用 Nox 打开 `.noxplugin`
2. 其他 App 的「用 Nox 打开」/「拷贝到 Nox」
3. 「设置 → 解析来源 → 右上角菜单 → 导入插件」
4. 系统分享面板选择 Nox；Share Extension 按 `.noxplugin` 后缀识别插件（其他后缀的文件会被明确拒绝），把 zlib 压缩后的内容编码进 `nox://import-plugin` 交给宿主 App 自动导入。文件过大或无法自动打开时，请在「文件」中使用「用 Nox 打开」

安装流程：

1. 检查扩展名必须是 `.noxplugin`
2. 在安全作用域内通过 `NSFileCoordinator` 读取文件
3. 校验文件大小（≤ 512 KiB）、UTF-8 编码、元数据头、JSON 字段、`apiVersion`、`minAppVersion`、权限和域名 / 正则规则
4. 用 JavaScriptCore `new Function(source)` 编译脚本体，检查语法；**不执行插件代码**
5. 检查同 `id` 是否已有用户导入版本或包内版本；有则弹出确认框，用户确认后才继续
6. 原子写入 `Application Support/Nox/Plugins/<id>.noxplugin`
7. 重新扫描注册表，「解析来源」列表与当前浏览页立即刷新
8. 若文件来自系统 `Documents/Inbox` 临时副本，安装成功后删除该副本

`UTI` / 文件类型在 `Info.plist` 中注册，因此 Nox 可以出现在系统「用其他 App 打开」列表中。

### 8.2 更新

- 同 `id` 的新文件视为更新，旧文件会被原子替换
- 导入前会先读取新文件并检查同 ID 的现有版本（用户导入版本优先，其次包内版本）
- 只要同 ID 插件已存在，无论新版本更高、更低还是相同，都先弹出确认框，显示「当前版本 → 新版本」以及升级 / 回退 / 同版本标记
- 用户可以选择「确认导入」或「取消」；确认前不会写入任何文件
- 一次导入多个文件时，确认框会列出所有已存在的插件；同批次里的新插件在确认后一并导入
- 新文件必须先通过完整校验，失败时保留旧文件
- 更新后保留原来的启用 / 禁用状态
- 新版本号更高时显示「已更新」
- 版本号相同时显示「已更新」（重新导入）
- 版本号更低时允许回退，但界面明确显示「已回退：旧版本 → 新版本」
- 当前不保留 `.bak` 自动备份；需要回滚时重新导入旧文件

### 8.3 删除

- 用户导入的版本：删除 `Application Support/Nox/Plugins/<id>.noxplugin`
- 只有包内版本时：把 `id` 写入 `Nox.hiddenBundledPlugins`，从本机解析来源中隐藏；App 包在运行期不可写，因此不会修改 IPA
- 删除导入版本时，如果包内存在同 ID 插件，也会一并隐藏，不会自动恢复
- 销毁对应运行时
- 从解析器列表移除
- 清除对应的禁用状态（恢复默认启用）
- 删除导入版本后不会回落到包内版本
- 页面回落到其他插件或通用 Sniffer
- 已下载的文件和历史记录不受影响

删除入口：长按「解析来源」中的单文件插件条目。包内插件默认隐藏；需要时连续点击「解析来源」标题十次，在弹窗中选择「恢复」，即可重新显示全部包内插件。

### 8.3.1 导出

- 用户导入的版本优先导出 `Application Support/Nox/Plugins/<id>.noxplugin`
- 没有导入版本时，从 App 包内复制对应的 `.noxplugin` 到临时目录再分享
- 导出不会修改注册表、启用状态或插件文件

### 8.4 启用 / 禁用

- 使用现有 `disabledSiteIDs` 机制
- 以插件 `id` 作为持久化键
- 禁用后不参与站点匹配
- 在设置里切换后，当前浏览页会立即重算解析入口

## 9. 匹配优先级

1. 「解析来源」列表从上到下依次匹配，**用户拖动顺序优先**
2. 默认顺序：`priority` 高的插件在前
3. 优先级相同时按显示名称、再按 `id` 排序
4. 通用 Sniffer 永远最后且不可拖动
5. 用户调整过顺序后，新加入且不在已保存顺序里的插件按默认排序追加在末尾
6. 导入插件与包内插件同 ID 时，导入版本覆盖包内版本（包内插件默认不参与匹配）
7. host 规则重叠时按列表顺序命中第一家；当前不额外弹冲突提示

## 10. 运行时与安全模型

- 每个插件使用独立的隐藏 `WKWebView` 运行时
- 插件代码运行在 WebContent 进程，死循环或崩溃不会直接卡死主 App
- 运行时通过 `WKScriptMessageHandler` 与原生 Bridge 通信
- 页面加载使用 CSP 禁止插件直接发起 `fetch` / XHR / WebSocket
- 所有网络请求必须经过原生 Bridge 和 `network` 白名单
- 插件不能访问文件系统、钥匙串、下载目录、AppState
- 插件不能调用原生方法或加载其他脚本
- `page.eval` 是强能力，只应安装可信插件
- 签名校验实现后，可用于完整性和来源验证，但也不构成对恶意插件的完全防护
- 超时后销毁并重建运行时
- 日志统一加 `[plugin:<id>]` 前缀

## 11. 版本兼容

- `apiVersion` 不匹配时拒绝加载
- `minAppVersion` 高于当前 App 版本时拒绝加载，并提示升级
- 新增可选字段属于向后兼容
- 删除字段、改变语义或改变返回结构必须提升 `apiVersion`
- 建议 App 同时支持当前和上一个 `apiVersion`

## 12. 最小示例

完整文件见：

- [`examples/example-site.noxplugin`](examples/example-site.noxplugin)
- [`examples/pornhub.noxplugin`](examples/pornhub.noxplugin)

最小结构：

```js
/* ==NoxPlugin==
{
  "apiVersion": 1,
  "id": "com.example.example-site",
  "name": "Example Site",
  "version": "1.0.0",
  "match": {
    "schemes": ["https"],
    "hosts": ["example.com"]
  },
  "permissions": ["page.eval"]
}
==NoxPlugin== */

Nox.register({
  async parse(ctx) {
    const src = await ctx.page.eval(`
      (() => document.querySelector("video")?.src || "")()
    `);

    if (!src) throw new Error("没有找到视频地址");

    return {
      variants: [
        { quality: "auto", format: "mp4", url: src }
      ]
    };
  }
});
```

## 13. MVP 验收标准

- 可以导入一个 `.noxplugin` 文件
- 导入前不执行插件代码
- 导入后出现在「解析来源」列表
- 可以启用 / 禁用 / 删除
- 删除后立即回落
- 站点匹配不需要启动插件运行时
- 示例插件可以返回清晰度列表
- 插件抛错时只影响当前解析
- 插件超时不会卡死主界面
- 未声明权限的调用会被拒绝
- 未签名插件有明确提示
- 内置 YouTube / Pornhub 不受影响

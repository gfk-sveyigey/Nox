# VideoSaver iOS

一个原生 SwiftUI 视频下载 App。它把原来的 Tampermonkey 用户脚本思路移植成了独立 iOS 应用：在 App 内打开视频页面，读取页面公开的 `flashvars_* / mediaDefinitions` 信息，取得远程视频清单，然后由原生 URLSession 下载。

## 功能

- 内置网页浏览器，不需要手工复制视频 URL
- 从页面运行时数据中寻找 `flashvars_*` 和 `mediaDefinitions`
- 解析远程视频清单并列出可用清晰度/格式
- 原生后台下载队列
- 下载进度、失败状态、取消状态
- 下载完成后分享到“文件”、AirDrop 等系统分享目标
- 历史记录
- 默认清晰度设置
- 下载文件保存在 App 的 Documents 目录
- SwiftUI 原生界面
- GitHub Actions 自动构建

## 本地编译

要求：

- macOS
- Xcode 16.4 或兼容版本
- iOS 17.0+

打开 `VideoSaver.xcodeproj`，把 Bundle Identifier 改成自己的，例如 `com.yourname.VideoSaver`。真机安装时在 Signing & Capabilities 中选择自己的 Team。

## GitHub Actions

工作流会进行无签名 Release 构建并上传 `VideoSaver-iOS-unsigned.zip`。

无签名 `.app` 不能直接作为普通 App 安装到 iPhone。要做 TestFlight / Ad Hoc / App Store 分发，需要配置 Apple Developer 签名证书和 provisioning profile。

## 解析逻辑来源

原用户脚本通过 `flashvars_*` 查找 `mediaDefinitions`，寻找 `remote` 条目并读取 `videoUrl`，随后请求远程 JSON 清单并从每一项的 `quality / format / videoUrl` 生成下载地址。本项目保留了这条核心数据路径，并将网络请求、下载和文件保存改成原生 iOS 实现。

## 限制

本项目不实现 DRM 解密、付费墙绕过、账号权限绕过或其他访问控制绕过。能否解析取决于目标页面当前提供给浏览器的公开运行时数据和网络访问条件。


## GitHub Actions

工程已经明确配置为 iOS target（iphoneos/iphonesimulator），并包含共享 Scheme。GitHub Actions 使用 `generic/platform=iOS` 进行无签名 Release 构建。

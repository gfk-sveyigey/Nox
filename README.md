# VideoSaver iOS

这是根据原 Userscript 的核心逻辑改写的 SwiftUI iOS 示例工程源码。

## 运行环境

- Xcode 16+
- iOS 16+
- Swift 5.9+

## 创建工程

在 Xcode 中：

1. File -> New -> Project
2. iOS -> App
3. Product Name: VideoSaver
4. Interface: SwiftUI
5. Language: Swift
6. 把本目录中的 `.swift` 文件加入 Target。

## 工作方式

原脚本的核心流程是：

flashvars_* 
-> mediaDefinitions
-> 找到 remote == true 的 videoUrl
-> 请求 remote
-> 读取 quality / format / videoUrl
-> 下载视频。

本版本使用：

- WKWebView：读取页面运行时的 `flashvars_*`
- URLSession：获取视频资源列表
- URLSessionDownloadTask：下载文件
- SwiftUI：界面
- ShareLink：将 App Documents 中的文件分享/保存到“文件”

## 注意

此项目只应处理你自己有权访问和下载的内容。它没有实现登录绕过、付费墙绕过、DRM 解密或其他访问控制规避功能。

网站页面结构、接口、请求头和访问策略变化后，解析器可能需要更新。

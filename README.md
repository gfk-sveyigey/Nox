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

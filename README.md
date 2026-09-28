# VideoSaver 修正版补丁

本补丁针对上一版的三个实际问题：

1. **文件 App 完全看不到 VideoSaver**
   - 下载文件仍固定保存到 App/Documents。
   - 增加 `Info.plist` 模板，必须确保最终 App 的 Info.plist 真正包含：
     - `UIFileSharingEnabled = YES`
     - `LSSupportsOpeningDocumentsInPlace = YES`
   - App 启动时主动创建 Documents 目录。
   - 注意：仅替换 Swift 文件不会修改 Xcode Target 的 Info.plist；请按 `PROJECT_SETTINGS.txt` 把两个 key 真正加入 Target。安装旧 IPA 后建议删除旧 App，再安装新构建，避免旧包缓存影响测试。

2. **取消按钮只有动画，实际下载还在继续**
   - 浏览页和下载页现在共享同一个 `DownloadManager`。
   - 不再为两个页面各创建一个独立的 background `URLSession`。
   - 取消时先调用真实 `URLSessionDownloadTask.cancel()`，再把记录标记为 cancelled；取消回调到达后清理任务。
   - 取消中的任务不会再被进度回调或完成回调重新标记为下载中/成功。

3. **成功后的分享无法分享**
   - 分享前检查 `fileURL` 确实存在于 Documents。
   - 仍通过系统 `UIActivityViewController` 分享本地文件 URL。
   - 分享 sheet 关闭后清理临时 SwiftUI 状态。

其他上一版功能继续保留：
- 历史记录改为长按菜单：跳转网页 / 复制链接 / 删除。
- 下载失败/取消后长按重试；成功后长按分享。
- 取消按钮为图标。
- 进度条位于每行底部，颜色表示成功/失败/取消/进行中。
- 下载清理有二次确认。
- 删除下载目录设置。
- 下载质量“每次询问”。
- 浏览器按钮使用 iOS 26 Liquid Glass。

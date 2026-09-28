# VideoSaver UI / storage patch

Replace the corresponding Swift files in the current Xcode 26 project.

Changes:
- History row uses long-press context menu: 跳转网页 / 复制链接 / 删除记录.
- History navigation passes a Binding URL into the browser and actually calls WKWebView.load().
- Download retry/share are long-press actions.
- Download cancel is icon-only.
- Progress bar is at the bottom of every download row; green=success, red=failed, gray=cancelled, accent=active.
- Download cleanup asks for confirmation.
- Download folder setting is removed.
- Downloads always go to App/Documents.
- Chinese quality option: 每次询问; old English values are migrated.
- Browser back/forward/reload/parse controls use iOS 26 Liquid Glass button style when available.
- Add UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace to the target.

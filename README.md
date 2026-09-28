# VideoSaver

SwiftUI + WKWebView iOS video downloader.

## Build

- Deployment target: iOS 17+
- GitHub Actions: macOS 26 + Xcode 26.6
- Unsigned iOS IPA is produced on merged PRs to `main`.
- Put the release version in the repository root `VERSION`, for example `1.0.0`.

## Current behavior

- Browser content uses system Dynamic Type fonts; no hard-coded headline/caption sizing.
- History opens the URL back inside the app's Browser tab.
- The Parse button stays disabled until navigation has finished and the current URL matches the supported video-page rule.
- Download quality supports `Ask Every Time`, `Best`, `1080`, `720`, `480`, and `360`.
- Download folder can be selected through the iOS Files picker and is persisted with a security-scoped bookmark.
- Background download temporary files are staged synchronously before main-thread processing, avoiding the previous Documents move failure.
- Failed/cancelled downloads can be retried.
- Standard NavigationStack/TabView controls are retained so iOS 26 can provide the system Liquid Glass appearance.

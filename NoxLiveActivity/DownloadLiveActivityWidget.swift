import ActivityKit
import Foundation
import SwiftUI
import WidgetKit
import NoxActivity

private let activityAccent = Color(red: 0.24, green: 0.82, blue: 0.98)
private let activityBackground = Color(red: 0.035, green: 0.045, blue: 0.075)

struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLiveActivityLockScreenView(
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(activityBackground)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(DownloadActivityLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadActivityMark(size: 30)
                        .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(percentText(context.state.progress))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if context.isStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.trailing, 2)
                }

                // 展开态的底部区域会一直铺到灵动岛的圆角边缘。
                // 这里保留水平 / 底部内边距，避免进度条和速度文字压到圆角外。
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(activityAccent)

                        HStack(spacing: 6) {
                            Text(context.state.currentTitle)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 4)

                            if context.state.bytesPerSecond > 1 {
                                Text(speedText(context.state.bytesPerSecond))
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(activityAccent)
            } compactTrailing: {
                Text(percentText(context.state.progress))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 34)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(activityAccent)
            }
            .keylineTint(activityAccent)
            .widgetURL(DownloadActivityLink.url)
        }
    }
}

private struct DownloadLiveActivityLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DownloadActivityMark(size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Nox")
                            .font(.headline.weight(.semibold))
                        if isStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(state.currentTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isStale {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text(state.updatedAt, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)

                Text(percentText(state.progress))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }

            ProgressView(value: state.progress)
                .tint(activityAccent)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text("\(state.activeCount)")
                    .monospacedDigit()
                if state.downloadingCount > 0 {
                    Text("·")
                    Image(systemName: "bolt.horizontal.circle")
                    Text("\(state.downloadingCount)")
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                if state.bytesPerSecond > 1 {
                    Text(speedText(state.bytesPerSecond))
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct DownloadActivityMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(activityAccent.opacity(0.18))

            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(activityAccent)
        }
        .frame(width: size, height: size)
    }
}

private func percentText(_ progress: Double) -> String {
    let percent = Int((min(max(progress, 0), 1) * 100).rounded())
    return "\(percent)%"
}

private func speedText(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))) + "/s"
}

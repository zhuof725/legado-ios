import SwiftUI

/// 卷标题本地展示，不伪造为正文章节，也不对书源发网络请求。
struct VolumeTitleView: View {
    let title: String
    let foreground: Color
    var body: some View {
        VStack(spacing: 18) {
            Text("分卷").font(.caption).foregroundStyle(foreground.opacity(0.5))
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("volume-title")
            Rectangle().fill(foreground.opacity(0.18)).frame(width: 48, height: 1)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

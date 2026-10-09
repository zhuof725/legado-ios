import SwiftUI
import UIKit

/// 保留原调用接口，复用原生容器已有的交叉淡化与手势路由。
/// 不再用零距离 DragGesture 模拟点按，避免抢走 UITextView 的段评气泡点击。
struct InteractivePageTurnView: View {
    let pages: [AnyView]
    @Binding var current: Int
    let style: PageTurnStyle
    let onEdge: (Int) -> Void
    let onTapCenter: () -> Void

    var body: some View {
        PageTurnView(pages: pages, current: $current, style: style, background: .clear,
                     onEdge: onEdge, onTapCenter: onTapCenter)
    }
}

import SwiftUI
import UIKit

/// SwiftUI-driven sliding/fade page renderer.
/// Keeping both adjacent pages mounted during the gesture avoids UIPageViewController's
/// scroll-transition blank-page state on some iOS versions.
struct InteractivePageTurnView: View {
    let pages: [AnyView]
    @Binding var current: Int
    let style: PageTurnStyle
    let onEdge: (Int) -> Void
    let onTapCenter: () -> Void

    @State private var visibleIndex = 0
    @State private var dragX: CGFloat = 0
    @State private var fadeOpacity = 1.0
    @State private var settling = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack {
                if pages.indices.contains(visibleIndex) {
                    pages[visibleIndex]
                        .frame(width: width, height: geo.size.height)
                        .offset(x: style == .slide ? dragX : 0)
                        .zIndex(1)
                }
                if style == .slide, dragX < 0, pages.indices.contains(visibleIndex + 1) {
                    pages[visibleIndex + 1]
                        .frame(width: width, height: geo.size.height)
                        .offset(x: width + dragX)
                        .shadow(color: .black.opacity(0.24), radius: 9, x: -5, y: 0)
                        .zIndex(2)
                } else if style == .slide, dragX > 0, pages.indices.contains(visibleIndex - 1) {
                    pages[visibleIndex - 1]
                        .frame(width: width, height: geo.size.height)
                        .offset(x: -width + dragX)
                        .shadow(color: .black.opacity(0.24), radius: 9, x: 5, y: 0)
                        .zIndex(2)
                }
            }
            .frame(width: width, height: geo.size.height)
            .clipped()
            .opacity(fadeOpacity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !settling else { return }
                    if style == .slide, abs(value.translation.width) > 4 {
                        dragX = rubberBand(value.translation.width, width: width)
                    }
                }
                .onEnded { value in
                    guard !settling else { return }
                    let delta = value.translation.width
                    if abs(delta) < 12 {
                        let x = value.startLocation.x / width
                        if x < 0.28 { move(-1, width: width) }
                        else if x > 0.72 { move(1, width: width) }
                        else { onTapCenter() }
                    } else {
                        let predicted = value.predictedEndTranslation.width
                        let commit = abs(delta) > width * 0.22 || abs(predicted) > width * 0.34
                        if commit { move(delta < 0 ? 1 : -1, width: width) }
                        else { withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) { dragX = 0 } }
                    }
                })
        }
        .background(Color.clear)
        .onAppear { visibleIndex = clamped(current) }
        .onChange(of: current) { newValue in
            guard !settling else { return }
            visibleIndex = clamped(newValue)
        }
        .onChange(of: pages.count) { _ in
            visibleIndex = clamped(current)
            dragX = 0
        }
    }

    private func clamped(_ value: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(value, 0), pages.count - 1)
    }

    private func rubberBand(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let direction: CGFloat = x < 0 ? -1 : 1
        let amount = min(abs(x), width)
        return direction * (amount * 0.92)
    }

    private func move(_ delta: Int, width: CGFloat) {
        let target = visibleIndex + delta
        guard pages.indices.contains(target) else {
            withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
            onEdge(delta)
            return
        }
        settling = true
        if style == .fade {
            withAnimation(.easeOut(duration: 0.10)) { fadeOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                visibleIndex = target
                current = target
                withAnimation(.easeIn(duration: 0.11)) { fadeOpacity = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { settling = false }
            }
        } else {
            let endX = delta > 0 ? -width : width
            withAnimation(.easeOut(duration: 0.22)) { dragX = endX }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
                visibleIndex = target
                current = target
                dragX = 0
                settling = false
            }
        }
    }
}

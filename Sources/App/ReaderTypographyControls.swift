import SwiftUI

/// 七项版式控制共用同样的单位和步长，保存值仍沿用旧 AppStorage 键。
struct ReaderTypographyControls: View {
    @ObservedObject var settings: ReadSettings

    var body: some View {
        Section("字体大小") {
            ReaderLayoutControl(title: "字号", identifier: "font", value: $settings.fontSize, range: 12...36)
        }
        Section("间距") {
            ReaderLayoutControl(title: "行间距", identifier: "line", value: $settings.lineSpacing, range: 0...30)
            ReaderLayoutControl(title: "段间距", identifier: "paragraph", value: $settings.paragraphSpacing, range: 0...30)
        }
        Section {
            ReaderLayoutControl(title: "左边距", identifier: "left", value: $settings.leftMargin, range: 0...60)
            ReaderLayoutControl(title: "右边距", identifier: "right", value: $settings.rightMargin, range: 0...60)
            ReaderLayoutControl(title: "上边距", identifier: "top", value: $settings.topMargin, range: 0...80)
            ReaderLayoutControl(title: "下边距", identifier: "bottom", value: $settings.bottomMargin, range: 0...80)
        } header: { Text("边距") } footer: {
            Text("单位为 pt。上下边距在系统安全区内计算；调整后即时生效并自动保存。")
        }
    }
}

private struct ReaderLayoutControl: View {
    let title: String
    let identifier: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value)) pt").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("layout-value-" + identifier)
            }
            HStack(spacing: 8) {
                Button { value = max(range.lowerBound, value - 1) } label: {
                    Image(systemName: "minus.circle").frame(width: 44, height: 36)
                }
                .buttonStyle(.borderless).disabled(value <= range.lowerBound)
                .accessibilityLabel("减小" + title).accessibilityIdentifier("layout-minus-" + identifier)
                Slider(value: $value, in: range, step: 1)
                    .accessibilityLabel(title).accessibilityIdentifier("layout-slider-" + identifier)
                Button { value = min(range.upperBound, value + 1) } label: {
                    Image(systemName: "plus.circle").frame(width: 44, height: 36)
                }
                .buttonStyle(.borderless).disabled(value >= range.upperBound)
                .accessibilityLabel("增大" + title).accessibilityIdentifier("layout-plus-" + identifier)
            }
        }
    }
}

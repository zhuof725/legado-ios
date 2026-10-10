import SwiftUI

final class ReadSettings: ObservableObject {
    @AppStorage("fontSize") var fontSize: Double = 19
    @AppStorage("lineSpacing") var lineSpacing: Double = 8
    @AppStorage("paragraphSpacing") var paragraphSpacing: Double = 8
    @AppStorage("leftMargin") var leftMargin: Double = 20
    @AppStorage("rightMargin") var rightMargin: Double = 20
    @AppStorage("topMargin") var topMargin: Double = 16
    @AppStorage("bottomMargin") var bottomMargin: Double = 10
    @AppStorage("theme") var theme: Int = 0
    @AppStorage("pageMode") var pageMode: Int = 0
    @AppStorage("pageTurnStyle") var pageTurnStyle: Int = 0

    init() {
        // One-time migration of the old cramped default; preserve custom spacing.
        if !UserDefaults.standard.bool(forKey: "readerOpticalTypographyV1") {
            if paragraphSpacing == 2 { paragraphSpacing = 8 }
            UserDefaults.standard.set(true, forKey: "readerOpticalTypographyV1")
        }
        // 旧版淡入淡出值 2 回退到原生滑动，保留字号、主题与阅读进度。
        if pageTurnStyle != 0 && pageTurnStyle != 1 { pageTurnStyle = 0 }
    }

    var typographyValues: [Double] {
        [fontSize, lineSpacing, paragraphSpacing, leftMargin, rightMargin, topMargin, bottomMargin]
    }

    static let themes: [(bg: Color, fg: Color, name: String)] = [
        (Color(red: 0.98, green: 0.96, blue: 0.90), Color(red: 0.2, green: 0.2, blue: 0.2), "米黄"),
        (Color.white, Color.black, "白色"),
        (Color(red: 0.80, green: 0.91, blue: 0.81), Color(red: 0.15, green: 0.25, blue: 0.15), "护眼"),
        (Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.65, green: 0.65, blue: 0.65), "夜间")
    ]
}

import SwiftUI

struct TypographyHarnessView: View {
    @StateObject private var settings = ReadSettings()
    @State private var showSettings = false
    private let title = "这是一个很长的章节标题，用来确认标题不会被截断或从阅读页面消失"

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(settings.paragraphSpacing)) {
                    ChapterTitleView(title: title, fontSize: CGFloat(settings.fontSize), color: .black)
                        .accessibilityIdentifier("typography-title")
                    Text(String(repeating: "这是版式设置的长正文。", count: 30))
                        .font(.system(size: CGFloat(settings.fontSize)))
                        .lineSpacing(CGFloat(settings.lineSpacing))
                }
                .padding(.leading, CGFloat(settings.leftMargin))
                .padding(.trailing, CGFloat(settings.rightMargin))
                .padding(.top, CGFloat(settings.topMargin))
                .padding(.bottom, CGFloat(settings.bottomMargin))
            }
            VStack {
                HStack {
                    Spacer()
                    Button("设置") { showSettings = true }
                        .accessibilityIdentifier("open-settings")
                }
                .padding()
                Spacer()
            }
            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Text("阅读设置").font(.headline)
                        Spacer()
                        Button("完成") { showSettings = false }
                            .accessibilityIdentifier("close-settings")
                    }
                    .padding()
                    Form { ReaderTypographyControls(settings: settings) }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(12)
                .shadow(radius: 12)
            }
        }
    }
}

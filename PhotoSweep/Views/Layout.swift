import SwiftUI

/// 版面比例：iPhone 照原本的樣子；iPad 這種寬螢幕上，內容不要拉滿整個螢幕
enum Layout {
    /// 清單、說明文字等閱讀內容的最大寬度
    static let readableWidth: CGFloat = 720
    /// 引導頁、完成畫面這類置中內容的最大寬度
    static let narrowWidth: CGFloat = 520
    /// 滑動卡片的最大寬度
    static let maxCardWidth: CGFloat = 680
    /// 卡片最寬只到「高 × 0.78」：iPad 上維持接近照片的直式比例，不會變成扁平的大方塊
    static let cardMaxAspect: CGFloat = 0.78
    /// 卡片飛出畫面的距離，iPad 橫放（1366pt）也飛得出去
    static let flyOutDistance: CGFloat = 2000

    /// 在可用空間內算出卡片大小（留邊 16pt / 上下 12pt）
    static func cardSize(in available: CGSize) -> CGSize {
        let height = max(0, available.height - 24)
        let width = max(0, min(available.width - 32, maxCardWidth, height * cardMaxAspect))
        return CGSize(width: width, height: height)
    }
}

/// 寬螢幕時把 List / ScrollView 的內容限制在可讀寬度並置中
private struct ReadableContentWidth: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        Group {
            if width > Layout.readableWidth + 64 {
                content.contentMargins(.horizontal, (width - Layout.readableWidth) / 2, for: .scrollContent)
            } else {
                // iPhone 與 iPad 分割畫面的窄欄：維持系統預設邊距
                content
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }
}

extension View {
    func readableContentWidth() -> some View {
        modifier(ReadableContentWidth())
    }
}

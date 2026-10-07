import Foundation
import Photos

/// 一批要逐張檢視的照片：某個月份、螢幕截圖、影片、隨機……
struct AssetGroup: Identifiable, Hashable {
    enum Kind: Hashable {
        case month(year: Int, month: Int)
        case undated
        case all
        case random
        case screenshots
        case videos
        case favorites

        /// 顯示名稱（月份用系統語系格式，例如「2026年9月」/「September 2026」）
        var title: String {
            switch self {
            case .month(let year, let month):
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = 1
                let date = Calendar.current.date(from: components) ?? Date()
                return date.formatted(.dateTime.year().month(.wide))
            case .undated: return String(localized: "No Date")
            case .all: return String(localized: "All Photos")
            case .random: return String(localized: "Random")
            case .screenshots: return String(localized: "Screenshots")
            case .videos: return String(localized: "Videos")
            case .favorites: return String(localized: "Favorites")
            }
        }

        var systemImage: String {
            switch self {
            case .month, .undated: return "calendar"
            case .all: return "photo.on.rectangle.angled"
            case .random: return "shuffle"
            case .screenshots: return "camera.viewfinder"
            case .videos: return "video"
            case .favorites: return "heart"
            }
        }
    }

    let id: String
    let kind: Kind
    let assets: [PHAsset]
    /// 預先取好的 localIdentifier，統計進度時不用每次向 PHAsset 要
    let ids: [String]

    init(id: String, kind: Kind, assets: [PHAsset]) {
        self.id = id
        self.kind = kind
        self.assets = assets
        self.ids = assets.map(\.localIdentifier)
    }

    var count: Int { assets.count }
    var cover: PHAsset? { assets.first }

    /// 月份排序用（越新越大）；非月份群組排最後
    var sortKey: Int {
        if case .month(let year, let month) = kind { return year * 100 + month }
        return -1
    }

    // 相等要比到內容：圖庫重新載入後會產生新的 PHAsset 物件，
    // SwiftUI 才會知道月份列的內容變了。比對物件位址即可，不用逐一比屬性。
    static func == (lhs: AssetGroup, rhs: AssetGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.assets.count == rhs.assets.count
            && lhs.assets.elementsEqual(rhs.assets, by: ===)
    }

    // 雜湊只用 id，與上面的 == 一致（相等的兩個群組 id 必定相同）
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// NavigationStack 的路徑元素
enum Route: Hashable {
    case swipe(AssetGroup)
    case trash
}

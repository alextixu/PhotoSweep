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

    var count: Int { assets.count }
    var cover: PHAsset? { assets.first }

    /// 月份排序用（越新越大）；非月份群組排最後
    var sortKey: Int {
        if case .month(let year, let month) = kind { return year * 100 + month }
        return -1
    }

    // 只用 id 判斷相等／雜湊，避免對上千個 PHAsset 做比較
    static func == (lhs: AssetGroup, rhs: AssetGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// NavigationStack 的路徑元素
enum Route: Hashable {
    case swipe(AssetGroup)
    case trash
}

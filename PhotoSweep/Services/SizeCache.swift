import Foundation
import Photos

/// 照片檔案大小（含 Live Photo 的影片、編輯後的調整檔），算過一次就記住。
/// PHAssetResource 沒有公開的檔案大小 API，這裡用 KVC 讀 "fileSize"
/// （自 iOS 9 起存在，眾多清理類 App 都這樣用）；讀不到就回 0。
actor SizeCache {
    static let shared = SizeCache()

    private var sizes: [String: Int64] = [:]

    func bytes(for asset: PHAsset) -> Int64 {
        let id = asset.localIdentifier
        if let cached = sizes[id] { return cached }
        let total = Self.compute(asset)
        sizes[id] = total
        return total
    }

    private static func compute(_ asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) {
            guard resource.responds(to: NSSelectorFromString("fileSize")) else { continue }
            if let number = resource.value(forKey: "fileSize") as? NSNumber {
                total += number.int64Value
            }
        }
        return total
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

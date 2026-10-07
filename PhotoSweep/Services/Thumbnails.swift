import Photos
import SwiftUI
import UIKit

/// 共用的 PhotoKit 影像管理員 + 記憶體縮圖快取。
/// NSCache 本身執行緒安全，記憶體吃緊時系統會自動清空。
enum Thumbnails {
    /// 滑動卡片用的解析度（aspectFit 落在 2000×2000 內），足夠 3x 螢幕清晰顯示
    static let cardTargetSize = CGSize(width: 2000, height: 2000)

    static let manager = PHCachingImageManager()

    /// 所有請求共用同一組選項：PHCachingImageManager 要求預載與實際請求的參數完全一致才會命中
    static let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic   // 先給低解析度，再給完整版
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // iCloud 照片
        return options
    }()

    /// 一張 2000px 卡片解碼後約 12–16 MB；128 MB 足夠換卡與復原用，又不會吃光舊機記憶體
    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    static func key(_ id: String, _ size: CGSize) -> NSString {
        "\(id)#\(Int(size.width))x\(Int(size.height))" as NSString
    }

    static func cached(_ id: String, _ size: CGSize) -> UIImage? {
        cache.object(forKey: key(id, size))
    }

    static func store(_ image: UIImage, _ id: String, _ size: CGSize) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: key(id, size), cost: Int(pixels * 4))
    }

    /// 開始預先解碼這些卡片
    static func prefetch(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets, targetSize: cardTargetSize, contentMode: .aspectFit, options: options
        )
    }

    /// 已經滑過的卡片不用再留著
    static func stopPrefetch(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(
            for: assets, targetSize: cardTargetSize, contentMode: .aspectFit, options: options
        )
    }

    static func stopPrefetching() {
        manager.stopCachingImagesForAllAssets()
    }
}

/// 顯示一個 PHAsset 的圖片；先查記憶體快取，沒有才向 PhotoKit 要。
struct AssetImage: View {
    let asset: PHAsset
    /// 以像素為單位
    let targetSize: CGSize
    let displayMode: ContentMode
    let cache: Bool
    /// 等待高解析度版本時先顯示的圖（例如全螢幕預覽沿用卡片已載好的 2000px 版本）
    let placeholder: UIImage?

    @State private var image: UIImage?

    init(
        asset: PHAsset,
        targetSize: CGSize,
        displayMode: ContentMode = .fill,
        cache: Bool = true,
        placeholder: UIImage? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.displayMode = displayMode
        self.cache = cache
        self.placeholder = placeholder
        // 建立時就從快取拿，切換卡片時不會閃一下空白
        let seeded = cache ? Thumbnails.cached(asset.localIdentifier, targetSize) : nil
        _image = State(initialValue: seeded ?? placeholder)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: displayMode)
            } else {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
            }
        }
        .task(id: asset.localIdentifier) {
            if cache, let cached = Thumbnails.cached(asset.localIdentifier, targetSize) {
                image = cached
                return
            }
            await load()
        }
    }

    private func load() async {
        let asset = self.asset
        let id = asset.localIdentifier
        let size = targetSize
        let shouldCache = cache
        let hasPlaceholder = placeholder != nil
        let contentMode: PHImageContentMode = displayMode == .fill ? .aspectFill : .aspectFit
        let manager = Thumbnails.manager

        // opportunistic 模式下 handler 可能被叫兩次（先低畫質、後完整），用 AsyncStream 承接
        let stream = AsyncStream<(UIImage, Bool)> { continuation in
            let requestID = manager.requestImage(
                for: asset, targetSize: size, contentMode: contentMode, options: Thumbnails.options
            ) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if let result {
                    continuation.yield((result, degraded))
                }
                if result == nil || !degraded || cancelled {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestID)
            }
        }

        for await (result, degraded) in stream {
            // 已經有清楚的預覽圖時，不要被更糊的低解析度版本蓋掉
            if degraded, hasPlaceholder { continue }
            image = result
            if shouldCache, !degraded {
                Thumbnails.store(result, id, size)
            }
        }
    }
}

import Photos
import SwiftUI
import UIKit

/// 共用的 PhotoKit 影像管理員 + 記憶體縮圖快取。
/// NSCache 本身執行緒安全，記憶體吃緊時系統會自動清空。
enum Thumbnails {
    /// 滑動卡片用的解析度（aspectFit 落在 2000×2000 內），足夠 3x 螢幕清晰顯示
    static let cardTargetSize = CGSize(width: 2000, height: 2000)

    static let manager = PHCachingImageManager()

    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
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

    static func requestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic   // 先給低解析度，再給完整版
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // iCloud 照片
        return options
    }

    /// 預先解碼接下來幾張卡片
    static func prefetch(_ assets: [PHAsset]) {
        manager.startCachingImages(
            for: assets, targetSize: cardTargetSize, contentMode: .aspectFit, options: requestOptions()
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
    var displayMode: ContentMode = .fill
    var cache = true

    @State private var image: UIImage?

    init(asset: PHAsset, targetSize: CGSize, displayMode: ContentMode = .fill, cache: Bool = true) {
        self.asset = asset
        self.targetSize = targetSize
        self.displayMode = displayMode
        self.cache = cache
        // 建立時就從快取拿，切換卡片時不會閃一下空白
        _image = State(initialValue: cache ? Thumbnails.cached(asset.localIdentifier, targetSize) : nil)
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
        let contentMode: PHImageContentMode = displayMode == .fill ? .aspectFill : .aspectFit
        let manager = Thumbnails.manager

        // opportunistic 模式下 handler 可能被叫兩次（先低畫質、後完整），用 AsyncStream 承接
        let stream = AsyncStream<(UIImage, Bool)> { continuation in
            let requestID = manager.requestImage(
                for: asset, targetSize: size, contentMode: contentMode, options: Thumbnails.requestOptions()
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
            image = result
            if shouldCache, !degraded {
                Thumbnails.store(result, id, size)
            }
        }
    }
}

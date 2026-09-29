import Foundation
import Observation
import Photos
import UIKit

/// 系統照片圖庫（PhotoKit）：授權、載入、依月份分組、圖庫變動時自動重新整理，
/// 以及唯二會改動圖庫的操作：刪除、設定最愛。
@MainActor
@Observable
final class PhotoLibrary {
    private(set) var authorization: PHAuthorizationStatus
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    private(set) var allAssets: [PHAsset] = []
    private(set) var monthGroups: [AssetGroup] = []
    private(set) var screenshots: [PHAsset] = []
    private(set) var videos: [PHAsset] = []
    private(set) var favorites: [PHAsset] = []
    private(set) var assetsByID: [String: PHAsset] = [:]
    private(set) var assetIDs: Set<String> = []
    /// 每次重新載入 +1，畫面用它得知該重新計算
    private(set) var generation = 0

    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var hasAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    // MARK: - 授權

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { await load() }
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// 「僅限所選照片」模式下，讓使用者再多選幾張
    func presentLimitedPicker() {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    // MARK: - 載入

    func load() async {
        guard hasAccess, !isLoading else { return }
        isLoading = true
        let snapshot = await Task.detached(priority: .userInitiated) {
            LibraryLoader.load()
        }.value
        allAssets = snapshot.all
        monthGroups = snapshot.months
        screenshots = snapshot.screenshots
        videos = snapshot.videos
        favorites = snapshot.favorites
        assetsByID = snapshot.byID
        assetIDs = snapshot.ids
        generation += 1
        isLoading = false
        hasLoaded = true
        startObserving()
    }

    /// 快速模式用的群組（隨機模式每次都重新洗牌）
    func quickGroup(_ kind: AssetGroup.Kind) -> AssetGroup {
        switch kind {
        case .all: return AssetGroup(id: "all", kind: .all, assets: allAssets)
        case .random: return AssetGroup(id: "random", kind: .random, assets: allAssets.shuffled())
        case .screenshots: return AssetGroup(id: "screenshots", kind: .screenshots, assets: screenshots)
        case .videos: return AssetGroup(id: "videos", kind: .videos, assets: videos)
        case .favorites: return AssetGroup(id: "favorites", kind: .favorites, assets: favorites)
        case .month, .undated:
            return monthGroups.first { $0.kind == kind } ?? AssetGroup(id: "empty", kind: kind, assets: [])
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = LibraryObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleReload()
            }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    /// 圖庫變動（刪除、加最愛、其他 App 新增照片）後 0.5 秒重新載入，避免連續事件重複載入
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await self?.load()
        }
    }

    // MARK: - 修改圖庫

    /// 真正刪除。iOS 會先跳出系統確認框；刪除的照片進入「最近刪除」保留 30 天。
    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    /// 設定「最愛」，與 Apple 照片 App 同步
    func setFavorite(_ asset: PHAsset, _ isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = isFavorite
        }
    }
}

// MARK: - 背景載入

struct LibrarySnapshot {
    var all: [PHAsset] = []
    var months: [AssetGroup] = []
    var screenshots: [PHAsset] = []
    var videos: [PHAsset] = []
    var favorites: [PHAsset] = []
    var byID: [String: PHAsset] = [:]
    var ids: Set<String> = []
}

enum LibraryLoader {
    private struct YearMonth: Hashable {
        let year: Int
        let month: Int
    }

    static func load() -> LibrarySnapshot {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let all = collect(PHAsset.fetchAssets(with: options))

        var snapshot = LibrarySnapshot()
        snapshot.all = all
        snapshot.months = monthGroups(from: all)
        snapshot.videos = all.filter { $0.mediaType == .video }
        snapshot.favorites = all.filter { $0.isFavorite }
        snapshot.screenshots = all.filter { $0.mediaSubtypes.contains(.photoScreenshot) }

        var byID: [String: PHAsset] = [:]
        byID.reserveCapacity(all.count)
        for asset in all { byID[asset.localIdentifier] = asset }
        snapshot.byID = byID
        snapshot.ids = Set(byID.keys)
        return snapshot
    }

    static func collect(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    /// 依拍攝月份分組；輸入已是由新到舊，群組內反轉成由舊到新，檢視時照時間順序走
    static func monthGroups(from assets: [PHAsset]) -> [AssetGroup] {
        let calendar = Calendar.current
        var buckets: [YearMonth: [PHAsset]] = [:]
        var undated: [PHAsset] = []

        for asset in assets {
            guard let date = asset.creationDate else {
                undated.append(asset)
                continue
            }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let key = YearMonth(year: parts.year ?? 0, month: parts.month ?? 0)
            buckets[key, default: []].append(asset)
        }

        var groups: [AssetGroup] = buckets.map { key, value in
            AssetGroup(
                id: "month-\(key.year)-\(key.month)",
                kind: .month(year: key.year, month: key.month),
                assets: Array(value.reversed())
            )
        }
        groups.sort { $0.sortKey > $1.sortKey }
        if !undated.isEmpty {
            groups.append(AssetGroup(id: "undated", kind: .undated, assets: undated))
        }
        return groups
    }
}

// MARK: - 圖庫變動監聽

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
    }

    // PhotoKit 在背景執行緒呼叫；onChange 內部會自己切回主執行緒
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

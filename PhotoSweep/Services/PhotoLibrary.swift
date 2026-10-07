import Foundation
import Observation
import Photos
import PhotosUI
import UIKit

/// 系統照片圖庫（PhotoKit）：授權、載入、依月份分組、圖庫變動時自動更新，
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
    /// 每次完整重新載入 +1，畫面用它得知該重新計算
    private(set) var generation = 0
    /// 最近一次載入是不是在「完整取用」下抓的；只有這種快照才能拿來清除紀錄
    private(set) var lastLoadHadFullAccess = false

    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// 載入途中又收到結構性變動：這次載完要再載一次，不能直接丟掉
    @ObservationIgnored private var reloadPending = false
    /// 載入途中收到的屬性變動（例如最愛）：先存著，載完直接套用，不必整個重掃
    @ObservationIgnored private var pendingMetadata: [PHAsset] = []
    /// 這一輪抓取期間有照片被刪除：抓到的快照是刪除前的，不能套用
    @ObservationIgnored private var deletedDuringFetch = false
    /// 正在清空垃圾桶（跨畫面共用，避免重新打開垃圾桶時又送出一次同樣的刪除）
    var isEmptyingTrash = false

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var hasAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    // MARK: - 授權

    /// 取得授權後由 RootView 的 .task(id: hasAccess) 負責載入，這裡不重複呼叫（否則第一次會掃兩次圖庫）
    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// 「僅限所選照片」模式下，讓使用者再多選幾張
    func presentLimitedPicker() {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var presenter = scene.keyWindow?.rootViewController
        else { return }
        // 畫面上已有 sheet 時，要從最上層的畫面彈出
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    // MARK: - 載入

    func load() async {
        guard hasAccess else { return }
        if isLoading {
            reloadPending = true
            return
        }
        isLoading = true
        // 第一次抓取前就開始監聽，抓取途中發生的變動也收得到
        startObserving()
        repeat {
            reloadPending = false
            deletedDuringFetch = false
            let snapshot = await Task.detached(priority: .userInitiated) {
                LibraryLoader.load()
            }.value
            // 抓取期間刪了照片：這份快照還含有被刪的照片，丟掉（reloadPending 已設好，會再抓一次）
            if deletedDuringFetch, hasLoaded { continue }
            apply(snapshot)
            // changedObjects 都是變動後的物件，套在任何一份快照之後都正確
            if !pendingMetadata.isEmpty {
                let changed = pendingMetadata
                pendingMetadata = []
                applyMetadataChanges(changed)
            }
        } while reloadPending
        isLoading = false
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        allAssets = snapshot.all
        monthGroups = snapshot.months
        screenshots = snapshot.screenshots
        videos = snapshot.videos
        favorites = snapshot.favorites
        assetsByID = snapshot.byID
        assetIDs = snapshot.ids
        if let fetchResult = snapshot.fetchResult {
            observer?.setFetchResult(fetchResult)
        }
        lastLoadHadFullAccess = snapshot.fullAccess
        generation += 1
        hasLoaded = true
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

    // MARK: - 圖庫變動

    private func startObserving() {
        guard observer == nil else { return }
        let observer = LibraryObserver { [weak self] change in
            Task { @MainActor [weak self] in
                self?.handle(change)
            }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func handle(_ change: LibraryChange) {
        switch change {
        case .structural:
            scheduleReload()
        case .metadata(let changed):
            if isLoading {
                // 進行中的載入可能是變動前抓的：先存著，載完再套用
                pendingMetadata.append(contentsOf: changed)
            } else {
                applyMetadataChanges(changed)
            }
        }
    }

    /// 新增、刪除、排序改變：0.5 秒後完整重新載入，避免連續事件重複載入
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await self?.load()
        }
    }

    /// 只有屬性改變（例如加入最愛）：就地換成新的 PHAsset，不用重掃整個圖庫
    private func applyMetadataChanges(_ changed: [PHAsset]) {
        var byID = assetsByID
        // 同一張可能在載入期間變了好幾次：每張只留最後一版
        var touched: [String: PHAsset] = [:]
        var dateChanged = false
        for asset in changed {
            guard let old = byID[asset.localIdentifier] else { continue }
            if old.creationDate != asset.creationDate { dateChanged = true }
            byID[asset.localIdentifier] = asset
            touched[asset.localIdentifier] = asset
        }
        guard !touched.isEmpty else { return }
        // 拍攝日期被改了：可能換了月份，排序沒變也要完整重新分組
        if dateChanged {
            scheduleReload()
            return
        }
        assetsByID = byID

        let touchedIDs = Set(touched.keys)
        var newFavorites = favorites.filter { !touchedIDs.contains($0.localIdentifier) }
        newFavorites.append(contentsOf: touched.values.filter(\.isFavorite))
        newFavorites.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        favorites = newFavorites
    }

    // MARK: - 修改圖庫

    /// 真正刪除。iOS 會先跳出系統確認框；刪除的照片進入「最近刪除」保留 30 天。
    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        // 立刻從所有清單拿掉，不必等重新載入：避免已刪除的照片以空白卡片出現，
        // 月份進度與各種數量也馬上正確
        let gone = Set(assets.map(\.localIdentifier))
        func keep(_ list: [PHAsset]) -> [PHAsset] {
            list.filter { !gone.contains($0.localIdentifier) }
        }
        assetIDs.subtract(gone)
        var byID = assetsByID
        for id in gone { byID[id] = nil }
        assetsByID = byID
        allAssets = keep(allAssets)
        favorites = keep(favorites)
        videos = keep(videos)
        screenshots = keep(screenshots)
        monthGroups = monthGroups.compactMap { (group: AssetGroup) -> AssetGroup? in
            let remaining = keep(group.assets)
            if remaining.count == group.assets.count { return group }
            return remaining.isEmpty ? nil : AssetGroup(id: group.id, kind: group.kind, assets: remaining)
        }
        // 正在進行的載入可能是刪除前抓的：不套用那份，再抓一次
        if isLoading {
            deletedDuringFetch = true
            reloadPending = true
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
    /// 用來比對之後的圖庫變動
    var fetchResult: PHFetchResult<PHAsset>?
    /// 抓取當下是不是「完整取用」
    var fullAccess = false
}

enum LibraryLoader {
    private struct YearMonth: Hashable {
        let year: Int
        let month: Int
    }

    static func load() -> LibrarySnapshot {
        // 先記下權限再抓：抓取途中才升級成完整取用時，這份快照仍視為部分資料
        let fullAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        let all = collect(result)

        var snapshot = LibrarySnapshot()
        snapshot.fetchResult = result
        snapshot.fullAccess = fullAccess
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

enum LibraryChange {
    /// 有新增、刪除或排序改變：需要完整重新載入
    case structural
    /// 只有屬性改變（最愛、編輯…），附上變動後的 PHAsset
    case metadata([PHAsset])
}

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: (LibraryChange) -> Void
    private let lock = NSLock()
    private var fetchResult: PHFetchResult<PHAsset>?

    init(onChange: @escaping (LibraryChange) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func setFetchResult(_ result: PHFetchResult<PHAsset>) {
        lock.lock()
        fetchResult = result
        lock.unlock()
    }

    // PhotoKit 在背景執行緒呼叫；onChange 內部會自己切回主執行緒
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        var change: LibraryChange?
        if let current = fetchResult {
            if let details = changeInstance.changeDetails(for: current) {
                fetchResult = details.fetchResultAfterChanges
                let structural = !details.hasIncrementalChanges
                    || details.hasMoves
                    || !details.insertedObjects.isEmpty
                    || !details.removedObjects.isEmpty
                change = structural ? .structural : .metadata(details.changedObjects)
            }
            // details == nil：跟我們抓的照片無關（例如相簿名稱改了），忽略
        } else {
            // 第一次載入還沒完成，無從比對：保守起見完整重新載入
            change = .structural
        }
        lock.unlock()
        if let change {
            onChange(change)
        }
    }
}

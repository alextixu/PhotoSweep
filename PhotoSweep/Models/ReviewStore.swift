import Foundation
import Observation

/// 使用者的檢視紀錄：哪些照片已保留、哪些在垃圾桶，以及累計釋放的空間。
/// 只記 PHAsset 的 localIdentifier，照片本身完全不動；
/// 資料存在 Application Support/PhotoSweep/review.json。
@MainActor
@Observable
final class ReviewStore {
    private struct Snapshot: Codable {
        var kept: Set<String> = []
        var trash: [String] = []
        var freedBytes: Int64 = 0
        var deletedCount: Int = 0
    }

    /// 已決定「保留」的照片
    private(set) var kept: Set<String> = []
    /// 垃圾桶（依加入順序）
    private(set) var trash: [String] = []
    private(set) var trashSet: Set<String> = []
    /// 真正刪除後累計釋放的位元組數
    private(set) var freedBytes: Int64 = 0
    /// 真正刪除的張數
    private(set) var deletedCount: Int = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("PhotoSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("review.json")

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            kept = snapshot.kept
            trash = snapshot.trash
            trashSet = Set(snapshot.trash)
            freedBytes = snapshot.freedBytes
            deletedCount = snapshot.deletedCount
        }
    }

    // MARK: - 查詢

    /// 已檢視、而且還在圖庫裡的照片（已刪除的另外算在 deletedCount）
    var reviewedCount: Int { kept.count + trash.count }

    func isReviewed(_ id: String) -> Bool { kept.contains(id) || trashSet.contains(id) }
    func isTrashed(_ id: String) -> Bool { trashSet.contains(id) }

    // MARK: - 滑動決定

    func keep(_ id: String) {
        removeFromTrash(id)
        kept.insert(id)
        scheduleSave()
    }

    func moveToTrash(_ id: String) {
        kept.remove(id)
        if trashSet.insert(id).inserted { trash.append(id) }
        scheduleSave()
    }

    /// 取消對某張照片的決定（復原滑動、從垃圾桶還原）
    func clearDecision(_ id: String) {
        kept.remove(id)
        removeFromTrash(id)
        scheduleSave()
    }

    func restore(_ id: String) { clearDecision(id) }

    /// 一次還原多張（垃圾桶的「全部還原」只還原畫面上看得到的那些）
    func restore(ids: [String]) {
        let restored = Set(ids)
        trash.removeAll { restored.contains($0) }
        trashSet.subtract(restored)
        scheduleSave()
    }

    /// 清空垃圾桶成功後呼叫
    func recordDeletion(of ids: [String], bytes: Int64) {
        // 一次處理整批，上萬張也不會逐張掃陣列
        let removed = Set(ids)
        trash.removeAll { removed.contains($0) }
        trashSet.subtract(removed)
        kept.subtract(removed)
        deletedCount += ids.count
        freedBytes += bytes
        scheduleSave()
    }

    /// 重新檢視：清掉這批照片的「保留」標記（垃圾桶內的不動）
    func resetKept(for ids: [String]) {
        kept.subtract(ids)
        scheduleSave()
    }

    func resetAll() {
        kept = []
        trash = []
        trashSet = []
        freedBytes = 0
        deletedCount = 0
        scheduleSave()
    }

    /// 圖庫重新載入後，移除已經不在圖庫裡的紀錄
    /// 只有真的有東西要移除時才改動，避免每次重新載入都讓畫面重畫
    func prune(keeping existing: Set<String>) {
        let newKept = kept.intersection(existing)
        let keptChanged = newKept.count != kept.count
        if keptChanged { kept = newKept }

        let trashChanged = trash.contains { !existing.contains($0) }
        if trashChanged {
            trash.removeAll { !existing.contains($0) }
            trashSet = Set(trash)
        }
        if keptChanged || trashChanged { scheduleSave() }
    }

    private func removeFromTrash(_ id: String) {
        if trashSet.remove(id) != nil {
            trash.removeAll { $0 == id }
        }
    }

    // MARK: - 存檔

    private var snapshot: Snapshot {
        Snapshot(kept: kept, trash: trash, freedBytes: freedBytes, deletedCount: deletedCount)
    }

    /// 延遲 300ms 再寫入，連續滑動時不會每張都寫磁碟
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = self.snapshot
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            Self.write(snapshot, to: url)
        }
    }

    /// 立刻寫入（進背景前）
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Self.write(snapshot, to: fileURL)
    }

    private nonisolated static func write(_ snapshot: Snapshot, to url: URL) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print("ReviewStore: save failed – \(error)")
        }
    }
}

extension ReviewStore {
    /// 畫面上要顯示的垃圾桶數量：只算圖庫裡看得到的，和垃圾桶畫面列出的一致。
    /// 「僅限所選照片」模式下沒被選取的照片、或已在別處刪掉的照片，紀錄會保留但不算進來，
    /// 避免「垃圾桶有 N 個」點進去卻是空的。
    func visibleTrashCount(in library: PhotoLibrary) -> Int {
        guard library.hasLoaded else { return trash.count }
        // 先取出來再逐一比對，不要每張都經過可觀察屬性的存取
        let ids = library.assetIDs
        return trash.reduce(0) { $0 + (ids.contains($1) ? 1 : 0) }
    }

    /// 畫面上要顯示的「已檢視」數量。完整取用時紀錄會隨圖庫同步清理，直接用總數；
    /// 「僅限所選照片」時只算看得到的（看得到的照片通常不多，逐一檢查很便宜）。
    func visibleReviewedCount(in library: PhotoLibrary) -> Int {
        guard library.hasLoaded, library.authorization == .limited else { return reviewedCount }
        let kept = self.kept
        let trashed = trashSet
        return library.assetIDs.reduce(0) { $0 + (kept.contains($1) || trashed.contains($1) ? 1 : 0) }
    }
}

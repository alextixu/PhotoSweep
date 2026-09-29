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

    var reviewedCount: Int { kept.count + trash.count + deletedCount }

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

    func restoreAll() {
        trash.removeAll()
        trashSet.removeAll()
        scheduleSave()
    }

    /// 清空垃圾桶成功後呼叫
    func recordDeletion(of ids: [String], bytes: Int64) {
        for id in ids {
            removeFromTrash(id)
            kept.remove(id)
        }
        deletedCount += ids.count
        freedBytes += bytes
        scheduleSave()
    }

    /// 重新檢視：清掉這批照片的「保留」標記（垃圾桶內的不動）
    func resetKept(for ids: [String]) {
        for id in ids { kept.remove(id) }
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
    func prune(keeping existing: Set<String>) {
        let keptBefore = kept.count
        let trashBefore = trash.count
        kept.formIntersection(existing)
        trash.removeAll { !existing.contains($0) }
        trashSet = Set(trash)
        if kept.count != keptBefore || trash.count != trashBefore { scheduleSave() }
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

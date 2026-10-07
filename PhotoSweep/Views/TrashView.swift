import Photos
import SwiftUI

/// 垃圾桶：格狀縮圖、單張還原、全部還原、一鍵清空（這裡才會真正刪除）
struct TrashView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.displayScale) private var displayScale

    @State private var totalBytes: Int64?
    /// 已經算好的檔案大小，按刪除時不用再算一次
    @State private var knownSizes: [String: Int64] = [:]
    @State private var isVisible = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var confirmRestoreAll = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]

    private var assets: [PHAsset] {
        store.trash.compactMap { library.assetsByID[$0] }
    }

    var body: some View {
        let items = assets
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Swipe left on a photo to put it here. Nothing is deleted until you empty the trash.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(items, id: \.localIdentifier) { asset in
                            TrashCell(
                                asset: asset,
                                pixelSize: CGSize(width: 160 * displayScale, height: 160 * displayScale)
                            ) {
                                store.restore(asset.localIdentifier)
                                Haptics.impact(.light)
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                }
                .safeAreaInset(edge: .bottom) {
                    deleteBar(count: items.count)
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restore All") {
                        confirmRestoreAll = true
                    }
                }
            }
        }
        .confirmationDialog("Restore all photos?", isPresented: $confirmRestoreAll, titleVisibility: .visible) {
            Button("Restore All") {
                // 只還原畫面上列出的；「僅限所選照片」時看不到的那些紀錄保留
                store.restore(ids: assets.map(\.localIdentifier))
            }
        } message: {
            Text("They go back to being unreviewed. Nothing is deleted.")
        }
        // 以畫面上實際列出的照片為準：垃圾桶沒變、但圖庫載入完成或選取範圍改變時也要重算
        .task(id: items.map(\.localIdentifier)) {
            await computeTotal()
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
        .alert("Couldn't delete", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func deleteBar(count: Int) -> some View {
        VStack(spacing: 10) {
            if let totalBytes {
                Text("\(count) items · \(ByteFormat.string(totalBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Calculating size…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { await emptyTrash() }
            } label: {
                Label("Delete \(count) Items", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(library.isEmptyingTrash)
            Text("iOS will ask you to confirm. Deleted photos stay in Recently Deleted for 30 days.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.bar)
    }

    /// 真正刪除：交給 PhotoKit，iOS 會先跳系統確認框
    private func emptyTrash() async {
        // 只刪按下當下畫面上列出的這些
        let requested = assets
        guard !requested.isEmpty, !library.isEmptyingTrash else { return }
        library.isEmptyingTrash = true
        defer { library.isEmptyingTrash = false }

        // 刪掉之後就讀不到檔案資訊，所以先把還沒算過的大小補齊
        let missing = requested.filter { knownSizes[$0.localIdentifier] == nil }
        if !missing.isEmpty {
            let more = await SizeCache.shared.sizes(for: missing)
            knownSizes.merge(more) { _, new in new }
            // 等待期間垃圾桶畫面被關掉了：不要在別的畫面上跳出刪除確認
            guard isVisible else { return }
        }

        // 等待期間使用者可能還原了幾張：只保留仍在垃圾桶裡的；之後才丟進來的不算。
        // 從這裡到交給 PhotoKit 之間沒有任何等待，清單不會再變。
        let requestedIDs = Set(requested.map(\.localIdentifier))
        let toDelete = assets.filter { requestedIDs.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { return }
        let bytes = toDelete.reduce(Int64(0)) { $0 + (knownSizes[$1.localIdentifier] ?? 0) }
        do {
            try await library.delete(toDelete)
            store.recordDeletion(of: toDelete.map(\.localIdentifier), bytes: bytes)
            Haptics.notify(.success)
        } catch {
            let nsError = error as NSError
            // 使用者在系統確認框按了「不允許」：什麼都不做
            if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.userCancelled.rawValue {
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func computeTotal() async {
        totalBytes = nil
        let sizes = await SizeCache.shared.sizes(for: assets)
        // 就算中途被取消，算好的部分也留著給刪除時用
        knownSizes.merge(sizes) { _, new in new }
        if Task.isCancelled { return }
        totalBytes = sizes.values.reduce(0, +)
    }
}

private struct TrashCell: View {
    let asset: PHAsset
    let pixelSize: CGSize
    let onRestore: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AssetImage(asset: asset, targetSize: pixelSize, displayMode: .fill)
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRestore) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .padding(6)
                .accessibilityLabel("Restore")
            }
            .contextMenu {
                Button {
                    onRestore()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
    }
}

import Photos
import SwiftUI

/// 核心畫面：一張一張滑。右滑保留、左滑進垃圾桶、雙擊加最愛、單擊看大圖。
struct SwipeView: View {
    let group: AssetGroup

    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// 這次要看的照片（排除已檢視過的）
    @State private var queue: [PHAsset] = []
    @State private var isReady = false
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var isAnimatingOut = false
    @State private var history: [Decision] = []
    @State private var sessionKept = 0
    @State private var sessionTrashed = 0
    /// 剛切換過最愛的照片：PHAsset 物件是舊的，先用這個蓋過去
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var showDetail = false
    @State private var showTrash = false
    @State private var showError = false
    @State private var errorMessage = ""

    private struct Decision {
        let asset: PHAsset
        let trashed: Bool
    }

    private var current: PHAsset? { index < queue.count ? queue[index] : nil }
    private var next: PHAsset? { index + 1 < queue.count ? queue[index + 1] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if !isReady {
                Spacer()
                ProgressView()
                Spacer()
            } else if let current {
                progressHeader
                cardStack(current: current)
                controls(current: current)
            } else {
                CompletionView(
                    wasEmpty: queue.isEmpty,
                    kept: sessionKept,
                    trashed: sessionTrashed,
                    trashTotal: store.trash.count,
                    onReviewTrash: { showTrash = true },
                    onReviewAgain: { reviewAgain() },
                    onDone: { dismiss() }
                )
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(group.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTrash = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.trash.isEmpty ? "trash" : "trash.fill")
                        Text(store.trash.count.formatted())
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("Trash")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        reviewAgain()
                    } label: {
                        Label("Review Again", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: group.id) {
            prepare()
        }
        .onDisappear {
            Thumbnails.stopPrefetching()
        }
        .fullScreenCover(isPresented: $showDetail) {
            if let current {
                AssetDetailView(asset: current)
            }
        }
        .sheet(isPresented: $showTrash) {
            TrashSheet()
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 畫面

    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(index + 1) of \(queue.count)")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Text("← Trash · Keep →")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func cardStack(current: PHAsset) -> some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.width - 32, height: geo.size.height - 24)
            // 拖到 120pt 時後面那張已長到全尺寸，換卡時不會跳
            let progress = min(1, abs(drag.width) / 120)
            ZStack {
                if let next {
                    PhotoCard(asset: next, size: size, isFavorite: isFavorite(next))
                        .scaleEffect(0.94 + 0.06 * progress)
                        .offset(y: 12 * (1 - progress))
                        .id(next.localIdentifier)
                }
                PhotoCard(asset: current, size: size, isFavorite: isFavorite(current))
                    .overlay(alignment: .topLeading) {
                        stamp("KEEP", color: .green, opacity: drag.width / 100)
                            .rotationEffect(.degrees(-15))
                            .padding(24)
                    }
                    .overlay(alignment: .topTrailing) {
                        stamp("TRASH", color: .red, opacity: -drag.width / 100)
                            .rotationEffect(.degrees(15))
                            .padding(24)
                    }
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width / 18)), anchor: .bottom)
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { toggleFavorite(current) }
                            .exclusively(before: TapGesture().onEnded { showDetail = true })
                    )
                    .gesture(dragGesture)
                    .id(current.localIdentifier)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.vertical, 8)
    }

    private func stamp(_ text: LocalizedStringKey, color: Color, opacity: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .opacity(Double(max(0, min(1, opacity))))
    }

    private func controls(current: PHAsset) -> some View {
        HStack(spacing: 24) {
            CircleButton(systemImage: "arrow.uturn.backward", color: .secondary, size: 52, label: "Undo") {
                undo()
            }
            .disabled(history.isEmpty || isAnimatingOut)
            .opacity(history.isEmpty ? 0.4 : 1)

            CircleButton(systemImage: "trash.fill", color: .red, size: 68, label: "Trash") {
                commit(trashed: true)
            }
            CircleButton(systemImage: "checkmark", color: .green, size: 68, label: "Keep") {
                commit(trashed: false)
            }
            CircleButton(
                systemImage: isFavorite(current) ? "heart.fill" : "heart",
                color: .pink, size: 52, label: "Favorite"
            ) {
                toggleFavorite(current)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: - 手勢與動作

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isAnimatingOut else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                let width = value.translation.width
                let predicted = value.predictedEndTranslation.width
                if width > 100 || predicted > 260 {
                    commit(trashed: false)
                } else if width < -100 || predicted < -260 {
                    commit(trashed: true)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        drag = .zero
                    }
                }
            }
    }

    private func prepare() {
        queue = group.assets.filter { !store.isReviewed($0.localIdentifier) }
        index = 0
        history = []
        sessionKept = 0
        sessionTrashed = 0
        isReady = true
        prefetch()
    }

    /// 清掉這組的「保留」標記後重來（垃圾桶內的不動）
    private func reviewAgain() {
        store.resetKept(for: group.assets.map(\.localIdentifier))
        prepare()
    }

    private func commit(trashed: Bool) {
        guard !isAnimatingOut, let asset = current else { return }
        isAnimatingOut = true
        Haptics.impact(trashed ? .rigid : .light)

        let direction: CGFloat = trashed ? -1 : 1
        withAnimation(.easeOut(duration: 0.28)) {
            drag = CGSize(width: direction * 1000, height: drag.height * 1.6)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(260))
            apply(trashed: trashed, to: asset)
            // 換下一張時不要有動畫：舊卡已飛出畫面，新卡直接出現在中央
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                index += 1
                drag = .zero
            }
            isAnimatingOut = false
            prefetch()
        }
    }

    private func apply(trashed: Bool, to asset: PHAsset) {
        let id = asset.localIdentifier
        if trashed {
            store.moveToTrash(id)
            sessionTrashed += 1
        } else {
            store.keep(id)
            sessionKept += 1
        }
        history.append(Decision(asset: asset, trashed: trashed))
        if history.count > 50 { history.removeFirst() }
    }

    private func undo() {
        guard !isAnimatingOut, let last = history.popLast() else { return }
        store.clearDecision(last.asset.localIdentifier)
        if last.trashed { sessionTrashed -= 1 } else { sessionKept -= 1 }
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            index = max(0, index - 1)
        }
    }

    private func isFavorite(_ asset: PHAsset) -> Bool {
        favoriteOverrides[asset.localIdentifier] ?? asset.isFavorite
    }

    private func toggleFavorite(_ asset: PHAsset) {
        let newValue = !isFavorite(asset)
        favoriteOverrides[asset.localIdentifier] = newValue
        Haptics.notify(.success)
        Task {
            do {
                try await library.setFavorite(asset, newValue)
            } catch {
                favoriteOverrides[asset.localIdentifier] = !newValue
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func prefetch() {
        guard index + 1 < queue.count else { return }
        let upcoming = Array(queue[(index + 1)..<min(index + 6, queue.count)])
        Thumbnails.prefetch(upcoming)
    }
}

// MARK: - 子元件

private struct CircleButton: View {
    let systemImage: String
    let color: Color
    let size: CGFloat
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 這一組看完（或一開始就沒東西可看）時的畫面
private struct CompletionView: View {
    let wasEmpty: Bool
    let kept: Int
    let trashed: Int
    let trashTotal: Int
    let onReviewTrash: () -> Void
    let onReviewAgain: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if wasEmpty {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Already reviewed")
                    .font(.title.bold())
                Text("Every photo here has been reviewed.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("All done!")
                    .font(.title.bold())
                Text("Kept \(kept) · Trashed \(trashed)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if trashTotal > 0 {
                Button {
                    onReviewTrash()
                } label: {
                    Text("Review Trash (\(trashTotal))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button {
                onReviewAgain()
            } label: {
                Text("Review Again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button("Done") {
                onDone()
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}

/// 從滑動畫面用 sheet 開垃圾桶，不用離開目前的進度
struct TrashSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrashView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

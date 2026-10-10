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
    /// 手勢被系統中斷（來電、控制中心…）時 onEnded 不會被呼叫，用這個偵測並把卡片放回中央
    @GestureState private var isDragging = false
    /// 已經決定、正在飛出畫面的卡片；不擋手勢，可以馬上滑下一張
    @State private var flying: [FlyingCard] = []
    @State private var history: [Decision] = []
    @State private var sessionKept = 0
    @State private var sessionTrashed = 0
    /// 剛切換過最愛的照片：PHAsset 物件是舊的，先用這個蓋過去
    @State private var favoriteOverrides: [String: Bool] = [:]
    /// 雙擊時要在哪張卡片上跳出大愛心
    @State private var heartBurst: HeartBurstItem?
    @State private var isVisible = false
    /// 目前請 PhotoKit 預先解碼的卡片
    @State private var cachedWindow: [PHAsset] = []
    /// 全螢幕預覽要顯示哪一張：記住被點的那張，而不是打開當下的「目前這張」
    @State private var detail: DetailItem?
    @State private var showTrash = false
    @State private var showError = false
    @State private var errorMessage = ""

    private struct Decision {
        let asset: PHAsset
        let trashed: Bool
    }

    private struct DetailItem: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    private struct FlyingCard {
        let token = UUID()
        let asset: PHAsset
        var offset: CGSize
    }

    private enum Role {
        case next
        case top
        case flying(CGSize)
    }

    /// 畫面上的每張卡片。用照片本身當身分，卡片從「下一張」變成「目前這張」再飛出去時，
    /// 已載入的圖片與進行中的 iCloud 下載都會跟著走，不會重新載入。
    private struct CardItem: Identifiable {
        let asset: PHAsset
        let role: Role
        var id: String { asset.localIdentifier }
    }

    private struct CardLayout {
        var offset: CGSize
        var scale: CGFloat
        var zIndex: Double
        var isTop: Bool
    }

    private var current: PHAsset? { index < queue.count ? queue[index] : nil }
    private var next: PHAsset? { index + 1 < queue.count ? queue[index + 1] : nil }
    private var trashCount: Int { store.visibleTrashCount(in: library) }

    var body: some View {
        VStack(spacing: 0) {
            if !isReady {
                Spacer()
                ProgressView()
                Spacer()
            } else if current != nil || !flying.isEmpty {
                progressHeader
                cardStack
                controls
            } else {
                CompletionView(
                    wasEmpty: queue.isEmpty,
                    kept: sessionKept,
                    trashed: sessionTrashed,
                    trashTotal: trashCount,
                    canUndo: !history.isEmpty,
                    onUndo: { undo() },
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
                        Image(systemName: trashCount == 0 ? "trash" : "trash.fill")
                        Text(trashCount.formatted())
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
            // 全螢幕預覽蓋上又關掉時，這個畫面會先消失再出現，task 會重跑；
            // 只有第一次才整理佇列，之後只恢復預載，進度與復原紀錄都保留
            if isReady {
                if isVisible { prefetch() }
            } else {
                prepare()
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            Thumbnails.stopPrefetching()
            cachedWindow = []
        }
        .onChange(of: isDragging) { _, active in
            // 手勢被中斷：卡片放回中央
            if !active, drag != .zero {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    drag = .zero
                }
            }
        }
        .fullScreenCover(item: $detail) { item in
            AssetDetailView(asset: item.asset)
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
                Text("\(min(index + 1, queue.count)) of \(queue.count)")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Text("← Trash · Keep →")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(index, queue.count)), total: Double(max(queue.count, 1)))
        }
        // iPad 上跟卡片同寬，不要拉滿整個螢幕
        .frame(maxWidth: Layout.maxCardWidth)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 由下往上：下一張、目前這張、正在飛出去的
    private var cardItems: [CardItem] {
        var items: [CardItem] = []
        if let next { items.append(CardItem(asset: next, role: .next)) }
        if let current { items.append(CardItem(asset: current, role: .top)) }
        for card in flying {
            items.append(CardItem(asset: card.asset, role: .flying(card.offset)))
        }
        return items
    }

    private func layout(for role: Role, progress: CGFloat) -> CardLayout {
        switch role {
        case .next:
            // 拖到 120pt 時後面那張已長到全尺寸，換卡時不會跳
            return CardLayout(
                offset: CGSize(width: 0, height: 12 * (1 - progress)),
                scale: 0.94 + 0.06 * progress,
                zIndex: 0,
                isTop: false
            )
        case .top:
            return CardLayout(offset: drag, scale: 1, zIndex: 1, isTop: true)
        case .flying(let offset):
            return CardLayout(offset: offset, scale: 1, zIndex: 2, isTop: false)
        }
    }

    private var cardStack: some View {
        GeometryReader { geo in
            // iPhone 填滿可用空間；iPad 限制寬度並維持直式比例，卡片置中
            let size = Layout.cardSize(in: geo.size)
            let progress = min(1, abs(drag.width) / 120)
            ZStack {
                ForEach(cardItems) { item in
                    let cardLayout = layout(for: item.role, progress: progress)
                    PhotoCard(asset: item.asset, size: size, isFavorite: isFavorite(item.asset))
                        .overlay(alignment: .topLeading) {
                            stamp("KEEP", color: .green, opacity: cardLayout.offset.width / 100)
                                .rotationEffect(.degrees(-15))
                                .padding(24)
                        }
                        .overlay(alignment: .topTrailing) {
                            stamp("TRASH", color: .red, opacity: -cardLayout.offset.width / 100)
                                .rotationEffect(.degrees(15))
                                .padding(24)
                        }
                        .overlay {
                            // 雙擊時照片中央跳出的大愛心，跟著卡片一起移動
                            if let burst = heartBurst, burst.assetID == item.id {
                                HeartBurst()
                                    .id(burst.token)
                            }
                        }
                        .scaleEffect(cardLayout.scale)
                        .offset(cardLayout.offset)
                        .rotationEffect(.degrees(Double(cardLayout.offset.width / 18)), anchor: .bottom)
                        .gesture(
                            TapGesture(count: 2)
                                .onEnded { likeByDoubleTap(item.asset) }
                                .exclusively(before: TapGesture().onEnded { openDetail(item.asset) })
                        )
                        .gesture(dragGesture(for: item.asset))
                        .allowsHitTesting(cardLayout.isTop)
                        .zIndex(cardLayout.zIndex)
                }
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

    private var controls: some View {
        let hasCard = current != nil
        let favorite = current.map { isFavorite($0) } ?? false
        return HStack(spacing: 24) {
            CircleButton(systemImage: "arrow.uturn.backward", color: .secondary, size: 52, label: "Undo") {
                undo()
            }
            .disabled(history.isEmpty)
            .opacity(history.isEmpty ? 0.4 : 1)

            CircleButton(systemImage: "trash.fill", color: .red, size: 68, label: "Trash") {
                commit(trashed: true)
            }
            .disabled(!hasCard)

            CircleButton(systemImage: "checkmark", color: .green, size: 68, label: "Keep") {
                commit(trashed: false)
            }
            .disabled(!hasCard)

            CircleButton(
                systemImage: favorite ? "heart.fill" : "heart",
                color: .pink, size: 52, label: "Favorite"
            ) {
                if let current { toggleFavorite(current) }
            }
            .disabled(!hasCard)
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: - 手勢與動作

    private func isTop(_ asset: PHAsset) -> Bool {
        asset.localIdentifier == current?.localIdentifier
    }

    /// 單擊要等雙擊判定逾時（約 0.3 秒）才觸發；這段時間內若已經滑走，就不要打開別張
    private func openDetail(_ asset: PHAsset) {
        guard isTop(asset) else { return }
        detail = DetailItem(asset: asset)
    }

    /// 每張卡片有自己的拖曳手勢：拖到一半這張不再是最上面（例如另一隻手指按了復原），
    /// 就不去移動或送出別張卡片
    private func dragGesture(for asset: PHAsset) -> some Gesture {
        // 用全域座標：卡片本身會跟著手指移動旋轉，用自身座標會讓位移量抖動
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard isTop(asset) else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard isTop(asset) else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        drag = .zero
                    }
                    return
                }
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
        // 透過目前的圖庫重新取得 PHAsset：已刪除的照片會被排除，最愛等屬性也是最新的
        queue = group.ids.compactMap { id in
            store.isReviewed(id) ? nil : library.assetsByID[id]
        }
        index = 0
        drag = .zero
        flying = []
        history = []
        sessionKept = 0
        sessionTrashed = 0
        isReady = true
        Thumbnails.stopPrefetching()
        cachedWindow = []
        prefetch()
    }

    /// 清掉這組的「保留」標記後重來（垃圾桶內的不動）
    private func reviewAgain() {
        store.resetKept(for: group.ids)
        prepare()
    }

    private func commit(trashed: Bool) {
        guard let asset = current else { return }
        Haptics.impact(trashed ? .rigid : .light)
        apply(trashed: trashed, to: asset)

        // 這張交給 flying 繼續飛出去；因為卡片身分跟著照片走，它會從手指放開的位置接著飛。
        // 下一張同時升上來，馬上就能滑。
        let direction: CGFloat = trashed ? -1 : 1
        let card = FlyingCard(
            asset: asset,
            offset: CGSize(width: direction * Layout.flyOutDistance, height: drag.height * 1.6)
        )
        withAnimation(.easeOut(duration: 0.28)) {
            flying.append(card)
            index += 1
            drag = .zero
        }

        let token = card.token
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                flying.removeAll { $0.token == token }
            }
        }
        if isVisible { prefetch() }
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
        guard let last = history.last else { return }
        let id = last.asset.localIdentifier
        // 這張已經從垃圾桶真正刪除了：無法復原，也不能跳過它（佇列位置會對不上），
        // 所以清空復原紀錄
        guard library.assetIDs.contains(id) else {
            history.removeAll()
            return
        }
        history.removeLast()
        store.clearDecision(id)
        if last.trashed { sessionTrashed -= 1 } else { sessionKept -= 1 }
        Haptics.impact(.light)
        // 還在飛的話，同一張卡片會從目前位置彈回中央
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            flying.removeAll { $0.asset.localIdentifier == id }
            index = max(0, index - 1)
            drag = .zero
        }
        if isVisible { prefetch() }
    }

    private func isFavorite(_ asset: PHAsset) -> Bool {
        favoriteOverrides[asset.localIdentifier] ?? asset.isFavorite
    }

    /// ♥ 按鈕：加入或取消最愛
    private func toggleFavorite(_ asset: PHAsset) {
        setFavorite(asset, !isFavorite(asset))
        Haptics.notify(.success)
    }

    /// 雙擊卡片：照片中央跳出大愛心並加入最愛。
    /// 跟 Instagram 一樣只加入、不取消，連點兩次不會不小心取消；要取消請按 ♥ 按鈕。
    private func likeByDoubleTap(_ asset: PHAsset) {
        let burst = HeartBurstItem(assetID: asset.localIdentifier)
        heartBurst = burst
        if isFavorite(asset) {
            Haptics.impact(.light)
        } else {
            setFavorite(asset, true)
            Haptics.notify(.success)
        }
        // 動畫結束後拿掉（期間又雙擊的話，以新的那次為準）
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if heartBurst?.token == burst.token { heartBurst = nil }
        }
    }

    private func setFavorite(_ asset: PHAsset, _ newValue: Bool) {
        let id = asset.localIdentifier
        let oldValue = isFavorite(asset)
        favoriteOverrides[id] = newValue
        Task {
            do {
                try await library.setFavorite(asset, newValue)
            } catch {
                favoriteOverrides[id] = oldValue
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    /// 只預載目前這張起的 6 張；滑過的就請 PhotoKit 放掉，長時間滑也不會越吃越多記憶體
    private func prefetch() {
        let upcoming = index < queue.count ? Array(queue[index..<min(index + 6, queue.count)]) : []
        let keepIDs = Set(upcoming.map(\.localIdentifier))
        let cachedIDs = Set(cachedWindow.map(\.localIdentifier))
        Thumbnails.stopPrefetch(cachedWindow.filter { !keepIDs.contains($0.localIdentifier) })
        Thumbnails.prefetch(upcoming.filter { !cachedIDs.contains($0.localIdentifier) })
        cachedWindow = upcoming
    }
}

// MARK: - 子元件

private struct HeartBurstItem {
    let token = UUID()
    let assetID: String
}

/// 雙擊照片時中央跳出的大愛心：彈出放大，停一下後淡出
private struct HeartBurst: View {
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 110))
            .foregroundStyle(.pink)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                    scale = 1
                    opacity = 1
                }
                try? await Task.sleep(for: .milliseconds(550))
                withAnimation(.easeOut(duration: 0.25)) {
                    scale = 1.25
                    opacity = 0
                }
            }
    }
}

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
    let canUndo: Bool
    let onUndo: () -> Void
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
            if canUndo {
                // 最後一張滑錯也能救回來
                Button {
                    onUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.large)
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
        // iPad 上按鈕不要拉滿整個螢幕
        .frame(maxWidth: Layout.narrowWidth)
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

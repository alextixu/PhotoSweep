import AVKit
import Photos
import SwiftUI

/// 全螢幕預覽：照片可捏合縮放、雙擊放大、拖曳平移、下拉關閉；影片直接播放
struct AssetDetailView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// 捏合時不讓單指平移跟著動，避免邊縮放邊漂移
    @State private var isPinching = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if asset.mediaType == .video {
                AssetVideoPlayer(asset: asset)
            } else {
                GeometryReader { geo in
                    let container = geo.size
                    AssetImage(
                        asset: asset,
                        targetSize: CGSize(width: 4096, height: 4096),
                        displayMode: .fit,
                        cache: false,
                        // 先顯示卡片已經載好的 2000px 版本，不會先閃一張模糊的
                        placeholder: Thumbnails.cached(asset.localIdentifier, Thumbnails.cardTargetSize)
                    )
                    .scaleEffect(scale)
                    .offset(offset)
                    // 手勢掛在固定不動的全螢幕範圍上：點上下黑邊也有反應，
                    // 圖片移到哪裡都不會讓手勢跟著跑掉
                    .frame(width: container.width, height: container.height)
                    .contentShape(Rectangle())
                    .gesture(magnifyGesture(container: container))
                    .simultaneousGesture(panGesture(container: container))
                    .onTapGesture(count: 2) { toggleZoom() }
                }
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .statusBarHidden(true)
    }

    // MARK: - 手勢

    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                scale = min(max(lastScale * value.magnification, 1), 6)
                // 縮小時可移動範圍跟著變小，位置要一起收回來
                offset = clamped(lastOffset, scale: scale, container: container)
            }
            .onEnded { _ in
                isPinching = false
                lastScale = scale
                if scale <= 1.02 {
                    resetZoom()
                } else {
                    offset = clamped(offset, scale: scale, container: container)
                    lastOffset = offset
                }
            }
    }

    private func panGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isPinching else { return }
                if scale > 1 {
                    let proposed = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                    offset = clamped(proposed, scale: scale, container: container)
                } else {
                    // 沒放大時往下拉：照片跟著手指走，放開超過 120pt 就關閉
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if !isPinching, value.translation.height > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = .zero
                    }
                }
            }
    }

    private func toggleZoom() {
        if scale > 1 {
            resetZoom()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                scale = 2.5
                lastScale = 2.5
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - 平移範圍

    /// 照片以 fit 放進畫面時的實際大小
    private func fittedSize(in container: CGSize) -> CGSize {
        let width = CGFloat(max(asset.pixelWidth, 1))
        let height = CGFloat(max(asset.pixelHeight, 1))
        let ratio = min(container.width / width, container.height / height)
        return CGSize(width: width * ratio, height: height * ratio)
    }

    /// 放大後最多能移多遠：照片邊緣剛好貼齊螢幕邊緣為止，不會被拖出畫面
    private func clamped(_ proposed: CGSize, scale: CGFloat, container: CGSize) -> CGSize {
        let fitted = fittedSize(in: container)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

/// 用 PhotoKit 取得 AVPlayerItem 後播放（含 iCloud 上的影片）
struct AssetVideoPlayer: View {
    let asset: PHAsset

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if failed {
                ContentUnavailableView("Can't play this video", systemImage: "video.slash")
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        let asset = self.asset
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let manager = PHImageManager.default()

        let stream = AsyncStream<AVPlayerItem?> { continuation in
            let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.yield(item)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestID)
            }
        }

        var item: AVPlayerItem?
        for await value in stream {
            item = value
            break
        }
        if let item {
            player = AVPlayer(playerItem: item)
        } else {
            failed = true
        }
    }
}

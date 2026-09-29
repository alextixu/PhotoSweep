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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if asset.mediaType == .video {
                AssetVideoPlayer(asset: asset)
            } else {
                AssetImage(
                    asset: asset,
                    targetSize: CGSize(width: 4096, height: 4096),
                    displayMode: .fit,
                    cache: false
                )
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnifyGesture)
                .simultaneousGesture(panGesture)
                .onTapGesture(count: 2) { toggleZoom() }
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

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > 120 {
                    dismiss()
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

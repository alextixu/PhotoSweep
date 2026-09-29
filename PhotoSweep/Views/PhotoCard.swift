import Photos
import SwiftUI

/// 滑動用的照片卡片：整張照片 aspect-fit 在黑底上，上方標籤、下方日期與檔案大小
struct PhotoCard: View {
    let asset: PHAsset
    let size: CGSize
    let isFavorite: Bool

    @State private var bytes: Int64?

    var body: some View {
        ZStack {
            Color.black
            AssetImage(asset: asset, targetSize: Thumbnails.cardTargetSize, displayMode: .fit)
        }
        .overlay(alignment: .top) { badges }
        .overlay(alignment: .bottom) { footer }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .task(id: asset.localIdentifier) {
            bytes = await SizeCache.shared.bytes(for: asset)
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if asset.mediaType == .video {
                Badge(text: Text(verbatim: durationString), systemImage: "play.fill")
            }
            if asset.mediaSubtypes.contains(.photoLive) {
                Badge(text: Text(verbatim: "LIVE"), systemImage: "livephoto")
            }
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                Badge(text: Text("Screenshot"), systemImage: "camera.viewfinder")
            }
            Spacer()
            if isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let date = asset.creationDate {
                Text(date.formatted(date: .long, time: .shortened))
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("No Date")
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(verbatim: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                if let bytes, bytes > 0 {
                    Text(verbatim: "·")
                    Text(verbatim: ByteFormat.string(bytes))
                }
            }
            .font(.caption)
            .opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        )
        .foregroundStyle(.white)
    }

    private var durationString: String {
        let total = Int(asset.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Badge: View {
    let text: Text
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            text
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

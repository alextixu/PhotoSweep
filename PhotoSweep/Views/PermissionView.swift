import SwiftUI
import UIKit

/// 第一次啟動的引導頁：說明玩法並請求照片權限；被拒絕時引導到系統設定
struct PermissionView: View {
    @Environment(PhotoLibrary.self) private var library
    @State private var isRequesting = false

    private var isDenied: Bool {
        library.authorization == .denied || library.authorization == .restricted
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("Tidy up your photos")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Go through your library one photo at a time. Keep the good ones, toss the rest.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "hand.point.right.fill", color: .green,
                    title: "Swipe right to keep",
                    detail: "The photo stays exactly where it is."
                )
                FeatureRow(
                    icon: "hand.point.left.fill", color: .red,
                    title: "Swipe left to trash",
                    detail: "It goes to the app's trash first. Nothing is deleted yet."
                )
                FeatureRow(
                    icon: "heart.fill", color: .pink,
                    title: "Double-tap to favorite",
                    detail: "Synced with the Favorites album in Photos."
                )
                FeatureRow(
                    icon: "trash.fill", color: .orange,
                    title: "Empty the trash when you're ready",
                    detail: "iOS keeps deleted photos in Recently Deleted for 30 days."
                )
            }
            .padding(.horizontal)

            Spacer()

            if isDenied {
                Text("Photo access is turned off. Enable it in Settings to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    isRequesting = true
                    Task {
                        await library.requestAccess()
                        isRequesting = false
                    }
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)
            }

            Text("Your photos never leave your iPhone.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

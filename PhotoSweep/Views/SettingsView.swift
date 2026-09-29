import SwiftUI

/// 設定：統計、重設進度、關於
struct SettingsView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var confirmResetProgress = false
    @State private var confirmResetAll = false

    var body: some View {
        NavigationStack {
            List {
                Section("Statistics") {
                    LabeledContent("Photos in library", value: library.allAssets.count.formatted())
                    LabeledContent("Reviewed", value: store.reviewedCount.formatted())
                    LabeledContent("Deleted", value: store.deletedCount.formatted())
                    LabeledContent("Space freed", value: ByteFormat.string(store.freedBytes))
                }

                Section {
                    Button("Reset review progress") {
                        confirmResetProgress = true
                    }
                    Button("Erase all app data", role: .destructive) {
                        confirmResetAll = true
                    }
                } footer: {
                    Text("Resetting only affects this app's records. Your photos are not touched.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Text("Photos you swipe left on go to the trash inside this app. They are only deleted when you empty the trash, and iOS keeps them in Recently Deleted for another 30 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Your photos never leave your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Reset review progress?", isPresented: $confirmResetProgress, titleVisibility: .visible) {
                Button("Reset Progress", role: .destructive) {
                    store.resetKept(for: Array(store.kept))
                }
            } message: {
                Text("All photos will be marked as unreviewed. The trash is kept.")
            }
            .confirmationDialog("Erase all app data?", isPresented: $confirmResetAll, titleVisibility: .visible) {
                Button("Erase Everything", role: .destructive) {
                    store.resetAll()
                }
            } message: {
                Text("Progress, trash and statistics will be cleared. Your photos stay in your library.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

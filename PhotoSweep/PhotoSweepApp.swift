import SwiftUI
import AVFoundation

@main
struct PhotoSweepApp: App {
    @State private var library = PhotoLibrary()
    @State private var store = ReviewStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 靜音開關打開時，預覽影片仍要有聲音
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            // 進背景前把進度立刻寫入磁碟（平常是延遲 300ms 批次寫入）
            if phase == .background || phase == .inactive {
                store.flush()
            }
        }
    }
}

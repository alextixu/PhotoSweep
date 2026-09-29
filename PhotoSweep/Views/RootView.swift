import SwiftUI

/// 依授權狀態決定顯示主畫面還是授權引導
struct RootView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.hasAccess {
                HomeView()
            } else {
                PermissionView()
            }
        }
        .task(id: library.hasAccess) {
            if library.hasAccess, !library.hasLoaded {
                await library.load()
            }
        }
        .onChange(of: library.generation) { _, _ in
            // 圖庫重載後，清掉已不存在的照片紀錄
            store.prune(keeping: library.assetIDs)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAuthorization()
            }
        }
    }
}

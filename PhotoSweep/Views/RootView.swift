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
            // 圖庫重載後，清掉已不存在的照片紀錄。
            // 只在「完整取用」且真的有抓到照片時才清：「僅限所選照片」只看得到一部分，
            // 圖庫暫時抓不到東西時也可能是空的，這兩種情況清下去會把其他照片的決定全部抹掉。
            // 看的是「抓這份快照當下」的權限，不是現在的：部分快照在升級成完整取用後才載完，也不能拿來清
            guard library.lastLoadHadFullAccess, !library.assetIDs.isEmpty else { return }
            store.prune(keeping: library.assetIDs)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAuthorization()
            }
        }
    }
}

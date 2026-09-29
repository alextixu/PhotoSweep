# PhotoSweep

**Swipe through your iPhone photo library one picture at a time — keep the good ones, trash the rest, free up space.**
A Picnic-style photo cleaner built with SwiftUI + PhotoKit. Nothing is deleted until you empty the trash, and iOS keeps deleted photos in *Recently Deleted* for another 30 days.

**Picnic 風格的 iPhone 刪照片 App**——一張一張滑：右滑保留、左滑丟垃圾桶、雙擊加最愛。清空垃圾桶前不會真的刪除任何照片。

## Features · 功能

- **Swipe to decide** — right to keep, left to trash; the same two buttons below the card, plus undo
- **Double-tap to favorite** — synced with the Favorites album in Apple Photos
- **Tap to inspect** — full-screen view with pinch-zoom; videos play inline
- **Browse by month** — every month is a deck; progress is remembered, and “Review Again” restarts a month
- **Quick modes** — Random, Screenshots, Videos, Favorites, All Photos
- **Trash with a safety net** — grid view, restore one or all, total size shown, one-tap empty (iOS asks you to confirm)
- **Stats** — reviewed count, items in trash, space freed
- **Works with limited access & iCloud** — “Selected Photos Only” is supported; iCloud originals load on demand
- **100% on-device** — no network, no accounts, no analytics
- **UI in your language** — Traditional Chinese, Simplified Chinese, English (follows the system language)

<details>
<summary>中文功能說明</summary>

- 右滑保留、左滑進垃圾桶，卡片下方也有按鈕，可復原上一步
- 雙擊加入最愛，與「照片」App 的最愛相簿同步
- 單擊看大圖（捏合縮放），影片直接播放
- 依月份分組，每個月的檢視進度會記住；「重新檢視」可重來
- 快速模式：隨機、螢幕截圖、影片、最愛、所有照片
- 垃圾桶：格狀縮圖、單張／全部還原、顯示總大小、一鍵清空（iOS 會再確認一次）
- 統計：已檢視、垃圾桶數量、已釋放空間
- 支援「僅限所選照片」與 iCloud 照片
- 完全離線，照片不會離開手機
- 三語介面：繁體中文、简体中文、English

</details>

## How deletion works · 刪除機制

1. Swiping left only records the photo's identifier in the app's own trash list. Your library is untouched.
2. Emptying the trash calls PhotoKit's delete API; iOS shows its own confirmation dialog.
3. Deleted photos land in Apple Photos → *Recently Deleted* and can be recovered for 30 days.

左滑只是把照片記進 App 自己的清單；清空垃圾桶時才透過 PhotoKit 刪除，且 iOS 會跳系統確認框；刪掉的照片還會在「最近刪除」保留 30 天。

## Requirements · 需求

- Xcode 16 or later · iOS 17.0+
- Test on a real iPhone — the Simulator only has a handful of sample photos

## Build · 建置

1. Open `PhotoSweep.xcodeproj` in Xcode.
2. *Signing & Capabilities* → choose your Team. Bundle ID is `com.lintaixu.PhotoSweep`; change it if you like.
3. Run on your iPhone. Grant photo access on first launch.

If the project file refuses to open in your Xcode version, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen && xcodegen generate
```

## No Mac? Build on GitHub, install with Sideloadly · 沒有 Mac 的安裝方式

1. Push this folder to a GitHub repo. The workflow in `.github/workflows/build-ipa.yml` builds an **unsigned** `PhotoSweep-unsigned.ipa` on GitHub's macOS runner (Actions tab → *Build unsigned IPA* → *Run workflow* → download the artifact).
2. On Windows, install iTunes and iCloud (the versions from apple.com, not the Microsoft Store), then [Sideloadly](https://sideloadly.io).
3. Plug in your iPhone, drag the `.ipa` into Sideloadly, enter your Apple ID, Start.
4. On the iPhone: *Settings → General → VPN & Device Management* → trust your Apple ID; on iOS 16+ also enable *Settings → Privacy & Security → Developer Mode*.
5. With a free Apple ID the app expires after 7 days — just run Sideloadly again.

把資料夾推上 GitHub 後，Actions 會自動編出未簽名的 .ipa；在 Windows 用 Sideloadly 以自己的 Apple ID 簽名安裝。免費帳號 7 天到期，重新 Sideloadly 一次即可。

## Project structure · 專案結構

```
PhotoSweep/
├── PhotoSweepApp.swift          進入點；注入 PhotoLibrary / ReviewStore
├── Models/
│   ├── AssetGroup.swift         一組照片（月份、截圖、影片…）與導覽 Route
│   └── ReviewStore.swift        保留／垃圾桶紀錄與統計，存成 JSON
├── Services/
│   ├── PhotoLibrary.swift       PhotoKit：授權、載入分組、監聽變動、刪除、最愛
│   ├── Thumbnails.swift         PHCachingImageManager + NSCache 與 AssetImage 元件
│   ├── SizeCache.swift          檔案大小快取
│   └── Haptics.swift
├── Views/
│   ├── RootView.swift           授權狀態分流
│   ├── PermissionView.swift     引導頁／權限被拒
│   ├── HomeView.swift           統計、快速模式、月份列表
│   ├── SwipeView.swift          滑動卡片、手勢、復原、完成畫面
│   ├── PhotoCard.swift          單張卡片（標籤、日期、大小）
│   ├── AssetDetailView.swift    全螢幕預覽／影片播放
│   ├── TrashView.swift          垃圾桶格狀、還原、清空
│   └── SettingsView.swift       統計、重設、關於
├── Localizable.xcstrings        三語字串目錄
├── InfoPlist.xcstrings          照片權限說明文字
└── Assets.xcassets              App 圖示、強調色
```

## Notes · 備註

- File sizes are read from `PHAssetResource` via the undocumented `fileSize` key (the same approach most cleaner apps use); if it ever disappears the app shows no size instead of crashing.
- No duplicate / similar-photo detection yet.
- Status: first version, not yet on the App Store. Screenshots will be added after the first device build.

## License

MIT © 2026 lintaixu

import Photos
import SwiftUI

/// 主畫面：統計、快速模式、依月份列表
struct HomeView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var store
    @State private var path = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if library.authorization == .limited {
                    limitedSection
                }
                statsSection
                quickSection
                monthsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("PhotoSweep")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .swipe(let group):
                    SwipeView(group: group)
                case .trash:
                    TrashView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(Route.trash)
                    } label: {
                        Image(systemName: store.trash.isEmpty ? "trash" : "trash.fill")
                    }
                    .accessibilityLabel("Trash")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !store.trash.isEmpty {
                    trashBar
                }
            }
            .overlay {
                if library.isLoading, !library.hasLoaded {
                    ProgressView("Loading your library…")
                }
            }
            .refreshable {
                await library.load()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - 區塊

    private var limitedSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limited photo access")
                        .font(.headline)
                    Text("Only the photos you selected are shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select More") {
                    library.presentLimitedPicker()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                StatTile(value: store.reviewedCount.formatted(), label: "Reviewed", color: .blue)
                Divider()
                StatTile(value: store.trash.count.formatted(), label: "In Trash", color: .red)
                Divider()
                StatTile(value: ByteFormat.string(store.freedBytes), label: "Freed", color: .green)
            }
            .padding(.vertical, 4)
        }
    }

    private var quickSection: some View {
        Section("Quick Start") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    QuickTile(kind: .random, count: library.allAssets.count, color: .purple) { open(.random) }
                    QuickTile(kind: .screenshots, count: library.screenshots.count, color: .blue) { open(.screenshots) }
                    QuickTile(kind: .videos, count: library.videos.count, color: .orange) { open(.videos) }
                    QuickTile(kind: .favorites, count: library.favorites.count, color: .pink) { open(.favorites) }
                    QuickTile(kind: .all, count: library.allAssets.count, color: .green) { open(.all) }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var monthsSection: some View {
        Section("By Month") {
            if library.monthGroups.isEmpty, library.hasLoaded {
                Text("No photos found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.monthGroups) { group in
                NavigationLink(value: Route.swipe(group)) {
                    MonthRow(group: group)
                }
            }
        }
    }

    private var trashBar: some View {
        Button {
            path.append(Route.trash)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill")
                Text("\(store.trash.count) in trash")
                    .fontWeight(.semibold)
                Spacer()
                Text("Review")
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func open(_ kind: AssetGroup.Kind) {
        let group = library.quickGroup(kind)
        guard !group.assets.isEmpty else { return }
        path.append(Route.swipe(group))
    }
}

// MARK: - 子元件

private struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuickTile: View {
    let kind: AssetGroup.Kind
    let count: Int
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                Spacer(minLength: 0)
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(count) items")
                    .font(.caption)
                    .opacity(0.85)
            }
            .padding(12)
            .frame(width: 128, height: 104, alignment: .leading)
            .foregroundStyle(.white)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.45 : 1)
    }
}

private struct MonthRow: View {
    @Environment(ReviewStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let group: AssetGroup

    var body: some View {
        let reviewed = group.assets.reduce(0) { $0 + (store.isReviewed($1.localIdentifier) ? 1 : 0) }
        let isDone = reviewed >= group.count
        HStack(spacing: 12) {
            if let cover = group.cover {
                AssetImage(
                    asset: cover,
                    targetSize: CGSize(width: 56 * displayScale, height: 56 * displayScale),
                    displayMode: .fill
                )
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.kind.title)
                    .font(.headline)
                Text("\(group.count) items · \(reviewed) reviewed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(reviewed), total: Double(max(group.count, 1)))
                    .tint(isDone ? .green : .accentColor)
            }
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

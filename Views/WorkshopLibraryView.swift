import AppKit
import Combine
import Kingfisher
import SwiftUI

enum WorkshopSection: String, CaseIterable, Identifiable {
    case browse
    case subscribed
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .browse: return t("浏览")
        case .subscribed: return t("已订阅")
        case .local: return t("本地")
        }
    }
}

struct WorkshopScopePicker: View {
    @Binding var selection: WorkshopSection

    var body: some View {
        Picker(t("Steam 工坊"), selection: $selection) {
            ForEach(WorkshopSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("mivori.workshop.scope")
    }
}

@MainActor
struct WorkshopLibraryView: View {
    @Binding var section: WorkshopSection
    @ObservedObject var viewModel: MediaExploreViewModel
    @ObservedObject private var steam = SteamServiceManager.shared
    @Environment(\.mainTopBarContentPadding) private var topPadding

    @State private var projects: [WorkshopLocalProject] = []
    @State private var subscriptions: [WorkshopWallpaper] = []
    @State private var lastSynced: Date?
    @State private var snapshotAccount = ""
    @State private var subscriptionIssue: String?
    @State private var activeSubscriptionRequest: UUID?
    @State private var localScan: Task<Void, Never>?
    @State private var subscriptionRefresh: Task<Void, Never>?
    @State private var scannedLocal = false
    @State private var query = ""
    @State private var type: WorkshopWallpaper.WallpaperType?
    @State private var installation: InstallationFilter = .all
    @State private var selectedItem: Entry?
    @State private var showLogin = false
    @State private var actionNotice = ""
    @State private var activeAction: String?

    private static let columns = [GridItem(.adaptive(minimum: 156, maximum: 280), spacing: 14)]

    private enum InstallationFilter: String, CaseIterable {
        case all, ready, pending

        var title: String {
            switch self {
            case .all: return t("全部状态")
            case .ready: return t("已下载")
            case .pending: return t("待下载")
            }
        }
    }

    private struct Entry: Identifiable {
        let id: String
        let local: WorkshopLocalProject?
        let subscription: WorkshopWallpaper?

        var title: String { local?.title ?? subscription?.title ?? id }
        var type: WorkshopWallpaper.WallpaperType { local?.type ?? subscription?.type ?? .unknown }
        var description: String? { local?.description ?? subscription?.description }
        var tags: [String] { local?.tags ?? subscription?.tags ?? [] }
        var isInstalled: Bool { local != nil }
        var stateTitle: String { isInstalled ? t("已下载") : t("待下载") }
        var typeTitle: String {
            switch type {
            case .video: return t("视频")
            case .scene, .pkg: return t("场景")
            case .web: return "Web"
            case .image: return t("图片")
            case .unknown: return t("工坊作品")
            }
        }
    }

    private var activeSteamAccount: String { steam.isLoggedIn ? steam.steamID : "" }

    private var entries: [Entry] {
        if section == .local {
            return projects.map { Entry(id: $0.id, local: $0, subscription: nil) }
        }

        guard !activeSteamAccount.isEmpty, activeSteamAccount == snapshotAccount else { return [] }
        let matches = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return subscriptions.map { wallpaper in
            Entry(id: wallpaper.id, local: matches[wallpaper.id], subscription: wallpaper)
        }
    }

    private var visibleEntries: [Entry] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (type == nil || type == entry.type || (type == .scene && entry.type == .pkg))
            && (installation == .all || section == .local || (installation == .ready) == entry.isInstalled)
            && (phrase.isEmpty || ([entry.title, entry.id] + entry.tags).contains {
                $0.localizedStandardContains(phrase)
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 28)
                .padding(.top, topPadding + 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !actionNotice.isEmpty {
                        Text(actionNotice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mivori.workshop.actionStatus")
                    }
                    if section == .subscribed && activeSteamAccount.isEmpty {
                        loginPrompt
                    } else {
                        filterBar
                        results
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: 1500, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityIdentifier("mivori.workshop.library")
        .onAppear {
            steam.start()
            scanLocal()
        }
        .task(id: activeSteamAccount) { await refreshForAccount(activeSteamAccount) }
        .onChange(of: section) { _, _ in
            query = ""
            type = nil
            installation = .all
            actionNotice = ""
            scanLocal()
            if section == .subscribed, lastSynced == nil { refreshSubscriptions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedLibraryContentsChanged)) { _ in scanLocal() }
        .onReceive(NotificationCenter.default.publisher(for: .downloadPathChanged)) { _ in scanLocal() }
        .onReceive(MediaLibraryService.shared.$downloadRecords.debounce(for: .milliseconds(240), scheduler: RunLoop.main)) { _ in
            scanLocal()
        }
        .onDisappear {
            localScan?.cancel()
            subscriptionRefresh?.cancel()
        }
        .sheet(isPresented: $showLogin) { WorkshopSteamLoginView() }
        .sheet(item: $selectedItem) { original in
            detail(entries.first(where: { $0.id == original.id }) ?? original)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Wallpaper Engine 工坊"))
                .font(.system(size: 26, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if section == .subscribed, !activeSteamAccount.isEmpty {
                if let lastSynced, snapshotAccount == activeSteamAccount {
                    Text(String(format: t("上次同步 %@"), lastSynced.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let subscriptionIssue {
                    Label(subscriptionIssue, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                WorkshopScopePicker(selection: $section)
                Spacer(minLength: 4)
                toolbarActions
            }
            VStack(alignment: .leading, spacing: 10) {
                WorkshopScopePicker(selection: $section)
                toolbarActions
            }
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if section == .local {
            Button { scanLocal() } label: {
                Label(t("重新扫描"), systemImage: "arrow.clockwise")
            }
            .disabled(!scannedLocal)
            .accessibilityIdentifier("mivori.workshop.rescan")
        } else if !activeSteamAccount.isEmpty {
            Button { refreshSubscriptions() } label: {
                Label(t("同步订阅"), systemImage: "arrow.clockwise")
            }
            .disabled(activeSubscriptionRequest != nil)
            .accessibilityIdentifier("mivori.workshop.sync")
        }
    }

    private var loginPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(t("登录 Steam 查看已订阅的壁纸"))
                .font(.title3.weight(.semibold))
            Text(t("Mivori 会从 Steam 同步当前账号的 Wallpaper Engine 订阅。已下载的壁纸可以直接在「本地」查看。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { loginActions }
                VStack(alignment: .leading, spacing: 8) { loginActions }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var loginActions: some View {
        Button(t("登录 Steam…")) { showLogin = true }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("mivori.workshop.login")
        Button(t("在 Steam 中查看已订阅")) { openSteamSubscriptions() }
            .accessibilityIdentifier("mivori.workshop.openSteam")
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                filters
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                HStack { filters }
            }
        }
    }

    private var searchField: some View {
        TextField(t("搜索壁纸名称、标签或 ID"), text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, maxWidth: 340)
            .accessibilityIdentifier("mivori.workshop.search")
    }

    @ViewBuilder
    private var filters: some View {
        Picker(t("类型"), selection: $type) {
            Text(t("全部类型")).tag(WorkshopWallpaper.WallpaperType?.none)
            Text(t("视频")).tag(WorkshopWallpaper.WallpaperType?.some(.video))
            Text(t("场景")).tag(WorkshopWallpaper.WallpaperType?.some(.scene))
            Text("Web").tag(WorkshopWallpaper.WallpaperType?.some(.web))
            Text(t("图片")).tag(WorkshopWallpaper.WallpaperType?.some(.image))
        }
        .fixedSize()
        .labelsHidden()
        .accessibilityIdentifier("mivori.workshop.type")

        if section == .subscribed {
            Picker(t("下载状态"), selection: $installation) {
                ForEach(InstallationFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .fixedSize()
            .labelsHidden()
            .accessibilityIdentifier("mivori.workshop.installation")
        }
    }

    @ViewBuilder
    private var results: some View {
        if !visibleEntries.isEmpty {
            Text(String(format: t("显示 %d 项壁纸"), visibleEntries.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                ForEach(visibleEntries) { entry in card(entry) }
            }
        } else if (section == .local && !scannedLocal) || activeSubscriptionRequest != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(section == .local ? t("正在扫描本地壁纸…") : t("正在同步 Steam 订阅…"))
            }
            .padding(.vertical, 20)
        } else if !entries.isEmpty {
            emptyState(t("没有符合筛选条件的壁纸"), icon: "magnifyingglass")
        } else if section == .local {
            emptyState(t("未找到已下载的 Wallpaper Engine 壁纸"), icon: "folder")
        } else if lastSynced != nil, snapshotAccount == activeSteamAccount {
            emptyState(t("这个 Steam 账号没有订阅 Wallpaper Engine 壁纸"), icon: "bookmark")
        } else if subscriptionIssue == nil {
            emptyState(t("选择「同步订阅」以读取当前账号的订阅"), icon: "arrow.trianglehead.clockwise")
        }
    }

    private func emptyState(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func card(_ entry: Entry) -> some View {
        Button {
            actionNotice = ""
            selectedItem = entry
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                cover(entry, height: 119)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2, reservesSpace: true)
                        .foregroundStyle(.primary)
                    HStack {
                        Text(entry.typeTitle)
                        Spacer(minLength: 4)
                        Label(entry.stateTitle, systemImage: entry.isInstalled ? "checkmark.circle" : "arrow.down.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(11)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([entry.title, entry.typeTitle, entry.stateTitle].joined(separator: ", "))
        .accessibilityIdentifier("mivori.workshop.item.\(entry.id)")
    }

    private func cover(_ entry: Entry, height: CGFloat) -> some View {
        Color.secondary.opacity(0.12)
            .overlay {
                if let url = entry.local?.previewURL ?? entry.subscription?.previewURL {
                    KFImage(url)
                        .placeholder { coverPlaceholder }
                        .resizable()
                        .scaledToFill()
                } else {
                    coverPlaceholder
                }
            }
            .frame(height: height)
            .clipped()
            .accessibilityHidden(true)
    }

    private var coverPlaceholder: some View {
        Image(systemName: "photo")
            .font(.title2)
            .foregroundStyle(.secondary)
    }

    private func detail(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    cover(entry, height: 194)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 9) {
                        Text(entry.typeTitle)
                        Text(entry.stateTitle)
                        if let source = entry.local?.source { Text(t(source.rawValue)) }
                        Text("ID \(entry.id)")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let description = entry.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(24)
                    }
                    if !actionNotice.isEmpty {
                        Text(actionNotice).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(23)
            }
            .frame(maxHeight: 440)
            Divider()
            HStack(spacing: 10) {
                Button(t("在 Steam 中打开")) {
                    if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(entry.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button(t("关闭")) { selectedItem = nil }
                    .keyboardShortcut(.cancelAction)
                if let local = entry.local {
                    Button(t("设为壁纸")) { apply(local) }
                        .buttonStyle(.borderedProminent)
                        .disabled(activeAction != nil)
                        .accessibilityIdentifier("mivori.workshop.apply")
                } else if let subscription = entry.subscription {
                    Button(t("下载")) { download(subscription) }
                        .buttonStyle(.borderedProminent)
                        .disabled(activeAction != nil || activeSteamAccount.isEmpty || activeSteamAccount != snapshotAccount)
                        .accessibilityIdentifier("mivori.workshop.download")
                }
            }
            .padding(16)
        }
        .frame(width: 475)
    }

    private func scanLocal() {
        localScan?.cancel()
        let mediaFolder = DownloadPathManager.shared.mediaFolderURL
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // An explicit launch argument allows QA to exercise real project files in an isolated library.
        let arguments = ProcessInfo.processInfo.arguments
        let selectedLibrary = arguments.firstIndex(of: "--mivori-workshop-library").flatMap { index -> URL? in
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        localScan = Task {
            let scanned = await Task.detached(priority: .utility) {
                WorkshopLocalLibrary.scan(mediaFolder: mediaFolder, applicationSupport: support, selectedLibrary: selectedLibrary)
            }.value
            guard !Task.isCancelled else { return }
            projects = scanned
            scannedLocal = true
        }
    }

    private func refreshSubscriptions() {
        guard !activeSteamAccount.isEmpty, activeSubscriptionRequest == nil else { return }
        let account = activeSteamAccount
        subscriptionRefresh = Task { await refreshForAccount(account, force: true) }
    }

    private func refreshForAccount(_ account: String, force: Bool = false) async {
        guard !account.isEmpty, activeSteamAccount == account else { return }
        let sameAccount = snapshotAccount == account
        guard force || !sameAccount || lastSynced == nil else { return }
        guard activeSubscriptionRequest == nil || !sameAccount else { return }
        if !sameAccount {
            if section == .subscribed { selectedItem = nil }
            subscriptions = []
            lastSynced = nil
            snapshotAccount = account
        }

        let request = UUID()
        activeSubscriptionRequest = request
        subscriptionIssue = nil
        defer { if activeSubscriptionRequest == request { activeSubscriptionRequest = nil } }
        do {
            let result = try await WorkshopService.shared.fetchAllSubscriptions(steamID: account)
            try Task.checkCancellation()
            guard activeSteamAccount == account, activeSubscriptionRequest == request else { return }
            subscriptions = result
            lastSynced = Date()
        } catch is CancellationError {
            return
        } catch {
            guard activeSteamAccount == account, activeSubscriptionRequest == request else { return }
            subscriptionIssue = lastSynced == nil
                ? error.localizedDescription
                : String(format: t("同步失败，正在显示上次的订阅。%@"), error.localizedDescription)
        }
    }

    private func apply(_ project: WorkshopLocalProject) {
        guard activeAction == nil else { return }
        activeAction = project.id
        actionNotice = t("正在设置壁纸…")
        Task {
            defer { activeAction = nil }
            do {
                let applied = try await LocalWallpaperApplyService.apply(localURL: project.projectURL, targetScreens: nil)
                actionNotice = applied ? t("壁纸已设置") : t("当前没有可用的显示器")
            } catch {
                actionNotice = error.localizedDescription
            }
        }
    }

    private func download(_ wallpaper: WorkshopWallpaper) {
        guard activeAction == nil, !activeSteamAccount.isEmpty else { return }
        activeAction = wallpaper.id
        actionNotice = t("正在向 Steam 提交下载任务…")
        Task {
            defer { activeAction = nil }
            do {
                let mediaItem = WorkshopService.shared.convertToMediaItem(wallpaper)
                try await viewModel.downloadWorkshopWallpaper(mediaItem)
                actionNotice = t("下载完成，可以设为壁纸。")
                scanLocal()
            } catch {
                actionNotice = error.localizedDescription
            }
        }
    }

    private func openSteamSubscriptions() {
        guard let site = URL(string: "https://steamcommunity.com/my/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions"),
              let steamURL = URL(string: "steam://openurl/" + site.absoluteString) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: steamURL) == nil || !NSWorkspace.shared.open(steamURL) {
            NSWorkspace.shared.open(site)
        }
    }
}

//
//  ArtworkSheets.swift
//  MacTagger — 封面三件套的子窗口
//
//  对应原版：FormPictureSearch（从网络搜索封面）、FormPictureFromTags（从标签取图）、
//           以及封面右键菜单里的「更改分辨率 / 内置图片大小限制 / 固定为 JPG」。
//
//  骨架与其余 sheet 一致：SheetTitleBar → card() 分组内容 → SheetButtonBar，
//  所有间距 / 字级 / 颜色取 Theme 令牌。这些窗体由 `ArtworkSheetPresenter`
//  以 AppKit sheet 的方式挂在主窗口上，因此关闭走 presenter 而不是 `@Environment(\.dismiss)`。
//

import SwiftUI
import AppKit

// MARK: - 缩略图缓存

/// 网格缩略图缓存。搜索结果一屏几十张，切换候选、改窗口大小都会重建视图，
/// 没有缓存就会对同一个 URL 反复发请求（各源的限速器会把界面卡成幻灯片）。
final class ArtworkThumbnailCache: @unchecked Sendable {

    static let shared = ArtworkThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 240
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func store(_ image: NSImage, forKey key: String, cost: Int = 0) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// 在线候选的缩略图格子。
struct RemoteArtworkThumbnail: View {

    let candidate: ArtworkCandidate
    var side: CGFloat = 96

    @State private var image: NSImage?
    @State private var failed = false

    private var cacheKey: String {
        candidate.previewURL?.absoluteString
            ?? "\(candidate.sourceID)|\(candidate.track.nativeID)|\(candidate.track.albumID ?? "")"
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder(corner: Theme.Radius.s)
                if !failed { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        // `.task(id:)` 换 id 重跑时，`@State` 是**跟着视图身份留下来的**：
        // 网格滚动 / 换一批候选会复用同一个 `RemoteArtworkThumbnail`，
        // 不清掉上一张图，就会出现「A 的格子里挂着 B 的封面」——
        // 新的一张若加载失败或较慢，那张错图还会一直挂着。
        failed = false
        if let cached = ArtworkThumbnailCache.shared.image(forKey: cacheKey) {
            image = cached
            return
        }
        image = nil
        do {
            let data = try await ArtworkSearchService.thumbnail(candidate, size: 300)
            // 等待期间视图可能已经被复用去画别的候选了，过期结果一律丢弃。
            guard !Task.isCancelled else { return }
            guard let img = NSImage(data: data) else { failed = true; return }
            ArtworkThumbnailCache.shared.store(img, forKey: cacheKey, cost: data.count)
            image = img
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// 本地文件的封面缩略图（从标签取图的左列用）。
struct LocalArtworkThumbnail: View {

    let url: URL
    var side: CGFloat = 40

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder(corner: Theme.Radius.xs)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .strokeBorder(Theme.Colors.artworkStroke))
        .task(id: url) { await load() }
    }

    private func load() async {
        let key = "file:" + url.path
        if let cached = ArtworkThumbnailCache.shared.image(forKey: key) { image = cached; return }
        // 同 `RemoteArtworkThumbnail`：List 复用视图时 `@State image` 会留着上一行的图。
        // 这里尤其致命 —— 新的一行**本来就没有封面**时 `load()` 直接 return，
        // 于是「没有封面」的文件顶着上一行的封面，正好骗过用户的判断。
        image = nil
        let path = url
        let data: Data? = await Task.detached(priority: .utility) {
            (try? TagService.readArtworks(path))?.first?.data
        }.value
        guard !Task.isCancelled else { return }
        guard let data, let img = NSImage(data: data) else { return }
        ArtworkThumbnailCache.shared.store(img, forKey: key, cost: data.count)
        image = img
    }
}

// MARK: - A. 从网络搜索封面（FormPictureSearch）

struct ArtworkSearchSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ArtworkStore

    private var targetCount: Int { max(model.selection.count, 1) }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "photo.on.rectangle.angled",
                          title: "从网络搜索封面",
                          subtitle: "所有勾选的来源并发查询，单个来源失效只淘汰它自己。点选候选可看实际像素与体积。") {
                if store.isSearching { ProgressView().controlSize(.small) }
            }

            queryBar
            sourceBar

            // 逐源结果条：搜出 0 张时，它是唯一能回答「是这些源没这张碟，
            // 还是某个源挂了」的东西 —— 原先只有底部一句灰字，看不出区别。
            // 数据来自 `ArtworkStore.sourceOutcomes`（`ArtworkSearchOutcome.sourceOutcomes` 原样），
            // 不再由界面从候选列表 + 错误摘要反推。
            if !store.sourceOutcomes.isEmpty {
                SourceOutcomeBar(outcomes: store.sourceOutcomes,
                                 trailingNote: "共 \(store.candidates.count) 张候选")
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xs)
                    .overlay(alignment: .bottom) { Divider().opacity(0.4) }
            }

            HStack(spacing: 0) {
                resultGrid
                Divider()
                previewPane
            }
            .frame(maxHeight: .infinity)

            SheetButtonBar {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(store.searchStatus)
                        .font(Theme.Typo.caption)
                        .lineLimit(1).truncationMode(.tail)
                        .help(store.searchStatus)
                    if let err = store.searchError {
                        // 「源：原因；源：原因」串起来动辄七八十个字，一行装不下，
                        // 而这一行是「为什么一张都没搜到」的**唯一**去处：全文必须挂上。
                        Text(err)
                            .font(Theme.Typo.badge)
                            .foregroundStyle(Theme.Colors.warning)
                            .lineLimit(1).truncationMode(.tail)
                            .help(err)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Toggle("添加后覆盖已有封面", isOn: $settings.overwriteArtworkOnAdd)
                    .toggleStyle(.checkbox)
                    .help("关掉则新封面追加在已有封面之后")
                Divider().frame(height: 18)
                Button("取消") { store.cancelSearch(); ArtworkSheetPresenter.shared.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用到选中的 \(targetCount) 个文件") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.previewData == nil)
                    .help("写入选中文件的工作副本，随后弹出保存确认")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 640)
    }

    private func apply() {
        guard let data = store.previewData else { return }
        let caption = store.selectedCandidate.map { "\($0.displayAlbum) · \($0.sourceName)" }
        model.applySearchedArtwork(data, caption: caption)
    }

    private func runSearch() {
        store.runSearch(duration: model.focusRow?.file.technical.duration ?? 0,
                        filename: model.focusRow?.file.url.deletingPathExtension().lastPathComponent)
    }

    // MARK: 查询条

    private var queryBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                labeledField("标题", $store.searchTitle)
                labeledField("艺术家", $store.searchArtist)
                labeledField("专辑", $store.searchAlbum)

                if store.isSearching {
                    Button("停止") { store.cancelSearch() }
                } else {
                    Button { runSearch() } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .help("联网搜索（回车同样可以）")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            Divider()
        }
    }

    private func labeledField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(label).font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
        }
    }

    // MARK: 来源多选

    private var sourceBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Text("来源").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                ForEach(store.availableSourceIDs, id: \.self) { id in
                    Toggle(isOn: Binding(get: { store.enabledSources.contains(id) },
                                         set: { _ in store.toggleSource(id) })) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(SourceBootstrap.displayName(id))
                            Chip(text: ArtworkSearchService.maxEdge(for: id) > 0
                                 ? "\(ArtworkSearchService.maxEdge(for: id)) px" : "原图")
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Chip(text: "已勾选 \(store.activeSourceIDs.count) / \(store.availableSourceIDs.count)")
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
            Divider()
        }
    }

    // MARK: 结果网格

    private var resultGrid: some View {
        Group {
            if store.candidates.isEmpty {
                EmptyStateView(systemImage: "photo.badge.arrow.down",
                               title: store.isSearching ? "正在搜索…" : "没有候选",
                               message: store.isSearching ? nil : "换个标题 / 艺术家 / 专辑再试一次")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 128),
                                                 spacing: Theme.Spacing.s2)],
                              alignment: .leading,
                              spacing: Theme.Spacing.m) {
                        ForEach(store.candidates) { candidate in
                            gridCell(candidate)
                        }
                    }
                    .padding(Theme.Spacing.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridCell(_ candidate: ArtworkCandidate) -> some View {
        let isSelected = store.selectedCandidateID == candidate.id
        return VStack(spacing: Theme.Spacing.xs) {
            RemoteArtworkThumbnail(candidate: candidate, side: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Theme.Colors.artworkStroke,
                                      lineWidth: isSelected ? 2 : 1)
                )
            Text(candidate.displayAlbum)
                .font(Theme.Typo.badge)
                .lineLimit(1).truncationMode(.tail)
            HStack(spacing: Theme.Spacing.xs) {
                Text(SourceBootstrap.displayName(candidate.sourceID))
                Text(candidate.sizeLabel)
            }
            .font(Theme.Typo.badge)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(Theme.Spacing.xs)
        .background(isSelected ? Theme.Colors.accentSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedCandidateID = candidate.id
            store.loadPreview(for: candidate)
        }
        // 卡片下方那两行（专辑名 / 源 · 尺寸）都是单行截断，长专辑名只剩个头，
        // tooltip 得把四项都给全。
        .help("""
              \(candidate.displayTitle) — \(candidate.displayArtist)
              专辑：\(candidate.displayAlbum.isEmpty ? "—" : candidate.displayAlbum)
              \(SourceBootstrap.displayName(candidate.sourceID)) · \(candidate.sizeLabel)
              """)
    }

    // MARK: 放大预览

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            if let candidate = store.selectedCandidate {
                ZStack {
                    if let data = store.previewData, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ArtworkPlaceholder(corner: Theme.Radius.l)
                        if store.isDownloadingPreview { ProgressView().controlSize(.small) }
                    }
                }
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                            .strokeBorder(Theme.Colors.artworkStroke))

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(candidate.displayTitle).font(Theme.Typo.value).lineLimit(2)
                    Text(candidate.displayArtist)
                        .font(Theme.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(candidate.displayAlbum)
                        .font(Theme.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // 预览栏只有 220 pt 宽，日文/全角专辑名两行就到头；三行全文挂 tooltip。
                .help("""
                      \(candidate.displayTitle)
                      \(candidate.displayArtist)
                      \(candidate.displayAlbum)
                      """)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: Theme.Spacing.xs2) {
                    KeyValueRow(label: "来源", value: candidate.sourceName)
                    KeyValueRow(label: "预计尺寸", value: candidate.sizeLabel, mono: true)
                    KeyValueRow(label: "实际像素", value: actualPixels, mono: true)
                    KeyValueRow(label: "字节数", value: actualBytes, mono: true)
                    KeyValueRow(label: "匹配分", value: String(format: "%.3f", candidate.score), mono: true)
                }

                if let err = store.previewError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.failed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.artworkAutoLimitEnabled {
                    Label("写入时会按偏好自动处理：\(settings.artworkAutoLimitSummary)",
                          systemImage: "slider.horizontal.3")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            } else {
                EmptyStateView(systemImage: "hand.tap",
                               title: "未选择候选",
                               message: "点左侧任意一张缩略图查看大图与实际尺寸")
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 268)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var actualPixels: String {
        guard let data = store.previewData else { return "" }
        let s = ArtworkProcessor.pixelSize(data)
        return s.width > 0 ? "\(s.width)×\(s.height)" : ""
    }

    private var actualBytes: String {
        guard let data = store.previewData else { return "" }
        return Formatters.fileSize(Int64(data.count))
    }
}

// MARK: - B. 从标签取图（FormPictureFromTags）

struct ArtworkFromTagsSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ArtworkStore

    @State private var scopeToSelection = true
    @State private var allowAlbumOnly = false

    private var sourceFiles: [ArtworkFileInfo] { store.propagationFiles.filter(\.hasArtwork) }
    private var targetRows: [FileRow] { model.selectedRows }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "photo.stack",
                          title: "从标签取图",
                          subtitle: "同一张专辑里往往只有一首带封面。这里把它复制给同专辑的其它文件——先看配对表，确认后再写入。") {
                Chip(text: "可用源 \(sourceFiles.count)")
            }

            HStack(spacing: 0) {
                sourceColumn
                Divider()
                targetColumn
            }
            .frame(height: 214)

            Divider()
            optionBar
            Divider()
            pairingTable

            SheetButtonBar {
                Text(store.propagationStatus)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(store.propagationStatus)
                Spacer()
                Button("关闭") { ArtworkSheetPresenter.shared.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(writeTitle) { write() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((store.propagationPlan?.acceptedCount ?? 0) == 0 || model.isBusy)
                    .help("按配对表批量写入封面。写入前会自动记录撤消快照。")
            }
        }
        .frame(width: Theme.Size.sheetWide, height: 620)
        .onAppear {
            if store.propagationFiles.isEmpty { store.propagationFiles = model.artworkFileInfos() }
        }
    }

    private var writeTitle: String {
        let n = store.propagationPlan?.acceptedCount ?? 0
        return n > 0 ? "写入 \(n) 个文件" : "写入"
    }

    private func write() {
        guard let plan = store.propagationPlan else { return }
        ArtworkSheetPresenter.shared.dismiss()
        model.performArtworkPropagation(plan.pairings)
    }

    // MARK: 左列：有封面的文件

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("封面来源（列表里已带封面的文件）")
            if sourceFiles.isEmpty {
                EmptyStateView(systemImage: "photo.badge.exclamationmark",
                               title: "没有可用的封面源",
                               message: "先给其中一首歌加上封面并保存")
            } else {
                List(sourceFiles, selection: $store.manualSourceURL) { info in
                    HStack(spacing: Theme.Spacing.s) {
                        LocalArtworkThumbnail(url: info.url, side: 40)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(info.fileName).lineLimit(1).truncationMode(.middle)
                            Text("\(info.albumDisplay) · \(info.albumArtistDisplay)")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .help("""
                              \(info.fileName)
                              \(info.albumDisplay) · \(info.albumArtistDisplay)
                              \(info.url.deletingLastPathComponent().path)
                              """)
                        Spacer(minLength: Theme.Spacing.xs)
                        Text(Formatters.fileSize(Int64(info.artworkByteCount)))
                            .font(Theme.Typo.badge)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(info.url)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 400)
    }

    // MARK: 右列：目标

    private var targetColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("目标（主列表当前选中的文件）")
            if targetRows.isEmpty {
                EmptyStateView(systemImage: "cursorarrow.rays",
                               title: "未选中目标",
                               message: "在主列表里选中要接收封面的文件；也可以直接用「按专辑自动匹配」处理全部")
            } else {
                List(targetRows) { row in
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: row.artworkCount > 0 ? "photo.fill" : "photo")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(row.artworkCount > 0 ? Color.secondary : Theme.Colors.placeholderText)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(row.fileName).lineLimit(1).truncationMode(.middle)
                            Text([row.draft.album, row.draft.albumArtist ?? row.draft.artist]
                                    .compactMap { $0 }.filter { !$0.isEmpty }
                                    .joined(separator: " · "))
                                .font(Theme.Typo.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .help(([row.fileName]
                               + [row.draft.album, row.draft.albumArtist ?? row.draft.artist]
                                    .compactMap { $0 }.filter { !$0.isEmpty })
                              .joined(separator: "\n"))
                        Spacer()
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.sectionHeader)
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.chipFill)
    }

    // MARK: 选项与两个动作

    private var optionBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                model.buildArtworkPropagationPlan(scopeToSelection: scopeToSelection,
                                                  allowAlbumOnly: allowAlbumOnly)
            } label: {
                Label("按专辑自动匹配", systemImage: "wand.and.stars")
            }
            .help("为每个无封面的文件，找同专辑（专辑 + 专辑艺术家相同）且有封面的源文件")

            Button {
                if let src = store.manualSourceURL { model.buildManualPropagationPlan(sourceURL: src) }
            } label: {
                Label("用左侧选中的源配对", systemImage: "arrow.right.doc.on.clipboard")
            }
            .disabled(store.manualSourceURL == nil || model.selection.isEmpty)
            .help("把左边选中的那张封面，发给主列表里当前选中的文件")

            Divider().frame(height: 16)

            Toggle("只处理选中项", isOn: $scopeToSelection)
                .toggleStyle(.checkbox)
                .help("关掉则处理列表里所有无封面的文件")
            Toggle("允许仅按专辑名匹配", isOn: $allowAlbumOnly)
                .toggleStyle(.checkbox)
                .help("专辑艺术家为空时也认；会把不同歌手的同名专辑混在一起，谨慎打开")

            Spacer()
            if let plan = store.propagationPlan, !plan.pairings.isEmpty {
                Button("全选") { setAll(true) }
                Button("全不选") { setAll(false) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func setAll(_ on: Bool) {
        guard var plan = store.propagationPlan else { return }
        for i in plan.pairings.indices { plan.pairings[i].accepted = on }
        store.propagationPlan = plan
    }

    // MARK: 配对表

    @ViewBuilder
    private var pairingTable: some View {
        if let plan = store.propagationPlan {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Spacing.s) {
                    Color.clear.frame(width: 18, height: 1)
                    Text("封面来源").frame(width: 260, alignment: .leading)
                    Color.clear.frame(width: 16, height: 1)
                    Text("目标文件").frame(minWidth: 220, alignment: .leading)
                    Text("依据").frame(width: 128, alignment: .leading)
                    Spacer()
                }
                .font(Theme.Typo.sectionHeader)
                .foregroundStyle(.secondary)
                .tracking(0.4)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Colors.chipFill)
                .overlay(alignment: .bottom) { Divider() }

                if plan.pairings.isEmpty {
                    EmptyStateView(systemImage: "questionmark.folder",
                                   title: "没有配对结果",
                                   message: plan.unmatched.isEmpty
                                        ? "所有目标文件都已经有封面了"
                                        : "\(plan.unmatched.count) 个文件在列表里找不到同专辑的封面源")
                } else {
                    List {
                        ForEach(Array(plan.pairings.enumerated()), id: \.element.id) { pair in
                            pairRow(pair.element, index: pair.offset)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            EmptyStateView(systemImage: "arrow.left.arrow.right",
                           title: "还没有配对表",
                           message: "点「按专辑自动匹配」，或在左侧选一个源后点「用左侧选中的源配对」")
                .frame(maxHeight: .infinity)
        }
    }

    private func pairRow(_ pair: ArtworkPairing, index: Int) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(
                get: { store.propagationPlan?.pairings.indices.contains(index) == true
                        ? store.propagationPlan!.pairings[index].accepted : false },
                set: { on in
                    guard store.propagationPlan?.pairings.indices.contains(index) == true else { return }
                    store.propagationPlan?.pairings[index].accepted = on
                }))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: 18)

            HStack(spacing: Theme.Spacing.xs) {
                LocalArtworkThumbnail(url: pair.source.url, side: 26)
                Text(pair.source.fileName).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 260, alignment: .leading)
            .help(pair.source.url.path)

            Image(systemName: "arrow.right")
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            Text(pair.target.fileName)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 220, alignment: .leading)
                .help(pair.target.url.path)

            Chip(text: pair.reason.localizedName,
                 tinted: pair.reason == .albumAndAlbumArtist)
                .frame(width: 128, alignment: .leading)

            Spacer()
        }
        .font(Theme.Typo.tableCell)
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

// MARK: - C. 调整分辨率 / 压缩

struct ArtworkAdjustSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ArtworkStore

    private var original: Artwork? { model.currentArtwork }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "slider.horizontal.3",
                          title: "调整封面",
                          subtitle: "对应原版的「更改分辨率」「内置图片大小限制」「固定为 JPG」。只影响当前这一张封面，绝不放大。")

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    previewCard
                    optionsCard
                    autoLimitCard
                }
                .padding(Theme.Spacing.l)
            }

            SheetButtonBar {
                Text(store.adjustError ?? sizeLine)
                    .font(Theme.Typo.digitsSmall)
                    .foregroundStyle(store.adjustError == nil ? Color.secondary : Theme.Colors.failed)
                    .lineLimit(1).truncationMode(.tail)
                    .help(store.adjustError ?? sizeLine)
                Spacer()
                Button("取消") { ArtworkSheetPresenter.shared.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    if let result = store.adjustPreview { model.applyArtworkAdjustment(result) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(store.adjustPreview == nil)
                .help("写入当前封面的工作副本，随后弹出保存确认")
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 560)
        .onAppear { store.recomputeAdjustPreview(from: original?.data) }
        .onChange(of: store.adjustOptions) { _, _ in
            store.scheduleAdjustPreview(from: original?.data)
        }
    }

    /// 「1200×1200 · 387 KB  →  500×500 · 62 KB」
    private var sizeLine: String {
        let o = store.adjustOriginal
        let before = o.width > 0
            ? String(format: "%d×%d · %.0f KB", o.width, o.height, Double(o.bytes) / 1024.0)
            : "—"
        guard let r = store.adjustPreview else { return before }
        return before + "   →   " + r.summary
    }

    // MARK: 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader("预览") {
                if let r = store.adjustPreview {
                    Chip(text: r.mimeType.replacingOccurrences(of: "image/", with: "").uppercased())
                }
            }
            HStack(spacing: Theme.Spacing.l) {
                thumb(original?.data, caption: "原始", detail: originalDetail)
                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                thumb(store.adjustPreview?.data, caption: "调整后", detail: store.adjustPreview?.summary ?? "—")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var originalDetail: String {
        let o = store.adjustOriginal
        guard o.width > 0 else { return "—" }
        return String(format: "%d×%d · %.0f KB", o.width, o.height, Double(o.bytes) / 1024.0)
    }

    private func thumb(_ data: Data?, caption: String, detail: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            ZStack {
                if let data, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ArtworkPlaceholder(corner: Theme.Radius.m)
                }
            }
            .frame(width: 132, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Theme.Colors.artworkStroke))
            Text(caption).font(Theme.Typo.caption).foregroundStyle(.secondary)
            Text(detail).font(Theme.Typo.badge).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: 选项

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("调整")

            HStack(spacing: Theme.Spacing.s) {
                Text("最长边").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    .frame(width: Theme.Size.fieldLabelWidth, alignment: .trailing)
                Picker("", selection: $store.adjustMaxEdge) {
                    ForEach(ArtworkProcessOptions.maxEdgeChoices, id: \.self) { v in
                        Text(ArtworkProcessOptions.maxEdgeLabel(v)).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: Theme.Spacing.s) {
                Text("格式").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    .frame(width: Theme.Size.fieldLabelWidth, alignment: .trailing)
                Picker("", selection: $store.adjustFormat) {
                    ForEach(ArtworkOutputFormat.allCases, id: \.self) { f in
                        Text(f.localizedName).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
            }

            HStack(spacing: Theme.Spacing.s) {
                Text("JPEG 质量").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                    .frame(width: Theme.Size.fieldLabelWidth, alignment: .trailing)
                Slider(value: $store.adjustQuality, in: 0.3...1.0, step: 0.05)
                Text(String(format: "%.2f", store.adjustQuality))
                    .font(Theme.Typo.digits)
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!producesJPEG)
            .opacity(producesJPEG ? 1 : 0.5)

            HStack(spacing: Theme.Spacing.s) {
                Toggle("大小上限", isOn: $store.adjustLimitEnabled)
                    .toggleStyle(.checkbox)
                Stepper(value: $store.adjustLimitKB, in: 50...2000, step: 50) {
                    Text("\(store.adjustLimitKB) KB").font(Theme.Typo.digits)
                }
                .disabled(!store.adjustLimitEnabled)
                Spacer()
            }

            Text("超过上限时先逐步降质，仍不达标再逐步缩边，最小缩到 200 px。原图已经达标就一个字节都不动。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var producesJPEG: Bool {
        if store.adjustFormat == .jpeg { return true }
        if store.adjustLimitEnabled { return true }      // 限体积一定会走 JPEG
        return (original?.mimeType ?? "").contains("jpeg")
    }

    // MARK: 偏好

    private var autoLimitCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader("添加封面时自动应用") {
                Chip(text: settings.artworkAutoLimitSummary,
                     tinted: settings.artworkAutoLimitEnabled)
            }
            Text("对之后每一次「添加 / 搜索 / 取图」得到的封面自动生效，默认关闭。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.s) {
                Text("限制最长边").font(Theme.Typo.fieldLabel).foregroundStyle(.secondary)
                Picker("", selection: $settings.artworkAutoLimitMaxEdge) {
                    ForEach(ArtworkProcessOptions.maxEdgeChoices, id: \.self) { v in
                        Text(v == 0 ? "关闭" : "≤ \(v) px").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Toggle("固定为 JPEG", isOn: $settings.artworkAutoConvertJPEG)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

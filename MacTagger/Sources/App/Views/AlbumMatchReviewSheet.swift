//
//  AlbumMatchReviewSheet.swift
//  MacTagger — 专辑模式的复核窗
//
//  和逐首模式的复核窗是同一件事的两种组织方式：
//  逐首模式一行一个文件，各查各的；专辑模式**先按文件夹分组**，
//  因为「这一组该用哪张专辑」才是真正要人眼确认的那个决定 ——
//  一旦专辑选对，组内每首曲子的标题、音轨号、年份就都是这张专辑的曲目表说了算，
//  不再有任何一首会偷偷跑去匹配 Live 版或翻唱。
//
//  ── 版式：组头是一张专辑卡，不是一行小字 ──
//  上一版把组头做成两行 11pt 小字 + 一个 22pt 的封面色块，结果是**最该被一眼看清的
//  那个决定反而最不显眼**：用户判一张专辑对不对，靠的是封面，而 22pt 的封面
//  连是不是同一张图都分不出来。
//
//  现在组头 = `AlbumCardHeader`：左边 160pt 大封面（组内文件原本有封面时，
//  右下角叠一张 48pt 的原封面，新旧同框），右边《专辑》— 艺术家 · 年份 · 曲目表规模 ·
//  来源，再下面是对齐率与组级字段 diff。整组一模一样的字段（专辑/专辑艺术家/年份/封面）
//  只在这张卡上说一次，行里不再重复 —— 重复十一遍只会淹没每首各不相同的标题与音轨号。
//
//  行内则只回答一件事：`文件名 → 新标题`，外加艺术家/音轨的原→新与变更 chips。
//  两个复核窗共用 `ReviewComponents.swift` 里的同一套构件，不再各写一份。
//

import SwiftUI
import AppKit

struct AlbumMatchReviewSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = AlbumMatchStore.shared
    @ObservedObject private var display = ReviewDisplayStore.shared

    /// 展开看完整字段级差异的行。
    @State private var expandedRows: Set<URL> = []
    /// 折叠起来的组。
    @State private var collapsedGroups: Set<URL> = []
    /// 顶部逐源结果条里被点中的源。非 nil 时「换候选」菜单只列这个源的候选（B4）。
    @State private var sourceFilter: String?
    /// 正在开手动搜索面板的那一行。
    @State private var manualTarget: URL?
    @State private var manualQuery = ManualSearchQuery()
    /// BL 轮：脚注「保存为歌词文件」直接绑这份偏好；「选项…」在本 sheet 里面再挂一层。
    @EnvironmentObject private var settings: AppSettings
    @State private var showFileOptionsSheet = false

    /// 「换候选 ▾」那一列的宽度。窗宽 `sheetExtraWide` 钉死在 1100。
    private static let pickWidth: CGFloat = 86

    var body: some View {
        VStack(spacing: 0) {
            if let review = store.review {
                SheetTitleBar(systemImage: "square.stack.3d.up",
                              title: "复核专辑匹配结果",
                              subtitle: "按文件夹分组。先看组头那张专辑卡对不对——封面、专辑名、艺术家、年份"
                                      + "决定了组内每一首的标题、音轨号与年份；不对就用卡片右上角的下拉换一张。") {
                    Chip(text: String(format: "耗时 %.1f 秒", review.elapsed))
                    // ★ BJ 轮：分阶段计时。「慢」得说得出慢在哪一段 ——
                    // 专辑模式接上取词之后，这一条会多出「歌词 y s（含翻译轮 …）」。
                    // 口径与逐首模式共用 `StageTimings.summaryLine`，逐字同款。
                    if !review.summary.stages.isEmpty {
                        Chip(text: review.summary.stages.summaryLine)
                            .help(review.summary.stages.concurrencyLine
                                  ?? "搜索/歌词是跨并发累加值，回答的是「占比」。")
                    }
                }

                toolbar(review)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(review.groups) { g in
                            groupCard(g)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.m)
                }
                .frame(maxHeight: .infinity)

                // BL 轮：与逐首模式、批量下载同款 —— 会写歌词字段时才出现。
                if model.autoMatchWritesLyrics {
                    LyricsFileSaveStrip(isOn: $settings.lyricsFile.enabled,
                                        options: settings.lyricsFile,
                                        onOptions: { showFileOptionsSheet = true })
                }

                SheetButtonBar {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("\(review.matchedGroupCount)/\(review.groups.count) 个文件夹锁定了专辑，"
                             + "\(review.alignedCount)/\(review.fileCount) 个文件对齐")
                            .font(Theme.Typo.digitsSmall)
                        // 「将修改 N 个文件，共 M 处」——**按勾中的字段算**，
                        // 用户在行里划掉一个碟号，这句话当场就少一处。
                        Text("可写入 \(review.writableCount) 项 · 将修改 "
                             + "\(review.acceptedCount) 个文件，共 \(review.acceptedChangeTotal) 处")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help("只统计勾中的行里**没有被排除**的字段与封面。"
                                + "\n行内灰色划线的 chip = 那个文件不写那个字段，不计入这里。")
                    }
                    Spacer()
                    Button("全选") { model.setAllAlbumAccepted(true) }
                    Button("全不选") { model.setAllAlbumAccepted(false) }
                    Divider().frame(height: 18)
                    Button("放弃") { model.discardAlbumMatchReview() }
                        .keyboardShortcut(.cancelAction)
                    Button("应用选中项（\(review.acceptedCount)）") { model.applyAlbumMatchSelection() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(review.acceptedCount == 0)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Theme.Size.sheetExtraWide, height: 760)
        .lyricsFileOptionsSheet(isPresented: $showFileOptionsSheet)
    }

    // MARK: 顶部工具条（密度 / 只看改动 / 逐源结果条）

    @ViewBuilder
    private func toolbar(_ review: AlbumMatchReview) -> some View {
        VStack(spacing: 0) {
            ReviewToolbar(display: display) {
                Divider().frame(height: 14)
                // 「一次性去掉所有音轨号」的入口。作用域是**整张复核表**（所有文件夹）。
                ReviewFieldMenu(title: "全部字段",
                                scopeNote: "当前复核表 \(review.fileCount) 个文件",
                                tallies: review.fieldTallies) { key, on in
                    model.setAlbumFieldForAll(key, on)
                }
                Divider().frame(height: 14)
                Chip(text: "文件夹 \(review.groups.count)", systemImage: "folder")
                Chip(text: "对齐 \(review.alignedCount)/\(review.fileCount)", tinted: true)
                if store.ignoreExistingTags {
                    Chip(text: "已忽略现有标签", tinted: true, systemImage: "eye.slash")
                }

                Spacer(minLength: Theme.Spacing.s)

                // 整轮的逐源结果条。没有它，某个源整轮挂掉时用户只看得到
                // 「0 个文件夹锁定了专辑」，完全分不清是「这些专辑线上没有」还是「源挂了」。
                if !review.sourceOutcomes.isEmpty {
                    SourceOutcomeBar(outcomes: review.sourceOutcomes,
                                     label: nil,
                                     selectedSourceID: sourceFilter,
                                     onTap: { id in sourceFilter = (sourceFilter == id) ? nil : id },
                                     trailingNote: sourceFilter.map {
                                         "只看 \(SourceOutcome.displayName($0)) 的候选"
                                     })
                    .fixedSize()
                }
            }

            if let note = review.sourceNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(Theme.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.xs)
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    // MARK: 一个文件夹组 = 一张专辑卡 + 组内曲目行

    @ViewBuilder
    private func groupCard(_ g: AlbumMatchGroupReview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumCardHeader(info: cardInfo(g),
                            isCollapsed: collapsedGroups.contains(g.folder),
                            onToggleCollapse: { toggleGroup(g.folder) }) {
                HStack(spacing: Theme.Spacing.xs) {
                    Button("全组") { model.setGroupAccepted(folder: g.folder, true) }
                        .disabled(g.writableCount == 0)
                        .help("勾选本组全部可写入项")
                    Button("全不选") { model.setGroupAccepted(folder: g.folder, false) }
                        .disabled(g.acceptedCount == 0)
                    // 「整组不写碟号」：上面两个按钮切的是「写不写这一行」，
                    // 这个菜单切的是「写不写这一列」—— 两把刀垂直。
                    ReviewFieldMenu(title: "本组字段",
                                    scopeNote: "本组 \(g.fileCount) 首",
                                    tallies: g.fieldTallies) { key, on in
                        model.setAlbumGroupField(folder: g.folder, key, on)
                    }
                    albumPicker(g)
                }
            }

            if !collapsedGroups.contains(g.folder) {
                Divider()

                // 本组收集专辑候选时每个源的实况。**「网易云没这张专辑」与「网易云挂了」
                // 会导致完全相反的处置**，组头必须把它们分开摆出来。
                if !g.sourceOutcomes.isEmpty {
                    SourceOutcomeBar(outcomes: g.sourceOutcomes, label: "本组")
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs)
                }

                let ctx = groupContext(g)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(g.items) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            TrackReviewRow(
                                item: item,
                                accepted: Binding(
                                    get: { item.accepted },
                                    set: { model.setAlbumItemAccepted(folder: g.folder,
                                                                      url: item.url, $0) }),
                                density: display.density,
                                onlyChangedFields: display.onlyChangedFields,
                                albumArtwork: g.artworkData,
                                group: ctx,
                                isExpanded: expandedRows.contains(item.id),
                                onToggleExpand: { toggleRow(item.id) },
                                onToggleField: { key in
                                    model.toggleAlbumField(folder: g.folder, url: item.url, key)
                                }) {
                                    candidatePicker(item, folder: g.folder)
                                }

                            if expandedRows.contains(item.id) {
                                detail(item, folder: g.folder)
                                    .padding(.horizontal, Theme.Spacing.m)
                                    .padding(.bottom, Theme.Spacing.s)
                            }
                        }
                        Divider().opacity(0.35)
                    }
                }
                .opacity(g.isReloading ? 0.45 : 1)
                .overlay {
                    if g.isReloading {
                        ProgressView("正在按新专辑重新对齐…")
                            .font(Theme.Typo.caption)
                            .controlSize(.small)
                    }
                }
            }
        }
        .card(padding: 0)
    }

    /// 这一组的组级字段口径。行内 chips 据此把专辑级字段让给专辑卡。
    ///
    /// 未匹配组 `summarizes: false`：那张灰卡上根本没有组级摘要，
    /// 把专辑级字段从行里折掉就等于让它们彻底消失 —— 没人接手的东西不能折。
    private func groupContext(_ g: AlbumMatchGroupReview) -> ReviewGroupContext {
        ReviewGroupContext.make(items: g.items, artwork: g.artworkData,
                                summarizes: g.chosenID != nil)
    }

    /// 把一个文件夹组翻译成专辑卡要画的内容。
    private func cardInfo(_ g: AlbumMatchGroupReview) -> AlbumCardInfo {
        let unmatched = g.chosenID == nil
        var info = AlbumCardInfo(
            albumTitle: g.chosen.map { "《\($0.detail.displayTitle)》" } ?? "未匹配到专辑",
            artist: g.chosen?.detail.artist,
            year: g.chosen?.detail.year,
            trackCountText: g.trackTableSummary ?? "\(g.fileCount) 个文件",
            sourceName: g.sourceName,
            folderName: g.folderName,
            alignedText: "对齐 \(g.alignedCount)/\(g.fileCount)")

        info.newArtwork = g.artworkData
        info.oldArtwork = g.originalArtworkData
        info.artworkSource = g.sourceName ?? ""
        info.artworkNote = g.artworkData == nil ? nil
            : "整组只下载一次，写入本组 \(g.artworkFileCount) 个文件"
            + (g.originalArtworkData != nil
               ? "；右下角小图是这组文件现在的封面（\(g.originalArtworkFileCount) 个文件带封面）" : "")
        info.isUnmatched = unmatched
        // BO#8：锁定了专辑的组，若新封面会替换文件里现有的封面，卡上用橙字说出来（默认不写）。
        info.note = unmatched ? (g.ignoredReason ?? "这一组没有锁定任何专辑，组内文件不会被写入。")
            : ReviewArtworkSummary.cardNote(g.items)

        // 专辑级字段的组级摘要：**整组一个值的东西只在这里说一次**。
        // 印哪几格由 `ctx.summarized` 说了算 —— 行内 chips 折掉的正是同一串，
        // 两边共用一个来源，就不会出现「卡上没印、行里也没了」的字段。
        guard !unmatched else { return info }
        let ctx = groupContext(g)
        info.diffs = ctx.summarized.map {
            cardDiff($0.localizedName, g.commonChange($0))
        }
        if let art = ReviewArtworkSummary.cardDiff(g.items, newArtwork: g.artworkData) {
            info.diffs.append(art)
        }
        info.diffFootnote = ctx.footnote
        return info
    }

    private func cardDiff(_ label: String,
                          _ change: (old: String, new: String, count: Int)?) -> AlbumCardDiff {
        AlbumCardDiff(label: label,
                      old: change?.old ?? "",
                      new: change?.new,
                      help: change == nil
                        ? "\(label)：整组都不改动"
                        : "\(label)：本组 \(change!.count) 个文件会改\n原：\(change!.old)\n新：\(change!.new)")
    }

    /// 专辑卡右上角的「换一张专辑」下拉。换完组内逐文件重新对齐。
    private func albumPicker(_ g: AlbumMatchGroupReview) -> some View {
        Menu {
            if g.candidates.isEmpty {
                Text("没有候选专辑")
            }
            ForEach(g.candidates) { c in
                Button {
                    model.changeAlbum(folder: g.folder, to: c.id)
                } label: {
                    Text(candidateLabel(c, chosenID: g.chosenID))
                }
            }
        } label: {
            Label("换专辑", systemImage: "rectangle.2.swap")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(g.candidates.count <= 1 || g.isReloading)
        .help(g.candidates.count <= 1
              ? "没有其它候选专辑可换"
              : "共 \(g.candidates.count) 张候选专辑，换一张会让本组重新对齐")
    }

    // MARK: 行内「换候选 ▾」（B2 / B3 / B4）

    /// 换掉**这一行**对到的曲目 —— 与组头的「换专辑」是两件事：
    /// 换专辑改的是整组的答案，换候选只改这一行。专辑模式的残余误配几乎全是
    /// 「对到了邻近的另一首」，候选就在同一张曲目表里，切换**不发一次请求**。
    /// 要跳出这张专辑另找，用同一个菜单里的「手动搜索…」。
    @ViewBuilder
    private func candidatePicker(_ item: AutoMatchReviewItem, folder: URL) -> some View {
        let list = visibleCandidates(item)
        Menu {
            if list.isEmpty {
                Text(item.candidates.isEmpty ? "没有候选" : "该来源没有候选")
            } else {
                ForEach(list) { c in
                    Button {
                        model.changeAlbumCandidate(folder: folder, url: item.url, to: c.id)
                    } label: {
                        Text(item.candidateLabel(c))
                    }
                }
            }
            Divider()
            Button("手动搜索…") {
                manualQuery = ManualSearchQuery.makeDefault(fileName: item.fileName, item: item)
                manualTarget = item.url
            }
            if sourceFilter != nil {
                Button("显示全部来源的候选") { sourceFilter = nil }
            }
        } label: {
            Label(item.isReloading ? "重算中" : "换候选",
                  systemImage: item.isReloading ? "hourglass" : "arrow.triangle.2.circlepath")
                .font(Theme.Typo.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: AlbumMatchReviewSheet.pickWidth, alignment: .leading)
        .disabled(item.isReloading)
        .help(pickerHelp(item))
        .popover(isPresented: Binding(get: { manualTarget == item.url },
                                      set: { if !$0 { manualTarget = nil } }),
                 arrowEdge: .bottom) {
            ManualSearchPanel(fileName: item.fileName, query: $manualQuery) {
                manualTarget = nil
                model.manualSearchAlbum(folder: folder, url: item.url, query: manualQuery)
            } onCancel: {
                manualTarget = nil
            }
        }
    }

    private func visibleCandidates(_ item: AutoMatchReviewItem) -> [TrackCandidate] {
        guard let f = sourceFilter else { return item.candidates }
        return item.candidates.filter { $0.sourceID == f }
    }

    private func pickerHelp(_ item: AutoMatchReviewItem) -> String {
        guard !item.candidates.isEmpty else {
            return "这一行没有备选曲目。用「手动搜索…」跳出这张专辑单独重搜。"
        }
        var s = "本行候选 \(item.candidates.count) 条（同一张专辑里最像的几首）。"
        s += "换一条会立刻重算这一行的 原→新 差异与音轨位置，并自动勾选。"
        if item.manuallyChosen { s += "\n（本行已由你手动确认）" }
        return s
    }

    /// 下拉里一条候选的文字。拆成函数是为了别让 SwiftUI 的类型推导在 Menu 里超时。
    private func candidateLabel(_ c: AlbumCandidate, chosenID: String?) -> String {
        let mark: String = (c.id == chosenID) ? "✓ " : "   "
        let score: String = String(format: "%.3f", c.score)
        let source: String = SourceBootstrap.displayName(c.detail.sourceID)
        let aligned: String = "\(c.alignedCount)/\(c.fileCount)"
        return mark + score + "  " + c.detail.summary + "  [" + source + "]  对齐 " + aligned
    }

    // MARK: 展开后的完整字段级差异

    @ViewBuilder
    private func detail(_ item: AutoMatchReviewItem, folder: URL) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if item.status != .matched, let err = item.errorText {
                Label(err, systemImage: "info.circle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pos = item.trackPositionDisplay {
                Text("曲目位置 \(pos)"
                     + (item.discCount > 1 ? "（第 \(item.discNumber ?? 1) 碟，本碟 \(item.tracksInDisc) 首）" : "")
                     + (item.writtenTrack.map { " · 写入 TRACKNUMBER = \($0)" } ?? ""))
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !item.changes.isEmpty {
                // 勾选框与行尾那枚 chip 是同一个开关。专辑模式的行内 chips 折掉了
                // 专辑级字段（它们归专辑卡说），**这里是逐首排除它们的唯一入口** ——
                // 比如「别的都写，唯独这一首不要跟着改年份」。
                Grid(alignment: .leading,
                     horizontalSpacing: Theme.Spacing.s,
                     verticalSpacing: Theme.Spacing.xs) {
                    ReviewFieldDiffHeader()
                    ForEach(item.changes) { c in
                        ReviewFieldDiffRow(key: .field(c.field),
                                           oldValue: c.oldDisplay,
                                           newValue: c.newDisplay,
                                           accepted: item.acceptedFields.contains(c.field)) { on in
                            model.setAlbumField(folder: folder, url: item.url, .field(c.field), on)
                        }
                    }
                    if item.hasArtwork {
                        ReviewFieldDiffRow(key: .artwork,
                                           oldValue: item.existingArtworkCell,
                                           newValue: artworkSizeText(item),
                                           accepted: item.acceptArtwork) { on in
                            model.setAlbumField(folder: folder, url: item.url, .artwork, on)
                        }
                    }
                }
            } else if item.status == .matched {
                Text("标签已经是这张专辑的值，无需改动。")
                    .font(Theme.Typo.caption).foregroundStyle(.tertiary)
            }

            if let data = item.artwork, let img = NSImage(data: data) {
                HStack(spacing: Theme.Spacing.s) {
                    ArtworkHoverPreview(
                        image: img,
                        meta: ArtworkMeta(data: data, image: img,
                                          source: item.sourceName ?? "",
                                          role: "新封面 · 本次将写入"),
                        size: Theme.Size.reviewArtInset,
                        corner: Theme.Radius.xs)
                    Text("将写入专辑封面 \(Int(img.size.width)) × \(Int(img.size.height))"
                         + " · \(Formatters.fileSize(Int64(data.count)))")
                        .font(Theme.Typo.badge).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chipFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    // MARK: 小工具

    /// 封面那一行的「新值」：尺寸 + 字节 —— 字段表里其它行都是文本，
    /// 封面只能用它的规格来指代自己。
    private func artworkSizeText(_ item: AutoMatchReviewItem) -> String {
        guard let data = item.artwork else { return "" }
        return ArtworkMeta(data: data, image: NSImage(data: data), source: "", role: "").line
    }

    private func toggleRow(_ id: URL) {
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
    }

    private func toggleGroup(_ id: URL) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }
}

// MARK: - 「原 → 新」一格

/// 复核表最早的那块砖：一格里同时摆下原值与新值。
///
/// 复核表本身已经改用 `DiffInline`（原值灰删除线、新值正文色），这一版**仍在服役** ——
/// 「统一 / 补齐标签」的预览表（`TagPropagationSheet`）用的就是它，那张表里
/// 强调色新值正是对的口径：那里一屏只有几行，蓝色不会泛滥。
struct OldNewCell: View {
    let old: String
    /// nil = 本次不改这个字段。
    let new: String?
    var width: CGFloat? = nil
    var font: Font = Theme.Typo.tableCell
    var mono: Bool = false
    /// false = 这一格确实会改，但**整组都这么改**，组头已经写过一次，
    /// 降到次要色，把强调色留给真正每首各不相同的那几格。
    var emphasis: Bool = true
    /// 不改动时显示什么。默认「—」。
    var unchangedText: String = "—"
    var help: String = ""

    var body: some View {
        Group {
            if let new {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(old.isEmpty ? "（空）" : old)
                        .foregroundStyle(old.isEmpty ? Theme.Colors.placeholderText : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.tertiary)
                    Text(new)
                        .foregroundStyle(emphasis ? Color.accentColor : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                }
            } else {
                Text(unchangedText)
                    .foregroundStyle(Theme.Colors.placeholderText)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .font(font)
        .monospacedDigit()
        .modifier(MonoIfNeeded(on: mono))
        .frame(width: width, alignment: .leading)
        // 两侧都是 `.truncationMode(.middle)`：列一窄，长专辑名就被截成
        // 「ＴＨＥ　ＶＥＲ…ＩＯＮ〜」，光看行内根本判断不了这次改得对不对。
        // 所以 tooltip 一律带上**完整**的原值与新值，调用方给的 `help` 只当抬头。
        .help(fullHelp)
    }

    private var fullHelp: String {
        var lines: [String] = []
        if !help.isEmpty { lines.append(help) }
        if let new {
            lines.append("原：" + (old.isEmpty ? "（空）" : old))
            lines.append("新：" + new)
        } else {
            lines.append(old.isEmpty ? "（空）" : old)
        }
        return lines.joined(separator: "\n")
    }
}

/// 音轨那一列要等宽数字才对得齐，其它列不要。
private struct MonoIfNeeded: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.fontDesign(.monospaced) } else { content }
    }
}

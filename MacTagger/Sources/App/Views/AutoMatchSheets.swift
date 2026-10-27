//
//  AutoMatchSheets.swift
//  MacTagger — 自动匹配标签的两个子窗口
//
//  对应原版：FormAutoMatchTags（选项）+ FormCombTagsSearch(+OwOptions)（来源与网络参数）。
//  复核窗是原版没有的加固：自动匹配会选错，写坏标签不可逆，所以落盘前必须过一遍人眼。
//
//  骨架与其余 sheet 一致：SheetTitleBar → card() 分组内容 → SheetButtonBar。
//

import SwiftUI
import AppKit

// MARK: - 选项（FormAutoMatchTags）

struct AutoMatchOptionsSheet: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var opts: AutoMatchSettings
    /// 歌词合并口径的唯一权威（与「批量下载歌词」共用同一份），见 BH 轮。
    @EnvironmentObject private var settings: AppSettings
    /// 专辑模式的开关与状态。单例，见 AppModel+AlbumMatch.swift。
    @ObservedObject private var album = AlbumMatchStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pickedSource: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "wand.and.stars",
                          title: "自动匹配标签",
                          subtitle: "将处理 " + model.autoMatchScopeLabel
                                    + (model.selection.isEmpty ? "（未选中任何项时处理全部）" : "")
                                    + "。匹配结果不会直接落盘，完成后先过复核窗。")

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    modeSection
                    sourcesSection
                    thresholdSection
                    fieldsSection
                    extrasSection
                    networkSection
                }
                .padding(Theme.Spacing.l)
            }

            SheetButtonBar {
                Button("恢复默认") { opts.resetToDefaults() }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始匹配") {
                    dismiss()
                    model.startAutoMatch()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!opts.isRunnable)
            }
        }
        .frame(width: Theme.Size.sheetMedium, height: 660)
        // 用户没亲手选过模式时，按目录结构挑一个默认值：
        // 文件都摆成「文件夹 = 专辑」的样子就默认专辑模式。
        .onAppear { album.autoSelectMode(albumLike: model.targetsLookLikeAlbums) }
    }

    // MARK: 匹配方式（逐首 / 按文件夹）

    private var modeSection: some View {
        section("匹配方式", note: nil) {
            Picker("", selection: Binding(get: { album.mode },
                                          set: { album.chooseMode($0) })) {
                ForEach(TagMatchMode.allCases) { m in
                    Text(m.localizedName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(album.mode.hint)
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if album.mode == .album {
                Divider().padding(.vertical, Theme.Spacing.xxs)

                Toggle("忽略现有标签，只用文件名和文件夹", isOn: $album.ignoreExistingTags)

                Text("用于修复被写错的标签。已经被写错的标题/专辑一旦参与查询，会把匹配再次拉回"
                     + "同一个错答案，越修越错；文件名和文件夹是唯一没被污染过的信息，"
                     + "打开它就只信这两样。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Theme.Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.m) {
                    Text("曲目对齐阈值")
                    Slider(value: $album.alignThreshold, in: 0.2...0.9, step: 0.05)
                    Text(String(format: "%.2f", album.alignThreshold))
                        .font(Theme.Typo.digits)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("单个文件对到专辑某首曲目的最低分。够不着就判「未在专辑曲目表中找到」，不写入。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.targetsLookLikeAlbums {
                    Label("这批文件已按「文件夹 = 专辑」摆好，适合专辑模式。",
                          systemImage: "checkmark.circle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.matched)
                } else {
                    Label("这批文件看起来不是按专辑摆的（同一目录里不足两个文件，或推断不出专辑名），"
                          + "专辑模式可能整组匹配不上。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 标签来源

    private var sourcesSection: some View {
        section("标签来源",
                note: "按列表顺序作为优先级，勾选的源会并发查询后统一打分选优。单个源失效只淘汰它自己，不影响整批。") {
            List(selection: $pickedSource) {
                ForEach(opts.sourceOrder, id: \.self) { id in
                    sourceRow(id).tag(id)
                }
                .onMove { from, to in opts.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 152)

            HStack(spacing: Theme.Spacing.xs) {
                Button { if let p = pickedSource { opts.moveUp(p) } } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .disabled(pickedSource == nil)
                .help("提高该来源的优先级")

                Button { if let p = pickedSource { opts.moveDown(p) } } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .disabled(pickedSource == nil)
                .help("降低该来源的优先级")

                Spacer()
                Chip(text: "已启用 \(opts.activeSourceIDs.count) / \(opts.sourceOrder.count)")
            }
            .controlSize(.small)
        }
    }

    private func sourceRow(_ id: String) -> some View {
        let rank = (opts.sourceOrder.firstIndex(of: id) ?? 0) + 1
        let enabled = opts.enabledSources.contains(id)
        return HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(get: { enabled }, set: { _ in opts.toggleSource(id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text("\(rank)")
                .font(Theme.Typo.digitsSmall)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(SourceBootstrap.displayName(id))
                .foregroundStyle(enabled ? .primary : .secondary)
            ForEach(SourceBootstrap.capabilityTags(id), id: \.self) { tag in
                Chip(text: tag)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: 采纳阈值

    private var thresholdSection: some View {
        section("采纳阈值",
                note: "最佳候选的匹配分低于此值时判为「忽略」，不会覆盖任何已有标签。调低会提高命中率但更容易抓错版本。") {
            HStack(spacing: Theme.Spacing.m) {
                Slider(value: $opts.acceptThreshold, in: 0...1, step: 0.05) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("0").font(Theme.Typo.badge).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("1").font(Theme.Typo.badge).foregroundStyle(.secondary)
                }
                Text(String(format: "%.2f", opts.acceptThreshold))
                    .font(Theme.Typo.digits)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(thresholdHint)
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thresholdHint: String {
        switch opts.acceptThreshold {
        case ..<0.4:  return "宽松：几乎什么都会被采纳，误匹配风险高，建议配合复核逐条检查。"
        case ..<0.7:  return "推荐区间：0.6 是实测的平衡点（正确原版通常在 0.9 以上）。"
        default:      return "严格：只接受高度吻合的结果，漏匹配会变多。"
        }
    }

    // MARK: 字段白名单

    private var fieldsSection: some View {
        section("允许写入的字段",
                note: "未勾选的字段绝不会被匹配结果覆盖 —— 只想补年份和音轨号、不动自己改过的标题时用它。") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                      alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(TagEdit.Field.allCases, id: \.rawValue) { f in
                    Toggle(f.localizedName, isOn: Binding(
                        get: { opts.isFieldEnabled(f) },
                        set: { opts.setField(f, $0) }))
                    .toggleStyle(.checkbox)
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                Button("全选") { opts.selectAllFields() }
                Button("全不选") { opts.clearAllFields() }
                Spacer()
                if opts.enabledFields.isEmpty {
                    Label("至少要选一个字段", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            .controlSize(.small)
            Text("注释 / 作曲 / 歌词 多数在线源不随搜索结果返回，勾上也未必有值。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 附加下载

    private var extrasSection: some View {
        section("同时下载", note: nil) {
            Toggle("下载封面并一并写入", isOn: $opts.fetchArtwork)

            HStack(spacing: Theme.Spacing.s) {
                Text("封面尺寸").foregroundStyle(opts.fetchArtwork ? .primary : .secondary)
                Picker("", selection: $opts.artworkSize) {
                    ForEach(AutoMatchSettings.artworkSizeChoices, id: \.self) { s in
                        Text("\(s) × \(s)").tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!opts.fetchArtwork)
                Spacer()
            }
            .padding(.leading, Theme.Spacing.xl)

            Text("下载到的封面会替换文件里原有的封面，写入前可在复核窗里看到缩略图。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, Theme.Spacing.xl)
                .fixedSize(horizontal: false, vertical: true)

            // 「封面存到哪 + 要不要预留填充」的全部选项由封面模块统一提供
            // （ArtworkPolicySheet.swift 的 ArtworkPolicyOptionsView，绑 ArtworkStore）。
            // 这里只是把同一份界面嵌进来：匹配一整批文件正是最该改成「文件夹封面」的时刻，
            // 让用户为此另开一个窗口就太远了。compact：这个 sheet 高度紧张，只留控件。
            ArtworkPolicyOptionsView(compact: true)
                .padding(.leading, Theme.Spacing.xl)
                .disabled(!opts.fetchArtwork)
                .opacity(opts.fetchArtwork ? 1 : 0.5)

            Toggle("下载歌词写入 LYRICS 字段", isOn: $opts.fetchLyrics)

            // ★ BH 轮：把「这一轮到底合不合译文、按什么格式合」摆到开关底下。
            // 这份设置与「批量下载歌词」**共用同一处**（`AppSettings.lyricsFile`），
            // 下面嵌的 `LyricsFileOptionsView` 就是改它的地方 —— 用户在哪个窗口改都一样。
            Label(settings.lyricsFile.includeTranslation
                  ? "有译文时按「\(settings.lyricsFile.mergeFormat.localizedName)」合并写入"
                  : "只写原文（「合并翻译」已关，下方「歌词文件选项」里可开）",
                  systemImage: settings.lyricsFile.includeTranslation
                  ? "character.book.closed" : "character.book.closed.fill")
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, Theme.Spacing.xl)
                .disabled(!opts.fetchLyrics)
                .opacity(opts.fetchLyrics ? 1 : 0.5)

            // 「同时保存一份 .lrc 歌词文件」的全部选项由歌词模块统一提供
            // （LyricsSheets.swift 的 LyricsFileOptionsView，绑 AppSettings.lyricsFile）。
            // 这里只是把同一份界面嵌进来，不另写一套——用户在哪个窗口改都是同一处设置。
            // compact：这个 sheet 高度紧张，去掉长说明只留控件。
            LyricsFileOptionsView(compact: true)
                .padding(.leading, Theme.Spacing.xl)
                .disabled(!opts.fetchLyrics)
                .opacity(opts.fetchLyrics ? 1 : 0.5)

            if opts.fetchLyrics && !opts.isFieldEnabled(.lyrics) {
                Label("「歌词」字段未在白名单里，下载到也不会写入。", systemImage: "info.circle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .padding(.leading, Theme.Spacing.xl)
            }

            Divider().padding(.vertical, Theme.Spacing.xxs)

            // 署名开关。放在「同时下载」而不是「字段」区：它不是「要不要写这个字段」，
            // 而是「值不值得为这个字段多花一趟网络」——那是两个不同的决定。
            Toggle("补全作曲/作词（需额外查询歌词源）", isOn: $opts.fetchCredits)
            Text(opts.fetchLyrics
                 ? "已开「下载歌词」：署名直接从下载到的歌词里解析，不会额外发请求。"
                 : "搜索接口几乎不返回作曲/作词，只能从歌词开头的署名行里取。"
                   + "胜出源自带歌词时顺手解析；不带时才多查一个源（网易云，其次酷狗），每首约多花 1–3 秒。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, Theme.Spacing.xl)
                .fixedSize(horizontal: false, vertical: true)

            if opts.fetchCredits,
               !opts.isFieldEnabled(.composer), !opts.isFieldEnabled(.lyricist) {
                Label("「作曲」「作词」都不在字段白名单里，这一步会自动跳过（不花时间）。",
                      systemImage: "info.circle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Spacing.xl)
            }
        }
    }

    // MARK: 网络参数

    private var networkSection: some View {
        section("网络",
                note: "对应原版的「网络搜索线程数」与「网络搜索项限制」。线程数越高越快，但更容易触发各源限流。") {
            HStack(spacing: Theme.Spacing.xl) {
                Stepper(value: $opts.concurrency, in: 1...8) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("网络搜索线程数")
                        Text("\(opts.concurrency)")
                            .font(Theme.Typo.digits)
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $opts.limitPerSource, in: 1...25) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("网络搜索项限制")
                        Text("\(opts.limitPerSource)")
                            .font(Theme.Typo.digits)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            // 软截止：这一项直接决定「每首歌最慢能慢到什么程度」。
            // 没有它时每首的耗时 = 最慢的那个源，一个 20 秒的源能把整批拖垮。
            HStack(spacing: Theme.Spacing.s) {
                Stepper(value: $opts.sourceSoftDeadline, in: 1...20, step: 1) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("每首最多等待")
                        Text(String(format: "%.0f", opts.sourceSoftDeadline))
                            .font(Theme.Typo.digits)
                            .foregroundStyle(.secondary)
                        Text("秒")
                    }
                }
                Spacer()
            }
            Text("到点还没返回的源这一轮就不等了，用已经拿到的候选打分（不算它失败，也不会因此暂停它）。"
                 + "MusicBrainz 慢但权威，自动放宽到 \(String(format: "%.0f", opts.sourceSoftDeadline * 2)) 秒。")
                .font(Theme.Typo.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, Theme.Spacing.xxs)

            // iTunes 曲库地区由数据源模块统一提供（`ITunesRegionPicker`，@AppStorage 自带状态，
            // 不依赖任何环境注入）。嵌在这里是因为「iTunes 那一格总是 0 条」正是用户
            // 在这个窗口里最先撞上的问题，让他为此另开一个面板就太远了。
            ITunesRegionPicker()
        }
    }

    // MARK: 分组卡片

    @ViewBuilder
    private func section<C: View>(_ title: String, note: String?,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title)
            if let note {
                Text(note)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - 结果复核
//
// 和专辑模式的复核窗（AlbumMatchReviewSheet）用同一套构件，也用同一套判读规则 ——
// 区别只在**分组是从哪来的**：专辑模式按文件夹分组（数据层就是那么匹配的），
// 逐首模式则按「每个文件各自匹配到的专辑」事后归拢。
//
// 为什么逐首模式也要分组：一次几十行滚下来全是同一张专辑的曲子，却看不出它们是一伙的；
// 而「这批到底对到了哪张专辑」恰恰是错得最离谱、也最该先被发现的那件事 ——
// 抓到 Live 版、抓到精选合辑，都是在专辑这一层先露馅，不是在某一首的标题上。
//
// **分组纯粹是展示**：每一行的勾选与写入仍旧一条不动地走原来的路径
// （`model.autoMatchReview?.items[i].accepted`，下标就是分组前的原始下标）。
// 匹配不上的那些行归到末尾的「未匹配」灰卡里，不与真正会写入的内容混排。

struct AutoMatchReviewSheet: View {

    @EnvironmentObject private var model: AppModel
    /// 专辑模式跑完时这里非 nil，复核整个交给按文件夹分组的那一版。
    /// （ContentView 的 sheet 由 `autoMatchReview` 驱动且已定型，所以在这里分发。）
    @ObservedObject private var album = AlbumMatchStore.shared
    @ObservedObject private var display = ReviewDisplayStore.shared

    @State private var expanded: Set<URL> = []
    @State private var collapsedGroups: Set<String> = []

    /// 「换候选 ▾」那一列的宽度。窗宽被 `sheetExtraWide` 钉死在 1100。
    private static let pickWidth: CGFloat = 86

    /// 顶部逐源结果条里被点中的源。非 nil 时「换候选」菜单只列这个源的候选（B4）。
    @State private var sourceFilter: String?
    /// 正在开手动搜索面板的那一行。
    @State private var manualTarget: URL?
    @State private var manualQuery = ManualSearchQuery()
    /// 写前预估（BH 轮 C3/C4）。**缓存在 @State 里**：`estimatedWriteCost` 要逐个文件
    /// 读文件头，放进 body 每帧算一遍会把复核表拖垮。勾选一变就重算一次，够用。
    @State private var writeForecast = AutoMatchWriteForecast()
    /// BL 轮：脚注「保存为歌词文件」直接绑这份偏好；「选项…」在本 sheet 里面再挂一层。
    @EnvironmentObject private var settings: AppSettings
    @State private var showFileOptionsSheet = false

    var body: some View {
        if album.review != nil {
            AlbumMatchReviewSheet()
        } else {
            perTrackBody
        }
    }

    private var perTrackBody: some View {
        VStack(spacing: 0) {
            if let review = model.autoMatchReview {
                SheetTitleBar(systemImage: "checklist",
                              title: "复核匹配结果",
                              subtitle: "按匹配到的专辑分组：先看组头那张专辑卡对不对，再逐行看"
                                      + "「文件名 → 新标题」。匹配不上的行在最后的灰卡里。") {
                    Chip(text: String(format: "耗时 %.1f 秒", review.elapsed))
                }

                toolbar(review)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(review.displayGroups) { g in
                            groupCard(g, review: review)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.m)
                }
                .frame(maxHeight: .infinity)

                // BL 轮：这一轮会写歌词字段时，脚注明确给出「保存为歌词文件」——
                // 与批量下载复核表同一个开关（`settings.lyricsFile.enabled`），勾选即记住。
                if model.autoMatchWritesLyrics {
                    LyricsFileSaveStrip(isOn: $settings.lyricsFile.enabled,
                                        options: settings.lyricsFile,
                                        onOptions: { showFileOptionsSheet = true })
                }

                SheetButtonBar {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(review.summary.description)
                            .font(Theme.Typo.digitsSmall)
                        // 「本轮 QQ 12/12 失败（retcode -1310），已跳过」——
                        // 没有这一行，整轮被某个源拖垮时用户只看得到「忽略 12」，
                        // 完全不知道该去查网络还是换个源。
                        if let note = review.sourceNote {
                            Label(note, systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.Colors.warning)
                        }
                        // 「将修改 N 个文件，共 M 处」——**按勾中的字段算**，
                        // 用户在行里划掉一个碟号，这句话当场就少一处。
                        Text("可写入 \(review.writableCount) 项 · 将修改 "
                             + "\(review.acceptedCount) 个文件，共 \(review.acceptedChangeTotal) 处")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help("只统计勾中的行里**没有被排除**的字段与封面。"
                                + "\n行内灰色划线的 chip = 那个文件不写那个字段，不计入这里。")

                        // ★ BH 轮 C1：分阶段耗时。用户只会说「慢」，
                        // 不分阶段报数他就永远不知道慢在搜索、取词还是写盘。
                        if !review.summary.stages.isEmpty {
                            Text(review.summary.stages.summaryLine)
                                .font(Theme.Typo.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .help(review.summary.stages.concurrencyLine
                                      ?? "匹配那几段是跨并发累加值，回答的是「占比」。")
                        }

                        // ★ BH 轮 C3：写前预估。整文件重写是物理搬动，改代码救不了，
                        // 但可以在按下「应用」**之前**把量级说清楚。
                        if let warn = writeForecast.warningText {
                            Label(warn, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.Colors.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // ★ BH 轮 C4：落点是可移动卷（TF 卡 / U 盘）且真要大搬动时，
                        // 才给出那条真正管用的出路 —— 并且一键就能切过去。
                        if writeForecast.suggestsFolderArtwork {
                            HStack(spacing: Theme.Spacing.xs) {
                                Label("封面存到 \(writeForecast.volumeName ?? "可移动卷")："
                                      + "建议改用「文件夹图片」模式，音频一个字节都不必重写",
                                      systemImage: "sdcard")
                                    .font(Theme.Typo.caption)
                                    .foregroundStyle(Theme.Colors.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("切到文件夹图片") { model.switchToFolderArtworkMode() }
                                    .buttonStyle(.link)
                                    .font(Theme.Typo.caption)
                            }
                        }
                    }
                    Spacer()
                    Button("全选") { model.setAllAutoMatchAccepted(true) }
                    Button("全不选") { model.setAllAutoMatchAccepted(false) }
                    Button("只选已匹配") { model.selectOnlyMatchedAutoMatch() }
                    Divider().frame(height: 18)
                    Button("放弃") { model.discardAutoMatchReview() }
                        .keyboardShortcut(.cancelAction)
                    Button("应用选中项（\(review.acceptedCount)）") { model.applyAutoMatchSelection() }
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
        .onAppear { recomputeForecast() }
        // 勾选一变，「会重写几个文件」就跟着变 —— 用户正是靠取消勾选把大搬动降下来的。
        // 封面勾不勾（BO#8 起已有封面默认不勾）改不了「几个文件」，但改得了「写多少字节」，一起盯。
        .onChange(of: model.autoMatchReview?.acceptedCount ?? 0) { _, _ in recomputeForecast() }
        .onChange(of: model.autoMatchReview?.acceptedChangeTotal ?? 0) { _, _ in recomputeForecast() }
    }

    /// 重算写前预估。只读文件头，勾选变化时才跑，不进 body。
    private func recomputeForecast() {
        guard let review = model.autoMatchReview else {
            writeForecast = AutoMatchWriteForecast(); return
        }
        writeForecast = model.autoMatchWriteForecast(review.acceptedItems)
    }

    // MARK: 顶部工具条（密度 / 只看改动 / 逐源结果条）

    @ViewBuilder
    private func toolbar(_ review: AutoMatchReview) -> some View {
        ReviewToolbar(display: display) {
            Divider().frame(height: 14)
            // 「一次性去掉所有音轨号」的入口。作用域是**整张复核表**。
            ReviewFieldMenu(title: "全部字段",
                            scopeNote: "当前复核表 \(review.items.count) 个文件",
                            tallies: review.fieldTallies) { key, on in
                model.setAutoMatchFieldForAll(key, on)
            }
            Divider().frame(height: 14)
            Chip(text: "专辑 \(review.displayGroups.filter { !$0.isUnmatched }.count)",
                 systemImage: "square.stack")
            Chip(text: "已匹配 \(review.items.filter { $0.status == .matched }.count)/\(review.items.count)",
                 tinted: true)

            Spacer(minLength: Theme.Spacing.s)

            // 这一轮每个源给了几条、还是挂了。
            // **它回答的是用户那句「搜索结果里没出现 QQ，不知道是没搜到还是挂了」。**
            if !review.sourceOutcomes.isEmpty {
                SourceOutcomeBar(outcomes: review.sourceOutcomes,
                                 label: nil,
                                 selectedSourceID: sourceFilter,
                                 onTap: { id in sourceFilter = (sourceFilter == id) ? nil : id },
                                 trailingNote: filterNote)
                .fixedSize()
            }
        }
    }

    private var filterNote: String? {
        guard let f = sourceFilter else { return nil }
        return "只看 \(SourceOutcome.displayName(f)) 的候选"
    }

    // MARK: 一个专辑组 = 一张专辑卡 + 组内曲目行

    @ViewBuilder
    private func groupCard(_ g: AutoMatchReview.DisplayGroup, review: AutoMatchReview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumCardHeader(info: cardInfo(g, review: review),
                            isCollapsed: collapsedGroups.contains(g.id),
                            onToggleCollapse: { toggleGroup(g.id) }) {
                HStack(spacing: Theme.Spacing.xs) {
                    Button("全组") { setGroupAccepted(g, review: review, true) }
                        .disabled(!hasWritable(g, review: review))
                        .help("勾选本组全部可写入项")
                    Button("全不选") { setGroupAccepted(g, review: review, false) }
                        .disabled(!hasAccepted(g, review: review))
                    // 「整组不写碟号」：勾选是「写不写这一行」，这个菜单是
                    // 「写不写这一列」—— 两把刀垂直，缺哪一把都得逐行去点。
                    ReviewFieldMenu(title: "本组字段",
                                    scopeNote: "本组 \(g.indices.count) 首",
                                    tallies: groupTallies(g, review: review)) { key, on in
                        model.setAutoMatchField(indices: g.indices, key, on)
                    }
                }
            }

            if !collapsedGroups.contains(g.id) {
                Divider()
                let cover = groupArtwork(g, review: review)
                let ctx = groupContext(g, review: review)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(g.indices, id: \.self) { i in
                        if review.items.indices.contains(i) {
                            let item = review.items[i]
                            VStack(alignment: .leading, spacing: 0) {
                                TrackReviewRow(
                                    item: item,
                                    accepted: acceptBinding(i),
                                    density: display.density,
                                    onlyChangedFields: display.onlyChangedFields,
                                    albumArtwork: cover,
                                    group: ctx,
                                    isExpanded: expanded.contains(item.id),
                                    onToggleExpand: { toggleExpanded(item.id) },
                                    onToggleField: { key in
                                        model.toggleAutoMatchField(item.url, key)
                                    }) {
                                        HStack(spacing: Theme.Spacing.xs) {
                                            scoreBadge(item)
                                            candidatePicker(item)
                                        }
                                    }

                                if expanded.contains(item.id) {
                                    detail(item)
                                        .padding(.horizontal, Theme.Spacing.m)
                                        .padding(.bottom, Theme.Spacing.s)
                                }
                            }
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .card(padding: 0)
    }

    /// 把一个展示分组翻译成专辑卡要画的内容。
    private func cardInfo(_ g: AutoMatchReview.DisplayGroup,
                          review: AutoMatchReview) -> AlbumCardInfo {
        let items = g.indices.compactMap { review.items.indices.contains($0) ? review.items[$0] : nil }
        var info = AlbumCardInfo(
            albumTitle: g.album.map { "《\($0)》" } ?? "未匹配",
            artist: g.artist,
            year: g.year,
            trackCountText: "\(items.count) 首",
            sourceName: g.sourceName,
            folderName: nil,
            alignedText: g.isUnmatched
                ? "未写入 \(items.count)"
                : "可写入 \(items.filter(\.hasSomethingToWrite).count)/\(items.count)")

        if !g.isUnmatched {
            info.newArtwork = items.first(where: \.hasArtwork)?.artwork
            let orig = items.compactMap(\.originalArtwork).first
            info.oldArtwork = (orig != nil && orig != info.newArtwork) ? orig : nil
            info.artworkSource = g.sourceName ?? ""
            // 跟着勾选走：已有封面的文件默认不勾（BO#8），不按勾选数就是在说谎。
            let artCount = items.filter { $0.acceptedArtwork != nil }.count
            info.artworkNote = info.newArtwork == nil ? nil
                : "本组 \(artCount) 个文件会写入封面"

            // 专辑级字段只在这里说一次。印哪几格由 `ctx.summarized` 说了算 ——
            // 行内 chips 折掉的正是同一串，两边共用一个来源，不会有字段两头落空。
            let ctx = ReviewGroupContext.make(items: items, artwork: info.newArtwork)
            info.diffs = ctx.summarized.map { cardDiff($0.localizedName, items, $0) }
            // BO#8：封面那一格按磁盘真值说「原 W×H → 新」，并提醒「将替换现有封面」。
            if let art = ReviewArtworkSummary.cardDiff(items, newArtwork: info.newArtwork) {
                info.diffs.append(art)
            }
            info.note = ReviewArtworkSummary.cardNote(items)
            info.diffFootnote = ctx.footnote
        } else {
            info.isUnmatched = true
            info.note = unmatchedNote(items)
        }
        return info
    }

    /// 这一组的组级字段口径。行内 chips 据此把专辑级字段让给专辑卡。
    ///
    /// 「未匹配」那一组的灰卡不画组级摘要（`summarizes: false`），
    /// 于是那几行一个字段都不折，也不会凭空多出「≠ 组」的橙 chip。
    private func groupContext(_ g: AutoMatchReview.DisplayGroup,
                              review: AutoMatchReview) -> ReviewGroupContext {
        let items = g.indices.compactMap { review.items.indices.contains($0) ? review.items[$0] : nil }
        return ReviewGroupContext.make(items: items,
                                       artwork: g.isUnmatched ? nil : groupArtwork(g, review: review),
                                       summarizes: !g.isUnmatched)
    }

    /// 「未匹配」灰卡上的一句话：把最常见的那个原因说出来，别让用户去逐行点开找。
    private func unmatchedNote(_ items: [AutoMatchReviewItem]) -> String {
        let reasons = items.compactMap { $0.ignoredReason ?? $0.errorText?.split(separator: "\n").first.map(String.init) }
        guard let first = reasons.first else {
            return "这些文件没有匹配到任何专辑，本次不会被写入。"
        }
        let same = reasons.allSatisfy { $0 == first }
        return same ? first + "（\(items.count) 个文件）"
                    : first + " 等 \(Set(reasons).count) 种原因，共 \(items.count) 个文件"
    }

    /// 组级共同改动：整组一模一样的那几个字段只在专辑卡上说一次。
    /// 原值不一致时如实说出有几种，不假装整齐 —— 与专辑模式的 `commonChange` 同一口径。
    private func cardDiff(_ label: String, _ items: [AutoMatchReviewItem],
                          _ f: TagEdit.Field) -> AlbumCardDiff {
        let cs = items.compactMap { $0.change(f) }
        guard let first = cs.first else {
            return AlbumCardDiff(label: label, old: "", new: nil, help: "\(label)：整组都不改动")
        }
        let olds = Set(cs.map(\.oldValue))
        let news = Set(cs.map(\.newValue))
        let old = olds.count == 1 ? first.oldDisplay : "（\(olds.count) 种原值）"
        let new = news.count == 1 ? first.newDisplay : "（\(news.count) 种新值）"
        return AlbumCardDiff(label: label, old: old, new: new,
                             help: "\(label)：本组 \(cs.count) 个文件会改\n原：\(old)\n新：\(new)")
    }

    private func groupArtwork(_ g: AutoMatchReview.DisplayGroup,
                              review: AutoMatchReview) -> Data? {
        for i in g.indices where review.items.indices.contains(i) {
            if let a = review.items[i].artwork { return a }
        }
        return nil
    }

    /// 本组逐字段的勾选统计。下标是分组前的原始下标，与勾选走的是同一套。
    private func groupTallies(_ g: AutoMatchReview.DisplayGroup,
                              review: AutoMatchReview) -> [ReviewFieldTally] {
        ReviewFieldTally.make(g.indices.compactMap {
            review.items.indices.contains($0) ? review.items[$0] : nil
        })
    }

    private func hasWritable(_ g: AutoMatchReview.DisplayGroup, review: AutoMatchReview) -> Bool {
        g.indices.contains { review.items.indices.contains($0) && review.items[$0].hasSomethingToWrite }
    }

    private func hasAccepted(_ g: AutoMatchReview.DisplayGroup, review: AutoMatchReview) -> Bool {
        g.indices.contains { review.items.indices.contains($0) && review.items[$0].accepted }
    }

    /// 组级勾选。语义与底部「全选 / 全不选」完全一致，只是范围缩到这一组。
    private func setGroupAccepted(_ g: AutoMatchReview.DisplayGroup,
                                  review: AutoMatchReview, _ on: Bool) {
        for i in g.indices where model.autoMatchReview?.items.indices.contains(i) == true {
            guard model.autoMatchReview!.items[i].hasSomethingToWrite else { continue }
            model.autoMatchReview?.items[i].accepted = on
        }
    }

    private func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    // MARK: 换候选 ▾（B2 / B3 / B4）

    /// 一行末尾的候选菜单。**逐首模式原先只有一个答案可看**，匹配错了只能整行放弃；
    /// 专辑模式早就有「换专辑」，这里补上等价的能力。
    ///
    /// 菜单里同时挂了「手动搜索…」与「只看某来源」，不再另开一个「更多 ▾」——
    /// 窗宽被 `sheetExtraWide` 钉死在 1100，多一个控件就得从别的列身上再抠 70pt。
    @ViewBuilder
    private func candidatePicker(_ item: AutoMatchReviewItem) -> some View {
        let list = visibleCandidates(item)
        Menu {
            if list.isEmpty {
                Text(item.candidates.isEmpty ? "没有候选" : "该来源没有候选")
            } else {
                ForEach(list) { c in
                    Button {
                        model.changeAutoMatchCandidate(url: item.url, to: c.id)
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
        .frame(width: AutoMatchReviewSheet.pickWidth, alignment: .leading)
        .disabled(item.isReloading)
        .help(pickerHelp(item))
        .popover(isPresented: Binding(get: { manualTarget == item.url },
                                      set: { if !$0 { manualTarget = nil } }),
                 arrowEdge: .bottom) {
            ManualSearchPanel(fileName: item.fileName, query: $manualQuery) {
                manualTarget = nil
                model.manualSearchAutoMatch(url: item.url, query: manualQuery)
            } onCancel: {
                manualTarget = nil
            }
        }
    }

    /// 顶部 chips 选了某个源时，菜单只列这个源的候选。
    private func visibleCandidates(_ item: AutoMatchReviewItem) -> [TrackCandidate] {
        guard let f = sourceFilter else { return item.candidates }
        return item.candidates.filter { $0.sourceID == f }
    }

    private func pickerHelp(_ item: AutoMatchReviewItem) -> String {
        guard !item.candidates.isEmpty else {
            return "这一行没有任何候选。用「手动搜索…」自己给一组关键词重搜。"
        }
        var s = "共 \(item.candidates.count) 条候选，当前是第 "
        let idx = (item.candidates.firstIndex { $0.id == item.selectedCandidate?.id } ?? 0) + 1
        s += "\(idx) 条。换一条会立刻重算这一行的 原→新 差异与封面，并自动勾选。"
        if item.manuallyChosen { s += "\n（本行已由你手动确认，不再受采纳阈值限制）" }
        return s
    }

    /// 封面那一行的「新值」：尺寸 + 字节。字段表里其它行都是文本，
    /// 封面只能用它的规格来指代自己。
    private func artworkSizeText(_ item: AutoMatchReviewItem) -> String {
        guard let data = item.artwork else { return "" }
        let img = NSImage(data: data)
        return ArtworkMeta(data: data, image: img, source: "", role: "").line
    }

    private func toggleExpanded(_ id: URL) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func scoreBadge(_ item: AutoMatchReviewItem) -> some View {
        Group {
            if item.bestTitle == nil && item.score <= 0 {
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text(String(format: "%.3f", item.score))
                    .foregroundStyle(scoreColor(item.score))
            }
        }
        .font(Theme.Typo.digitsSmall)
        .frame(width: 42, alignment: .trailing)
        .help("匹配分：0.85 以上通常是原版，0.6 以下多半抓错了版本。")
    }

    // MARK: 展开后的完整字段级差异

    @ViewBuilder
    private func detail(_ item: AutoMatchReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let album = item.bestAlbum, !album.isEmpty {
                Text("候选专辑：\(album)")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
            }
            if !item.triedSources.isEmpty {
                Text("查询了 \(item.triedSources.count) 个源，共 \(item.candidateCount) 条候选")
                    .font(Theme.Typo.caption).foregroundStyle(.tertiary)
            }
            // 这一行自己的逐源结果条：顶部那条是整轮汇总，这里是「这首歌」的实况。
            if !item.sourceOutcomes.isEmpty {
                SourceOutcomeBar(outcomes: item.sourceOutcomes, label: "本行")
            }
            // 时间花在哪。用户抱怨「慢」时最想看到的就是这一行 ——
            // 结果条只说「谁给了几条」，这一行说「谁花了多久、谁被跳过了」。
            if let t = item.timingLine, !t.isEmpty {
                Text("耗时：" + t
                     + (item.elapsed > 0 ? String(format: " · 本首合计 %.1f s", item.elapsed) : ""))
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let q = item.manualQuery {
                Text("手动搜索：标题「\(q.title)」艺术家「\(q.artist)」专辑「\(q.album)」")
                    .font(Theme.Typo.badge).foregroundStyle(.tertiary)
            }
            if let reason = item.ignoredReason {
                Label(reason, systemImage: "info.circle.fill")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Colors.warning)
                    // 与紧邻的 errorText 一致：忽略原因也可能很长，让它换行而不是截断。
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = item.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Colors.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.changes.isEmpty {
                // 这张表是唯一同时给出**勾选框**与**完整原 → 新**的地方：
                // 决定「这个碟号要不要写」，常常得先看清它到底要写成什么。
                // 勾选框与行尾那枚 chip 是同一个开关，改哪边另一边立刻跟着变。
                Grid(alignment: .leading,
                     horizontalSpacing: Theme.Spacing.s,
                     verticalSpacing: Theme.Spacing.xs) {
                    ReviewFieldDiffHeader()
                    ForEach(item.changes) { c in
                        ReviewFieldDiffRow(key: .field(c.field),
                                           oldValue: c.oldDisplay,
                                           newValue: c.newDisplay,
                                           accepted: item.acceptedFields.contains(c.field)) { on in
                            model.setAutoMatchField(item.url, .field(c.field), on)
                        }
                    }
                    if item.hasArtwork {
                        ReviewFieldDiffRow(key: .artwork,
                                           oldValue: item.existingArtworkCell,
                                           newValue: artworkSizeText(item),
                                           accepted: item.acceptArtwork) { on in
                            model.setAutoMatchField(item.url, .artwork, on)
                        }
                    }
                }
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
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("将写入封面").font(Theme.Typo.caption)
                        Text("\(Int(img.size.width)) × \(Int(img.size.height))，\(Formatters.fileSize(Int64(data.count)))")
                            .font(Theme.Typo.badge).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chipFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    // MARK: 小工具

    /// 勾选绑定。**下标是分组前的原始下标**，分组只影响这一行摆在哪里，不影响它是谁。
    private func acceptBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let r = model.autoMatchReview, r.items.indices.contains(index) else { return false }
                return r.items[index].accepted
            },
            set: { on in
                guard model.autoMatchReview?.items.indices.contains(index) == true else { return }
                model.autoMatchReview?.items[index].accepted = on
            })
    }

    private func scoreColor(_ v: Double) -> Color {
        v >= 0.85 ? Theme.Colors.matched : (v >= 0.6 ? Theme.Colors.warning : Color.secondary)
    }
}

// MARK: - 行内手动搜索面板（B3）

/// 复核表某一行的「手动搜索…」弹出面板。
///
/// 为什么要它：候选表是**自动查询**的产物。自动查询的输入若本身就错了
/// （文件名是 `Track 03.flac`、标题被别的工具写成了 Live 版的名字），
/// 那么候选里从头到尾都不会出现正确答案，换多少条都没用 ——
/// 必须允许用户自己给一组关键词，只对这一行重搜。
///
/// 默认值取文件已有标签，没有就拆文件名，与自动匹配的兜底口径一致。
struct ManualSearchPanel: View {

    let fileName: String
    @Binding var query: ManualSearchQuery
    var onSearch: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("只对这一个文件重新搜索")
                .font(Theme.Typo.sectionHeader)
                .foregroundStyle(.secondary)
            Text(fileName)
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .help(fileName)

            field("标题", text: $query.title, focus: true)
            field("艺术家", text: $query.artist, focus: false)
            field("专辑", text: $query.album, focus: false)

            Text("结果会并入这一行的候选表并自动选中最佳的一条。")
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("搜索") { onSearch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.isEmpty)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, focus: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label)
                .font(Theme.Typo.fieldLabel)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            if focus {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.value)
                    .focused($focused)
            } else {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.value)
            }
        }
    }
}

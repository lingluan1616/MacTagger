//
//  AppModel.swift
//  MacTagger — 主窗口状态机
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 弹窗载体

struct AlertBox: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var isError: Bool = false
}

struct ConfirmBox: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String = "确定"
    var destructive: Bool = false
    var action: () -> Void
}

/// 「有未保存的改动」三选一（切目录 / 重新载入 / 移除项 / 清空列表 / 退出 App 共用，BO#11）。
enum UnsavedChangesChoice { case save, discard, cancel }

/// 交给提问者的上下文。默认用 NSAlert 问；离屏工装 / 自动化可换成脚本回答
/// （`AppModel.unsavedChangesPrompter`）。
struct UnsavedChangesPrompt {
    /// 动作名：「切换到「X」」「退出 MacTagger」…
    var action: String
    /// 有未保存改动的文件数。
    var fileCount: Int
    /// 检查器里有没有还没落进草稿的封面改动。
    var hasArtworkEdit: Bool

    var title: String { "\(action)前，有未保存的改动" }
    var message: String {
        var text = "有 \(fileCount) 个文件的改动还没保存"
        if hasArtworkEdit { text += "（含封面改动）" }
        return text + "。\n\n保存：先写入这些改动再继续。\n放弃改动：直接继续，这些改动会丢失。"
    }
}

// MARK: - 可编辑字段（标签面板）

enum EditorField: String, CaseIterable, Identifiable {
    case title, artist, albumArtist, album, year, track, disc
    case genre, comment, composer, lyricist, lyrics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "标题"
        case .artist: return "艺术家"
        case .albumArtist: return "专辑艺术家"
        case .album: return "专辑"
        case .year: return "年份"
        case .track: return "音轨号"
        case .disc: return "碟号"
        case .genre: return "风格"
        case .comment: return "注释"
        case .composer: return "作曲家"
        case .lyricist: return "作词家"
        case .lyrics: return "歌词"
        }
    }

    var tagField: TagEdit.Field? {
        switch self {
        case .title: return .title
        case .artist: return .artist
        case .albumArtist: return .albumArtist
        case .album: return .album
        case .year: return .year
        case .track: return .track
        case .disc: return .disc
        case .genre: return .genre
        case .comment: return .comment
        case .composer: return .composer
        case .lyrics: return .lyrics
        case .lyricist: return nil
        }
    }

    var rawKey: String? { self == .lyricist ? "LYRICIST" : nil }
}

// MARK: - 主模型

@MainActor
final class AppModel: ObservableObject {

    // 数据
    @Published private(set) var allRows: [FileRow] = []
    /// 过滤 + 排序后的显示序列，`Table` 的数据源。
    @Published private(set) var displayRows: [FileRow] = []
    private var allIndex: [URL: Int] = [:]
    private var displayIndex: [URL: Int] = [:]

    // 选择与排序
    @Published var selection: Set<URL> = [] { didSet { onSelectionChanged(from: oldValue) } }
    @Published var sortOrder: [FileSortComparator] = [FileSortComparator(columnID: .filename)] {
        didSet {
            rebuildDisplay()
            // 排序一变，「屏幕上是哪 80 行」也跟着变 —— 重新排一次队。
            // （放在这里而不是 `rebuildDisplay()` 里：那个函数也被读标签的收尾调用，
            //   在那里起按需任务会挡住紧接着的全量读取交接，正是 AS- 报告里的坑。）
            prioritizeLeadingRows()
        }
    }
    @Published var filterText: String = "" { didSet { rebuildDisplay() } }
    /// 顶栏漏斗菜单里勾中的快捷筛选。**多选取交集**（同时满足），与过滤词叠加生效。
    /// 刻意不持久化：它是「我现在要处理这一批」的临时视角，重启后还挡着列表
    /// 只会让用户以为文件丢了。
    @Published var quickFilters: Set<QuickFilter> = [] { didSet { rebuildDisplay() } }

    // 界面反馈
    @Published var statusMessage: String = "拖入音频文件或文件夹开始"
    @Published var progress: BatchProgress?
    @Published var progressTitle: String = ""
    @Published var alert: AlertBox?
    @Published var confirm: ConfirmBox?

    // MARK: 「忙」的令牌（BO#7）

    /// 批处理（保存 / 清除 / 匹配 / 整理 / 刷新…）的「忙」令牌。
    ///
    /// 各批处理照旧写 `isBusy = true / false`，落到这里。导入与后台补读**各有各的令牌**
    /// （`isListing` / `isMaterializing`），绝不动它 —— 从前导入收尾一句 `isBusy = false`
    /// 把正在跑的写入批也「清」掉了：顶栏按钮全部解禁、浮层消失、写入还在后台跑（BO#7）。
    @Published private(set) var batchBusy = false {
        didSet { if oldValue, !batchBusy { batchDidEnd() } }
    }
    /// 界面意义上的「忙」= 批处理 ∪ 导入列出 ∪ 后台补读。按钮 / 菜单的禁用条件都看它。
    /// 写它只动批处理令牌（`isBusy = false` 清不掉别人的导入，导入也清不掉批处理）。
    var isBusy: Bool {
        get { batchBusy || isListing || isMaterializing }
        set { batchBusy = newValue }
    }
    /// 批量入口前的后台补读（`materializePendingTagsInBackground`）正在跑。
    @Published private(set) var isMaterializing = false
    private var materializeCancelled = false
    /// 批处理结束（`batchBusy` 落回 false）后要接着办的事，例如「保存完再切目录」。
    private var batchEndActions: [() -> Void] = []
    /// 忙时收到的追加导入（拖放 / ⌘O / 添加到列表），等忙完自动接着导。
    private(set) var deferredImportURLs: [URL] = []
    /// 当前整张列表是从哪个目录载入的（替换类导入时记下；用户在确认框里点「取消」时据此把侧栏选中态退回去）。
    private var listDirectory: URL?
    /// 全量读标签跑完表上却还有待读行时，自动续读的剩余次数（BO#36）。
    private var fullReadResumeBudget = 0
    private var refreshCancelled = false
    /// 撤消旁存仓库初始化失败的说明（BO#34）。nil = 正常。
    @Published private(set) var sideCarError: String?
    /// 替换「有未保存的改动」默认的 NSAlert 提问（离屏工装 / 自动化用）。nil = 弹 NSAlert。
    var unsavedChangesPrompter: ((UnsavedChangesPrompt) -> UnsavedChangesChoice)?
    private var volumeObserver: NSObjectProtocol?

    // MARK: 两段式导入
    //
    // 阶段一「列出」与阶段二「读标签」各有自己的任务与取消口：
    // 取消阶段一保留已列出的行，取消阶段二保留已读的标签、未读的仍是待读状态。

    /// 阶段一（枚举）正在跑。
    @Published private(set) var isListing = false
    /// 阶段二（读标签）正在跑。
    @Published private(set) var isReadingTags = false
    /// 已列出的行数（= `allRows.count`，单独存一份给进度文案用，避免每帧数数组）。
    @Published private(set) var listedCount = 0
    /// 已读出标签的行数。
    @Published private(set) var loadedTagCount = 0
    /// 还没读标签的行数。> 0 时右键菜单出现「继续读取标签」。
    @Published private(set) var pendingTagCount = 0
    /// 待读行**超过 5 秒还没人读**：状态栏摆出「有 N 首未读取标签 · 点此读取」。
    /// 见 `refreshPendingHint()`。
    @Published private(set) var showPendingHint = false

    /// 状态栏那句提示的文案。
    var pendingHintText: String { "有 \(pendingTagCount) 首未读取标签 · 点此读取" }

    private var importTask: Task<Void, Never>?
    private var tagReadTask: Task<Void, Never>?
    /// 每轮导入 / 每轮读标签各自自增。
    ///
    /// 用户在阶段一跑到一半时点了另一个目录：旧任务的 `finishListing` 还会在稍后落到主线程上，
    /// 那时新一轮已经开工了 —— 不认运行号的话，旧任务会把新一轮的 `isBusy`、进度条、
    /// 甚至「要不要自动读标签」的结论一并改掉，还会把旧目录的行追加进新列表。
    private var importRunID = 0
    private var tagReadRunID = 0
    /// 待读队列。取消后仍留着，「继续读取标签」直接接上。
    private var tagQueue: TagReadQueue?
    /// 「欠着一次全量读取」。
    ///
    /// 阶段一还在跑的时候，界面的 `onAppear` 就可能先起了一条**按需**读取任务
    /// （`noteRowVisible` → `prioritizeTagRead`）。阶段一结束时 `finishListing` 想起全量读取，
    /// 却会被 `startTagRead` 的 `tagReadTask == nil` 挡板**静默吞掉** —— 全量读取永远不开始，
    /// 表上留着一片占位行，用户只有点表头排序（触发重建 + 重新 onAppear）才看见标签补上。
    /// 这就是「读完不刷新，切换排序后才显示」的根因（复现实验见 research/AS- 报告）。
    /// 记在这里，按需任务收工时交接。
    private var fullTagReadPending = false
    /// 本轮导入的根路径（判可移动卷用）。
    private var importRoots: [URL] = []
    /// 本轮导入是不是「启动时接着上次」——只有它受 2000 个文件的保护阈值管。
    private var importIsRestore = false

    /// 读到的标签先攒在这里，每 `tagFlushInterval` 秒统一刷进列表。
    ///
    /// 不攒的话 3 万首会产生上千次 `@Published` 变更，SwiftUI 每次都要 diff 整张表 ——
    /// 列表会在第二阶段全程卡顿。攒一下，刷新次数降到每秒 4 次。
    private var tagFlushBuffer: [URL: FileRow] = [:]
    private var tagFlushDrops: [URL: String] = [:]
    private var tagFlushScheduled = false
    private static let tagFlushInterval: Duration = .milliseconds(250)

    /// 可见行的插队缓冲（`FileTableView` 的 onAppear 灌进来）。
    private var visibleBuffer: Set<URL> = []
    private var visibleFlushScheduled = false
    /// 上一拍里 onAppear 报上来的行在 `displayRows` 里的下标区间（= 大致可见范围）。
    /// 每次巡检读完就清空，它说的是「刚刚滚过来的那一带」。
    private var visibleBandLow: Int?
    private var visibleBandHigh: Int?
    /// 最近一次报上来的行下标。滚动停下后 onAppear 不再来，靠它记住用户停在哪儿。
    private var visibleAnchor: Int?
    /// 300 ms 一次的可见窗口巡检。只在还有待读行时活着。
    private var visibleSweepTask: Task<Void, Never>?
    /// 巡检连着多少拍没排出任何行（用来把周期放慢，见 `ensureVisibleSweep`）。
    private var visibleSweepIdleTicks = 0
    /// 「有待读行且没人在读」是从什么时候开始的。nil = 当前不满足条件。
    private var pendingIdleSince: Date?

    // 封面
    @Published var focusArtworks: [Artwork] = []
    @Published var artworkIndex: Int = 0
    @Published var artworkDirty = false

    // 历史
    @Published var historyEntries: [TagsHistoryEntry] = []
    @Published var historyScopeIsAll = false
    @Published var historyError: String?

    // 自动匹配标签（原版 FormAutoMatchTags）
    /// 选项窗是自动匹配 / 专辑匹配**唯一**的入口，所以把「待读的行先补读标签」
    /// 挂在它打开的这一下：窗一弹出来，作用域内的标题/艺术家就已经是真值，
    /// 不会拿着空标签去联网瞎猜。
    @Published var showAutoMatchOptions = false {
        didSet {
            guard showAutoMatchOptions, !oldValue else { return }
            let targets = autoMatchTargets
            let pending = targets.reduce(0) { $0 + ($1.tagsState.isPending ? 1 : 0) }
            // 少量待读行：同步补读（几十毫秒），窗照常立刻弹。
            guard pending > AppModel.syncMaterializeLimit else {
                materializePendingTags(in: targets)
                return
            }
            // BO#16：量大时不再同步读几百上千首把主线程卡成彩虹球 —— 先把窗收回去，
            // 后台补读（有进度、可取消），读完再弹窗。窗一弹出来作用域内仍然全是真值。
            showAutoMatchOptions = false
            Task { [weak self] in
                guard let self else { return }
                if await self.materializePendingTagsInBackground(in: targets, title: "自动匹配前补读标签…") {
                    self.showAutoMatchOptions = true
                }
            }
        }
    }
    /// 匹配完成后的待复核清单。非 nil 即弹出复核窗——**匹配结果绝不直接落盘**。
    @Published var autoMatchReview: AutoMatchReview?
    @Published var isAutoMatching = false
    /// 进度浮层上的「取消」按钮；nil 表示当前任务不可取消。
    @Published var cancelHandler: (() -> Void)?
    var autoMatchTask: Task<Void, Never>?
    /// 每次匹配自增，用来让已取消任务的在途结果作废。
    var autoMatchRunID = 0

    // 歌词（原版 FormLyric / FormLyricSearch / FormLyricAdjustTimetag / FormFindReplace）
    /// 非 nil 即弹出独立的歌词编辑窗。
    @Published var lyricsEditorContext: LyricsEditorContext?
    /// 主窗口直接发起的「从网络搜索歌词」。
    @Published var showLyricsSearch = false
    /// 批量下载完成后的待复核清单。与自动匹配同理：**绝不直接落盘**。
    @Published var lyricsBatchReview: LyricsBatchReview?
    @Published var showLrcExportOptions = false
    @Published var isDownloadingLyrics = false
    var lyricsTask: Task<Void, Never>?
    var lyricsRunID = 0
    /// 歌词偏好（合并格式、Lrc 文件设置）。用单例避免改动已定型的 init 签名。
    var lyricsSettings: LyricsSettings { LyricsSettings.shared }

    let settings: AppSettings
    let columns: ColumnStore
    let directories: DirectoryStore
    let autoMatchSettings: AutoMatchSettings
    private(set) var historyStore: TagsHistoryStore?
    private(set) var sideCarStore: SideCarStore?

    init(settings: AppSettings,
         columns: ColumnStore,
         directories: DirectoryStore,
         autoMatchSettings: AutoMatchSettings) {
        self.settings = settings
        self.columns = columns
        self.directories = directories
        self.autoMatchSettings = autoMatchSettings
        do {
            historyStore = try TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL())
        } catch {
            historyError = "初始化数据库失败 (\(error.localizedDescription))"
        }
        // BO#34：旁存仓库单独初始化，失败要说出来。从前是 `try?` 静默降级 ——
        // 之后封面 / 歌词 / 表外字段的改动全都撤不回来，界面上却什么都看不出。
        do {
            sideCarStore = try SideCarStore()
        } catch {
            let text = "撤消旁存仓库初始化失败（\(error.localizedDescription)）。"
                + "此后封面、歌词以及专辑艺术家 / 风格 / 注释 / 作曲 / 作词的改动无法撤消，"
                + "「撤消标签保存」只能还原标题、艺术家、专辑、年份、音轨、碟号 6 个字段。"
            sideCarError = text
            alert = AlertBox(title: "撤消功能受限", message: text, isError: true)
        }
        // BO#13：启动时维护一次撤消旁存（孤儿目录 + 数量 / 体积上限）。本体在 AppModel+Editing
        // （C 组，后台跑、10 分钟节流、忙时不跑）。若它排到时启动载入正在列目录（忙）而跳过，
        // 启动载入收尾时会再补调一次（见 `finishListing`）。
        maintainUndoStorage()
        // BO#37：上次的工作目录在外接卷 / TF 卡上、启动时没插 —— 插上后自动接着载入。
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreLastDirectoryIfNeeded() }
        }
    }

    // MARK: 派生状态

    var selectedRows: [FileRow] {
        displayRows.filter { selection.contains($0.id) }
    }

    var focusRow: FileRow? {
        selectedRows.first
    }

    var dirtyRows: [FileRow] { allRows.filter { $0.isDirty } }

    /// 有没有没保存的改动：检查器里的封面改动、已读行的草稿差、**待读行上的占位改动**（BO#2）。
    var hasPendingChanges: Bool {
        artworkDirty || allRows.contains { $0.isDirty || $0.hasPlaceholderEdits }
    }

    var totalCount: Int { allRows.count }
    var visibleCount: Int { displayRows.count }
    var selectedCount: Int { selection.count }

    func row(id: URL) -> FileRow? {
        allIndex[id].map { allRows[$0] }
    }

    // MARK: 行改写

    private func reindex() {
        allIndex = Dictionary(uniqueKeysWithValues: allRows.enumerated().map { ($0.element.id, $0.offset) })
        displayIndex = Dictionary(uniqueKeysWithValues: displayRows.enumerated().map { ($0.element.id, $0.offset) })
    }

    func mutate(_ id: URL, _ body: (inout FileRow) -> Void) {
        // 下标对不上（行刚被删、索引还没重建）就跳过，别改到别的行上去、更别越界。
        if let i = allIndex[id], allRows.indices.contains(i), allRows[i].id == id { body(&allRows[i]) }
        if let j = displayIndex[id], displayRows.indices.contains(j), displayRows[j].id == id {
            body(&displayRows[j])
        }
    }

    func mutateSelection(_ body: (inout FileRow) -> Void) {
        mutateRows(selection, body)
    }

    /// 批量改写多行：在本地副本上改完、**一次**赋回。
    ///
    /// `@Published` 数组没有原地 `_modify`，`allRows[i] = x` 每一下都会把整个数组复制一遍 ——
    /// ⌘A 两千行改一个字段、补读 / 刷新两千行，逐行写就是 O(n²) 的整表复制（BO#16 实测秒级）。
    func mutateRows<S: Sequence>(_ ids: S, _ body: (inout FileRow) -> Void) where S.Element == URL {
        var all = allRows
        var shown = displayRows
        var touched = false
        for id in ids {
            if let i = allIndex[id], all.indices.contains(i), all[i].id == id { body(&all[i]); touched = true }
            if let j = displayIndex[id], shown.indices.contains(j), shown[j].id == id { body(&shown[j]); touched = true }
        }
        guard touched else { return }
        allRows = all
        displayRows = shown
    }

    /// 一行是否命中当前过滤条件。
    ///
    /// 待读的行**只拿文件名比**：它的标题/艺术家还没读出来，拿空串去比会让
    /// 「搜什么都搜不到」变成「搜什么都被挡掉」，用户会以为文件丢了。
    func matchesFilter(_ row: FileRow, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if row.tagsState.isPending {
            return row.fileName.lowercased().contains(needle)
                || row.directory.lowercased().contains(needle)
        }
        return columns.visible.contains { row.text(for: $0).lowercased().contains(needle) }
            || row.fileName.lowercased().contains(needle)
    }

    /// 一行是否通过快捷筛选。多条勾选取**交集** —— 「无封面 + 无歌词」是
    /// 同时缺这两样的那一批，不是两者相加。
    func matchesQuickFilters(_ row: FileRow) -> Bool {
        guard !quickFilters.isEmpty else { return true }
        return quickFilters.allSatisfy { $0.matches(row) }
    }

    /// 快捷筛选 + 过滤词，两道一起过。列表增量落表与整表重建共用同一把尺子。
    func passesFilters(_ row: FileRow, needle: String) -> Bool {
        matchesQuickFilters(row) && matchesFilter(row, needle: needle)
    }

    // MARK: 快捷筛选的开关

    /// 状态栏胶囊上的文案：「无封面 · 无歌词」。顺序按枚举声明，不随勾选先后跳。
    var quickFilterSummary: String {
        QuickFilter.allCases.filter { quickFilters.contains($0) }
            .map(\.localizedName).joined(separator: " · ")
    }

    func toggleQuickFilter(_ f: QuickFilter) {
        if quickFilters.contains(f) { quickFilters.remove(f) } else { quickFilters.insert(f) }
    }

    func setQuickFilter(_ f: QuickFilter, _ on: Bool) {
        if on { quickFilters.insert(f) } else { quickFilters.remove(f) }
    }

    func clearQuickFilters() {
        guard !quickFilters.isEmpty else { return }
        quickFilters = []
    }

    /// 右键菜单的「仅显示无封面的」：换成**只有**这一条，不与已勾的条件求交 ——
    /// 菜单上写的是「仅」，做出来就得是「仅」。
    func showOnlyMissingArtwork() {
        quickFilters = [.noArtwork]
    }

    /// 重新计算过滤 + 排序（只在导入 / 删除 / 改排序 / 改过滤时调用，
    /// 编辑单元格时不重排，避免行在输入过程中乱跳）。
    func rebuildDisplay() {
        var rows = allRows
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !quickFilters.isEmpty {
            rows = rows.filter { matchesQuickFilters($0) }
        }
        if !needle.isEmpty {
            rows = rows.filter { matchesFilter($0, needle: needle) }
        }
        if let comparator = sortOrder.first {
            rows.sort { comparator.compare($0, $1) == .orderedAscending }
        }
        displayRows = rows
        reindex()
        // 选中项可能被过滤掉了
        let visible = Set(rows.map(\.id))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
    }

    // MARK: 导入

    func presentAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要添加的音频文件"
        panel.prompt = "添加"
        panel.allowedContentTypes = ImportOptions.defaultExtensions
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func presentAddDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择要添加的目录"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            directories.add(panel.urls)
            if directories.current == nil { directories.current = panel.urls.first }
            importURLs(panel.urls)
        }
    }

    /// 启动时把上次的工作目录接着载入回来（Apple Music 那种「接着上次」）。
    ///
    /// 为什么必须有它：侧栏靠 `List(selection:)` 切目录，而 `DirectoryStore.current`
    /// 是持久化的 —— 第二次启动时那一行**本来就是选中态**，SwiftUI 不会再调 setter，
    /// `importURLs` 于是永远不跑，用户看到「明明选中了目录，列表却是空的，点了也没反应」。
    ///
    /// 只在列表为空且不忙时动手，所以重复调用无副作用（挂在 `ContentView` 的 `.task` 上）。
    /// 上次的目录已经不在磁盘上（外接盘拔了 / 目录被删）时不报错弹窗，
    /// 只把选中态清掉并在状态栏说一句，免得一启动就糊用户一脸弹窗。
    /// 启动自动载入的**保护阈值**：超过这么多文件就只列出、不自动读标签。
    /// 一开机就把几万首的标签全读一遍，用户还没点任何东西就先卡几分钟，得不偿失。
    private static let restoreAutoReadLimit = 2000

    func restoreLastDirectoryIfNeeded() {
        guard !isBusy, allRows.isEmpty, let url = directories.current else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // BO#37：**不再清掉**持久化的「当前目录」。TF 卡 / 外接盘多半只是这次没插 ——
            // 插上后 didMount 通知会再调一次这里自动载入，用户点侧栏那一行也能重新载入。
            statusMessage = "上次的工作目录暂时不可用（所在的卷未连接或目录已移走）：\(url.lastPathComponent)"
            return
        }
        beginImport([url], replaceExisting: true, isRestore: true)
    }

    // MARK: 阶段一：列出

    /// 拖拽 / 菜单 / 目录管理窗共用的入口。
    ///
    /// **两条路径**，由 `AppSettings.lazyThreshold`（默认 500，0 = 关掉直接路径）分流：
    ///
    /// - **直接路径**（文件数 ≤ 阈值）：枚举出来的文件先攒着**不上表**，后台把标签一次读完，
    ///   整表一次性上屏 —— 列表出现时每一格都是真值。10 首歌的目录不该先闪一片
    ///   「读取中…」再一格格填，那比直接等 0.2 秒更慢（用户原话：小库反而更慢）。
    ///   全程仍在后台，主线程一步不挡。
    /// - **两段式**（文件数 > 阈值）：阶段一只走目录树，每 200 个文件就把占位行推上表 ——
    ///   3 万首几秒内可见、可滚、可取消；阶段二在后台读标签，读到一批换掉一批，可见行优先。
    ///
    /// 枚举途中一旦攒过了阈值就**立刻退回两段式**，把攒下的那些一次推上表 ——
    /// 不知道总数就先按小库走、超了再切，这样两头都不亏。
    ///
    /// - Parameter isRestore: 启动时「接着上次」。只有这条路径受
    ///   `restoreAutoReadLimit` 与可移动卷两道保护（见 `shouldAutoReadTags`）。
    func importURLs(_ urls: [URL], replaceExisting: Bool = false, isRestore: Bool = false) {
        guard !urls.isEmpty else { return }

        // BO#7：写入批 / 后台补读正占着「忙」—— 导入不许抢它的进度浮层与「取消」。
        // 追加类（拖放 / ⌘O / 添加到列表）排队，等它结束自动接着导；替换类（切目录 / 重新载入）直接拒。
        if batchBusy || isMaterializing {
            let what = busyActivityName
            if replaceExisting {
                statusMessage = "正在\(what)，请等它结束后再切换或重新载入目录"
                revertDirectoryHighlight()
            } else {
                deferImport(urls)
                statusMessage = "正在\(what)，结束后自动添加 \(deferredImportURLs.count) 项"
            }
            return
        }
        // BO#36：追加导入撞上正在列出的上一轮 —— 排在它后面，不再把它整轮作废。
        if !replaceExisting, isListing {
            deferImport(urls)
            return
        }
        // BO#11：替换整张列表前，有未保存的改动先问「保存 / 放弃 / 取消」。
        // 侧栏走 `switchDirectory(to:)`（那里已经问过）；这里兜住其它直接替换列表的入口
        // （如目录管理窗「设为当前」：它先改了 `directories.current`，取消时要退回去）。
        if replaceExisting, !isRestore, hasPendingChanges {
            let previous = listDirectory
            confirmDiscardIfDirty("载入新的列表", onCancel: { [weak self] in
                guard let self else { return }
                if let previous, self.directories.current != previous { self.directories.current = previous }
                self.revertDirectoryHighlight()
            }) { [weak self] in
                self?.beginImport(urls, replaceExisting: true, isRestore: isRestore)
            }
            return
        }
        beginImport(urls, replaceExisting: replaceExisting, isRestore: isRestore)
    }

    /// 真正开工的导入（前置检查都在 `importURLs` / `switchDirectory` 里做完了）。
    private func beginImport(_ urls: [URL], replaceExisting: Bool, isRestore: Bool) {
        // 上一轮还在跑就整轮作废：用户已经点到别的目录去了，旧结果没人要。
        // （追加导入走到这里时一定没有在列的上一轮，见 `importURLs`，这一句是空操作。）
        cancelImport(silent: true)

        if replaceExisting {
            cancelTagRead(silent: true)
            allRows.removeAll()
            // 索引必须跟着清空。否则「重新载入同一个目录」时 allIndex 还留着旧的下标，
            // 后面按下标改写就会越界 —— 实测直接 crash。
            allIndex.removeAll()
            displayRows.removeAll()
            displayIndex.removeAll()
            selection.removeAll()
            artworkDirty = false
            tagQueue = TagReadQueue()
            fullTagReadPending = false
            // 换一批文件了：可见范围的锚点全部作废。
            visibleBandLow = nil
            visibleBandHigh = nil
            visibleAnchor = nil
            // 排队的追加导入是冲着旧列表去的，随它一起作废。
            deferredImportURLs.removeAll()
            importRoots = urls
            listDirectory = urls.count == 1 ? urls[0] : nil
        } else {
            // BO#36：追加导入（含改名 / 整理收尾的重新导入）**不再**掐断正在进行的全量读标签，
            // 也不换队列 —— 新行排进同一条队列，正在读的任务顺手读掉，老列表剩下的待读行照读不误。
            if tagQueue == nil { tagQueue = TagReadQueue() }
            importRoots = Array((importRoots + urls).prefix(8))
        }

        let options = settings.importOptions
        importRunID &+= 1
        let runID = importRunID
        importIsRestore = isRestore
        // 5 秒提示的时钟作废；三个计数按表上现状重数（追加导入时老列表的待读行还在）。
        pendingIdleSince = nil
        showPendingHint = false
        recountTagStates()

        // 0 = 用户把直接路径关了，任何目录都走两段式。
        let threshold = settings.lazyThreshold
        let concurrency = TagReader.recommendedConcurrency(for: urls)

        // 导入只拿自己的令牌 `isListing`（`isBusy` 由它派生），不碰批处理的 `batchBusy`。
        isListing = true
        if !batchBusy {
            progressTitle = "正在列出文件…"
            progress = BatchProgress(completed: 0, total: 0)
            cancelHandler = { [weak self] in self?.cancelImport() }
        }
        statusMessage = "正在列出文件…"

        importTask = Task { [weak self] in
            var skippedCount = 0
            var cancelled = false
            /// 直接路径下先攒着不上表的文件。超过阈值就一次性倒给两段式。
            var held: [EnumeratedFile] = []
            /// 还在直接路径上吗。
            var direct = threshold > 0

            do {
                for try await batch in ImportService.enumerate(urls: urls, options: options) {
                    if Task.isCancelled { cancelled = true; break }
                    skippedCount += batch.skipped.count
                    guard direct else {
                        let files = batch.files
                        await MainActor.run { self?.appendListedBatch(files, runID: runID) }
                        continue
                    }
                    held.append(contentsOf: batch.files)
                    guard held.count > threshold else { continue }
                    // 超阈值：退回两段式。攒下的这些一步都不浪费，立刻推上表。
                    direct = false
                    let backlog = held
                    held = []
                    await MainActor.run { self?.appendListedBatch(backlog, runID: runID) }
                }
            } catch {
                cancelled = true            // 目前只有 CancellationError 走这条路
            }
            if Task.isCancelled { cancelled = true }

            if direct {
                // 目录整个 ≤ 阈值 —— **不管在什么卷上**都在这里一次读完再上表。
                // 只有「从不自动读取」会走到 else 分支（那是用户明确要的按需模式）。
                var readNow = false
                if !cancelled, !held.isEmpty {
                    let n = held.count
                    readNow = await MainActor.run {
                        self?.shouldAutoReadTags(listed: n, direct: true) ?? false
                    }
                }
                if readNow {
                    let total = held.count
                    await MainActor.run { self?.beginDirectTagRead(total: total, runID: runID) }
                    let sink = DirectReadSink()
                    let queue = TagReadQueue(held.map(\.url))
                    await TagReader.drain(queue: queue, options: options,
                                          concurrency: concurrency) { batch in
                        let done = sink.add(batch)
                        Task { @MainActor [weak self] in
                            self?.noteDirectTagProgress(done: done, total: total, runID: runID)
                        }
                    }
                    if Task.isCancelled { cancelled = true }
                    let result = sink.take()
                    skippedCount += result.skipped
                    // 取消时已读的照样上表，没轮到的退回占位行 —— 与两段式的取消语义一致。
                    let leftovers = held.filter { !result.handled.contains($0.url.path) }
                    let failedRows = result.failures.compactMap { pair -> (EnumeratedFile, String)? in
                        guard let f = held.first(where: { $0.url == pair.url }) else { return nil }
                        return (f, pair.error.localizedDescription)
                    }
                    let loaded = result.files
                    await MainActor.run {
                        self?.appendLoadedBatch(loaded, failures: failedRows, runID: runID)
                        if !leftovers.isEmpty { self?.appendListedBatch(leftovers, runID: runID) }
                    }
                } else {
                    let backlog = held
                    if !backlog.isEmpty {
                        await MainActor.run { self?.appendListedBatch(backlog, runID: runID) }
                    }
                }
            }

            await MainActor.run {
                self?.finishListing(skipped: skippedCount, cancelled: cancelled,
                                    runID: runID, direct: direct)
            }
        }
    }

    /// 阶段一的一批（默认 200 个）落表。
    ///
    /// **只往末尾追加、绝不重排**：列表在增长过程中已有的行一步都不动，
    /// 用户滚到哪儿就停在哪儿。排序留到阶段一结束时一次性做（见 `finishListing`）。
    private func appendListedBatch(_ files: [EnumeratedFile], runID: Int) {
        guard runID == importRunID else { return }      // 上一轮的在途批次，丢掉
        guard !files.isEmpty else { return }
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var fresh: [FileRow] = []
        var visible: [FileRow] = []
        fresh.reserveCapacity(files.count)

        for f in files {
            // 已经在表里的（「添加到列表（不清空）」重复添加同一目录）保留原行，
            // 别把已经读好的标签退回待读状态。
            guard allIndex[f.url] == nil else { continue }
            let row = FileRow(pending: f)
            allIndex[f.url] = allRows.count + fresh.count
            fresh.append(row)
            if passesFilters(row, needle: needle) { visible.append(row) }
        }
        guard !fresh.isEmpty else { return }

        // 每批 200 行插入必须**关掉动画**：SwiftUI 默认会给新行做淡入，
        // 一秒钟几千行的淡入动画本身就够把主线程压垮。
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            allRows.append(contentsOf: fresh)
            if !visible.isEmpty {
                let base = displayRows.count
                displayRows.append(contentsOf: visible)
                for (i, r) in visible.enumerated() { displayIndex[r.id] = base + i }
            }
        }

        tagQueue?.append(fresh.map(\.id))
        listedCount = allRows.count
        pendingTagCount += fresh.count
        if !batchBusy {
            progress = BatchProgress(completed: listedCount, total: 0)
            progressTitle = "正在列出文件…"
        }
    }

    /// 直接路径：标签已经读齐的一批整体落表。
    ///
    /// 与 `appendListedBatch` 的区别只有两点：行是 `.loaded` 而不是 `.pending`，
    /// 以及**不碰 `displayRows`** —— 紧接着的 `finishListing` 会 `rebuildDisplay()`
    /// 一次性排好序，中途没有任何一帧会让用户看到没排序的表。
    private func appendLoadedBatch(_ files: [AudioFile],
                                   failures: [(EnumeratedFile, String)],
                                   runID: Int) {
        guard runID == importRunID else { return }
        var fresh: [FileRow] = []
        fresh.reserveCapacity(files.count + failures.count)
        for f in files {
            guard allIndex[f.url] == nil else { continue }
            allIndex[f.url] = allRows.count + fresh.count
            fresh.append(FileRow(file: f))
        }
        for (enumerated, message) in failures {
            guard allIndex[enumerated.url] == nil else { continue }
            var row = FileRow(pending: enumerated)
            row.tagsState = .failed(message)
            allIndex[enumerated.url] = allRows.count + fresh.count
            fresh.append(row)
        }
        guard !fresh.isEmpty else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { allRows.append(contentsOf: fresh) }
        listedCount = allRows.count
    }

    /// 直接路径的进度浮层：从「正在列出文件…」换成「正在读取标签…」。
    private func beginDirectTagRead(total: Int, runID: Int) {
        guard runID == importRunID else { return }
        if !batchBusy {
            progressTitle = "正在读取标签…"
            progress = BatchProgress(completed: 0, total: total,
                                     note: "已列出 \(total) 首 · 正在读取标签")
        }
        statusMessage = "正在读取 \(total) 首的标签…"
    }

    private func noteDirectTagProgress(done: Int, total: Int, runID: Int) {
        guard runID == importRunID, !batchBusy else { return }
        let n = min(done, total)
        progress = BatchProgress(completed: n, total: total,
                                 note: "已列出 \(total) 首 · 已读取标签 \(n)/\(total)")
    }

    /// - Parameter direct: 走的是直接路径（标签已在后台读齐，不必再起阶段二）。
    private func finishListing(skipped: Int, cancelled: Bool, runID: Int, direct: Bool) {
        // 已经开了新一轮：这一轮的收尾一句都不能做，否则会顶掉新一轮的进度与状态。
        guard runID == importRunID else { return }
        importTask = nil
        // 只放下导入自己的令牌。`isBusy` 由它派生，别人的批处理令牌一概不碰（BO#7）。
        isListing = false
        // 直接路径下 loaded / pending 两个数只有行状态说了算（有失败行、有取消剩下的），
        // 两段式下也顺手对一次账，比 appendListedBatch 的加加减减稳。
        recountTagStates()
        // 阶段一全程只追加，这里补一次排序 + 过滤，把表摆成用户设定的样子。
        rebuildDisplay()

        // 直接路径已经把标签读完了（或用户明确不读），不再起阶段二。
        let autoRead = !direct && !cancelled && shouldAutoReadTags(listed: listedCount, direct: false)
        var parts: [String]
        if direct {
            parts = [cancelled ? "已取消，已载入 \(listedCount) 首" : "已载入 \(listedCount) 首"]
        } else {
            parts = [cancelled ? "已取消列出，已列出 \(listedCount) 首" : "已列出 \(listedCount) 首"]
        }
        if skipped > 0 { parts.append("已忽略 \(skipped) 个") }
        if !autoRead && pendingTagCount > 0 { parts.append("标签按需读取") }
        statusMessage = parts.joined(separator: "，")

        if selection.isEmpty, let first = displayRows.first { selection = [first.id] }

        if autoRead && pendingTagCount > 0 {
            // 前 80 行先排到队首，紧接着的全量读取**一样先吃插队队列**，
            // 所以「屏幕上看得到的行先出标签」不会因为全量读取而排到几万首之后。
            // 这里不许它自己起按需任务：马上就要起全量任务了，起两条只会互相挡。
            prioritizeLeadingRows(startIfIdle: false)
            requestFullTagRead()
        } else {
            // BO#36：追加导入时老列表的全量读取可能还在跑 —— 浮层交还给它，而不是清掉。
            if isReadingTags {
                publishTagProgress()
            } else if !batchBusy {
                progress = nil
                cancelHandler = nil
            }
            // 不自动全读（「从不」/ 取消 / 启动保护阈值）时，至少把看得见的那一屏读出来 ——
            // 这就是「按需读取」该兑现的样子，不能指望行的 onAppear 那条不可靠的路。
            prioritizeLeadingRows(startIfIdle: true)
        }
        ensureVisibleSweep()
        noteTagPendingStateChanged()
        // 列的时候排进来的追加导入，接着导。
        scheduleDeferredImportFlush()
        // BO#13：启动时那次旁存维护若因「正在列目录」被跳过，这里补上（节流保证不会跑两遍）。
        if importIsRestore { maintainUndoStorage() }
    }

    /// 阶段一之后要不要自动接着读标签。
    ///
    /// 设置里三档：`always` / `never` / `auto`（默认）。
    ///
    /// **阈值优先于卷类型**（2026-09-11 修）：文件数 ≤ `lazyThreshold` 的目录一律
    /// 一次读完再显示，**不管在什么卷上**，`never` 是唯一的例外。
    /// 从前 `auto` 在可移动卷上一律不读，于是 TF 卡上 14 首的小目录也永远挂着
    /// 一片「读取中…」—— 阈值这道闸门本来就是为「小目录不该拆两段」设的，
    /// 卷类型不该再把它推翻一次（复现与根因见 research/BC- 报告）。
    ///
    /// 超过阈值的大目录：内置卷照旧全量后台读；可移动卷也读，只是**读得慢** ——
    /// 并发 2 + 每 200 首让出一次（见 `TagReader.recommendedYieldEvery`），
    /// 不再「只列不读」。启动自动载入时对超阈值的大目录仍留一道 2000 的保护，
    /// 一开机就把几万首全读一遍得不偿失（可见的那一屏仍有前 80 行优先兜着）。
    ///
    /// - Parameter direct: 走的是直接路径（整个目录 ≤ 阈值，标签读完才上表）。
    private func shouldAutoReadTags(listed: Int, direct: Bool) -> Bool {
        switch settings.autoReadTags {
        case .always: return true
        case .never:  return false
        case .auto:
            if direct { return true }       // 阈值优先：小目录在任何卷上都读完再显示
            if importIsRestore && listed > Self.restoreAutoReadLimit { return false }
            return true
        }
    }

    /// 取消阶段一。已经列出的行**全部保留**。
    func cancelImport(silent: Bool = false) {
        guard importTask != nil else { return }
        importTask?.cancel()
        importTask = nil
        if silent { importRunID &+= 1 }    // 让在途的收尾作废（非静默时由调用方自己收尾）
        isListing = false
        if !silent {
            if !batchBusy {
                progress = nil
                cancelHandler = nil
            }
            rebuildDisplay()
            statusMessage = "已取消列出，已列出 \(listedCount) 首（标签可稍后读取）"
            scheduleDeferredImportFlush()
        }
    }

    // MARK: 阶段二：读标签

    /// 请求「把剩下的标签一次读完」。**阶段一结束后必须走这一条，不能直接叫 `startTagRead`**。
    ///
    /// 因为界面的 `onAppear` 很可能在阶段一还没跑完时就先起了一条按需任务，
    /// 那时 `startTagRead` 的 `tagReadTask == nil` 挡板会把全量请求静默吞掉。
    /// 见 `fullTagReadPending` 的注释与 research/AS- 报告里的复现实验。
    private func requestFullTagRead() {
        fullReadResumeBudget = 2
        if tagReadTask == nil {
            fullTagReadPending = false
            startTagRead(priorityOnly: false)
        } else {
            // 按需任务正在跑：欠着，等它收工交接。进度浮层先摆上，
            // 否则这段时间里用户看不到「还在读」。
            fullTagReadPending = true
            publishTagProgress()
        }
    }

    /// 启动后台读标签。
    /// - Parameter priorityOnly: true = 只读界面插队进来的可见行，读完即收工（按需模式）。
    private func startTagRead(priorityOnly: Bool) {
        guard tagReadTask == nil else { return }
        let queue = tagQueue ?? TagReadQueue()
        tagQueue = queue
        // 队列被上一轮（取消 / 按需 / 直接路径）派发空了，但表上还有待读行：重建再开工。
        // 不补这一句，全量读取会因为「队列空」而在 guard 处静默返回，行永远留在待读态。
        if !priorityOnly, queue.remainingCount == 0, pendingTagCount > 0 {
            queue.reset(with: allRows.filter { $0.tagsState.isPending }.map(\.id))
        }
        guard queue.remainingCount > 0 else { return }
        let options = settings.importOptions
        let probeRoots = importRoots.isEmpty ? Array(allRows.prefix(4).map(\.id)) : importRoots
        let concurrency = TagReader.recommendedConcurrency(for: probeRoots)
        // 可移动卷上的**全量**读取放慢：并发 2 + 每 200 首让出一次。
        // 按需读取（priorityOnly）不节流 —— 用户正看着那一屏，它要的就是「立刻」。
        let yieldEvery = priorityOnly ? 0 : TagReader.recommendedYieldEvery(for: probeRoots)
        isReadingTags = true
        tagReadRunID &+= 1
        let runID = tagReadRunID
        if !priorityOnly { publishTagProgress() }
        noteTagPendingStateChanged()

        tagReadTask = Task { [weak self] in
            await TagReader.drain(queue: queue,
                                  options: options,
                                  concurrency: concurrency,
                                  priorityOnly: priorityOnly,
                                  yieldEvery: yieldEvery) { batch in
                Task { @MainActor [weak self] in self?.receiveTagBatch(batch) }
            }
            await MainActor.run { self?.finishTagRead(priorityOnly: priorityOnly, runID: runID) }
        }
    }

    /// 收到一批标签：先攒着，250 ms 刷一次表。
    private func receiveTagBatch(_ batch: TagReadBatch) {
        for file in batch.files {
            guard allIndex[file.url] != nil else { continue }
            // 用户在占位行上改过的东西，到刷表那一拍才重放到真值上（`flushTagBuffer` →
            // `replayPlaceholderDraft`）：这 250 ms 里用户可能还在往占位行上敲字，
            // 在这里合并会拿一份过期的草稿去盖。
            tagFlushBuffer[file.url] = FileRow(file: file)
        }
        for (url, reason) in batch.skipped { tagFlushDrops[url] = reason }
        for (url, error) in batch.failures {
            guard var row = allIndex[url].map({ allRows[$0] }) else { continue }
            row.tagsState = .failed(error.localizedDescription)
            tagFlushBuffer[url] = row
        }
        scheduleTagFlush()
    }

    private func scheduleTagFlush() {
        guard !tagFlushScheduled else { return }
        tagFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppModel.tagFlushInterval)
            self?.flushTagBuffer()
        }
    }

    /// 一轮读取结束后要不要重建一次 `displayRows`。
    ///
    /// 平时刷表只按 `displayIndex` 定点改写，够快也够准。两种情况定点改写救不回来：
    ///
    /// - **过滤词非空**：待读行只拿文件名参与过滤（见 `matchesFilter`），
    ///   标签读出来之后它可能**刚刚才**命中过滤 —— 不重建就永远进不了 `displayRows`。
    /// - **排序列需要标签**：待读行被排序器统一按到末尾，读完得回到它该在的位置。
    /// - **快捷筛选非空**：待读行在「无封面 / 无歌词」这类条件下一律不命中
    ///   （标签未知 ≠ 没有），读完才知道它该不该进表 —— 与过滤词同理。
    ///
    /// 三者都不成立时（默认：无过滤 + 无筛选 + 按文件名排序）不重建，
    /// 免得三万行的目录在每一次「滚到哪读到哪」收工时都白排一次序。
    private var needsDisplayRebuildAfterTags: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
            || !quickFilters.isEmpty
            || (sortOrder.first?.columnID.requiresTags ?? false)
    }

    /// 把攒下的一批标签一次性刷进表。
    ///
    /// 一次 `@Published` 变更换掉几十上百行，比一行一次少几个数量级的 SwiftUI diff。
    ///
    /// - Parameter final: 本轮读取的**收尾刷新**（正常读完 / 取消 / 失败都要走一次）。
    ///   除了把缓冲清干净，还会按 `needsDisplayRebuildAfterTags` 决定要不要重建 `displayRows`。
    private func flushTagBuffer(final: Bool = false) {
        tagFlushScheduled = false
        let rows = tagFlushBuffer
        let drops = tagFlushDrops
        tagFlushBuffer.removeAll(keepingCapacity: true)
        tagFlushDrops.removeAll(keepingCapacity: true)
        guard !rows.isEmpty || !drops.isEmpty else {
            // 收尾时缓冲已经空了也要把重建补上：这一轮可能全靠中途的定时刷完成，
            // 而「读完之后才命中过滤 / 才排得动」的行还等着重建才进得了表。
            if final, needsDisplayRebuildAfterTags { rebuildDisplay() }
            return
        }

        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            // 在本地副本上换完再一次赋回（见 `mutateRows`：逐行写 @Published 数组是 O(n²)）。
            var all = allRows
            var shown = displayRows
            for (url, fresh) in rows {
                guard let i = allIndex[url] else { continue }
                let current = all[i]
                // 这一行已经被同步补读 / 刷新过（`materializePendingTags` / `refreshSelected`），
                // 用户可能已经在真值上改了东西 —— 拿这份更早排队的读数去盖只会冲掉改动。
                guard current.tagsState.isPending else { continue }
                var row: FileRow
                if fresh.tagsState.isLoaded {
                    // BO#2（P0）：占位行上的改动是「对空模板的增量」，重放到读回的真值上；
                    // 绝不让「只填了一格的空草稿」整份顶替真值（那会把其余字段全判成删除）。
                    row = fresh
                    AppModel.replayPlaceholderDraft(from: current, onto: &row)
                } else {
                    // 读失败：保留占位行（连同用户的占位改动），只换状态。
                    row = current
                    row.tagsState = fresh.tagsState
                }
                all[i] = row
                if let j = displayIndex[url] { shown[j] = row }
            }
            allRows = all
            displayRows = shown
            // 时长过滤 / MP4 视频这类「打开文件才判得出」的忽略项，
            // 在第二阶段才有结论，命中的行从列表里撤下来。
            if !drops.isEmpty {
                allRows.removeAll { drops[$0.id] != nil }
                displayRows.removeAll { drops[$0.id] != nil }
                // 先重建索引再动选择：选择一变就会把封面改动落进行草稿（按下标改行）。
                reindex()
                selection.subtract(Set(drops.keys))
            }
        }

        // 三个计数直接重数一遍而不是加加减减：同一行可能既被队列读到、又被
        // `materializePendingTags` 同步补过，加减法会漂。3 万行扫一遍几十微秒，
        // 一秒最多 4 次，买一个「永远对得上」很划算。
        recountTagStates()
        if isReadingTags { publishTagProgress() }
        if final, needsDisplayRebuildAfterTags { rebuildDisplay() }
    }

    /// 进度浮层的文案：「已列出 n 首 · 已读取标签 m/n」。
    ///
    /// 只在没有别的批处理占着浮层时才写（`isBusy` 为真说明保存/清除/匹配正在用它），
    /// 免得两个任务抢同一个进度条。
    private func publishTagProgress() {
        guard !isBusy else { return }
        let total = listedCount
        let done = min(total, max(0, total - pendingTagCount))
        progressTitle = "读取标签…"
        progress = BatchProgress(completed: done, total: total,
                                 note: "已列出 \(total) 首 · 已读取标签 \(done)/\(total)")
        cancelHandler = { [weak self] in self?.cancelTagRead() }
    }

    private func finishTagRead(priorityOnly: Bool, runID: Int) {
        // 被取消 / 被新一轮顶掉的旧任务，收尾交给顶掉它的那一位。
        guard runID == tagReadRunID else { return }
        tagReadTask = nil
        isReadingTags = false
        // 收尾必刷：这一轮最后几批很可能还躺在 250 ms 的缓冲里，
        // 不在这里倒干净就得等定时器那一拍，小库下整批 < 250 ms 读完时尤其明显。
        flushTagBuffer(final: true)
        // 「还剩多少没读」变了：状态栏那句 5 秒提示的时钟跟着重算
        //（下面几条分支要是又起了新任务，`startTagRead` 会再算一次）。
        noteTagPendingStateChanged()
        // 按需模式读完可见的那一屏就收工，剩下的仍待读，不报「完成」也不动状态栏。
        if priorityOnly {
            // 阶段一结束时被挡下来的那次全量读取在这里交接。
            // 全量模式**一样先吃插队队列**，所以「用户正看的那一屏优先」不会因此丢掉。
            if fullTagReadPending, pendingTagCount > 0 {
                fullTagReadPending = false
                startTagRead(priorityOnly: false)
                return
            }
            fullTagReadPending = false
            if !isBusy { progress = nil; cancelHandler = nil }
            // 收工前又滚来了新的可见行，接着读。
            if let q = tagQueue, q.priorityCount > 0 { startTagRead(priorityOnly: true) }
            return
        }
        fullTagReadPending = false
        // BO#36：全量读到头了表上却还有待读行 —— 多半是读取途中追加导入进来、错过了这一轮的队列。
        // 接着读，不甩给「按需读取」（次数有上限，读不动的行不会让它空转）。
        if pendingTagCount > 0, fullReadResumeBudget > 0 {
            fullReadResumeBudget -= 1
            startTagRead(priorityOnly: false)
            if isReadingTags { return }
        }
        if !isBusy { progress = nil; cancelHandler = nil }
        statusMessage = pendingTagCount == 0
            ? "已读取全部 \(listedCount) 首的标签"
            : "已读取 \(loadedTagCount)/\(listedCount) 首的标签，其余按需读取"
        noteTagPendingStateChanged()
    }

    /// 取消阶段二。已读的保留，未读的仍是待读状态，随时可「继续读取标签」。
    func cancelTagRead(silent: Bool = false) {
        guard tagReadTask != nil else { return }
        tagReadTask?.cancel()
        tagReadTask = nil
        tagReadRunID &+= 1                 // 让在途的收尾作废
        isReadingTags = false
        fullTagReadPending = false
        flushTagBuffer(final: true)
        if !silent {
            if !isBusy { progress = nil; cancelHandler = nil }
            statusMessage = "已取消读取标签：已列出 \(listedCount) 首，已读取 \(loadedTagCount) 首，"
                          + "未读取 \(pendingTagCount) 首（右键可继续）"
        }
        noteTagPendingStateChanged()
    }

    /// 右键菜单的「继续读取标签」/ 状态栏那句提示。用当前还是待读状态的行重建队列再开工。
    func resumeTagRead() {
        guard !isReadingTags else { return }
        let waiting = allRows.filter { $0.tagsState.isPending }.map(\.id)
        guard !waiting.isEmpty else { return }
        pendingTagCount = waiting.count
        let queue = tagQueue ?? TagReadQueue()
        queue.reset(with: waiting)
        tagQueue = queue
        statusMessage = "继续读取 \(waiting.count) 首的标签…"
        // 先把看得见的那一屏排到队首，再全量开工 —— 用户点「继续读取」是想立刻看到东西。
        prioritizeLeadingRows(startIfIdle: false)
        fullReadResumeBudget = 2
        startTagRead(priorityOnly: false)
        ensureVisibleSweep()
    }

    // MARK: 可见行优先
    //
    // 「屏幕上看得到的行 1 秒内有标签」靠三条路一起兜（任何一条失灵都还有别的）：
    //
    //   ① **前 80 行**：导入结束 / 改排序之后立刻整批送进插队队列。
    //      不依赖任何视图事件，所以一定会发生 —— 这是最要紧的一条。
    //   ② **行的 onAppear**：`FileTableView` 报上来的「这一行进视口了」。
    //      `Table` 底下是 NSTableView 的复用机制，onAppear **不可靠**（用户实测：
    //      14 首的目录只有第一行报了上来），所以它只是加分项，不是主力。
    //   ③ **300 ms 巡检**：拿不到精确可见范围时的退化路径 —— 围着「最近报上来的行」
    //      和「选中行」各取 ±40 行送进队列。滚动停下后至少还有选中行这个锚点。
    //
    // 三条都只是往插队队列里塞 URL，塞重了由队列自己去重（`dispatched`），
    // 已经读到标签的行在 `prioritizeTagRead` 那一层就被滤掉了。

    /// 导入 / 改排序之后立刻优先读的行数。
    ///
    /// 80 ≈ 一屏（30pt 行高的表在 27 寸满屏约 45 行）再加一屏余量，
    /// 保证「用户一眼看得到的行」排在队列最前面。
    static let leadingPriorityRows = 80
    /// 拿不到精确可见范围时，围着锚点取的半径。
    static let visibleWindowRadius = 40
    /// 可见窗口的巡检周期。
    private static let visibleSweepInterval: Duration = .milliseconds(300)
    /// 连着这么多拍没活干就放慢（10 拍 = 3 秒，比 5 秒的提示阈值短，提示不会被拖慢）。
    private static let visibleSweepSlowAfter = 10
    /// 放慢之后的周期。
    private static let visibleSweepIdleInterval: Duration = .seconds(1)
    /// pending 行「没人在读」多久之后，状态栏摆出那句可点的提示。
    private static let pendingHintDelay: TimeInterval = 5

    /// 表格里某一行出现在视口里了。
    ///
    /// 两件事：把它记成可见带的锚点（给 300 ms 巡检用），以及攒 120 ms 一批送进队列插队。
    /// 后者是快车道 —— onAppear 真的来了就不必等巡检那一拍。
    func noteRowVisible(_ id: URL) {
        // 没有待读行时这条路整条关掉：锚点只在「还有东西要读」时才有用。
        guard pendingTagCount > 0 else { return }
        // 已读的行也要记锚点 —— 它同样说明「用户正看着这一带」。
        if let i = displayIndex[id] {
            visibleBandLow = min(visibleBandLow ?? i, i)
            visibleBandHigh = max(visibleBandHigh ?? i, i)
            visibleAnchor = i
        }
        guard row(id: id)?.tagsState.isPending == true else { return }
        visibleBuffer.insert(id)
        ensureVisibleSweep()
        guard !visibleFlushScheduled else { return }
        visibleFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.visibleFlushScheduled = false
            let ids = self.visibleBuffer
            self.visibleBuffer.removeAll(keepingCapacity: true)
            self.prioritizeTagRead(Array(ids))
        }
    }

    /// 把当前排序下的前 `leadingPriorityRows` 行送进插队队列。
    ///
    /// - Parameter startIfIdle: 没有任务在跑时要不要顺手起一条按需任务。
    ///   紧接着就要起全量任务的场合（`finishListing` / `resumeTagRead`）传 false，
    ///   起两条只会互相挡在 `startTagRead` 的 `tagReadTask == nil` 上。
    /// - Returns: 实际排进队列的行数。
    @discardableResult
    func prioritizeLeadingRows(startIfIdle: Bool = true) -> Int {
        guard pendingTagCount > 0 else { return 0 }
        let ids = displayRows.prefix(Self.leadingPriorityRows)
            .filter { $0.tagsState.isPending }
            .map(\.id)
        guard !ids.isEmpty else { return 0 }
        prioritizeTagRead(ids, startIfIdle: startIfIdle)
        return ids.count
    }

    /// 300 ms 一次的可见窗口巡检。只在还有待读行时跑，读完自己收工。
    ///
    /// 连着几拍什么都没排出来（用户不动、看得见的那些已经读完）就把周期放慢到 1 秒 ——
    /// 「从不自动读取」下几万行会长期挂着待读，不能为它一直 300 ms 醒一次。
    /// 用户一滚 / 一改选中（`noteRowVisible` / `onSelectionChanged`）立刻切回 300 ms。
    private func ensureVisibleSweep() {
        visibleSweepIdleTicks = 0
        guard visibleSweepTask == nil, pendingTagCount > 0, !allRows.isEmpty else { return }
        visibleSweepTask = Task { @MainActor [weak self] in
            while true {
                let slow = (self?.visibleSweepIdleTicks ?? 0) >= AppModel.visibleSweepSlowAfter
                try? await Task.sleep(for: slow ? AppModel.visibleSweepIdleInterval
                                                : AppModel.visibleSweepInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.pendingTagCount > 0, !self.allRows.isEmpty else {
                    self.visibleSweepTask = nil
                    self.refreshPendingHint()
                    return
                }
                let queued = self.sweepVisibleWindow()
                self.visibleSweepIdleTicks = queued > 0 ? 0 : self.visibleSweepIdleTicks + 1
                self.refreshPendingHint()
            }
        }
    }

    private func stopVisibleSweep() {
        visibleSweepTask?.cancel()
        visibleSweepTask = nil
    }

    /// 巡检一次：把「大概看得见的那些行」里还待读的送进插队队列。
    ///
    /// 三段并起来，顺序就是优先级（前面的先读）：最近报上来的可见带 → 锚点 ±40 →
    /// 选中行 ±40 → 前 80 行。全部读完之后这里每次都返回空，等于不花钱。
    /// - Returns: 这一拍排进队列的行数（0 = 没活干，巡检据此放慢周期）。
    @discardableResult
    private func sweepVisibleWindow() -> Int {
        guard pendingTagCount > 0, !displayRows.isEmpty else { return 0 }
        let r = Self.visibleWindowRadius
        var seen = Set<URL>()
        var wanted: [URL] = []
        func take(_ lo: Int, _ hi: Int) {
            let a = max(0, lo), b = min(displayRows.count - 1, hi)
            guard a <= b else { return }
            for i in a...b {
                let row = displayRows[i]
                guard row.tagsState.isPending, seen.insert(row.id).inserted else { continue }
                wanted.append(row.id)
            }
        }
        // ① 上一拍里 onAppear 报上来的那一带（拿得到就用，它最准）。
        //    读完就清空：可见带说的是「刚刚滚过来的行」，留着会越攒越大。
        if let lo = visibleBandLow, let hi = visibleBandHigh { take(lo - 8, hi + 8) }
        visibleBandLow = nil
        visibleBandHigh = nil
        // ② 锚点 ±40：滚动停下之后 onAppear 就不再来了，靠它记住用户停在哪儿。
        if let anchor = visibleAnchor { take(anchor - r, anchor + r) }
        // ③ 选中行 ±40：onAppear 完全不来时（用户实测的那种）最后的退化路径。
        if let first = selection.compactMap({ displayIndex[$0] }).min() { take(first - r, first + r) }
        // ④ 前 80 行：表刚出来、用户还没动过任何东西的场合。
        take(0, Self.leadingPriorityRows - 1)
        guard !wanted.isEmpty else { return 0 }
        prioritizeTagRead(wanted)
        return wanted.count
    }

    /// 把这些行插到待读队列最前面；没有任务在跑就起一个「按需」任务。
    ///
    /// 这就是「标签按需读取」的兑现方式：用户看着哪一屏，哪一屏的标签立刻补上。
    /// - Parameter startIfIdle: 见 `prioritizeLeadingRows(startIfIdle:)`。
    func prioritizeTagRead(_ urls: [URL], startIfIdle: Bool = true) {
        let wanted = urls.filter { row(id: $0)?.tagsState.isPending == true }
        guard !wanted.isEmpty else { return }
        let queue = tagQueue ?? TagReadQueue()
        tagQueue = queue
        // 队列可能已经把这些派发过（上一轮被取消），重建一次才有得读。
        if queue.remainingCount == 0 {
            queue.reset(with: allRows.filter { $0.tagsState.isPending }.map(\.id))
        }
        queue.prioritize(wanted)
        if startIfIdle, tagReadTask == nil { startTagRead(priorityOnly: true) }
    }

    // MARK: 「还有 N 首没读」的状态栏提示

    /// 待读行 5 秒还没人读时，状态栏那句可点的提示要不要出现。
    ///
    /// 为什么要有它：可移动卷上的大目录、「从不自动读取」、以及取消过读取之后，
    /// 表上会长期挂着待读行。右键菜单里的「继续读取标签」藏得太深 ——
    /// 状态栏这句是同一个动作的明面入口。
    private func refreshPendingHint() {
        // 正在列 / 正在读的时候不提示：进度浮层已经在说这件事了。
        let idle = pendingTagCount > 0 && !isReadingTags && !isListing
        guard idle else {
            pendingIdleSince = nil
            if showPendingHint { showPendingHint = false }
            return
        }
        let since = pendingIdleSince ?? Date()
        pendingIdleSince = since
        let due = Date().timeIntervalSince(since) >= Self.pendingHintDelay
        if showPendingHint != due { showPendingHint = due }
    }

    /// 「待读还剩多少 / 有没有人在读」变了：重算提示时钟，必要时把巡检拉起来。
    private func noteTagPendingStateChanged() {
        refreshPendingHint()
        if pendingTagCount > 0 { ensureVisibleSweep() }
    }

    /// 批量入口一次**同步**补读的上限。超过它的入口（目前是自动匹配选项窗）改走后台补读。
    static let syncMaterializeLimit = 24

    /// 需要补读的行：目标行里的待读行；`includeEditedElsewhere` 时再加上**整张表里带着占位改动的待读行**
    /// —— 它们可能经「无选中 → 存全部未保存行」进保存，读回真值前不许参与（BO#2 的保险）。
    private func materializeCandidates(in rows: [FileRow], includeEditedElsewhere: Bool) -> [URL] {
        var ids = rows.filter { $0.tagsState.isPending }.map(\.id)
        guard includeEditedElsewhere else { return ids }
        var seen = Set(ids)
        for r in allRows where r.hasPlaceholderEdits && !seen.contains(r.id) {
            ids.append(r.id)
            seen.insert(r.id)
        }
        return ids
    }

    /// 批量操作前的兜底：把目标行里还没读标签的**同步**补上。
    ///
    /// 同步是给「紧接着就要用这些标签」的老调用方（保存 / 清除 / 批量歌词）留的契约。
    /// BO#16 之后：读盘按卷的推荐并发拆成几路并行（主线程只等结果），同样的量比从前串行快；
    /// 量大、调用方又能等的入口请改用 `materializePendingTagsInBackground(in:title:)` ——
    /// 后台分块读、带进度与取消，主线程一拍都不卡。
    ///
    /// 读回来的行**不再整行顶替**：占位行上用户已经改过的字段按「对空模板的增量」重放到真值上（BO#2）。
    /// - Parameter includeEditedElsewhere: 顺带补读表上其它带占位改动的待读行（默认 true；
    ///   选中变化补焦点行那一路传 false，免得每点一下都去读别处）。
    /// - Returns: 实际补读了多少行。
    @discardableResult
    func materializePendingTags(in rows: [FileRow], includeEditedElsewhere: Bool = true) -> Int {
        let ids = materializeCandidates(in: rows, includeEditedElsewhere: includeEditedElsewhere)
        guard !ids.isEmpty else { return 0 }
        statusMessage = "正在补读 \(ids.count) 首的标签…"
        let result = AppModel.readTagsConcurrently(ids, concurrency: TagReader.recommendedConcurrency(for: ids))
        applyMaterialized(result)
        return ids.count
    }

    /// `materializePendingTags` 的后台版（BO#16）：读盘在后台线程分块做，主线程只做行替换；
    /// 没人占着浮层时显示进度，并挂「取消」。
    /// - Returns: false = 用户取消了，调用方别接着开工。
    @discardableResult
    func materializePendingTagsInBackground(in rows: [FileRow], title: String = "正在补读标签…") async -> Bool {
        let ids = materializeCandidates(in: rows, includeEditedElsewhere: true)
        guard !ids.isEmpty else { return true }
        let ownsOverlay = !isBusy
        isMaterializing = true
        materializeCancelled = false
        let concurrency = TagReader.recommendedConcurrency(for: ids)
        if ownsOverlay {
            progressTitle = title
            progress = BatchProgress(completed: 0, total: ids.count, note: "补读标签 0/\(ids.count)")
            cancelHandler = { [weak self] in self?.materializeCancelled = true }
        }
        statusMessage = "正在补读 \(ids.count) 首的标签…"
        var done = 0
        while done < ids.count, !materializeCancelled {
            let slice = Array(ids[done..<min(done + 48, ids.count)])
            let result = await Task.detached(priority: .userInitiated) {
                AppModel.readTagsConcurrently(slice, concurrency: concurrency)
            }.value
            applyMaterialized(result)
            done += slice.count
            if ownsOverlay {
                progress = BatchProgress(completed: done, total: ids.count, note: "补读标签 \(done)/\(ids.count)")
            }
        }
        let cancelled = materializeCancelled
        materializeCancelled = false
        isMaterializing = false
        if ownsOverlay, !batchBusy {
            progress = nil
            cancelHandler = nil
        }
        statusMessage = cancelled
            ? "已取消补读标签（已读 \(done)/\(ids.count) 首）"
            : "已补读 \(done) 首的标签"
        scheduleDeferredImportFlush()
        return !cancelled
    }

    /// 补读结果落表：只换**仍是待读**的行（别人已经读好 / 改过的不动），占位改动重放到真值上。
    private func applyMaterialized(_ result: (files: [AudioFile], failures: [(URL, TagError)])) {
        // 本地副本上换完一次赋回（逐行写 @Published 数组是 O(n²)，见 `mutateRows`）。
        var all = allRows
        var shown = displayRows
        for file in result.files {
            guard let i = allIndex[file.url], all[i].tagsState.isPending else { continue }
            var row = FileRow(file: file)
            AppModel.replayPlaceholderDraft(from: all[i], onto: &row)
            all[i] = row
            if let j = displayIndex[file.url] { shown[j] = row }
        }
        for (url, error) in result.failures {
            guard let i = allIndex[url], all[i].tagsState.isPending else { continue }
            all[i].tagsState = .failed(error.localizedDescription)
            if let j = displayIndex[url] { shown[j] = all[i] }
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            allRows = all
            displayRows = shown
        }
        recountTagStates()
        noteTagPendingStateChanged()
    }

    /// 选中行里还没读标签的部分（批量入口调它做兜底）。
    var selectedPendingCount: Int {
        selectedRows.reduce(0) { $0 + ($1.tagsState.isPending ? 1 : 0) }
    }

    /// 从 Finder 拖进来的 provider。
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    box.append(url)
                } else if let url = item as? URL {
                    box.append(url)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = box.take()
            guard !urls.isEmpty else { return }
            self?.importURLs(urls)
        }
        return true
    }

    // MARK: 列表操作

    func selectAll() { selection = Set(displayRows.map(\.id)) }

    func invertSelection() {
        let all = Set(displayRows.map(\.id))
        selection = all.subtracting(selection)
    }

    func clearSelection() { selection = [] }

    /// 原版「删除项」——只从列表移除，不动磁盘。
    ///
    /// **不问**未保存的改动：这是改名 / 整理收尾撤掉旧路径行也在用的原语。
    /// 界面入口（右键「从列表中删除项」、顶栏「从列表移除选中项」）请走
    /// `requestRemoveSelectedItems()`（BO#11）。
    func removeSelectedItems() {
        guard !selection.isEmpty else { return }
        removeItems(selection)
    }

    /// 按 id 从列表移除（不动磁盘，不问）。
    func removeItems(_ ids: Set<URL>) {
        guard !ids.isEmpty else { return }
        allRows.removeAll { ids.contains($0.id) }
        // 先重建索引再动选择：选择一变就会把封面改动落进行草稿（按下标改行）。
        reindex()
        selection.subtract(ids)
        rebuildDisplay()
        recountTagStates()
        noteTagPendingStateChanged()
        statusMessage = "已从列表移除 \(ids.count) 项"
    }

    /// 界面上的「从列表移除选中项」：选中行里有未保存的改动先问「保存 / 放弃 / 取消」（BO#11）。
    func requestRemoveSelectedItems() {
        let ids = selection
        guard !ids.isEmpty else { return }
        confirmDiscardIfDirty("从列表移除 \(ids.count) 项", scope: ids) { [weak self] in
            self?.removeItems(ids)
        }
    }

    /// 界面上的「清空列表」：有未保存的改动先问（BO#11）。
    func requestRemoveAllItems() {
        guard !allRows.isEmpty else { return }
        confirmDiscardIfDirty("清空列表") { [weak self] in self?.removeAllItems() }
    }

    func removeAllItems() {
        // 清空列表就不再接排队的追加导入；检查器里没落盘的封面改动随列表一起丢
        // （界面入口 `requestRemoveAllItems` 已经问过）。
        deferredImportURLs.removeAll()
        artworkDirty = false
        // 非静默：清空列表时必须把进度浮层一并收干净，
        // 否则「导入到一半清空列表」会让顶栏按钮永远是禁用态。
        cancelImport()
        cancelTagRead()
        stopVisibleSweep()
        allRows.removeAll()
        reindex()
        selection = []
        tagQueue = nil
        listDirectory = nil
        visibleBandLow = nil
        visibleBandHigh = nil
        visibleAnchor = nil
        rebuildDisplay()
        recountTagStates()
        noteTagPendingStateChanged()
        statusMessage = "列表已清空"
    }

    /// 行被增删之后重新数一遍三个计数。只有增删行时才调（一次 O(n) 扫描）。
    private func recountTagStates() {
        listedCount = allRows.count
        pendingTagCount = allRows.reduce(0) { $0 + ($1.tagsState.isPending ? 1 : 0) }
        loadedTagCount = listedCount - pendingTagCount
    }

    /// 原版「刷新」——重新从磁盘读标签，丢弃未保存的改动。
    ///
    /// BO#35：读盘挪到后台（分块、按卷并发），主线程只做行替换 —— ⌘A 后刷新几千首不再整段卡住；
    /// 期间有进度浮层与「取消」（取消停在块之间，已刷新的保留）。
    func refreshSelected() {
        guard !batchBusy, !isMaterializing else {
            statusMessage = "正在\(busyActivityName)，请等它结束后再刷新"
            return
        }
        let targets = selection.isEmpty ? allRows.map(\.id) : Array(selection)
        guard !targets.isEmpty else { return }
        let concurrency = TagReader.recommendedConcurrency(for: targets)
        refreshCancelled = false
        artworkDirty = false
        isBusy = true
        progressTitle = "刷新…"
        progress = BatchProgress(completed: 0, total: targets.count)
        cancelHandler = { [weak self] in self?.refreshCancelled = true }
        statusMessage = "正在刷新 \(targets.count) 项…"
        Task { [weak self] in
            var done = 0, ok = 0, failed = 0
            while done < targets.count {
                guard let self, !self.refreshCancelled else { break }
                let slice = Array(targets[done..<min(done + 64, targets.count)])
                let result = await Task.detached(priority: .userInitiated) {
                    AppModel.readTagsConcurrently(slice, concurrency: concurrency)
                }.value
                self.applyRefreshed(result.files)
                ok += result.files.count
                failed += result.failures.count
                done += slice.count
                self.progress = BatchProgress(completed: done, total: targets.count)
            }
            guard let self else { return }
            let cancelled = self.refreshCancelled
            self.refreshCancelled = false
            self.artworkDirty = false
            self.loadArtworksForFocus()
            self.showDraftArtworkIfAny()
            self.recountTagStates()
            self.noteTagPendingStateChanged()
            self.cancelHandler = nil
            self.progress = nil
            self.isBusy = false
            var text = failed == 0 ? "已刷新 \(ok) 项" : "已刷新 \(ok) 项，失败 \(failed) 项"
            if cancelled { text = "已取消刷新：" + text + "（其余 \(targets.count - done) 项未刷新）" }
            self.statusMessage = text
        }
    }

    /// 刷新读回的行落表（整行换掉 = 丢弃未保存的改动，这是「刷新」的本意）。
    private func applyRefreshed(_ files: [AudioFile]) {
        var all = allRows
        var shown = displayRows
        for file in files {
            let row = FileRow(file: file)
            if let i = allIndex[row.id] { all[i] = row }
            if let j = displayIndex[row.id] { shown[j] = row }
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            allRows = all
            displayRows = shown
        }
    }

    /// 原版「打开文件目录」。
    func revealInFinder() {
        let urls = selectedRows.map(\.file.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: 选择变化

    private func onSelectionChanged(from old: Set<URL>) {
        // BO#9：换选中前，检查器里还没保存的封面改动落进**原选中行**的草稿（按文件保存），
        // 不再一句 `artworkDirty = false` 静默丢掉。行因此带上 dirty 点，保存时照常写出去。
        if artworkDirty { stashArtworkEdit(into: old) }
        artworkDirty = false
        artworkIndex = 0
        // 焦点行的标签**同步**补上：右栏面板下一帧就要显示它，
        // 一个文件的读取耗时与这里本来就有的「读封面」同量级，不额外拖慢什么。
        if let focus = focusRow, focus.tagsState.isPending {
            materializePendingTags(in: [focus], includeEditedElsewhere: false)
        }
        // 选中行同时也是「用户正看着哪儿」最可靠的信号 —— onAppear 一条都不来时，
        // 300 ms 巡检就靠它围出可见窗口（见 `sweepVisibleWindow`）。
        if let i = selection.compactMap({ displayIndex[$0] }).min() { visibleAnchor = i }
        // 其余选中行走插队队列，异步补。批量操作真要用时还有
        // `materializePendingTags` 兜底（见保存 / 清除路径）；读回时用户在占位行上的改动
        // 会重放到真值上（`replayPlaceholderDraft`），不会被整行顶替。
        if pendingTagCount > 0, selection.count > 1 {
            prioritizeTagRead(Array(selection))
        }
        if pendingTagCount > 0 { ensureVisibleSweep() }
        loadArtworksForFocus()
        // 焦点行草稿里带着没保存的封面改动（上面刚落进去的，或更早切走时落的）→ 显示草稿里的那份。
        showDraftArtworkIfAny()
        loadHistoryForFocus()
    }
}

// MARK: - BP-B：忙碌令牌 / 排队导入 / 未保存确认 / 封面草稿 / 占位草稿重放

extension AppModel {

    // MARK: 忙时排队的导入（BO#7 / #36）

    /// 状态栏里「正在 X」的那个 X。
    var busyActivityName: String {
        if isMaterializing { return "补读标签" }
        let t = progressTitle.trimmingCharacters(in: CharacterSet(charactersIn: "… ."))
        return t.isEmpty ? "执行批处理" : "「\(t)」"
    }

    private func deferImport(_ urls: [URL]) {
        for u in urls where !deferredImportURLs.contains(u) { deferredImportURLs.append(u) }
    }

    /// 忙完了：把排队的追加导入接着导。推到下一拍，让收尾代码（afterBatch / finishListing）先跑完。
    private func scheduleDeferredImportFlush() {
        guard !deferredImportURLs.isEmpty else { return }
        Task { @MainActor [weak self] in self?.flushDeferredImports() }
    }

    private func flushDeferredImports() {
        guard !deferredImportURLs.isEmpty, !isBusy else { return }
        let urls = deferredImportURLs
        deferredImportURLs = []
        importURLs(urls)
    }

    /// 批处理令牌落回 false：先办排队的「保存完再……」，再接着导排队的文件。
    /// 推到下一拍：`afterBatch` 在 `isBusy = false` 之后还有状态栏 / 失败弹窗要写，让它先写完。
    private func batchDidEnd() {
        Task { @MainActor [weak self] in
            guard let self, !self.batchBusy else { return }
            let actions = self.batchEndActions
            self.batchEndActions = []
            for action in actions { action() }
            self.flushDeferredImports()
        }
    }

    /// 侧栏选中态退回 `directories.current`（用户取消 / 切换被拒时）。
    func revertDirectoryHighlight() {
        directories.objectWillChange.send()
    }

    // MARK: 切目录 / 重新载入（BO#11）

    /// 侧栏点目录、点当前目录（= 重新载入）、右键「重新载入 / 设为当前工作目录」共用；
    /// 目录管理窗「设为当前」也该走这里。
    ///
    /// 写入批在跑 → 拒绝并说明；目录不在（卷没插）→ 列表不动、只提示；
    /// 有未保存的改动 → 先问「保存 / 放弃 / 取消」，取消时侧栏选中态退回去。
    func switchDirectory(to url: URL) {
        let isReload = directories.current == url
        let name = url.lastPathComponent
        if batchBusy || isMaterializing {
            statusMessage = "正在\(busyActivityName)，请等它结束后再\(isReload ? "重新载入" : "切换")目录"
            revertDirectoryHighlight()
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            statusMessage = "「\(name)」暂时不可用（所在的卷未连接或目录已移走），列表未改动"
            revertDirectoryHighlight()
            return
        }
        confirmDiscardIfDirty(isReload ? "重新载入「\(name)」" : "切换到「\(name)」",
                              onCancel: { [weak self] in self?.revertDirectoryHighlight() }) { [weak self] in
            guard let self else { return }
            self.directories.current = url
            self.beginImport([url], replaceExisting: true, isRestore: false)
        }
    }

    // MARK: 未保存改动的统一确认（BO#11）

    /// 这些行（nil = 整张表）里有没有没保存的改动：已读行的草稿差、待读行上的占位改动、
    /// 检查器里还没落进草稿的封面改动（它属于当前选中行）。
    func hasUnsavedChanges(in scope: Set<URL>? = nil) -> Bool {
        guard let scope else { return hasPendingChanges }
        if artworkDirty, !selection.isDisjoint(with: scope) { return true }
        return scope.contains { id in row(id: id).map { $0.isDirty || $0.hasPlaceholderEdits } ?? false }
    }

    private func unsavedFileCount(in scope: Set<URL>?) -> Int {
        var ids = Set<URL>()
        for r in allRows where (scope?.contains(r.id) ?? true) && (r.isDirty || r.hasPlaceholderEdits) {
            ids.insert(r.id)
        }
        if artworkDirty { ids.formUnion(scope.map { selection.intersection($0) } ?? selection) }
        return ids.count
    }

    /// **公共入口**：有未保存的改动时先问「保存 / 放弃改动 / 取消」，再决定要不要继续。
    ///
    /// 切目录、重新载入、移除项、清空列表都走它；App 退出钩子请用 `terminationReply(for:)`（内部也是它）。
    ///
    /// - Parameters:
    ///   - action: 动作名，进提问标题（「切换到「X」」「退出 MacTagger」…）。
    ///   - scope: 只关心这些行（nil = 整张表）。
    ///   - onCancel: 用户点「取消」、写入批正在跑、或「保存」没能全部存上时调用。
    ///   - proceed: 可以继续了（本来就没改动 / 用户放弃 / 保存成功）。**没改动时同步调用。**
    func confirmDiscardIfDirty(_ action: String,
                               scope: Set<URL>? = nil,
                               onCancel: (() -> Void)? = nil,
                               then proceed: @escaping () -> Void) {
        guard hasUnsavedChanges(in: scope) else { proceed(); return }
        guard !batchBusy else {
            statusMessage = "正在\(busyActivityName)，请等它结束后再\(action)"
            onCancel?()
            return
        }
        // 推到下一拍再问：调用方可能正处在 List 的选中回调 / 菜单动作里，别在那里面开模态循环。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.hasUnsavedChanges(in: scope) else { proceed(); return }
                let prompt = UnsavedChangesPrompt(action: action,
                                                  fileCount: self.unsavedFileCount(in: scope),
                                                  hasArtworkEdit: self.artworkDirty)
                switch self.askAboutUnsavedChanges(prompt) {
                case .cancel:
                    onCancel?()
                case .discard:
                    self.artworkDirty = false
                    proceed()
                case .save:
                    self.saveUnsavedChanges(scope: scope, action: action, onCancel: onCancel, then: proceed)
                }
            }
        }
    }

    /// 「保存」：把范围内的未保存改动存掉，存完（批处理结束）再继续；有没存上的就停下。
    private func saveUnsavedChanges(scope: Set<URL>?, action: String,
                                    onCancel: (() -> Void)?, then proceed: @escaping () -> Void) {
        // 检查器里的封面改动先落进当前选中行的草稿，这样换选择去存也不会丢。
        if artworkDirty { stashArtworkEdit(into: selection) }
        let keep = selection
        // `requestSave`：有选中存选中，无选中存全部未保存行（它会先补读待读行与带占位改动的待读行）。
        selection = scope ?? []
        let before = confirm?.id
        requestSave()
        // 用户已经在上一个框里选了「保存」，保存确认框不再问第二遍。
        if let box = confirm, box.id != before {
            confirm = nil
            box.action()
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            let survivors = keep.filter { self.row(id: $0) != nil }
            if self.selection != survivors { self.selection = survivors }
            if self.hasUnsavedChanges(in: scope) {
                self.statusMessage = "有 \(self.unsavedFileCount(in: scope)) 个文件没能保存，已停止「\(action)」"
                onCancel?()
            } else {
                proceed()
            }
        }
        if batchBusy { batchEndActions.append(finish) } else { finish() }
    }

    /// 默认的提问：NSAlert 三个按钮。app 模态（`runModal`），不受主窗口上挂着的 sheet 排队影响。
    private func askAboutUnsavedChanges(_ prompt: UnsavedChangesPrompt) -> UnsavedChangesChoice {
        if let prompter = unsavedChangesPrompter { return prompter(prompt) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: "保存")                          // ⏎
        let discard = alert.addButton(withTitle: "放弃改动")        // ⌘D
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: "取消")             // Esc
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// 给 App 退出钩子用：`applicationShouldTerminate(_:)` 里 `return model.terminationReply(for: sender)`。
    ///
    /// - 没有未保存改动、也没有写入在跑 → `.terminateNow`；
    /// - 写入批在跑 → 当场问「仍要退出？」（整文件重写途中退出可能写坏文件）；
    /// - 有未保存改动 → `.terminateLater`，问完「保存 / 放弃 / 取消」后再 `reply(toApplicationShouldTerminate:)`。
    func terminationReply(for app: NSApplication) -> NSApplication.TerminateReply {
        if batchBusy {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "正在\(busyActivityName)"
            alert.informativeText = "现在退出，正在写入的文件可能损坏。建议等它完成后再退出。"
            alert.addButton(withTitle: "等它完成")
            let quit = alert.addButton(withTitle: "仍然退出")
            quit.hasDestructiveAction = true
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        guard hasUnsavedChanges() else { return .terminateNow }
        confirmDiscardIfDirty("退出 MacTagger",
                              onCancel: { app.reply(toApplicationShouldTerminate: false) }) {
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: 封面改动随草稿按文件保存（BO#9）

    /// 把检查器里还没保存的封面改动（全局 `focusArtworks` + `artworkDirty`）落进这些行的草稿。
    /// 落进去之后它就是行级改动：行带 dirty 点、`pendingEdit` 里有封面动作、保存时照常写出，
    /// 撤消快照照常从磁盘备份旧封面。
    func stashArtworkEdit(into ids: Set<URL>) {
        guard artworkDirty else { return }
        let arts = focusArtworks
        mutateRows(ids) { row in
            if !arts.isEmpty {
                row.draft.artworks = arts
            } else if row.artworkCount > 0 || row.tagsState.isPending {
                // 删光：文件原本有封面（待读行还不知道，先记着，读回后按真值判）才算改动。
                row.markArtworkRemoval()
            } else {
                // 文件原本就没有封面：撤掉之前落下的换图草稿即可。
                row.draft.artworks = row.file.tags.artworks
            }
        }
        artworkDirty = false
    }

    /// 焦点行草稿里带着没保存的封面改动 → 检查器显示草稿里的那份，而不是磁盘上的。
    func showDraftArtworkIfAny() {
        guard !artworkDirty, let row = focusRow, row.hasDraftArtworkEdit else { return }
        focusArtworks = row.draft.artworks
        artworkIndex = 0
    }

    // MARK: 占位草稿重放（BO#2，P0）

    /// 待读行上用户改过的东西，是「对空模板 `Tags()` 的增量」—— 读回真值后**只把这些字段**
    /// 套到真值上，其余字段一律取读回的值。
    ///
    /// 从前是 `row.draft = old.draft` 整份顶替：只填了「专辑」一格的空草稿活到了保存，
    /// 与真值做差时标题 / 艺术家 / 年份 / 音轨 / 流派全被判成「删除」，保存即抹掉（BO 工装实证）；
    /// 同步补读那一路则反过来整行 `FileRow(file:)`，用户那一格改动被静默丢掉。
    ///
    /// 占位行上「清空某字段」（写 nil）与「没动过」分不出来，一律按没动过处理 ——
    /// 宁可少改一格，也不凭空删用户磁盘上的值。
    static func replayPlaceholderDraft(from pending: FileRow, onto loaded: inout FileRow) {
        guard pending.hasPlaceholderEdits else { return }
        let d = pending.draft
        func put(_ value: String?, _ apply: (String) -> Void) {
            if let v = value, !v.isEmpty { apply(v) }
        }
        put(d.title) { loaded.draft.title = $0 }
        put(d.artist) { loaded.draft.artist = $0 }
        put(d.albumArtist) { loaded.draft.albumArtist = $0 }
        put(d.album) { loaded.draft.album = $0 }
        put(d.year) { loaded.draft.year = $0 }
        put(d.genre) { loaded.draft.genre = $0 }
        put(d.comment) { loaded.draft.comment = $0 }
        put(d.composer) { loaded.draft.composer = $0 }
        put(d.lyricist) { loaded.draft.lyricist = $0 }
        put(d.lyrics) { loaded.draft.lyrics = $0 }
        // 音轨 / 碟号是「号/总数」一对，编辑时整对写入（见 `AppModel.assign`），重放也整对替换。
        if d.trackNumber != nil || d.trackTotal != nil {
            loaded.draft.trackNumber = d.trackNumber
            loaded.draft.trackTotal = d.trackTotal
        }
        if d.discNumber != nil || d.discTotal != nil {
            loaded.draft.discNumber = d.discNumber
            loaded.draft.discTotal = d.discTotal
        }
        // 表外键（作词家等写在 rawProperties 里的）。
        for (key, values) in d.rawProperties where !values.isEmpty {
            loaded.draft.rawProperties[key] = values
        }
        // 封面：占位行上落下的换图 / 删光（见 `stashArtworkEdit`）。
        if pending.hasDraftArtworkEdit {
            if !d.artworks.isEmpty {
                loaded.draft.artworks = d.artworks
            } else if loaded.artworkCount > 0 {
                loaded.markArtworkRemoval()
            }
        }
    }

    // MARK: 并行读标签（BO#16 / #35）

    /// 按 `concurrency` 路并行读标签（每路一串，互不抢同一个文件）。`concurrency <= 1` 时就是串行。
    /// 在调用线程上阻塞到全部读完 —— 同步入口在主线程上直接用，后台入口套在 `Task.detached` 里用。
    nonisolated static func readTagsConcurrently(_ urls: [URL], concurrency: Int)
        -> (files: [AudioFile], failures: [(URL, TagError)]) {
        let width = min(max(1, concurrency), urls.count)
        guard width > 1 else { return TagService.readAll(urls) }
        let box = TagReadResultBox(width)
        DispatchQueue.concurrentPerform(iterations: width) { k in
            let stripe = stride(from: k, to: urls.count, by: width).map { urls[$0] }
            box.set(k, TagService.readAll(stripe))
        }
        return box.merged()
    }
}

/// `readTagsConcurrently` 各路结果的收集盒（`concurrentPerform` 的回调在任意线程）。
final class TagReadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [(files: [AudioFile], failures: [(URL, TagError)])]

    init(_ count: Int) {
        parts = Array(repeating: (files: [], failures: []), count: count)
    }

    func set(_ index: Int, _ part: (files: [AudioFile], failures: [(URL, TagError)])) {
        lock.lock(); parts[index] = part; lock.unlock()
    }

    func merged() -> (files: [AudioFile], failures: [(URL, TagError)]) {
        lock.lock(); defer { lock.unlock() }
        return (parts.flatMap { $0.files }, parts.flatMap { $0.failures })
    }
}

// MARK: - 行上的草稿辅助（BP-B）

extension FileRow {

    /// 「删光封面」的占位：`FileRow` 为省内存不驻留封面，`file.tags.artworks` 平时恒为空，
    /// 草稿里的「空」与之做差得不出删除 —— 在 `file` 这一侧放一张空字节的占位图，
    /// `TagEdit.diff` 就会给出 `.removeAll`。写前撤消快照会从磁盘重读真封面
    /// （`AppModel.writeUndoSnapshot`），占位不会进旁存；保存后行被整行重读，占位随之消失。
    static let artworkRemovalMarker = Artwork(data: Data(), caption: "MacTagger.pendingArtworkRemoval")

    mutating func markArtworkRemoval() {
        file.tags.artworks = [FileRow.artworkRemovalMarker]
        draft.artworks = []
    }

    /// 草稿里有没有还没保存的封面改动（换图 / 删光）。
    var hasDraftArtworkEdit: Bool {
        draft.artworks.map(\.data) != file.tags.artworks.map(\.data)
    }

    /// 待读行上用户已经改过的东西（对占位 `Tags()` 的增量）。读回真值后由
    /// `AppModel.replayPlaceholderDraft` 重放；读回前它不算 `isDirty`、不参与保存。
    var hasPlaceholderEdits: Bool {
        guard tagsState.isPending else { return false }
        var text = draft
        text.artworks = []
        return text != Tags() || hasDraftArtworkEdit
    }
}

/// 直接路径（≤ `lazyThreshold`）下把 `TagReader.drain` 的多线程回调收成一份结果。
///
/// `drain` 的 `onBatch` 在任意线程，所以上锁；`handled` 记下三类都算处理过的路径，
/// 取消时用它算出「还没轮到的那些」，退回占位行。
final class DirectReadSink: @unchecked Sendable {

    struct Result {
        var files: [AudioFile]
        var failures: [(url: URL, error: TagError)]
        var skipped: Int
        /// 读成功 / 被规则挡掉 / 读失败三类的路径全在这里。
        var handled: Set<String>
    }

    private let lock = NSLock()
    private var files: [AudioFile] = []
    private var failures: [(url: URL, error: TagError)] = []
    private var skipped = 0
    private var handled = Set<String>()

    /// 收一批，返回**累计已处理**的个数（进度浮层用）。
    @discardableResult
    func add(_ batch: TagReadBatch) -> Int {
        lock.lock(); defer { lock.unlock() }
        files.append(contentsOf: batch.files)
        failures.append(contentsOf: batch.failures)
        skipped += batch.skipped.count
        for f in batch.files { handled.insert(f.url.path) }
        for s in batch.skipped { handled.insert(s.url.path) }
        for f in batch.failures { handled.insert(f.url.path) }
        return handled.count
    }

    func take() -> Result {
        lock.lock(); defer { lock.unlock() }
        return Result(files: files, failures: failures, skipped: skipped, handled: handled)
    }
}

/// `loadItem` 回调在任意线程，收集时需要一个线程安全的盒子。
final class URLBox: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()
    func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func take() -> [URL] { lock.lock(); defer { urls = []; lock.unlock() }; return urls }
}

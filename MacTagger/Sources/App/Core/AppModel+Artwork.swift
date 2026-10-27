//
//  AppModel+Artwork.swift
//  MacTagger — 封面三件套的状态与动作
//
//  承载本轮补齐的三项原版功能：
//    A. 从网络搜索封面   （原版 FormPictureSearch）
//    B. 从标签取图       （原版 FormPictureFromTags）
//    C. 更改分辨率 / 压缩（原版「更改分辨率」「内置图片大小限制」「固定为 JPG」）
//
//  两条硬性约定：
//  1. **状态放独立 store，不加到 AppModel 上** —— Swift 扩展加不了存储属性，
//     而 `AppModel` 的定义与 init 签名已经定型。沿用 `LyricsSettings.shared`
//     那套单例做法，视图通过 `@EnvironmentObject` 拿到。
//  2. **写盘一律走既有保存路径**：组装好 `TagEdit` 后先 `recordUndoSnapshot`
//     再交给 `BatchEngine.applyEdits`，收尾走 `afterBatch`。绕过这条链，
//     「撤消标签保存」就找不回封面（历史表只存得下 6 个文本字段）。
//

import Foundation
import SwiftUI
import AppKit

// MARK: - 界面状态

@MainActor
final class ArtworkStore: ObservableObject {

    static let shared = ArtworkStore()

    private enum Key {
        static let sources   = "MacTagger.artwork.searchSources"
        static let maxEdge   = "MacTagger.artwork.adjustMaxEdge"
        static let format    = "MacTagger.artwork.adjustFormat"
        static let quality   = "MacTagger.artwork.adjustQuality"
        static let limitOn   = "MacTagger.artwork.adjustLimitEnabled"
        static let limitKB   = "MacTagger.artwork.adjustLimitKB"
        // D —— 封面落地方式 / 预留填充（本轮新增）
        static let embedMode      = "MacTagger.artwork.embedMode"
        static let folderNaming   = "MacTagger.artwork.folderNaming"
        static let folderOverwrite = "MacTagger.artwork.folderOverwrite"
        static let reserveOn      = "MacTagger.artwork.reservePaddingEnabled"
        static let reserveBytes   = "MacTagger.artwork.reservePaddingBytes"
    }

    // MARK: A —— 从网络搜索封面

    @Published var searchTitle = ""
    @Published var searchArtist = ""
    @Published var searchAlbum = ""
    @Published var enabledSources: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledSources), forKey: Key.sources) }
    }
    @Published var candidates: [ArtworkCandidate] = []
    @Published var selectedCandidateID: UUID?
    @Published var isSearching = false
    @Published var searchStatus = "填好标题 / 艺术家 / 专辑后点「搜索」"
    @Published var searchError: String?
    /// 本次搜索的逐源结果条（实数据，直接来自 `ArtworkSearchOutcome.sourceOutcomes`）。
    ///
    /// 搜出 0 张时它是唯一能分开「这些源没这张碟」和「某个源挂了」的东西。
    /// 界面从前是拿候选列表 + 一句 `源：原因` 摘要反推的：那份近似口径数得出
    /// 「谁给了几张」，却数不出**请求成功但 0 条**的源，而 iTunes 的 `country=CN`
    /// 恰好长期就是这一态（HTTP 全 200、一条不给），近似口径下它和「没勾选」没区别。
    @Published var sourceOutcomes: [SourceOutcome] = []
    /// 放大预览用的正式大图（点选候选后按需下载）。
    @Published var previewData: Data?
    @Published var previewCandidateID: UUID?
    @Published var isDownloadingPreview = false
    @Published var previewError: String?

    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    var selectedCandidate: ArtworkCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    /// 注册表里可搜封面的源，顺序即推荐优先级。
    var availableSourceIDs: [String] { ArtworkSearchService.artworkSourceIDs }

    var activeSourceIDs: [String] { availableSourceIDs.filter { enabledSources.contains($0) } }

    // MARK: B —— 从标签取图

    @Published var propagationFiles: [ArtworkFileInfo] = []
    @Published var propagationPlan: ArtworkPropagationPlan?
    /// 左列手动选中的封面源。
    @Published var manualSourceURL: URL?
    @Published var propagationStatus = "左侧是列表里已带封面的文件，右侧是当前选中的目标"

    // MARK: C —— 调整分辨率 / 压缩

    @Published var adjustMaxEdge: Int { didSet { UserDefaults.standard.set(adjustMaxEdge, forKey: Key.maxEdge) } }
    @Published var adjustFormat: ArtworkOutputFormat {
        didSet { UserDefaults.standard.set(adjustFormat.rawValue, forKey: Key.format) }
    }
    @Published var adjustQuality: Double { didSet { UserDefaults.standard.set(adjustQuality, forKey: Key.quality) } }
    @Published var adjustLimitEnabled: Bool { didSet { UserDefaults.standard.set(adjustLimitEnabled, forKey: Key.limitOn) } }
    @Published var adjustLimitKB: Int { didSet { UserDefaults.standard.set(adjustLimitKB, forKey: Key.limitKB) } }
    /// 实时预览结果（「调整后 W×H · N KB」那一行）。
    @Published var adjustPreview: ArtworkProcessResult?
    @Published var adjustError: String?
    @Published var adjustOriginal: (width: Int, height: Int, bytes: Int) = (0, 0, 0)

    // MARK: D —— 封面落地方式 / 预留填充
    //
    // 用户的无损库在 TF 卡上，往 FLAC 里嵌大封面会触发 TagLib 整文件重写（几十 MB
    // 一首）。两条对策各自有一个开关放在这里：
    //   * `artworkEmbedMode` = .folderFile → 封面存成专辑目录里的图片，音频完全不动；
    //   * `reservePaddingEnabled`          → 在那次「反正要重写」的保存之后，把文件头
    //     填充一次扩到位，之后换封面 / 改标签全部原地完成。
    //
    // **本轮只落设置，不接线到保存路径**（写入路径的接线由主会话统一安排）。

    /// 封面写到哪里：嵌标签 / 文件夹图片 / 两者都写。默认 `.embed`（原版行为）。
    @Published var artworkEmbedMode: ArtworkEmbedMode {
        didSet { UserDefaults.standard.set(artworkEmbedMode.rawValue, forKey: Key.embedMode) }
    }

    /// 文件夹封面的文件名规则。
    @Published var folderArtworkNaming: FolderArtworkNaming {
        didSet { UserDefaults.standard.set(folderArtworkNaming.rawValue, forKey: Key.folderNaming) }
    }

    /// 目录里已经有同名封面时，是否覆盖。默认否 —— 用户自己放的封面优先。
    @Published var folderArtworkOverwrite: Bool {
        didSet { UserDefaults.standard.set(folderArtworkOverwrite, forKey: Key.folderOverwrite) }
    }

    /// 是否在「刚刚整文件重写过」的保存之后顺手扩填充。默认开。
    @Published var reservePaddingEnabled: Bool {
        didSet { UserDefaults.standard.set(reservePaddingEnabled, forKey: Key.reserveOn) }
    }

    /// 预留字节数。写入时夹在 0…960 KB —— 超过 TagLib 的 1 MB 上限，
    /// 下次保存反而会把填充收缩回去（又一次整文件重写）。
    @Published var reservePaddingBytes: Int {
        didSet {
            let clamped = PaddingReserver.safeTarget(reservePaddingBytes)
            if clamped != reservePaddingBytes { reservePaddingBytes = clamped; return }
            UserDefaults.standard.set(reservePaddingBytes, forKey: Key.reserveBytes)
        }
    }

    /// 「预留 512 KB」这类给界面用的说明文案。
    var reservePaddingSummary: String {
        guard reservePaddingEnabled else { return "关闭" }
        return String(format: "预留 %.0f KB（上限 %.0f KB）",
                      Double(reservePaddingBytes) / 1024.0,
                      Double(PaddingReserver.maxSafeReserveBytes) / 1024.0)
    }

    var adjustOptions: ArtworkProcessOptions {
        ArtworkProcessOptions(maxEdge: adjustMaxEdge,
                              format: adjustFormat,
                              jpegQuality: adjustQuality,
                              maxBytes: adjustLimitEnabled ? adjustLimitKB * 1024 : 0)
    }

    // MARK: 初始化

    init() {
        SourceBootstrap.registerAll()
        let d = UserDefaults.standard
        let available = Set(ArtworkSearchService.artworkSourceIDs)
        if let saved = d.stringArray(forKey: Key.sources) {
            let restored = Set(saved).intersection(available)
            enabledSources = restored.isEmpty ? available : restored
        } else {
            enabledSources = available
        }
        adjustMaxEdge = d.object(forKey: Key.maxEdge) as? Int ?? 500
        adjustFormat = ArtworkOutputFormat(rawValue: d.string(forKey: Key.format) ?? "") ?? .keep
        adjustQuality = d.object(forKey: Key.quality) as? Double ?? 0.85
        adjustLimitEnabled = d.object(forKey: Key.limitOn) as? Bool ?? false
        adjustLimitKB = d.object(forKey: Key.limitKB) as? Int ?? 300

        artworkEmbedMode = ArtworkEmbedMode(rawValue: d.string(forKey: Key.embedMode) ?? "") ?? .embed
        folderArtworkNaming = FolderArtworkNaming(rawValue: d.string(forKey: Key.folderNaming) ?? "") ?? .coverJpg
        folderArtworkOverwrite = d.object(forKey: Key.folderOverwrite) as? Bool ?? false
        reservePaddingEnabled = d.object(forKey: Key.reserveOn) as? Bool ?? true
        reservePaddingBytes = PaddingReserver.safeTarget(
            d.object(forKey: Key.reserveBytes) as? Int ?? PaddingReserver.defaultReserveBytes)
    }

    // MARK: A 的动作

    func toggleSource(_ id: String) {
        if enabledSources.contains(id) { enabledSources.remove(id) } else { enabledSources.insert(id) }
    }

    func runSearch(duration: TimeInterval = 0, filename: String? = nil, limitPerSource: Int = 8) {
        searchTask?.cancel()
        let query = TrackQuery(title: searchTitle.isEmpty ? nil : searchTitle,
                               artist: searchArtist.isEmpty ? nil : searchArtist,
                               album: searchAlbum.isEmpty ? nil : searchAlbum,
                               filename: filename,
                               duration: duration)
        guard !query.isEmpty else {
            searchStatus = "请至少填写标题、艺术家或文件名"
            return
        }
        let ids = activeSourceIDs
        guard !ids.isEmpty else {
            searchError = "没有勾选任何封面来源。"
            return
        }

        isSearching = true
        searchError = nil
        previewError = nil
        searchStatus = "正在并发查询 \(ids.count) 个来源…"
        sourceOutcomes = []
        candidates = []
        selectedCandidateID = nil
        previewData = nil
        previewCandidateID = nil

        searchTask = Task { [weak self] in
            let outcome = await ArtworkSearchService.search(query, sourceIDs: ids,
                                                            limitPerSource: limitPerSource)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isSearching = false
                self.candidates = outcome.candidates
                self.selectedCandidateID = outcome.candidates.first?.id
                self.searchError = outcome.errorSummary
                // iTunes 若发生过地区回退，把「CN 0 → HK 命中」补进那枚 chip 的悬停提示：
                // 用户看到的是「iTunes 6」，得让他查得出这 6 张其实是港区商店给的。
                self.sourceOutcomes = outcome.sourceOutcomes.map { ITunesSource.annotate($0) }
                let okSources = outcome.succeededSourceIDs.count
                self.searchStatus = outcome.candidates.isEmpty
                    ? "没有搜到候选，换个关键词再试"
                    : "找到 \(outcome.candidates.count) 张候选（\(okSources) 个来源有结果）"
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        isSearching = false
        searchStatus = "已停止搜索"
    }

    /// 点选候选后拉正式大图，用于放大预览与「应用」。
    func loadPreview(for candidate: ArtworkCandidate) {
        previewTask?.cancel()
        previewData = nil
        previewCandidateID = candidate.id
        previewError = nil
        isDownloadingPreview = true
        previewTask = Task { [weak self] in
            do {
                let data = try await ArtworkSearchService.download(candidate)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.previewCandidateID == candidate.id else { return }
                    self.previewData = data
                    self.isDownloadingPreview = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.previewCandidateID == candidate.id else { return }
                    self.isDownloadingPreview = false
                    self.previewError = error.localizedDescription
                }
            }
        }
    }

    func resetSearch() {
        searchTask?.cancel(); previewTask?.cancel()
        isSearching = false
        isDownloadingPreview = false
    }

    // MARK: C 的动作

    private var adjustTask: Task<Void, Never>?

    /// 拖滑块时的防抖预览：120ms 合并一次，重编码放到后台线程。
    /// 「限制大小」那条路径最多会试十来次编码，同步跑在主线程会把滑块拖出卡顿。
    func scheduleAdjustPreview(from data: Data?) {
        adjustTask?.cancel()
        guard let data, !data.isEmpty else {
            adjustPreview = nil
            adjustOriginal = (0, 0, 0)
            return
        }
        let size = ArtworkProcessor.pixelSize(data)
        adjustOriginal = (size.width, size.height, data.count)
        let options = adjustOptions
        adjustTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let outcome: Result<ArtworkProcessResult, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try ArtworkProcessor.process(data, options: options)) }
                catch { return .failure(error) }
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success(let r): self.adjustPreview = r; self.adjustError = nil
                case .failure(let e): self.adjustPreview = nil; self.adjustError = e.localizedDescription
                }
            }
        }
    }

    /// 重算「调整后 W×H · N KB」。原图为 nil 时清空预览。
    func recomputeAdjustPreview(from data: Data?) {
        guard let data, !data.isEmpty else {
            adjustPreview = nil
            adjustOriginal = (0, 0, 0)
            return
        }
        let size = ArtworkProcessor.pixelSize(data)
        adjustOriginal = (size.width, size.height, data.count)
        do {
            adjustPreview = try ArtworkProcessor.process(data, options: adjustOptions)
            adjustError = nil
        } catch {
            adjustPreview = nil
            adjustError = error.localizedDescription
        }
    }
}

// MARK: - 偏好派生：添加封面时的自动限制

extension AppSettings {
    /// 「添加封面时自动限制」的处理选项。两个开关都关时是恒等变换。
    var artworkAutoLimitOptions: ArtworkProcessOptions {
        ArtworkProcessOptions(maxEdge: max(0, artworkAutoLimitMaxEdge),
                              format: artworkAutoConvertJPEG ? .jpeg : .keep,
                              jpegQuality: 0.85,
                              maxBytes: 0)
    }

    var artworkAutoLimitEnabled: Bool {
        artworkAutoLimitMaxEdge > 0 || artworkAutoConvertJPEG
    }

    var artworkAutoLimitSummary: String {
        var parts: [String] = []
        if artworkAutoLimitMaxEdge > 0 { parts.append("≤ \(artworkAutoLimitMaxEdge) px") }
        if artworkAutoConvertJPEG { parts.append("转 JPEG") }
        return parts.isEmpty ? "关闭" : parts.joined(separator: " · ")
    }
}

// MARK: - AppModel 动作

extension AppModel {

    var artworkStore: ArtworkStore { ArtworkStore.shared }

    /// 新加入的封面统一过这里：按偏好自动限制尺寸 / 转 JPEG，并把声明尺寸校准。
    /// 处理失败时原样返回 —— 压缩失败绝不能把封面本身弄丢。
    func normalizedArtwork(_ art: Artwork) -> Artwork {
        let limited = ArtworkProcessor.processLeniently(art, options: settings.artworkAutoLimitOptions)
        return ArtworkProcessor.refreshedMetadata(limited)
    }

    // MARK: A —— 从网络搜索封面

    func presentArtworkSearch() {
        guard focusRow != nil else {
            statusMessage = "请先在列表中选择文件"
            return
        }
        let store = artworkStore
        store.resetSearch()
        store.searchTitle = mergedValue(.title) ?? ""
        store.searchArtist = mergedValue(.artist) ?? ""
        store.searchAlbum = mergedValue(.album) ?? ""
        store.candidates = []
        store.selectedCandidateID = nil
        store.previewData = nil
        store.searchStatus = "填好标题 / 艺术家 / 专辑后点「搜索」"
        store.searchError = nil

        ArtworkSheetPresenter.shared.present(model: self,
                                             width: Theme.Size.sheetWide,
                                             height: 640) {
            ArtworkSearchSheet()
        }
        // 打开即自动搜一次：标签齐全时用户不用再点一下。
        if !store.searchTitle.isEmpty || !store.searchArtist.isEmpty {
            store.runSearch(duration: focusRow?.file.technical.duration ?? 0,
                            filename: focusRow?.file.url.deletingPathExtension().lastPathComponent)
        }
    }

    /// 把搜到的封面应用到**当前选中的全部文件**的工作副本，随后走标准保存流程。
    func applySearchedArtwork(_ data: Data, caption: String?) {
        guard !selection.isEmpty else {
            statusMessage = "请先在列表中选择文件"
            return
        }
        let mime = ArtworkProcessor.mimeType(data) ?? "image/jpeg"
        var art = Artwork(data: data, mimeType: mime, caption: caption, type: .frontCover)
        art = normalizedArtwork(art)

        if settings.overwriteArtworkOnAdd {
            focusArtworks = [art]
        } else {
            focusArtworks.append(art)
        }
        artworkIndex = max(0, focusArtworks.count - 1)
        artworkDirty = true
        let n = selection.count
        statusMessage = "已取得封面 \(art.declaredWidth)×\(art.declaredHeight)，将写入 \(n) 个文件"
        ArtworkSheetPresenter.shared.dismiss()
        requestSave()
    }

    // MARK: B —— 从标签取图

    func presentArtworkFromTags() {
        guard !allRows.isEmpty else {
            statusMessage = "列表里还没有文件"
            return
        }
        let store = artworkStore
        store.propagationFiles = artworkFileInfos()
        store.propagationPlan = nil
        store.manualSourceURL = store.propagationFiles.first(where: { $0.hasArtwork })?.url
        let sourceCount = store.propagationFiles.filter(\.hasArtwork).count
        store.propagationStatus = sourceCount == 0
            ? "列表里没有任何带封面的文件，无法取图"
            : "列表里有 \(sourceCount) 个文件带封面，可作为取图来源"

        ArtworkSheetPresenter.shared.present(model: self,
                                             width: Theme.Size.sheetWide,
                                             height: 620) {
            ArtworkFromTagsSheet()
        }
    }

    /// 汇总列表里每个文件的配对信息。封面字节数只对**带封面**的文件读一次，
    /// 且设了上限——整个目录几千首歌时，把封面全读进内存会直接吃光内存。
    func artworkFileInfos() -> [ArtworkFileInfo] {
        var budget = 400
        return allRows.map { row in
            let has = row.artworkCount > 0
            var bytes = 0
            if has, budget > 0 {
                budget -= 1
                bytes = (try? TagService.readArtworks(row.file.url))?.first?.byteCount ?? 0
            }
            return ArtworkFileInfo(url: row.file.url,
                                   fileName: row.fileName,
                                   album: row.draft.album,
                                   albumArtist: row.draft.albumArtist,
                                   artist: row.draft.artist,
                                   hasArtwork: has,
                                   artworkByteCount: bytes)
        }
    }

    /// 「按专辑自动匹配」：目标默认是列表里所有无封面的文件；
    /// 有选中项时只处理选中项（原版同样以选中为准）。
    func buildArtworkPropagationPlan(scopeToSelection: Bool, allowAlbumOnly: Bool) {
        let store = artworkStore
        let files = store.propagationFiles.isEmpty ? artworkFileInfos() : store.propagationFiles
        store.propagationFiles = files
        let targets: Set<URL>? = (scopeToSelection && !selection.isEmpty) ? selection : nil
        let plan = ArtworkPropagation.autoMatchByAlbum(files,
                                                       targets: targets,
                                                       includeFilesWithArtwork: false,
                                                       allowAlbumOnly: allowAlbumOnly)
        store.propagationPlan = plan
        store.propagationStatus = plan.summary
    }

    /// 「把左边选中的这张封面发给右边选中的文件」。
    func buildManualPropagationPlan(sourceURL: URL) {
        let store = artworkStore
        let files = store.propagationFiles.isEmpty ? artworkFileInfos() : store.propagationFiles
        store.propagationFiles = files
        guard let src = files.first(where: { $0.url == sourceURL }) else { return }
        let targets = files.filter { selection.contains($0.url) && $0.url != sourceURL }
        guard !targets.isEmpty else {
            store.propagationStatus = "右侧没有可写入的目标：请在主列表里选中要接收封面的文件"
            store.propagationPlan = nil
            return
        }
        let plan = ArtworkPropagation.manualPlan(source: src, targets: targets)
        store.propagationPlan = plan
        store.propagationStatus = "手动指定：\(src.fileName) → \(targets.count) 个文件"
    }

    /// 批量写入配对结果。**每条都先记撤消快照**，撤消才找得回原封面。
    ///
    /// BO#16（BP-E）：原先读来源封面、按偏好压图、`fitArtworks`、写前快照（读目标旧封面 + 旁存落盘）
    /// 全在主线程上同步逐条做，而且排在 `isBusy/progress` 之前 —— 一张专辑十几张大图就是
    /// 一段看不到浮层的彩虹球。现在先置浮层，逐条把这几步甩到后台线程，带进度、可取消。
    func performArtworkPropagation(_ pairings: [ArtworkPairing]) {
        let accepted = pairings.filter(\.accepted)
        guard !accepted.isEmpty else {
            statusMessage = "没有勾选任何配对"
            return
        }
        if refuseWhileBusy() { return }

        let preserveDate = settings.preserveModificationDate
        let limitOptions = settings.artworkAutoLimitOptions
        let history = historyStore
        let sideCar = sideCarStore

        // 主线程只查行（不读盘）。
        struct Job { let source: URL; let target: AudioFile; let modifiedAt: Date? }
        var jobs: [Job] = []
        var missingRows = 0
        for pair in accepted {
            guard let row = row(id: pair.target.url) else { missingRows += 1; continue }
            jobs.append(Job(source: pair.source.url, target: row.file, modifiedAt: row.modifiedAt))
        }
        guard !jobs.isEmpty else {
            alert = AlertBox(title: "从标签取图",
                             message: "没有可写入的项：目标文件已不在列表里。", isError: true)
            return
        }

        isBusy = true
        progressTitle = "从标签取图…"
        progress = BatchProgress(completed: 0, total: jobs.count,
                                 note: "准备封面与撤消数据 0/\(jobs.count)", startedAt: Date())

        let task = Task { [weak self] in
            var cache: [URL: [Artwork]] = [:]
            var payload: [(url: URL, edit: TagEdit)] = []
            var mtimes: [URL: Date] = [:]
            var skippedNoSource = missingRows
            var historyFailures = 0
            var artShrunk = 0
            var prepared = 0
            let startedAt = self?.progress?.startedAt

            for job in jobs {
                if Task.isCancelled { break }
                // 来源封面：每个来源只读一次（后台线程）。
                let arts: [Artwork]
                if let cached = cache[job.source] {
                    arts = cached
                } else {
                    let src = job.source
                    arts = await Task.detached(priority: .userInitiated) {
                        (try? TagService.readArtworks(src)) ?? []
                    }.value
                    cache[job.source] = arts
                }
                prepared += 1
                guard let picked = arts.first(where: { $0.type == .frontCover }) ?? arts.first else {
                    skippedNoSource += 1
                    continue
                }
                // 压图 + 容器上限（AT-04：来源可能是张超大图，比如 MP4 里的 20 MB 封面，目标若是
                // FLAC 会撞上 24 bit 块长上限）+ 写前快照 —— 顺序要紧：撤消旁存要依据完整的 edit
                // （含 artworkAction）判断该备份什么。三步都在后台线程。
                let target = job.target
                let (edit, shrunk, ok) = await Task.detached(priority: .userInitiated) {
                    () -> (TagEdit, Bool, Bool) in
                    let limited = ArtworkProcessor.processLeniently(picked, options: limitOptions)
                    var copy = ArtworkProcessor.refreshedMetadata(limited)
                    copy.caption = picked.caption
                    var e = TagEdit()
                    e.artworkAction = .replace([copy])
                    let s = TagService.fitArtworks(in: &e, for: target.url)
                    let recorded = AppModel.writeUndoSnapshot(file: target, edit: e,
                                                              history: history, sideCar: sideCar)
                    return (e, s, recorded)
                }.value
                if shrunk { artShrunk += 1 }
                if !ok { historyFailures += 1 }
                payload.append((target.url, edit))
                if preserveDate, let d = job.modifiedAt { mtimes[target.url] = d }
                self?.progress = BatchProgress(completed: 0, total: jobs.count,
                                               currentPath: target.url.path,
                                               note: "准备封面与撤消数据 \(prepared)/\(jobs.count)",
                                               startedAt: startedAt)
            }

            guard let self else { return }
            if Task.isCancelled {
                self.abandonBatchBeforeWrite("从标签取图", recordedSnapshots: payload.count)
                return
            }
            guard !payload.isEmpty else {
                self.isBusy = false
                self.progress = nil
                self.cancelHandler = nil
                self.alert = AlertBox(title: "从标签取图",
                                      message: "没有可写入的项：来源文件里读不到封面。", isError: true)
                return
            }

            let finalPayload = payload
            let summary = await BatchEngine.applyEdits(finalPayload, concurrency: 4) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            // 这个 Task 继承了主线程隔离（在 @MainActor 方法里创建），await 回来就在主线程上。
            do {
                if preserveDate {
                    for (url, date) in mtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                var notes: [String] = []
                if skippedNoSource > 0 { notes.append("\(skippedNoSource) 项来源无封面已跳过") }
                if historyFailures > 0 { notes.append("\(historyFailures) 条历史记录失败") }
                if let n = AppModel.artworkAutoShrinkNote(artShrunk) { notes.append(n) }
                self.afterBatch(summary,
                                reloadURLs: finalPayload.map(\.url),
                                title: "从标签取图",
                                extraNote: notes.isEmpty ? nil : "（" + notes.joined(separator: "，") + "）")
                // 文件清单（哪些文件带封面）要等回读刷新完才准 —— `afterBatch` 返回时行还是写前的样子。
                // 原先这里立刻 `artworkFileInfos()`：拿旧行算，而且在主线程上同步读最多 400 张封面。
                // 回读收工后由 `AppModel+Editing` 的 `refreshViewsDependingOnRows`（按标题
                // 「从标签取图」识别）重算一遍，这里不再重复做。
                self.artworkStore.propagationPlan = nil
            }
        }
        cancelHandler = { task.cancel() }
    }

    // MARK: C —— 调整分辨率 / 压缩

    func presentArtworkAdjust() {
        guard let art = currentArtwork else {
            statusMessage = "当前文件没有封面可调整"
            return
        }
        let store = artworkStore
        store.adjustError = nil
        store.recomputeAdjustPreview(from: art.data)

        ArtworkSheetPresenter.shared.present(model: self,
                                             width: Theme.Size.sheetMedium,
                                             height: 560) {
            ArtworkAdjustSheet()
        }
    }

    /// 把调整结果写回当前这一张封面的工作副本，随后走标准保存流程。
    func applyArtworkAdjustment(_ result: ArtworkProcessResult) {
        guard focusArtworks.indices.contains(artworkIndex) else { return }
        var art = focusArtworks[artworkIndex]
        art.data = result.data
        art.mimeType = result.mimeType
        art.declaredWidth = result.width
        art.declaredHeight = result.height
        focusArtworks[artworkIndex] = art
        artworkDirty = true
        statusMessage = "封面已调整为 \(result.width)×\(result.height)，"
            + String(format: "%.0f KB", Double(result.data.count) / 1024.0)
        ArtworkSheetPresenter.shared.dismiss()
        requestSave()
    }
}

// MARK: - Sheet 宿主

/// 用 AppKit 直接把 SwiftUI 视图挂成宿主窗口的 sheet。
///
/// 为什么不走 `.sheet(...)` 修饰符：那需要在 `ContentView` 上再叠三个 sheet，
/// 而这一轮的红线是不动 `ContentView`。sheet 在 macOS 上本来就是一个附着窗口，
/// 这里做的事情与 SwiftUI 内部完全一致（`NSHostingController` + `beginSheet`），
/// 交互、Esc 关闭、辅助功能树都和其余 sheet 一模一样。
@MainActor
final class ArtworkSheetPresenter {

    static let shared = ArtworkSheetPresenter()

    private var sheetWindow: NSWindow?
    private weak var hostWindow: NSWindow?

    func present<Content: View>(model: AppModel,
                                width: CGFloat,
                                height: CGFloat,
                                @ViewBuilder content: () -> Content) {
        dismiss()
        guard let host = Self.mainWindow() else { return }

        let root = content()
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(ArtworkStore.shared)
            .frame(width: width, height: height)

        let controller = NSHostingController(rootView: AnyView(root))
        controller.preferredContentSize = NSSize(width: width, height: height)

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: width, height: height))
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("MacTagger.artworkSheet")

        sheetWindow = window
        hostWindow = host
        host.beginSheet(window) { [weak self] _ in
            guard let self else { return }
            if self.sheetWindow === window { self.sheetWindow = nil }
        }
    }

    func dismiss() {
        guard let sheet = sheetWindow else { return }
        sheetWindow = nil
        (hostWindow ?? sheet.sheetParent)?.endSheet(sheet)
    }

    /// 主窗口：优先 key，其次 main，最后任意可见且不是 sheet 的窗口。
    private static func mainWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, w.sheetParent == nil, !(w.styleMask.contains(.docModalWindow)) { return w }
        if let w = NSApp.mainWindow, w.sheetParent == nil { return w }
        return NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.canBecomeMain }
    }
}

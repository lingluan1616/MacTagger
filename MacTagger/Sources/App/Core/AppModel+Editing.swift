//
//  AppModel+Editing.swift
//  MacTagger — 标签编辑、保存、清除、撤消、封面与历史
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「清除标签」当前的批处理任务。
///
/// `AppModel` 是单例式的主窗口状态机（全程只有一个实例），而 Swift 的 extension
/// 不能加存储属性、`AppModel.swift` 又不在本次可改动范围内，所以用一个
/// 主线程隔离的文件级变量持有它。只被本文件的清除路径读写。
@MainActor private var clearTagsTask: Task<Void, Never>?

/// 批量收尾的异步回读（BP-C #16）。同理用文件级变量持有：只被本文件的 `afterBatch` 链读写。
/// - `batchRefreshRunID`：每起一轮回读自增，过期轮次的回调一律丢弃；
/// - `batchRefreshWaiters`：`whenBatchRefreshed` 登记的「回读完再做」的收尾。
@MainActor private var batchRefreshRunID = 0
@MainActor private var batchRefreshInFlight = false
@MainActor private var batchRefreshWaiters: [@MainActor () -> Void] = []

/// 撤消数据维护（BP-C #13）的节流状态。
@MainActor private var undoMaintenanceRunning = false
@MainActor private var lastUndoMaintenance: Date?

extension AppModel {

    // MARK: - 字段读写（单曲 / 批量共用）

    /// 选中行在该字段上的共同值；值不一致时返回 nil（界面显示「多个值」）。
    func mergedValue(_ field: EditorField) -> String? {
        let rows = selectedRows
        guard let first = rows.first else { return nil }
        let v0 = value(of: field, in: first)
        for r in rows.dropFirst() where value(of: field, in: r) != v0 { return nil }
        return v0
    }

    /// 该字段在选中行里是否存在多个不同值。
    func isMixed(_ field: EditorField) -> Bool {
        let rows = selectedRows
        guard rows.count > 1 else { return false }
        return mergedValue(field) == nil
    }

    func value(of field: EditorField, in row: FileRow) -> String {
        switch field {
        case .title: return row.draft.title ?? ""
        case .artist: return row.draft.artist ?? ""
        case .albumArtist: return row.draft.albumArtist ?? ""
        case .album: return row.draft.album ?? ""
        case .year: return row.draft.year ?? ""
        case .track: return row.draft.trackString ?? ""
        case .disc: return row.draft.discString ?? ""
        case .genre: return row.draft.genre ?? ""
        case .comment: return row.draft.comment ?? ""
        case .composer: return row.draft.composer ?? ""
        case .lyrics: return row.draft.lyrics ?? ""
        // 作词以 `Tags.lyricist` 为唯一真相（与作曲同级），读盘时它与 PropertyMap 的 LYRICIST 同值。
        case .lyricist: return row.draft.lyricist ?? ""
        }
    }

    /// 写进选中行的工作副本。只有用户实际编辑才会调用（Binding 的 setter）。
    func apply(_ field: EditorField, _ text: String) {
        mutateSelection { row in AppModel.assign(field, text, to: &row) }
        objectWillChange.send()
    }

    /// 单行改写（列表内联编辑用）。
    func applyInline(_ column: ColumnID, _ text: String, to id: URL) {
        let spec = ColumnCatalog.spec(column)
        guard let field = AppModel.editorField(for: spec) else { return }
        mutate(id) { row in AppModel.assign(field, text, to: &row) }
        objectWillChange.send()
    }

    static func editorField(for spec: ColumnSpec) -> EditorField? {
        if spec.rawKey == "LYRICIST" { return .lyricist }
        guard let f = spec.field else { return nil }
        switch f {
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
        case .lyricist: return .lyricist
        case .lyrics: return .lyrics
        }
    }

    static func assign(_ field: EditorField, _ text: String, to row: inout FileRow) {
        let v: String? = text.isEmpty ? nil : text
        switch field {
        case .title: row.draft.title = v
        case .artist: row.draft.artist = v
        case .albumArtist: row.draft.albumArtist = v
        case .album: row.draft.album = v
        case .year: row.draft.year = v
        case .genre: row.draft.genre = v
        case .comment: row.draft.comment = v
        case .composer: row.draft.composer = v
        case .lyrics: row.draft.lyrics = v
        case .track:
            let (n, t) = parsePair(text)
            row.draft.trackNumber = n; row.draft.trackTotal = t
        case .disc:
            let (n, t) = parsePair(text)
            row.draft.discNumber = n; row.draft.discTotal = t
        case .lyricist:
            // BO #10：原来只写 `rawProperties["LYRICIST"]`，而 `TagEdit.diff` 不比 raw，
            // 于是改作词永远不算未保存、保存也不写。现在写命名字段（diff 已比 .lyricist），
            // 同时镜像一份到 PropertyMap —— 列表「作词家」列按 raw 取值（`FileRow.raw`），
            // 清空时镜像成 [""] 而不是删键，否则 `raw()` 会回落到磁盘旧值、列里还显示旧作词。
            row.draft.lyricist = v
            row.draft.rawProperties[TagEdit.Field.lyricist.rawValue] = [v ?? ""]
        }
    }

    /// `3/12` → (3, 12)；`3` → (3, nil)；空 → (nil, nil)
    static func parsePair(_ text: String) -> (Int?, Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let n = Int(parts.first ?? "")
        let t = parts.count > 1 ? Int(parts[1]) : nil
        return (n, t)
    }

    /// 丢弃选中行未保存的改动。
    func revertSelected() {
        if refuseWhileBusy() { return }
        mutateSelection { $0.draft = $0.file.tags }
        artworkDirty = false
        loadArtworksForFocus()
        objectWillChange.send()
        statusMessage = "已还原未保存的改动"
    }

    // MARK: - 保存标签

    // MARK: 忙时闸（BO #5/#6）

    /// 批量任务进行中时拒绝新的写盘入口时给的状态栏文案。
    static let busyRefusalMessage = "正在执行批量任务，请稍候"

    /// 批量任务（保存 / 清除 / 撤消 / 匹配写入 / 收尾回读…）进行中时，把会写盘或起新批的
    /// 入口统一挡掉：两批 `BatchEngine` 并发原地写同一个文件可能写坏，先完成的那批收尾还会把
    /// `isBusy` / 进度浮层清掉。菜单与右键的 `.disabled` 由界面层（D 组）绑，这里是模型层的底线。
    /// - Returns: `true` = 正忙，调用方应直接返回。
    @discardableResult
    func refuseWhileBusy() -> Bool {
        guard isBusy else { return false }
        statusMessage = AppModel.busyRefusalMessage
        return true
    }

    /// 「保存标签」此刻能不能点：**有未保存改动即可，不要求有选中**（无选中时存全部未保存行，
    /// 见 `requestSave`），忙时不可。菜单 ⌘S / 右键「保存标签」绑它。
    var canSave: Bool { !isBusy && hasPendingChanges }

    func requestSave() {
        if refuseWhileBusy() { return }
        // 两段式导入的兜底：待读的行 `file.tags` 还是空的，直接拿去做差会把
        // 「文件本来就有的标签」当成用户删掉的字段写回去。先把它们补读出来。
        materializePendingTags(in: selectedRows)
        let targets = selectedRows.isEmpty ? dirtyRows : selectedRows
        let payload = targets.filter { $0.isDirty || artworkDirty }
        guard !payload.isEmpty else {
            // 选中的几行没改、别处却有改动：直说，别让人以为改动丢了。
            let elsewhere = selectedRows.isEmpty ? 0 : dirtyRows.count
            statusMessage = elsewhere > 0
                ? "选中的文件没有改动；另有 \(elsewhere) 个文件有未保存的改动，取消选择后保存即可全部保存"
                : "没有改动，无需保存"
            return
        }
        var message = "确认要保存 \(payload.count) 个文件的标签？"
        // 写入代价预估（只读，见 TagService.estimatedWriteCost）。
        // 封面塞不进标签区的空闲位时 TagLib 会整文件重写：耗时由**歌曲文件大小**决定，
        // 跟图片本身多大没关系（实测见 research/AF- 报告）。把量级提前摆出来，
        // 用户就不会对着一个「没反应」的进度条发懵。
        //
        // 预估吃的是**过完封面策略之后**的编辑集：`.folderFile` 模式下封面动作已经
        // 变回 .keep，于是这里自然报「0 个整文件重写」，不需要另写一套判断。
        let (planned, jobs, policy) = applyArtworkPolicy(plannedEdits(for: payload))
        let plan = TagService.estimatedWriteCost(planned, padding: currentPaddingPolicy)
        if let folderText = policy.plannedText(jobs: jobs) {
            message += "\n\n" + folderText
        }
        if let warn = plan.warningText {
            message += "\n\n" + warn + "。"
            // 图片越小越可能塞进现成的填充里，连重写都省了 —— 顺手指路。
            if plan.largestPayloadBytes > 256 * 1024 && !settings.artworkAutoLimitEnabled {
                message += "\n开启「添加封面时自动限制」可把封面压小，多数文件就不必整文件重写了。"
            }
        }
        confirm = ConfirmBox(title: "保存标签",
                             message: message,
                             confirmTitle: "保存标签") { [weak self] in
            self?.performSave(rows: payload)
        }
    }

    /// 组装本次要写的编辑集（**不落盘、不记历史**）。
    /// 保存确认框的代价预估与真正的 `performSave` 共用同一套组装规则，
    /// 免得「预估的」和「真写的」不是同一批东西。
    func plannedEdits(for rows: [FileRow]) -> [(url: URL, edit: TagEdit)] {
        let artAction: TagEdit.ArtworkAction? = artworkDirty
            ? (focusArtworks.isEmpty ? .removeAll : .replace(focusArtworks))
            : nil
        var payload: [(url: URL, edit: TagEdit)] = []
        for r in rows {
            var edit = r.pendingEdit
            if let artAction { edit.artworkAction = artAction }
            guard !edit.isEmpty else { continue }
            payload.append((r.file.url, edit))
        }
        return payload
    }

    /// 写盘前记录一次可撤销快照。
    ///
    /// 历史表（`TagsHistoryStore`）沿用原版结构，只存得下 6 个文本字段；封面、歌词
    /// 以及 albumArtist / genre / comment / composer / lyricist 这些表外字段，靠
    /// `UndoService` 旁存到应用支持目录才能回滚。所有会写盘的路径都必须走这里。
    ///
    /// - Parameters:
    ///   - row: 目标行；`row.file` 是**磁盘现状**（不是工作副本），旁存以它为准。
    ///   - edit: 本次即将写入的改动。旁存依据它判断要备份哪些字段与封面，
    ///           所以必须在 `edit` 完全组装好（含 `artworkAction`）之后再调用。
    /// - Returns: `false` 表示历史库可用但这一条没记上，调用方可据此计入失败数；
    ///            历史库本身不可用时返回 `true`（那是配置问题，不该逐条报错）。
    ///
    /// - Important: 本方法**同步**执行磁盘 IO（读旧封面 + 旁存落盘），在 @MainActor 上调用
    ///   就等于把这些字节压在主线程上。批量路径（保存 / 清除）请改用
    ///   `writeUndoSnapshotOffMain(...)`，把 IO 甩到后台线程；这里保留同步版本，
    ///   是给逐条、量小的调用点（重命名 / 自动匹配 / 歌词 / 封面配对）继续用的。
    @discardableResult
    func recordUndoSnapshot(for row: FileRow, edit: TagEdit) -> Bool {
        AppModel.writeUndoSnapshot(file: row.file, edit: edit,
                                   history: historyStore, sideCar: sideCarStore)
    }

    /// `recordUndoSnapshot` 的**纯磁盘部分**：读旧封面 + 写历史表 + 写旁存。
    ///
    /// 从 @MainActor 里拆出来是为了能在后台线程跑（`nonisolated`）。逻辑与原来的
    /// 同步版本一字不差 —— 记什么、什么时候记、返回值含义全都没动，只是不再要求
    /// 调用方持有主线程。两个仓库本身都是线程安全的：`TagsHistoryStore` 内部 NSLock +
    /// SQLite FULLMUTEX，`SideCarStore` 标了 `@unchecked Sendable`（各序列号独立目录）。
    nonisolated static func writeUndoSnapshot(file: AudioFile,
                                              edit: TagEdit,
                                              history: TagsHistoryStore?,
                                              sideCar: SideCarStore?) -> Bool {
        guard let store = history else { return true }
        do {
            if let side = sideCar {
                // 关键：`FileRow.init` 为省内存把 `file.tags.artworks` 清空了
                // （见 FileRow.swift「封面二进制不驻留内存」），直接拿 row.file 去旁存，
                // 存下来的封面永远是 0 张 —— 撤消时封面就回不来。
                // 所以本次真会动封面时，先从磁盘把封面字节读回来再交给旁存。
                var current = file
                if !AppModel.keepsArtwork(edit) {
                    current.tags.artworks = (try? TagService.readArtworks(file.url)) ?? []
                }
                _ = try UndoService.recordBeforeWrite(url: file.url,
                                                      current: current,
                                                      edit: edit,
                                                      history: store,
                                                      sideCar: side)
            } else {
                // 没有旁存仓库时退回原版写法：至少把 6 个文本字段记进历史表。
                _ = try store.record(filePath: file.url.path, tags: file.tags)
            }
            return true
        } catch {
            return false
        }
    }

    /// 同上，但保证跑在**后台线程**。
    ///
    /// 批量快照是「每首歌读一张旧封面 + 把它原样写进旁存」——66 首 × 15.8 MB 就是
    /// 约 2 GB 的读写。原来这段挂在 @MainActor 的 `Task {}` 里同步执行，`Task.yield()`
    /// 让出的只是**任务调度点**，磁盘 IO 本身仍然占着主线程：实测辅助功能查询被挂起
    /// 7.4 秒，进度浮层拿不到任何中间值。这里用 `Task.detached` 把每条的 IO 甩到
    /// 全局并发执行器上，调用方（仍在主线程的循环）只负责取消检查与进度上报。
    ///
    /// 之所以是「每条一个 detached」而不是「整个循环一个 detached」：`Task.detached`
    /// **不继承取消**，整段甩出去就没法在文件之间响应「取消」了。逐条甩出去，取消检查
    /// 与进度更新都还留在原来的父任务里，语义与改动前完全一致。
    nonisolated static func writeUndoSnapshotOffMain(file: AudioFile,
                                                     edit: TagEdit,
                                                     history: TagsHistoryStore?,
                                                     sideCar: SideCarStore?) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            AppModel.writeUndoSnapshot(file: file, edit: edit, history: history, sideCar: sideCar)
        }.value
    }

    /// `TagEdit.ArtworkAction` 没有 Equatable，单独判一下「本次不动封面」。
    /// `nonisolated`：`writeUndoSnapshot` 在后台线程上要调它。
    nonisolated static func keepsArtwork(_ edit: TagEdit) -> Bool {
        if case .keep = edit.artworkAction { return true }
        return false
    }

    // MARK: - 封面体积上限（AT-04）

    /// 写盘前把超出目标容器上限的封面自动压到限内。**所有写封面的路径都要先过这里。**
    ///
    /// 起因：FLAC 的 METADATA_BLOCK 长度字段只有 24 bit，超过 16 MB 的 PICTURE 块
    /// 会被 TagLib 在渲染阶段整块跳过 —— `save()` 照样成功，可原有封面早被换下去了，
    /// 于是「报成功 + 封面凭空消失」。桥接层现在会在动文件之前拒写，这里再往前一步：
    /// 能压下去的就悄悄压掉，压不下去才让用户看见错误。
    ///
    /// 压缩是 CPU 活儿，只在**真有图超限**时才发生（`fitArtworks` 内部先量后压），
    /// 正常路径一次重编码都不会多做。
    ///
    /// - Returns: 真被压过的文件数；> 0 时调用方在结果里补一句 note。
    @discardableResult
    func fitArtworksToContainerLimits(_ payload: inout [(url: URL, edit: TagEdit)]) -> Int {
        var compressed = 0
        for i in payload.indices {
            if TagService.fitArtworks(in: &payload[i].edit, for: payload[i].url) { compressed += 1 }
        }
        return compressed
    }

    /// 上面那句 note 的统一文案。
    static func artworkAutoShrinkNote(_ count: Int) -> String? {
        count > 0 ? "\(count) 个文件的封面已自动压缩到 FLAC 上限以内" : nil
    }

    private func performSave(rows: [FileRow]) {
        // 确认框可能排在别的 sheet 后面、弹出时另一批已经开工了：确认那一刻再查一次。
        if refuseWhileBusy() { return }
        let preserveDate = settings.preserveModificationDate
        let artAction: TagEdit.ArtworkAction? = artworkDirty
            ? (focusArtworks.isEmpty ? .removeAll : .replace(focusArtworks))
            : nil

        var assembled: [(url: URL, edit: TagEdit)] = []
        var mtimes: [URL: Date] = [:]
        for r in rows {
            var edit = r.pendingEdit
            if let artAction { edit.artworkAction = artAction }
            guard !edit.isEmpty else { continue }
            if preserveDate, let d = r.modifiedAt { mtimes[r.file.url] = d }
            assembled.append((r.file.url, edit))
        }

        // 封面策略：`.folderFile` 把封面收成文件夹任务并让音频侧回到 .keep（音频不打开），
        // `.both` 两边都做，`.embed` 原样穿过。**必须排在记历史之前**——历史旁存依据的是
        // 「本次真会写什么」，folderFile 模式下音频侧根本不动封面，记了反而是假账。
        var (payload, folderJobs, policy) = applyArtworkPolicy(assembled)
        // 超出容器上限的封面先自动压小（AT-04）。排在记历史之前：旁存备份的是**旧**封面，
        // 与这里换掉的新封面无关，但 payload 必须在写入前就是最终形态。
        let shrunk = fitArtworksToContainerLimits(&payload)
        let written = Set(payload.map(\.url))
        mtimes = mtimes.filter { written.contains($0.key) }

        // 写前要记的那批快照。**必须排在 edit 组装完成之后**——旁存要依据本次实际改动的
        // 字段，才知道除历史表那 6 列外还得备份哪些（专辑艺术家/风格/注释/作曲/作词/
        // 歌词/封面）。少了这一步，「删封面后保存」再撤消，封面就回不来了。
        // 用索引化的 row(id:) 而不是 rows.first(where:)：整目录几千首歌时后者是 O(n²)。
        // 这里只做「查行」（主线程状态），真正的磁盘 IO 留到下面的后台阶段。
        let snapshots: [(file: AudioFile, edit: TagEdit)] = payload.compactMap { item in
            row(id: item.url).map { (file: $0.file, edit: item.edit) }
        }

        guard !payload.isEmpty || !folderJobs.isEmpty else {
            statusMessage = "没有改动，无需保存"
            return
        }

        isBusy = true
        progressTitle = "保存标签…"
        progress = BatchProgress(completed: 0, total: payload.count, startedAt: Date())
        let padding = currentPaddingPolicy
        let history = historyStore
        let sideCar = sideCarStore

        Task { [weak self] in
            // ① 撤销旁存。逐条把磁盘部分甩到后台线程（`writeUndoSnapshotOffMain`），
            //    主线程只留进度上报 —— 66 首 × 15.8 MB 旧封面≈2 GB 的读写不再压在
            //    主线程上，进度浮层能实时拿到「记录撤消数据 n/N」。
            var historyFailures = 0
            let startedAt = await MainActor.run { self?.progress?.startedAt }
            for (i, s) in snapshots.enumerated() {
                let ok = await AppModel.writeUndoSnapshotOffMain(file: s.file, edit: s.edit,
                                                                 history: history, sideCar: sideCar)
                if !ok { historyFailures += 1 }
                await MainActor.run {
                    self?.progress = BatchProgress(completed: 0,
                                                   total: payload.count,
                                                   currentPath: s.file.url.path,
                                                   note: "记录撤消数据 \(i + 1)/\(snapshots.count)",
                                                   startedAt: startedAt)
                }
            }

            // ② 真正写入。
            let summary = await BatchEngine.applyEdits(payload,
                                                       concurrency: BatchEngine.recommendedConcurrency(for: payload.map(\.url)),
                                                       paddingPolicy: padding) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            let folder = await self?.runFolderArtwork(folderJobs, policy: policy) ?? FolderArtworkOutcome()
            await MainActor.run {
                guard let self else { return }
                if preserveDate {
                    for (url, date) in mtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                var notes: [String] = []
                if historyFailures > 0 { notes.append("\(historyFailures) 条历史记录失败") }
                if let n = AppModel.artworkAutoShrinkNote(shrunk) { notes.append(n) }
                if let side = self.writeSideNote(folder: folder, summary: summary) { notes.append(side) }
                self.afterBatch(summary,
                                reloadURLs: payload.map(\.url),
                                title: "保存标签",
                                extraNote: notes.isEmpty ? nil : "（" + notes.joined(separator: "；") + "）",
                                keepsArtworkDraftOnFailure: true)
                // 只改了封面 + folderFile 模式 → 音频一个都没写，报「成功: 0 …」会让人以为失败。
                if payload.isEmpty, let s = folder.statusNote { self.statusMessage = s }
            }
        }
    }

    /// 批处理收尾：报告结果、标出失败行、**异步**回读写成功的行。
    ///
    /// BP-C 之前这里对 `reloadURLs` 整批**同步** `TagService.readAll`（逐个含封面字节），
    /// 而且不分成败一律 `replaceRow`：
    /// - BO #4：写失败的文件也被磁盘旧值覆盖，用户的未保存改动静默消失、「未保存」标记也没了；
    /// - BO #16：大封面库 / TF 卡上整段压在主线程，彩虹球数十秒到分钟。
    ///
    /// 现在分四步：
    /// 1. **写失败的行草稿原样保留**，只标 `lastError`（表格状态点变红）；状态栏写明失败数与第一条
    ///    原因，失败弹窗照旧。改动还在、仍是「未保存」，处理掉原因（去只读 / 插回卡）直接再存即可。
    /// 2. 写成功（及被忽略）的行交给 `TagReadQueue` + `TagReader.drain` 在后台回读，
    ///    读到一小批就回主线程**逐行**替换（`applyBatchRefresh`）。
    /// 3. 回读期间 `isBusy` 保持为真、浮层显示「回读刷新 n/N」—— 行没刷新完之前不许再起一批
    ///    （否则下一批拿到的是写前的行）。回读完才算整批收工（`finishBatchRefresh`）。
    /// 4. 被取消的批次：`BatchSummary` 不列「没轮到的 URL」，回读后若磁盘标签与写前一模一样，
    ///    就认定它没写到，草稿保留。
    ///
    /// 依赖「行已刷新」的后续动作请挂在 `whenBatchRefreshed { … }` 里。
    ///
    /// - Parameter keepsArtworkDraftOnFailure: 保存标签传 true：有文件写失败时保留封面草稿
    ///   （`artworkDirty` / `focusArtworks`），重试时封面改动还在。
    func afterBatch(_ summary: BatchSummary, reloadURLs: [URL], title: String, extraNote: String? = nil,
                    keepsArtworkDraftOnFailure: Bool = false) {
        var failed: [URL: String] = [:]
        for f in summary.failures where failed[f.url] == nil {
            failed[f.url] = f.error.localizedDescription
        }
        var seen = Set<URL>()
        let reread = reloadURLs.filter { failed[$0] == nil && seen.insert($0).inserted }

        // ① 失败行：草稿不动，只标错。
        for (url, message) in failed { mutate(url) { $0.lastError = message } }

        // ② 封面草稿：全局只有一份（焦点行的 focusArtworks），保存有失败时留着给重试。
        if !(keepsArtworkDraftOnFailure && !failed.isEmpty) { artworkDirty = false }

        // ③ 结果。
        var status = summary.description + (extraNote ?? "")
        if !failed.isEmpty {
            let first = summary.failures.first.map {
                "\($0.url.lastPathComponent)：\($0.error.localizedDescription)"
            } ?? ""
            status += "；\(failed.count) 个文件写入失败（\(first)），这些文件的改动已保留，处理后可重试"
        }
        statusMessage = status

        // ④ 偏好「保存标签的同时保存 Lrc 文件」：只在真正写标签的那几条路径上触发，
        //    清除标签 / 撤消保存不应该顺手生成 Lrc。
        //    保存标签：写进去的就是草稿，直接拿草稿的歌词与标题/艺术家，不必等回读（顺序与原来一致）。
        //    自动匹配 / 下载歌词：写的是候选值、不在草稿里，只能等回读完用磁盘真值（见 finishBatchRefresh）。
        if summary.succeeded > 0, title == "保存标签" {
            var texts: [URL: String] = [:]
            for url in reread { if let r = row(id: url) { texts[url] = r.draft.lyrics ?? "" } }
            saveLyricsFilesIfNeeded(reread, texts: texts)
        }
        if summary.failed > 0 {
            let detail = summary.failures.prefix(8)
                .map { "· \($0.url.lastPathComponent)：\($0.error.localizedDescription)" }
                .joined(separator: "\n")
            alert = AlertBox(title: "\(title)：\(summary.description)", message: detail, isError: true)
        }

        // ⑤ 只回读写成功（及被忽略）的文件，后台读、逐行刷新。
        startBatchRefresh(reread, title: title, cancelled: summary.isCancelled,
                          lyricsFiles: summary.succeeded > 0 && ["下载歌词", "自动匹配标签"].contains(title))
    }

    // MARK: 收尾异步回读（BP-C #16）

    /// 「行已按磁盘刷新」之后再做 `body`。没有回读在跑时立即执行。
    ///
    /// `afterBatch` 返回时行还没刷新（回读在后台）；需要拿**写后真值**的后续动作
    /// （重建统一标签分组、补存歌词文件、封面匹配的文件清单……）应挂在这里。
    func whenBatchRefreshed(_ body: @escaping @MainActor () -> Void) {
        if batchRefreshInFlight { batchRefreshWaiters.append(body) } else { body() }
    }

    private func startBatchRefresh(_ urls: [URL], title: String, cancelled: Bool, lyricsFiles: Bool) {
        batchRefreshRunID &+= 1
        let runID = batchRefreshRunID
        // 收尾那一刻的行：回读回来据此判断「期间用户有没有再改」「这个文件到底写没写到」。
        var before: [URL: (file: Tags, draft: Tags)] = [:]
        for url in urls { if let r = row(id: url) { before[url] = (r.file.tags, r.draft) } }
        batchRefreshInFlight = true
        guard !before.isEmpty else {
            finishBatchRefresh(runID: runID, refreshed: [], title: title, lyricsFiles: lyricsFiles)
            return
        }
        let targets = urls.filter { before[$0] != nil }
        let total = targets.count
        isBusy = true
        cancelHandler = nil
        progressTitle = "回读刷新…"
        progress = BatchProgress(completed: 0, total: total, note: "回读 0/\(total)", startedAt: Date())

        // 与两段式导入同一套读取器：按卷定并发（可移动卷 2 路），可逐批交付。
        // 这里的文件都已在表里，时长 / MP4 视频过滤一律不启用，读出什么就是什么。
        let queue = TagReadQueue(targets)
        let options = ImportOptions(minimumDuration: nil, ignoreVideoMP4: false)
        let concurrency = TagReader.recommendedConcurrency(for: targets)
        var continuation: AsyncStream<TagReadBatch>.Continuation?
        let stream = AsyncStream<TagReadBatch> { continuation = $0 }
        let sink = continuation
        Task.detached(priority: .userInitiated) {
            await TagReader.drain(queue: queue, options: options, concurrency: concurrency,
                                  chunkSize: 8) { batch in sink?.yield(batch) }
            sink?.finish()
        }
        Task { @MainActor [weak self] in
            var done = 0
            var refreshed: [URL] = []
            for await batch in stream {
                guard let self, batchRefreshRunID == runID else { continue }
                refreshed += self.applyBatchRefresh(batch, before: before, cancelled: cancelled)
                done += batch.count
                self.progress = BatchProgress(completed: done, total: total,
                                              currentPath: batch.files.last?.url.path,
                                              note: "回读 \(done)/\(total)",
                                              startedAt: self.progress?.startedAt)
            }
            self?.finishBatchRefresh(runID: runID, refreshed: refreshed, title: title,
                                     lyricsFiles: lyricsFiles)
        }
    }

    /// 回读到的一批：逐行换成磁盘真值。返回刷新了的 URL。
    private func applyBatchRefresh(_ batch: TagReadBatch,
                                   before: [URL: (file: Tags, draft: Tags)],
                                   cancelled: Bool) -> [URL] {
        var refreshed: [URL] = []
        for file in batch.files {
            guard let current = row(id: file.url) else { continue }   // 回读期间被移出列表
            var fresh = FileRow(file: file)
            if let snap = before[file.url] {
                if current.draft != snap.draft {
                    // 回读期间用户又改了这一行：把「那之后的改动」叠到新读回的标签上，别吞掉。
                    fresh.draft = fresh.file.tags.overlaying(TagEdit.diff(from: snap.draft, to: current.draft))
                } else if cancelled, current.isDirty, fresh.file.tags == snap.file {
                    // 批次被取消、这个文件没轮到：磁盘一字未变，草稿原样保留。
                    fresh.draft = current.draft
                }
            }
            mutate(file.url) { $0 = fresh }
            refreshed.append(file.url)
        }
        for (url, error) in batch.failures {
            mutate(url) { $0.lastError = "回读失败：" + error.localizedDescription }
        }
        return refreshed
    }

    private func finishBatchRefresh(runID: Int, refreshed: [URL], title: String, lyricsFiles: Bool) {
        guard runID == batchRefreshRunID else { return }
        batchRefreshInFlight = false
        loadArtworksForFocus()
        loadHistoryForFocus()
        rebuildDisplay()
        isBusy = false
        progress = nil
        cancelHandler = nil
        if lyricsFiles, !refreshed.isEmpty { saveLyricsFilesIfNeeded(refreshed) }
        refreshViewsDependingOnRows(afterBatchTitled: title)
        let waiters = batchRefreshWaiters
        batchRefreshWaiters = []
        for body in waiters { body() }
        maintainUndoStorage()
    }

    /// 兼容：几条批量路径（别的文件里）在 `afterBatch` 返回后**立刻**拿行去重算界面数据，
    /// 那时行还没刷新。它们迁到 `whenBatchRefreshed` 之前，这里在回读完替它们再算一遍。
    /// 重复算是幂等的，迁过去之后这里多算一遍也无妨。
    private func refreshViewsDependingOnRows(afterBatchTitled title: String) {
        if title == "统一标签" || title.hasPrefix("简繁转换（标签") {
            rebuildPropagationGroups()
            loadPropagationGroup()
        } else if title == "从标签取图" {
            artworkStore.propagationFiles = artworkFileInfos()
        }
    }

    func replaceRow(with file: AudioFile) {
        let row = FileRow(file: file)
        mutate(row.id) { $0 = row }
    }

    // MARK: - 清除标签

    func requestClearTags() {
        if refuseWhileBusy() { return }
        // 撤销旁存要按「文件当前有什么」来备份，待读的行必须先补读，
        // 否则清完之后撤销回来的是一份空标签。
        materializePendingTags(in: selectedRows)
        let rows = selectedRows
        guard !rows.isEmpty else {
            statusMessage = "请至少选择一项"
            return
        }
        confirm = ConfirmBox(title: "清除标签",
                             message: "确认要清除 \(rows.count) 个文件的全部标签？此操作会删除文件里的标签容器。",
                             confirmTitle: "清除标签",
                             destructive: true) { [weak self] in
            self?.performClearTags(rows)
        }
    }

    private func performClearTags(_ rows: [FileRow]) {
        if refuseWhileBusy() { return }
        let preserveDate = settings.preserveModificationDate

        // 清除标签 = 把文件里的东西全删掉，所以旁存也得把一切都存下来。
        // 造一份「所有字段删除 + 移除全部封面」的 TagEdit 交给 UndoService：
        // 它据此判断本次动了哪些表外字段（专辑艺术家/风格/注释/作曲/作词）、
        // 动没动歌词与封面，从而把它们一并备份。否则清除后撤消，
        // 这些内容会永久丢失——历史表只存得下 6 个文本字段。
        var clearEdit = TagEdit()
        for field in TagEdit.Field.allCases { clearEdit.remove(field) }
        clearEdit.artworkAction = .removeAll

        let urls = rows.map(\.file.url)
        let mtimes: [URL: Date] = preserveDate
            ? Dictionary(uniqueKeysWithValues: rows.compactMap { r in r.modifiedAt.map { (r.file.url, $0) } })
            : [:]

        isBusy = true
        progressTitle = "清除标签…"
        progress = BatchProgress(completed: 0, total: rows.count, startedAt: Date())

        // 原来这里是一个同步 for 循环直接调 `TagService.stripAllTags`，
        // 既不上报进度也不能取消 —— 用户点下「清除标签」后界面就是一片死寂。
        // 现在改成两段：① 逐条记旁存（这一步在覆盖 2 MB 封面的库里本身就不便宜，
        // 必须让用户看见）② 交给 `BatchEngine.stripAll` 并发清除。两段都上报进度。
        let files = rows.map(\.file)
        let history = historyStore
        let sideCar = sideCarStore
        let task = Task { [weak self] in
            guard let self else { return }

            // ① 撤销旁存。记什么、什么时候记、失败怎么计数全都没动，只是磁盘部分
            //    （读旧封面 + 旁存落盘）改由 `writeUndoSnapshotOffMain` 甩到后台线程。
            //    原来这段挂在主线程上同步跑，`Task.yield()` 让出的只是任务调度点、
            //    IO 仍然堵着主线程：66 首 × 15.8 MB 封面≈2 GB，实测辅助功能查询被挂起
            //    7.4 秒、进度浮层一个中间值都拿不到。取消检查与进度上报仍留在本任务里
            //    （`Task.detached` 不继承取消，所以只逐条甩 IO，不把整个循环甩出去）。
            var historyFailures = 0
            for (i, f) in files.enumerated() {
                if Task.isCancelled { break }
                let ok = await AppModel.writeUndoSnapshotOffMain(file: f, edit: clearEdit,
                                                                 history: history, sideCar: sideCar)
                if !ok { historyFailures += 1 }
                self.progress = BatchProgress(completed: 0,
                                              total: files.count,
                                              currentPath: f.url.path,
                                              note: "记录撤消数据 \(i + 1)/\(files.count)",
                                              startedAt: self.progress?.startedAt)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.finishClearTags(nil, urls: urls, historyFailures: historyFailures)
                return
            }

            // ② 真正清除。取消只在**文件之间**生效：TagLib 的 save() 是同步 C++ 调用，
            //    没有取消点，开写的那一个一定写完，不会把文件写坏。
            let summary = await BatchEngine.stripAll(
                urls,
                concurrency: BatchEngine.recommendedConcurrency(for: urls)
            ) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }

            await MainActor.run {
                if preserveDate {
                    for (url, date) in mtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                self.finishClearTags(summary, urls: urls, historyFailures: historyFailures)
            }
        }
        clearTagsTask = task
        cancelHandler = { [weak self] in
            task.cancel()
            self?.statusMessage = "正在取消清除标签…（当前文件写完即停）"
        }
    }

    /// 清除标签收尾：清掉取消钩子，再走公共的 `afterBatch`。
    private func finishClearTags(_ summary: BatchSummary?, urls: [URL], historyFailures: Int) {
        clearTagsTask = nil
        cancelHandler = nil
        guard let summary else {
            // 旁存阶段就被取消：一个文件都没动过，直接收摊。
            isBusy = false
            progress = nil
            statusMessage = "已取消清除标签（尚未修改任何文件）"
            return
        }
        var note = historyFailures > 0 ? "（\(historyFailures) 条历史记录失败）" : nil
        if summary.isCancelled {
            note = (note ?? "") + "（已取消，\(summary.unprocessed) 项未处理）"
        }
        afterBatch(summary, reloadURLs: urls, title: "清除标签", extraNote: note)
    }

    // MARK: - 撤消标签保存

    func requestUndo() {
        if refuseWhileBusy() { return }
        let rows = selectedRows
        guard !rows.isEmpty else {
            statusMessage = "请至少选择一项"
            return
        }
        confirm = ConfirmBox(title: "撤消标签保存",
                             message: "确认要撤消 \(rows.count) 个文件标签？将回滚到最近一次保存前的状态。",
                             confirmTitle: "撤消") { [weak self] in
            self?.performUndo(rows)
        }
    }

    private func performUndo(_ rows: [FileRow]) {
        if refuseWhileBusy() { return }
        guard let store = historyStore else {
            alert = AlertBox(title: "撤消失败", message: "标签历史库不可用。", isError: true)
            return
        }
        var entries: [TagsHistoryEntry] = []
        var missing = 0
        for r in rows {
            guard let entry = (try? store.history(forFilePath: r.file.url.path, limit: 1))?.first else {
                missing += 1
                continue
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else {
            alert = AlertBox(title: "撤消失败", message: "选中的文件没有可用的标签历史记录。", isError: true)
            return
        }

        // 走 UndoService：历史表只回滚得了 6 个文本字段，封面 / 歌词 / 表外字段
        // （专辑艺术家、风格、注释、作曲、作词）得从旁存取回来一并写回。
        // 只有旁存仓库不可用时才退回 entry.undoEdit 的老写法。
        let side = sideCarStore
        let list = entries
        let reloadURLs = list.map { URL(fileURLWithPath: $0.filePath) }

        isBusy = true
        progressTitle = "撤消标签保存…"
        progress = BatchProgress(completed: 0, total: list.count)
        Task { [weak self] in
            let summary = await BatchEngine.run(
                list,
                concurrency: BatchEngine.recommendedConcurrency(for: reloadURLs),
                urlOf: { URL(fileURLWithPath: $0.filePath) },
                progress: { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
            ) { entry in
                do {
                    if let side {
                        _ = try UndoService.undo(to: entry, sideCar: side)
                    } else {
                        _ = try TagService.write(entry.undoEdit,
                                                 to: URL(fileURLWithPath: entry.filePath))
                    }
                    return .succeeded
                } catch let e as TagError {
                    return .failed(e)
                } catch {
                    return .failed(.unknown(error.localizedDescription))
                }
            }
            await MainActor.run {
                self?.afterBatch(summary, reloadURLs: reloadURLs, title: "撤消标签保存",
                                 extraNote: missing > 0 ? "（\(missing) 项无历史，已忽略）" : nil)
            }
        }
    }

    /// 标签历史窗里「撤消到这一条」。
    func undo(to entry: TagsHistoryEntry) {
        if refuseWhileBusy() { return }
        let url = URL(fileURLWithPath: entry.filePath)
        do {
            if let side = sideCarStore {
                _ = try UndoService.undo(to: entry, sideCar: side)
            } else {
                _ = try TagService.write(entry.undoEdit, to: url)
            }
            let file = try TagService.read(url)
            replaceRow(with: file)
            loadHistoryForFocus()
            statusMessage = "已撤消到 \(entry.createdAtRaw)"
        } catch {
            alert = AlertBox(title: "撤消失败", message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - 标签历史

    func loadHistoryForFocus() {
        guard let store = historyStore else { return }
        do {
            if historyScopeIsAll {
                historyEntries = try store.allHistory(limit: 500)
            } else if let row = focusRow {
                historyEntries = try store.history(forFilePath: row.file.url.path)
            } else {
                historyEntries = []
            }
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    /// 旧入口：确认框挂在根视图的 `model.confirm` 上。
    ///
    /// 标签历史窗**不再用它**（BO #15：根上的确认框在历史窗开着时排队，点了没反应、关窗后才冒出来），
    /// 改为窗内 `.confirmationDialog` 确认后直接调 `clearAllHistory()`。这里留给没有 sheet 挡着的入口。
    func requestClearHistory() {
        if refuseWhileBusy() { return }
        confirm = ConfirmBox(title: "清除所有标签历史",
                             message: "确认要清除所有标签历史?",
                             confirmTitle: "清除",
                             destructive: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let error = await self.clearAllHistory() else { return }
                self.alert = AlertBox(title: "清除失败", message: error, isError: true)
            }
        }
    }

    /// 清除全部标签历史，**连同撤消旁存一起清空**（BO #13：原先只清历史表，旁存只增不减）。
    ///
    /// 删上千个旁存目录是实打实的磁盘活，放在后台线程做；期间置 `isBusy`（浮层「清理撤消旁存…」），
    /// 免得新一批保存刚写下的旁存被这次清空一并删掉。
    /// - Returns: 失败时的错误文案（调用方就地显示）；成功返回 nil。
    @discardableResult
    func clearAllHistory() async -> String? {
        if refuseWhileBusy() { return AppModel.busyRefusalMessage }
        guard let store = historyStore else { return "标签历史库不可用。" }
        let side = sideCarStore
        isBusy = true
        progressTitle = "清理撤消旁存…"
        progress = BatchProgress(completed: 0, total: 0, startedAt: Date())
        let result: Result<(removed: Int, freedBytes: Int64), Error> = await Task.detached(priority: .userInitiated) {
            do {
                if let side {
                    return .success(try UndoService.clearAll(history: store, sideCar: side))
                }
                try store.clearAll()
                return .success((0, 0))
            } catch {
                return .failure(error)
            }
        }.value
        isBusy = false
        progress = nil
        historyEntries = []
        loadHistoryForFocus()
        switch result {
        case .success(let r):
            statusMessage = "清除所有标签历史完成"
                + (r.removed > 0 ? "，同时清理撤消旁存 \(r.removed) 份（\(TagService.humanBytes(r.freedBytes))）" : "")
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    // MARK: - 撤消数据维护（BP-C #13）

    /// 在后台按 `UndoService.RetentionPolicy.default`（旁存 500 MB / 30 天 / 孤儿宽限 10 分钟，
    /// 重命名日志 30 天）清理撤消数据。
    ///
    /// 调用时机：App 启动时一次（AppModel 启动流程调），此后每批写入回读收尾时顺带一次；
    /// 10 分钟内最多跑一次（`force` 跳过节流），忙时不跑。结果写系统日志，不打扰状态栏。
    func maintainUndoStorage(force: Bool = false) {
        Task { @MainActor [weak self] in
            _ = await self?.maintainUndoStorageNow(force: force)
        }
    }

    /// 同上，可等待，返回本次维护的总账（被节流 / 忙 / 仓库不可用时返回 nil）。
    @discardableResult
    func maintainUndoStorageNow(force: Bool = false) async -> UndoService.MaintenanceReport? {
        guard let history = historyStore, let side = sideCarStore else { return nil }
        guard !undoMaintenanceRunning, !isBusy else { return nil }
        if !force, let last = lastUndoMaintenance, Date().timeIntervalSince(last) < 600 { return nil }
        undoMaintenanceRunning = true
        lastUndoMaintenance = Date()
        let report = await Task.detached(priority: .utility) {
            UndoService.maintain(history: history, sideCar: side)
        }.value
        undoMaintenanceRunning = false
        if let text = report.summaryText { NSLog("MacTagger 撤消数据维护：%@", text) }
        return report
    }

    func deleteHistory(_ entry: TagsHistoryEntry) {
        guard let store = historyStore else { return }
        _ = try? store.delete(serial: entry.serial)
        loadHistoryForFocus()
    }

    func historyCount() -> Int {
        guard let store = historyStore else { return 0 }
        return (try? store.entryCount()) ?? 0
    }

    // MARK: - 封面

    func loadArtworksForFocus() {
        guard !artworkDirty else { return }
        guard let row = focusRow else {
            focusArtworks = []
            artworkIndex = 0
            return
        }
        focusArtworks = (try? TagService.readArtworks(row.file.url)) ?? []
        artworkIndex = min(artworkIndex, max(0, focusArtworks.count - 1))
        showDraftArtworkIfAny()
    }

    var currentArtwork: Artwork? {
        guard focusArtworks.indices.contains(artworkIndex) else { return nil }
        return focusArtworks[artworkIndex]
    }

    func presentAddArtwork() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = "选择封面图片（jpg / png）"
        panel.prompt = "添加封面"
        guard panel.runModal() == .OK else { return }
        addArtworks(from: panel.urls)
    }

    func addArtworks(from urls: [URL]) {
        var added: [Artwork] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png"].contains(ext) else { continue }
            let art = Artwork(data: data,
                              mimeType: ext == "png" ? "image/png" : "image/jpeg",
                              caption: url.deletingPathExtension().lastPathComponent,
                              type: .frontCover)
            // 「＋添加 / 拖入图片」和其它加图入口一视同仁：过「添加封面时自动限制」，
            // 并按真实字节校准 mimeType 与声明尺寸（扩展名常年与内容对不上）。
            added.append(normalizedArtwork(art))
        }
        guard !added.isEmpty else { return }
        if settings.overwriteArtworkOnAdd {
            focusArtworks = [added[0]]
        } else {
            focusArtworks.append(contentsOf: added)
        }
        artworkIndex = max(0, focusArtworks.count - 1)
        artworkDirty = true
        statusMessage = "已添加 \(added.count) 张封面，保存标签后写入"
    }

    func removeCurrentArtwork() {
        guard focusArtworks.indices.contains(artworkIndex) else { return }
        focusArtworks.remove(at: artworkIndex)
        artworkIndex = min(artworkIndex, max(0, focusArtworks.count - 1))
        artworkDirty = true
        statusMessage = "已删除封面，保存标签后生效"
    }

    func setCurrentArtworkType(_ type: PictureType) {
        guard focusArtworks.indices.contains(artworkIndex) else { return }
        focusArtworks[artworkIndex].type = type
        artworkDirty = true
    }

    /// 原版「打开封面」：写临时文件后交给「预览」。
    func openCurrentArtwork() {
        guard let art = currentArtwork else { return }
        let ext = (art.mimeType?.contains("png") ?? false) ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTagger-cover-\(UUID().uuidString).\(ext)")
        do {
            try art.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            alert = AlertBox(title: "打开封面失败", message: error.localizedDescription, isError: true)
        }
    }

    /// 导出当前封面到用户指定位置。
    func exportCurrentArtwork() {
        guard let art = currentArtwork, let row = focusRow else { return }
        let ext = (art.mimeType?.contains("png") ?? false) ? "png" : "jpg"
        let panel = NSSavePanel()
        panel.message = "文件另存为"
        panel.nameFieldStringValue = row.file.url.deletingPathExtension().lastPathComponent + "." + ext
        panel.allowedContentTypes = [ext == "png" ? .png : .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try art.data.write(to: url)
            statusMessage = "保存完成，文件保存在 \(url.deletingLastPathComponent().path)"
        } catch {
            alert = AlertBox(title: "写入封面文件失败", message: error.localizedDescription, isError: true)
        }
    }

    /// 原版「提取封面」：批量导出到歌曲所在目录。
    func requestExtractCovers() {
        if refuseWhileBusy() { return }
        let rows = selectedRows
        guard !rows.isEmpty else {
            statusMessage = "请至少选择一项"
            return
        }
        confirm = ConfirmBox(title: "提取封面",
                             message: "确认要提取 \(rows.count) 项封面？文件将保存在歌曲所在目录中。",
                             confirmTitle: "提取封面") { [weak self] in
            self?.performExtractCovers(rows)
        }
    }

    private func performExtractCovers(_ rows: [FileRow]) {
        if refuseWhileBusy() { return }
        var ok = 0, fail = 0, skip = 0
        for r in rows {
            guard let arts = try? TagService.readArtworks(r.file.url), !arts.isEmpty else {
                skip += 1
                continue
            }
            for (i, art) in arts.enumerated() {
                let ext = (art.mimeType?.contains("png") ?? false) ? "png" : "jpg"
                var name = r.file.url.deletingPathExtension().lastPathComponent
                if i > 0 { name += "-\(i + 1)" }
                let dest = r.file.url.deletingLastPathComponent()
                    .appendingPathComponent(name).appendingPathExtension(ext)
                do { try art.data.write(to: dest); ok += 1 }
                catch { fail += 1 }
            }
        }
        statusMessage = "成功: \(ok), 失败: \(fail), 忽略: \(skip), 总共: \(rows.count)"
        alert = AlertBox(title: "提取封面",
                         message: "提取完成，文件保存在歌曲所在目录中。\n" + statusMessage)
    }

    /// 封面区拖入图片。
    func handleArtworkDrop(_ providers: [NSItemProvider]) -> Bool {
        let box = URLBox()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    box.append(url)
                } else if let url = item as? URL {
                    box.append(url)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.addArtworks(from: box.take())
        }
        return true
    }
}

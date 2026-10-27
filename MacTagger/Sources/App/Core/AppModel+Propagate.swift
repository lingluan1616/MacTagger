//
//  AppModel+Propagate.swift
//  MacTagger — 「统一 / 补齐标签」的界面状态与写入动作
//
//  数据层在 `Sources/TagKit/TagPropagation.swift`（纯逻辑、probe 也用同一份）。
//  本文件只做三件 App 才需要的事：
//    1. 从列表行建组 / 把选中组的封面字节按需从磁盘补全；
//    2. 把「勾了哪些字段、选了哪个值、只填空还是覆盖」折成一份 `PropagationPlan`；
//    3. 把计划交给**与手动保存完全相同的那条写入链**落盘。
//
//  两条硬性约定，与 `AppModel+Artwork.swift` 一字不差：
//  1. **状态放独立 store，不加到 AppModel 上** —— Swift 扩展加不了存储属性。
//  2. **写盘一律走既有保存路径**：
//         applyArtworkPolicy → writeUndoSnapshotOffMain → BatchEngine.applyEdits
//         → runFolderArtwork → 保留修改时间 → afterBatch
//     这正是 `AppModel+Editing.performSave` 的五步，一步不多一步不少，每一步调的
//     都是它调的同一个函数。
//
//     为什么不直接调 `performSave(rows:)`：它的编辑集来自**行的 draft 差分**，
//     封面动作则来自**全局的 `focusArtworks`**——一次只有一个封面动作，而且会套在
//     传进去的每一行上。统一标签要表达的是「这个文件补封面、那个文件只补年份」，
//     逐文件各不相同，`performSave` 的入参形状装不下。硬套的后果是：`只填空的`
//     模式下，本来已经有封面的文件会被再写一遍同一张图 —— 在 FLAC 上就是一次
//     几十 MB 的整文件重写，还把它原本不同的封面覆盖掉，正好违背用户选的模式。
//     所以这里复用的是那条链的每一环，而不是它的入口壳子。
//

import Foundation
import SwiftUI
import AppKit


// MARK: - 界面状态

@MainActor
final class TagPropagationStore: ObservableObject {

    static let shared = TagPropagationStore()

    /// 值下拉里「自定义…」那一项的桶 id。
    static let customChoiceID = "__custom__"
    /// 单组补全封面字节的上限。超过就不谈封面（读几百个 1.5 MB 的图进内存不划算）。
    static let artworkHydrationLimit = 400

    // 分组
    @Published var grouping: PropagationGrouping = .folder
    @Published var groups: [PropagationGroup] = []
    @Published var selectedGroupID: String?

    // 选中组的字段全貌
    @Published var surveys: [FieldSurvey] = []
    /// 封面字节有没有补全（没补全时封面行不出现）。
    @Published var artworkReady = false
    @Published var isLoadingGroup = false
    /// 正在为本组 / 本池补读待读行时非 nil。界面据此显示「取消读取」并禁用「应用」。
    @Published var pendingLoad: BatchRunToken?

    // 用户选择：字段 id → 勾选 / 选定桶 / 手输值
    @Published var enabledFields: Set<String> = []
    @Published var choiceByField: [String: String] = [:]
    @Published var customByField: [String: String] = [:]
    @Published var mode: PropagationMode = .fillEmptyOnly

    // 结果
    @Published var plan = PropagationPlan()
    /// 写前预估（`TagService.estimatedWriteCost`），没有整文件重写时为 nil。
    @Published var costText: String?
    /// 组内有未保存改动的文件数 —— 应用后会被磁盘现状覆盖，得先说一声。
    @Published var dirtyInGroup = 0
    @Published var status = ""

    /// 请求时主窗口上已经挂着别的 sheet（本表会被 AppKit 排到它关掉之后才出现）：
    /// 出现时按最新的行重建分组、重算计划（BO #42）。一次性，用完即清。
    var refreshWhenShown = false
    /// 上面那次重建要不要按「多数值 + 只填空的」预勾选（沿用请求时的入参）。
    var autoFillOnShow = false

    var selectedGroup: PropagationGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    func survey(_ field: PropagationField) -> FieldSurvey? {
        surveys.first { $0.field == field }
    }

    /// 该字段当前选定的值（桶里的原样值，或手输的自定义值）。空串 = 没得选。
    func chosenValue(_ field: PropagationField) -> String {
        let id = choiceByField[field.id]
        if id == Self.customChoiceID { return customByField[field.id] ?? "" }
        guard let s = survey(field) else { return "" }
        if let id, let b = s.buckets.first(where: { $0.id == id }) { return b.display }
        return s.majority?.display ?? ""
    }

    /// 该字段当前选定的封面（只有封面行有意义）。
    var chosenArtwork: Artwork? {
        guard enabledFields.contains(PropagationField.artwork.id),
              let s = survey(.artwork) else { return nil }
        let id = choiceByField[PropagationField.artwork.id]
        if let id, let b = s.buckets.first(where: { $0.id == id }) { return b.artwork }
        return s.majority?.artwork
    }

    /// 勾选的文本字段 → 选定值。
    var textChoices: [TagEdit.Field: String] {
        var out: [TagEdit.Field: String] = [:]
        for s in surveys {
            guard case .tag(let f) = s.field, enabledFields.contains(s.field.id) else { continue }
            let v = chosenValue(s.field).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out[f] = v }
        }
        return out
    }

    /// 换组 / 换分组方式时把用户选择清干净，免得上一组的「自定义值」串到下一组。
    func resetChoices() {
        enabledFields.removeAll()
        choiceByField.removeAll()
        customByField.removeAll()
        plan = PropagationPlan()
        costText = nil
    }

    /// 按「有空缺或不一致的整组级字段」预勾选。
    func preselect() {
        enabledFields = Set(surveys.filter(\.suggestsPropagation).map(\.field.id))
    }
}

// MARK: - AppModel 接线

extension AppModel {

    // MARK: 入口

    /// 「标签 › 按文件夹统一标签…」/ 顶栏「更多 ▾」/ 检查器快捷按钮共用的入口。
    ///
    /// - Parameter grouping: 打开时的默认分组方式。检查器上那个「用组内多数值填空字段」
    ///   传 `.selection`（用户已经框好了范围），菜单入口传 `.folder`。
    /// - Parameter autoFillMajority: true 时打开即按「多数值 + 只填空的」勾好，
    ///   用户只需扫一眼预览表点「应用」。**不静默写盘。**
    ///
    /// 统计值分布、判「只填空的」、记撤消快照都要**磁盘现状**：打开前先把会用到的待读行
    /// 读回来（后台 + 进度浮层 + 可取消，BO P0-1）。表内换组 / 换分组时由
    /// `loadPropagationGroup` / `changePropagationGrouping` 在表内补读。
    func presentTagPropagation(grouping: PropagationGrouping = .folder,
                               autoFillMajority: Bool = false) {
        guard !allRows.isEmpty else {
            statusMessage = "列表是空的，先拖入文件或目录"
            return
        }
        withPendingTagsLoaded(propagationIDsNeedingTags(grouping), purpose: "统一标签") { [weak self] in
            self?.openTagPropagationSheet(grouping: grouping, autoFillMajority: autoFillMajority)
        }
    }

    private func openTagPropagationSheet(grouping: PropagationGrouping, autoFillMajority: Bool) {
        let store = TagPropagationStore.shared
        cancelPropagationPendingLoad(silently: true)
        store.grouping = grouping
        store.mode = .fillEmptyOnly
        store.resetChoices()
        rebuildPropagationGroups(preferFocus: true)
        loadPropagationGroup(autoFillMajority: autoFillMajority)

        // 主窗口上已经挂着别的 sheet（例如复核表）时，AppKit 会把本表排到它关掉之后才弹。
        // 那段时间里文件可能已被改写 —— 真正挂上时（`propagationSheetWindowReady`）按最新数据重算。
        store.refreshWhenShown = Self.propagationHostHasForeignSheet()
        store.autoFillOnShow = autoFillMajority

        ArtworkSheetPresenter.shared.present(model: self,
                                             width: Theme.Size.sheetWide,
                                             height: 660) {
            TagPropagationSheet()
        }
    }

    /// 打开时哪些行必须先有标签：
    /// - 按专辑：分组本身靠专辑名，池里全部待读行都得先读；
    /// - 当前选中：选中项（没选则全部）；
    /// - 按文件夹：分组只看路径，只需默认选中的那一组（焦点行所在文件夹，没有焦点则第一组）。
    ///   换到别的文件夹时由 `loadPropagationGroup` 在表内补读那一组。
    private func propagationIDsNeedingTags(_ grouping: PropagationGrouping) -> [URL] {
        let pool = propagationPool(grouping)
        switch grouping {
        case .album, .selection:
            return pool.map(\.url)
        case .folder:
            let groups = TagPropagation.groupFiles(pool, by: .folder)
            let focus = focusRow?.file.url
            let hit = focus.flatMap { f in groups.first { $0.files.contains { $0.url == f } } }
                ?? groups.first
            return hit?.files.map(\.url) ?? []
        }
    }

    /// 本表将要挂到的那个窗口上，是否已经挂着一张**别的** sheet（本表会排队）。
    /// 找窗口的口径与 `ArtworkSheetPresenter.mainWindow()` 一致。
    private static func propagationHostHasForeignSheet() -> Bool {
        let host: NSWindow? = {
            if let w = NSApp.keyWindow, w.sheetParent == nil,
               !w.styleMask.contains(.docModalWindow) { return w }
            if let w = NSApp.mainWindow, w.sheetParent == nil { return w }
            return NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.canBecomeMain }
        }()
        guard let sheet = host?.attachedSheet else { return false }
        // 自己那一类（封面与写入选项 / 上一张统一标签表）会被 `present()` 先关掉，不算排队。
        return sheet.identifier?.rawValue != "MacTagger.artworkSheet"
    }

    /// 本表的窗口就位（`TagPropagationSheet` 的窗口探针）。
    ///
    /// 排队弹出的那一次：窗口早就建好了，但要等前一张 sheet 关掉、本表**真正挂上主窗口**
    /// （可见且有 sheetParent）才算出现 —— 在那一刻按最新数据重算。每 100 ms 看一眼；
    /// 本表没弹出就被关掉（窗口释放）或又开了新的一张（旗标被复位）时自动收手。
    func propagationSheetWindowReady(_ window: NSWindow) {
        let store = TagPropagationStore.shared
        guard store.refreshWhenShown else { return }
        Task { @MainActor [weak self, weak window] in
            while store.refreshWhenShown {
                guard let w = window else { store.refreshWhenShown = false; return }
                if w.isVisible, w.sheetParent != nil {
                    self?.propagationSheetDidAppear()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// 排队弹出的那一次真正出现时：按最新数据重建分组、重算计划。
    func propagationSheetDidAppear() {
        let store = TagPropagationStore.shared
        guard store.refreshWhenShown else { return }
        store.refreshWhenShown = false
        changePropagationGrouping(store.grouping, autoFillMajority: store.autoFillOnShow)
    }

    // MARK: 建组

    /// 参与分组的文件池。
    ///
    /// `.selection` 用选中项（没选就退回全部）；`.folder` / `.album` 一律用**全部**行 ——
    /// 用户只点了一首歌也该看到「这个文件夹里另外 10 首写着什么」，那正是本功能的用途。
    private func propagationPool(_ grouping: PropagationGrouping) -> [AudioFile] {
        switch grouping {
        case .selection:
            let rows = selectedRows.isEmpty ? allRows : selectedRows
            return rows.map(\.file)
        case .folder, .album:
            return allRows.map(\.file)
        }
    }

    /// 重建分组列表。`preferFocus` 时默认选中「当前焦点行所在的那一组」。
    func rebuildPropagationGroups(preferFocus: Bool = false) {
        let store = TagPropagationStore.shared
        let groups = TagPropagation.groupFiles(propagationPool(store.grouping), by: store.grouping)
        store.groups = groups
        if preferFocus, let focus = focusRow?.file.url,
           let hit = groups.first(where: { $0.files.contains { $0.url == focus } }) {
            store.selectedGroupID = hit.id
        } else if store.selectedGroupID == nil
                    || !groups.contains(where: { $0.id == store.selectedGroupID }) {
            store.selectedGroupID = groups.first?.id
        }
    }

    /// 表内切换分组方式（也是排队弹出时的重建入口）。
    ///
    /// 按专辑分组要先有**全部**行的专辑名 —— 待读行的专辑是空的，不读回来它们会全挤进
    /// 「无专辑」那一组。池里有待读行就先在表内补读，读完再分组。
    func changePropagationGrouping(_ grouping: PropagationGrouping, autoFillMajority: Bool = false) {
        let store = TagPropagationStore.shared
        cancelPropagationPendingLoad(silently: true)
        store.grouping = grouping
        store.resetChoices()
        if grouping == .album {
            let waiting = pendingTagIDs(in: propagationPool(.album).map(\.url))
            if !waiting.isEmpty {
                store.groups = []
                store.selectedGroupID = nil
                loadPendingForPropagation(waiting) { [weak self] in
                    self?.rebuildPropagationGroups(preferFocus: true)
                    self?.loadPropagationGroup(autoFillMajority: autoFillMajority)
                }
                return
            }
        }
        rebuildPropagationGroups(preferFocus: true)
        loadPropagationGroup(autoFillMajority: autoFillMajority)
    }

    // MARK: 表内补读待读行

    /// 在表内补读（主窗口的进度浮层被 sheet 挡着，进度写在表头状态条上，「取消读取」按钮也在表内）。
    private func loadPendingForPropagation(_ ids: [URL], then: @escaping @MainActor () -> Void) {
        let store = TagPropagationStore.shared
        let token = BatchRunToken()
        store.pendingLoad = token
        store.isLoadingGroup = true
        store.surveys = []
        store.artworkReady = false
        store.plan = PropagationPlan()
        store.costText = nil
        store.dirtyInGroup = 0
        store.status = "正在读取 \(ids.count) 个待读文件的标签…"
        readPendingTagsInBackground(ids, token: token, progress: { done, total in
            guard store.pendingLoad === token else { return }
            store.status = "正在读取 \(total) 个待读文件的标签…（\(done)/\(total)）"
        }, completion: { [weak self] cancelled in
            token.finish()
            guard let self, store.pendingLoad === token else { return }
            store.pendingLoad = nil
            if cancelled {
                store.isLoadingGroup = false
                let left = self.pendingTagIDs(in: ids).count
                store.status = "已取消读取：还有 \(left) 个文件标签未读，暂不能统一"
                return
            }
            then()
        })
    }

    /// 表内「取消读取」按钮 / 关表 / 换组。
    /// - Parameter silently: true 时连收尾文案也不要（换组、关表：旧的那次补读直接作废）。
    func cancelPropagationPendingLoad(silently: Bool = false) {
        let store = TagPropagationStore.shared
        guard let token = store.pendingLoad else { return }
        token.cancel()
        if silently {
            store.pendingLoad = nil
            store.isLoadingGroup = false
        }
    }

    // MARK: 补全封面 + 统计

    /// 把当前选中组的封面字节从磁盘读回来，然后统计全字段值分布。
    ///
    /// 为什么必须读：列表行（`FileRow`）为省内存把 `tags.artworks` 清空了，只留张数。
    /// 直接拿它统计，封面一栏会把「没读」当成「没有封面」，于是给本来有图的文件
    /// 再写一遍图 —— 白白触发整文件重写，还覆盖掉人家原本的封面。
    ///
    /// 组内还有待读行时先在表内把它们读回来（`materializePendingTags`），读完再统计：
    /// 待读行的标签是空壳，「只填空的」会把它磁盘上原本有值的字段当成空的覆盖掉。
    func loadPropagationGroup(autoFillMajority: Bool = false) {
        let store = TagPropagationStore.shared
        cancelPropagationPendingLoad(silently: true)
        guard let group = store.selectedGroup else {
            statPropagationGroup(autoFillMajority: autoFillMajority)
            return
        }
        let waiting = pendingTagIDs(in: group.files.map(\.url))
        guard waiting.isEmpty else {
            let groupID = group.id
            loadPendingForPropagation(waiting) { [weak self] in
                guard let self else { return }
                // 分组依据可能随读出的标签变了（按专辑分组时）：重建，尽量留在原来那一组。
                self.rebuildPropagationGroups()
                if store.groups.contains(where: { $0.id == groupID }) { store.selectedGroupID = groupID }
                self.statPropagationGroup(autoFillMajority: autoFillMajority)
            }
            return
        }
        statPropagationGroup(autoFillMajority: autoFillMajority)
    }

    /// 统计本组（此时组内应已没有待读行；万一还有 —— 补读被取消 / 刚冒出来的 —— 一律排除）。
    private func statPropagationGroup(autoFillMajority: Bool) {
        let store = TagPropagationStore.shared
        guard let group = store.selectedGroup else {
            store.surveys = []
            store.artworkReady = false
            store.isLoadingGroup = false
            store.plan = PropagationPlan()
            store.status = "没有可用的分组"
            return
        }

        // 只有「标签已读出」的行参与统计与计划：还待读的与读不出的（损坏 / 无权限），
        // 标签都是空壳，拿去统计会被当成「空值」，「只填空的」就会把它们磁盘上的真值覆盖掉。
        var usable: [AudioFile] = []
        var excluded = 0
        for f in group.files {
            guard let r = row(id: f.url) else { continue }
            if r.tagsState.isLoaded { usable.append(r.file) } else { excluded += 1 }
        }
        let excludedNote = excluded > 0 ? "；另有 \(excluded) 个文件标签未读或读不出，已排除" : ""
        let base = PropagationGroup(id: group.id, title: group.title,
                                    subtitle: group.subtitle, files: usable)
        if let i = store.groups.firstIndex(where: { $0.id == group.id }) { store.groups[i] = base }
        store.dirtyInGroup = usable.filter { row(id: $0.url)?.isDirty == true }.count

        guard !usable.isEmpty else {
            store.surveys = []
            store.artworkReady = false
            store.isLoadingGroup = false
            store.plan = PropagationPlan()
            store.costText = nil
            store.status = "本组没有标签已读出的文件" + excludedNote
            return
        }

        let urls = usable.map(\.url)
        guard urls.count <= TagPropagationStore.artworkHydrationLimit else {
            // 太大了就只统计文本字段，封面行不出现（也就不会被误勾）。
            store.surveys = TagPropagation.surveyAll(base, includeArtwork: false)
            store.artworkReady = false
            store.isLoadingGroup = false
            if autoFillMajority { store.preselect() }
            store.status = "\(base.count) 个文件（超过 \(TagPropagationStore.artworkHydrationLimit) 个，本组不统计封面）"
                + excludedNote
            recomputePropagationPlan()
            return
        }

        store.isLoadingGroup = true
        store.status = "正在读取 \(urls.count) 个文件的封面…"
        Task { [weak self] in
            // 封面字节可能有几十 MB，读在后台线程上，主线程只接结果。
            let files: [AudioFile] = await Task.detached(priority: .userInitiated) {
                TagService.readAll(urls).files
            }.value
            await MainActor.run {
                guard let self else { return }
                // 读的过程中用户可能已经换组了，认准 id 再落。
                guard store.selectedGroup?.id == group.id, store.pendingLoad == nil else { return }
                let hydrated = PropagationGroup(id: group.id, title: group.title,
                                                subtitle: group.subtitle,
                                                files: files.isEmpty ? base.files : files)
                if let i = store.groups.firstIndex(where: { $0.id == group.id }) {
                    store.groups[i] = hydrated
                }
                store.surveys = TagPropagation.surveyAll(hydrated, includeArtwork: true)
                store.artworkReady = true
                store.isLoadingGroup = false
                if autoFillMajority {
                    store.mode = .fillEmptyOnly
                    store.preselect()
                }
                let lost = files.isEmpty ? 0 : base.count - files.count
                let lostNote = lost > 0 ? "；\(lost) 个文件这次没读出来，已排除" : ""
                store.status = "\(hydrated.count) 个文件" + excludedNote + lostNote
                self.recomputePropagationPlan()
            }
        }
    }

    // MARK: 生成计划

    /// 按当前勾选重算计划与写前预估。任何一处选择变了都调它。
    func recomputePropagationPlan() {
        let store = TagPropagationStore.shared
        guard let group = store.selectedGroup, store.pendingLoad == nil else {
            store.plan = PropagationPlan()
            store.costText = nil
            return
        }
        let plan = PropagationPlan.plan(group: group,
                                        choices: store.textChoices,
                                        mode: store.mode,
                                        artwork: store.chosenArtwork)
        store.plan = plan

        guard !plan.isEmpty else { store.costText = nil; return }
        // 与保存确认框同一套口径：先过封面策略（`.folderFile` 模式下音频侧不动封面），
        // 再拿过完策略的编辑集去预估，免得「预估的」和「真写的」不是同一批东西。
        let (planned, _, _) = applyArtworkPolicy(plan.edits)
        let cost = TagService.estimatedWriteCost(planned, padding: currentPaddingPolicy)
        store.costText = cost.warningText
    }

    // MARK: 写入

    /// 把计划落盘。**与手动保存同一条链**，撤消因此完整（含封面与表外字段）。
    ///
    /// 五步与 `AppModel+Editing.performSave` 逐一对应：
    ///   ① `applyArtworkPolicy` —— 必须排在记历史之前，`.folderFile` 模式下音频侧
    ///      根本不动封面，先记就是假账；
    ///   ② `writeUndoSnapshotOffMain` —— 逐条把旧封面读回来旁存，磁盘 IO 甩到后台线程；
    ///   ③ `BatchEngine.applyEdits` —— 并发度按卷决定，带预留填充策略；
    ///   ④ `runFolderArtwork` + 保留修改时间；
    ///   ⑤ `afterBatch` —— 回读复核、刷新行、报结果。
    ///
    /// 「统一标签」「简繁转换（标签）」「从文件名更改标签」三条入口共用这一条链。
    ///
    /// - Parameters:
    ///   - extraNotes: 调用方要追加到结果里的说明（未匹配 / 未读跳过…）。
    ///   - refreshPropagationStore: 写完是否重建「统一标签」表的分组与统计。只有从那张表
    ///     点「应用」时才需要；别的入口重建它只是白读一遍磁盘。
    func performTagPropagation(_ edits: [(url: URL, edit: TagEdit)],
                               title: String = "统一标签",
                               extraNotes: [String] = [],
                               refreshPropagationStore: Bool = true) {
        guard !edits.isEmpty else {
            statusMessage = "0 个文件需要修改"
            return
        }
        guard !isBusy else {
            statusMessage = "正在处理其它任务，请稍后再试「\(title)」"
            return
        }
        let preserveDate = settings.preserveModificationDate
        var mtimes: [URL: Date] = [:]
        if preserveDate {
            for e in edits { if let d = row(id: e.url)?.modifiedAt { mtimes[e.url] = d } }
        }

        // ① 封面策略 + 容器上限自动压缩（AT-04：FLAC 单张封面 24 bit 块长）
        var (payload, folderJobs, policy) = applyArtworkPolicy(edits)
        let artShrunk = fitArtworksToContainerLimits(&payload)

        // 写前快照的「现状」：行上的标签**已读出**就用它（与手动保存同一口径）；
        // 行还待读 / 读失败 / 不在列表里 → 到后台从磁盘现读一份。**绝不拿待读行的空壳记快照** ——
        // 那样撤消时 6 个文本字段会被当成 nil 逐个删掉（BO P0-1）。读不出现状的文件干脆不写。
        let sources: [(url: URL, edit: TagEdit, known: AudioFile?)] = payload.map { item in
            let r = row(id: item.url)
            return (url: item.url, edit: item.edit, known: r?.tagsState.isLoaded == true ? r?.file : nil)
        }

        guard !payload.isEmpty || !folderJobs.isEmpty else {
            statusMessage = "没有改动，无需保存"
            return
        }

        isBusy = true
        progressTitle = title + "…"
        progress = BatchProgress(completed: 0, total: payload.count, startedAt: Date())
        let padding = currentPaddingPolicy
        let history = historyStore
        let sideCar = sideCarStore

        Task { [weak self] in
            // ② 撤销旁存
            var historyFailures = 0
            var unreadable: [URL] = []
            let startedAt = await MainActor.run { self?.progress?.startedAt }
            for (i, s) in sources.enumerated() {
                var current = s.known
                if current == nil {
                    let url = s.url
                    current = await Task.detached(priority: .userInitiated) { try? TagService.read(url) }.value
                }
                if let current {
                    let ok = await AppModel.writeUndoSnapshotOffMain(file: current, edit: s.edit,
                                                                     history: history, sideCar: sideCar)
                    if !ok { historyFailures += 1 }
                } else {
                    unreadable.append(s.url)
                }
                await MainActor.run {
                    self?.progress = BatchProgress(completed: 0,
                                                   total: payload.count,
                                                   currentPath: s.url.path,
                                                   note: "记录撤消数据 \(i + 1)/\(sources.count)",
                                                   startedAt: startedAt)
                }
            }
            let skip = Set(unreadable)
            let toWrite = skip.isEmpty ? payload : payload.filter { !skip.contains($0.url) }
            let written = Set(toWrite.map(\.url))
            let keptMtimes = mtimes.filter { written.contains($0.key) }

            // ③ 真正写入
            let summary = await BatchEngine.applyEdits(toWrite,
                                                       concurrency: BatchEngine.recommendedConcurrency(for: toWrite.map(\.url)),
                                                       paddingPolicy: padding) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            // ④ 文件夹封面 + 保留修改时间
            let folder = await self?.runFolderArtwork(folderJobs, policy: policy) ?? FolderArtworkOutcome()
            await MainActor.run {
                guard let self else { return }
                if preserveDate {
                    for (url, date) in keptMtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                var notes = extraNotes
                if !unreadable.isEmpty {
                    notes.append("\(unreadable.count) 个文件读不出当前标签，未写入（没有可信的撤消快照）")
                }
                if historyFailures > 0 { notes.append("\(historyFailures) 条历史记录失败") }
                if let n = AppModel.artworkAutoShrinkNote(artShrunk) { notes.append(n) }
                if let side = self.writeSideNote(folder: folder, summary: summary) { notes.append(side) }
                // ⑤ 收尾
                self.afterBatch(summary,
                                reloadURLs: toWrite.map(\.url),
                                title: title,
                                extraNote: notes.isEmpty ? nil : "（" + notes.joined(separator: "；") + "）")
                // 写完把这一组重新统计一遍：再点「应用」应当报「0 个文件需要修改」。
                if refreshPropagationStore {
                    self.rebuildPropagationGroups()
                    self.loadPropagationGroup()
                }
            }
        }
    }

    /// 检查器多选态那个快捷按钮：按「组内多数值 + 只填空的」直接备好选择并打开预览。
    /// **不静默写盘** —— 仍然要用户在 sheet 里看过预览表再点「应用」。
    func presentPropagationFillFromMajority() {
        guard selectedCount > 1 else {
            statusMessage = "请先选中多个文件"
            return
        }
        presentTagPropagation(grouping: .selection, autoFillMajority: true)
    }
}

//
//  AppModel+Chinese.swift
//  MacTagger — 批量简繁转换的界面状态与动作
//
//  对应 B 报告 5.2 节 F / K 两条，原版菜单里的四项：
//      标签 简→繁 / 标签 繁→简 / 文件名 简→繁 / 文件名 繁→简
//
//  数据层在 `Sources/TagKit/ChineseConversionService.swift`（纯逻辑、probe 也用同一份）。
//  本文件只做三件 App 才需要的事：
//    1. 装表单状态（作用对象 / 方向 / 预览表）；
//    2. 按当前选择重算预览；
//    3. 把计划交给**既有的**两条落盘链，一条都不新造：
//         · 标签   → `performTagPropagation`（= 手动保存那五步，可「撤消标签保存」）
//         · 文件名 → `runRenamePlans`（后台逐条 `RenameService.apply`，可取消、可「撤消重命名」）
//
//  状态为什么不加到 AppModel 上：Swift 扩展加不了存储属性，且 AppModel 与 ContentView
//  已定稿、本轮只允许定点增行。照搬 `RenameState.shared` 的既有做法，对既有文件零侵入。
//

import Foundation
import SwiftUI
import AppKit

// MARK: - 表单状态

@MainActor
final class ChineseConvertState: ObservableObject {

    static let shared = ChineseConvertState()

    private enum Key {
        static let scope  = "MacTagger.zhConvert.scope"
        static let policy = "MacTagger.zhConvert.policy"
    }

    /// sheet 开关。关表时顺带作废表内还在跑的补读。
    @Published var isPresented = false {
        didSet {
            if !isPresented, let token = loadToken {
                token.cancel()
                loadToken = nil
                loadingText = nil
            }
        }
    }

    /// 作用对象：标签 / 文件名。
    @Published var scope: ChineseConversionScope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: Key.scope) }
    }

    /// 方向。`.simplified` = 繁→简，`.traditional` = 简→繁。
    /// **不允许是 `.none`** —— 这个面板的存在意义就是转换，不转就别开它。
    @Published var policy: ChineseVariantPolicy {
        didSet {
            if policy == .none { policy = .simplified; return }
            UserDefaults.standard.set(policy.rawValue, forKey: Key.policy)
        }
    }

    // 预览（由 AppModel 重算，不在 body 里算 —— 文件名那条要跑磁盘存在性检查）
    @Published var tagPlan = ChineseTagPlan()
    @Published var filePlans: [RenamePlanItem] = []
    @Published var status = ""
    /// 标签作用对象下，因标签未读 / 读不出而没参与的文件名（预览摘要与结果里要说出来）。
    @Published var unreadNames: [String] = []
    /// 表内补读待读行时的进度文案（非 nil 时「应用」不可用，摘要行显示它）。
    @Published var loadingText: String?
    /// 表内补读的控制块；关表即取消。
    var loadToken: BatchRunToken?

    private init() {
        let d = UserDefaults.standard
        scope = ChineseConversionScope(rawValue: d.string(forKey: Key.scope) ?? "") ?? .tags
        let raw = d.string(forKey: Key.policy) ?? ""
        let restored = ChineseVariantPolicy(rawValue: raw) ?? .simplified
        policy = restored == .none ? .simplified : restored
    }

    // MARK: 派生

    /// 方向的中文说法，标题与按钮共用。
    var directionLabel: String {
        policy == .simplified ? "繁 → 简" : "简 → 繁"
    }

    var title: String { "简繁转换 · \(scope.label) \(directionLabel)" }

    /// 有没有任何一行可执行。
    var isRunnable: Bool {
        guard loadingText == nil else { return false }
        switch scope {
        case .tags:      return !tagPlan.isEmpty
        case .filenames: return filePlans.contains { $0.status.isReady }
        }
    }

    /// 底部那行摘要。
    var summary: String {
        if let loadingText { return loadingText }
        switch scope {
        case .tags:
            guard !unreadNames.isEmpty else { return tagPlan.summary }
            return tagPlan.summary + "；另有 \(unreadNames.count) 个文件标签未读或读不出，未参与"
        case .filenames: return ChineseConversionService.summary(for: filePlans)
        }
    }

    /// 预览重算的触发键：作用对象或方向变了就重算。
    var previewKey: String { scope.rawValue + "|" + policy.rawValue }
}

// MARK: - 动作

extension AppModel {

    // MARK: 入口

    /// 菜单四项与顶栏「更多 ▾ › 简繁转换…」共用的入口。
    ///
    /// - Parameters:
    ///   - scope: 作用对象。菜单四项各自指定，顶栏那一行传 nil 表示"沿用上次"。
    ///   - policy: 方向。同上。
    ///
    /// **一律先开预览，绝不静默写盘** —— 简繁转换会碰整库的标题与艺术家，
    /// 是本应用改动面最大的批量操作之一，必须让用户看过「原 → 新」再点应用。
    func presentChineseConvert(scope: ChineseConversionScope? = nil,
                               policy: ChineseVariantPolicy? = nil) {
        guard !allRows.isEmpty else {
            statusMessage = "列表是空的，先添加文件"
            return
        }
        let state = ChineseConvertState.shared
        if let scope { state.scope = scope }
        if let policy, policy != .none { state.policy = policy }
        let open: @MainActor () -> Void = { [weak self] in
            self?.refreshChineseConvertPreview(state)
            state.isPresented = true
        }
        // 标签作用对象要拿「标签现状」算转换、再按它记撤消快照：待读行先读回来
        // （后台 + 进度浮层 + 可取消）。文件名作用对象不看标签，直接开；
        // 开表后再切到「标签」时由预览在表内补读（见 `refreshChineseConvertPreview`）。
        if state.scope == .tags {
            withPendingTagsLoaded(renameTargets.map(\.id), purpose: "简繁转换（标签）", then: open)
        } else {
            open()
        }
    }

    // MARK: 预览

    /// 重算预览表。作用对象、方向、或选中项变了都调它。
    func refreshChineseConvertPreview(_ state: ChineseConvertState) {
        // 批处理目标与重命名/自动匹配同口径：有选中只处理选中项，没选中处理列表全部。
        let rows = renameTargets
        guard !rows.isEmpty else {
            state.tagPlan = ChineseTagPlan()
            state.filePlans = []
            state.status = "没有可处理的文件"
            return
        }

        guard ChineseVariant.isAvailable else {
            state.tagPlan = ChineseTagPlan()
            state.filePlans = []
            state.status = "OpenCC 引擎不可用：" + (ChineseVariant.unavailableReason ?? "未知原因")
            return
        }

        switch state.scope {
        case .tags:
            // 表开着时切到「标签」而目标里还有待读行：先在表内补读（摘要行显示进度，关表即取消），
            // 读完再重算。补读期间计划为空，「应用」不可用。
            let waiting = pendingTagIDs(in: rows.map(\.id))
            if !waiting.isEmpty, state.isPresented {
                state.tagPlan = ChineseTagPlan()
                state.filePlans = []
                state.unreadNames = []
                guard state.loadToken == nil else { return }      // 已经在读了，读完会自己重算
                let token = BatchRunToken()
                state.loadToken = token
                state.loadingText = "正在读取 \(waiting.count) 个待读文件的标签…"
                readPendingTagsInBackground(waiting, token: token, progress: { done, total in
                    guard state.loadToken === token else { return }
                    state.loadingText = "正在读取 \(total) 个待读文件的标签…（\(done)/\(total)）"
                }, completion: { [weak self] cancelled in
                    token.finish()
                    guard state.loadToken === token else { return }
                    state.loadToken = nil
                    state.loadingText = nil
                    if !cancelled { self?.refreshChineseConvertPreview(state) }
                })
                return
            }
            // 只有标签**已读出**的行参与：待读行的 draft 是空壳，会被当成「无字段需转换」静默跳过（BO #38）；
            // 读不出的同理。它们在摘要里单独点名。
            let usable = rows.filter { $0.tagsState.isLoaded }
            state.unreadNames = rows.filter { !$0.tagsState.isLoaded }.map(\.fileName)
            // 用 draft（工作副本）而不是磁盘现状：检查器里刚改还没保存的值也一起转，
            // 与「文件名 ↔ 标签」的取值口径一字不差。
            let items = usable.map { (url: $0.file.url, tags: $0.draft) }
            state.tagPlan = ChineseConversionService.planTags(items, to: state.policy)
            state.filePlans = []
        case .filenames:
            state.filePlans = ChineseConversionService.planFilenames(
                rows.map(\.file.url),
                to: state.policy,
                options: RenameOptions(renameCompanions: RenameState.shared.renameCompanions))
            state.tagPlan = ChineseTagPlan()
            state.unreadNames = []
        }
        state.status = "共 \(rows.count) 个文件参与"
    }

    // MARK: 应用

    func applyChineseConvert(_ state: ChineseConvertState) {
        switch state.scope {
        case .tags:      performChineseTagConversion(state)
        case .filenames: performChineseFilenameConversion(state)
        }
    }

    /// 标签：走「统一标签」那条五步链，撤消因此完整（历史库旁存 → 「撤消标签保存」）。
    private func performChineseTagConversion(_ state: ChineseConvertState) {
        let plan = state.tagPlan
        guard !plan.isEmpty else {
            alert = AlertBox(title: "简繁转换",
                             message: "没有任何字段需要转换。",
                             isError: true)
            return
        }
        let notes = [AppModel.unreadableNote(state.unreadNames)].compactMap { $0 }
        state.isPresented = false
        performTagPropagation(plan.edits,
                              title: "简繁转换（标签 \(state.directionLabel)）",
                              extraNotes: notes,
                              refreshPropagationStore: false)
    }

    /// 文件名：走重命名那条链，可「撤消重命名」。
    private func performChineseFilenameConversion(_ state: ChineseConvertState) {
        let plans = state.filePlans
        guard plans.contains(where: { $0.status.isReady }) else {
            alert = AlertBox(title: "简繁转换",
                             message: "没有任何一行可以执行。请看预览里的失败原因。",
                             isError: true)
            return
        }
        state.isPresented = false
        // 与「标签 → 文件名」同一条后台链：置忙 + 进度 + 可取消，收尾就地改行（BO #39 / #40）。
        runRenamePlans(plans,
                       title: "简繁转换（文件名 \(state.directionLabel)）",
                       statusSuffix: "（可用「撤消重命名」回滚）")
    }
}

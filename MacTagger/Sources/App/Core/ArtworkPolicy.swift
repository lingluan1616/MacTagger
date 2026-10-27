//
//  ArtworkPolicy.swift（App 侧）
//  MacTagger — 把封面策略与预留填充接到写入路径上
//
//  引擎在 `Sources/TagKit/ArtworkPolicyEngine.swift`（纯函数、无 SwiftUI，probe 也用同一份）。
//  本文件只做三件 App 才需要的事：
//    1. 从 `ArtworkStore` 把用户设置读成一份 `ArtworkPolicy` / `PaddingPolicy`；
//    2. 把文件夹封面任务丢到后台线程落地，结果折成一句状态栏文案；
//    3. 「封面与写入选项…」的入口动作。
//
//  接线点只有两处，各一行：
//    * `AppModel+Editing.performSave`      —— 检查器悬停条「添加封面 → 保存标签」也走这条；
//    * `AppModel+AutoMatch.performAutoMatchWrite` —— 逐首 / 专辑两种匹配模式共用。
//  歌词那条路径不带封面，不需要接。
//

import Foundation
import SwiftUI

// MARK: - 从设置读策略

extension ArtworkPolicy {
    /// 当前设置下的封面落地策略。
    @MainActor
    static var current: ArtworkPolicy {
        let s = ArtworkStore.shared
        return ArtworkPolicy(mode: s.artworkEmbedMode,
                             naming: s.folderArtworkNaming,
                             overwrite: s.folderArtworkOverwrite)
    }
}

extension PaddingPolicy {
    /// 当前设置下的预留填充策略。关掉开关时返回 `.disabled`（`applyEdits` 完全沿用旧行为）。
    @MainActor
    static func current(preserveModificationDate: Bool) -> PaddingPolicy {
        let s = ArtworkStore.shared
        guard s.reservePaddingEnabled else { return .disabled }
        return PaddingPolicy(enabled: true,
                             preferredBytes: s.reservePaddingBytes,
                             preserveModificationDate: preserveModificationDate)
    }
}

// MARK: - AppModel 接线助手

extension AppModel {

    /// 保存 / 匹配写入共用的一句话：读设置 → 改写编辑集 → 拿到文件夹封面任务。
    ///
    /// `.folderFile` 模式下只改封面的项会被整条剔除（音频不打开），所以返回的
    /// payload **可能是空的而 jobs 非空** —— 调用方的「没有改动」判断要把 jobs 算上。
    func applyArtworkPolicy(_ payload: [(url: URL, edit: TagEdit)])
        -> (payload: [(url: URL, edit: TagEdit)], jobs: [FolderArtworkJob], policy: ArtworkPolicy) {
        let policy = ArtworkPolicy.current
        let (out, jobs) = policy.apply(to: payload)
        return (out, jobs, policy)
    }

    /// 本次写入用的预留填充策略（跟随「保留修改时间」偏好）。
    var currentPaddingPolicy: PaddingPolicy {
        PaddingPolicy.current(preserveModificationDate: settings.preserveModificationDate)
    }

    /// 把文件夹封面任务落地。**在后台线程写**：几张 1 MB 的图同步写在主线程上会掉帧。
    nonisolated func runFolderArtwork(_ jobs: [FolderArtworkJob],
                                      policy: ArtworkPolicy) async -> FolderArtworkOutcome {
        guard !jobs.isEmpty else { return FolderArtworkOutcome() }
        return await Task.detached(priority: .userInitiated) { policy.run(jobs) }.value
    }

    /// 把「文件夹封面 + 预留填充」两件事折成一句状态栏补充（不带括号，由调用方拼）。
    /// 都没发生时返回 nil。
    func writeSideNote(folder: FolderArtworkOutcome, summary: BatchSummary) -> String? {
        var parts: [String] = []
        if let s = folder.statusNote { parts.append(s) }
        if let r = summary.reserveNote { parts.append(r) }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    /// 「标签 › 封面与写入选项…」。
    func presentArtworkPolicy() {
        ArtworkSheetPresenter.shared.present(model: self,
                                             width: Theme.Size.sheetMedium,
                                             height: 600) {
            ArtworkPolicySheet()
        }
    }
}

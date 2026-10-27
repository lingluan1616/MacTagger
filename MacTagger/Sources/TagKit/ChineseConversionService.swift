//
//  ChineseConversionService.swift
//  MacTagger — 批量简繁转换（标签 / 文件名）
//
//  对应 B 报告 5.2 节 F 条与 K 条：原版菜单里那四项
//      标签 简→繁 / 标签 繁→简 / 文件名 简→繁 / 文件名 繁→简
//
//  与「在线结果归一」的分工：
//  · 归一（`ChineseVariant` + 四个服务里的入口）管的是**将要写进来的新数据**；
//  · 本文件管的是**用户库里已经躺着的旧数据** —— 库里混着几年前从各处抓来的繁体标签，
//    归一再准也追不回去，只能整批转一遍。
//
//  三条与其余批量功能一致的底线：
//  1. **只改会变的字段**。`converted == old` 的字段一个都不排进 `TagEdit` ——
//     排进去就是一次无谓的整文件重写（FLAC 上是几十 MB），还会把修改时间搅乱。
//  2. **预览先行**。两种作用对象都先出一张「原 → 新」的表，用户看过再点应用。
//  3. **可撤消**。标签走 `AppModel+Propagate` 那条五步链（历史库旁存 → 撤消标签保存）；
//     文件名走 `RenameJournal`（撤消重命名）。本文件不自己发明第三套回滚。
//

import Foundation

// MARK: - 作用对象

/// 转换作用在什么上。
public enum ChineseConversionScope: String, CaseIterable, Sendable, Identifiable {
    case tags
    case filenames

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tags:      return "标签"
        case .filenames: return "文件名"
        }
    }

    public var undoHint: String {
        switch self {
        case .tags:      return "可用「撤消标签保存」回滚"
        case .filenames: return "可用「撤消重命名」回滚"
        }
    }
}

// MARK: - 标签改动

/// 一处字段改动，预览表一行。
public struct ChineseTagChange: Sendable, Identifiable, Equatable {
    public var url: URL
    public var field: TagEdit.Field
    public var old: String
    public var new: String

    public var id: String { url.path + "\u{1}" + field.rawValue }
    public var fileName: String { url.lastPathComponent }

    public init(url: URL, field: TagEdit.Field, old: String, new: String) {
        self.url = url; self.field = field; self.old = old; self.new = new
    }
}

/// 标签转换的完整计划。
public struct ChineseTagPlan: Sendable {
    /// 逐字段改动，按文件、再按字段顺序排好。
    public var changes: [ChineseTagChange]
    /// 可直接交给写入链的编辑集。**只含真的会变的字段。**
    public var edits: [(url: URL, edit: TagEdit)]
    /// 扫过但一个字段都不用改的文件数。
    public var untouchedFileCount: Int

    public init(changes: [ChineseTagChange] = [],
                edits: [(url: URL, edit: TagEdit)] = [],
                untouchedFileCount: Int = 0) {
        self.changes = changes
        self.edits = edits
        self.untouchedFileCount = untouchedFileCount
    }

    public var isEmpty: Bool { edits.isEmpty }
    public var fileCount: Int { edits.count }
    public var changeCount: Int { changes.count }

    /// 一行摘要：`将修改 3 个文件共 11 处（另有 5 个文件无需修改）`
    public var summary: String {
        guard !isEmpty else {
            return untouchedFileCount > 0
                ? "\(untouchedFileCount) 个文件都不含需要转换的字符，无需修改"
                : "没有可转换的内容"
        }
        var s = "将修改 \(fileCount) 个文件共 \(changeCount) 处"
        if untouchedFileCount > 0 { s += "（另有 \(untouchedFileCount) 个文件无需修改）" }
        return s
    }
}

// MARK: - 服务

public enum ChineseConversionService {

    /// 默认参与转换的字段。与 `Tags.convertibleFields` 同一份表 ——
    /// 年份/音轨号/碟号是数字，转了没有意义还可能被 OpenCC 的异体字表碰坏。
    public static let defaultFields: [TagEdit.Field] = Tags.convertibleFields

    // MARK: 标签

    /// 为一批文件生成标签转换计划。
    ///
    /// - Parameters:
    ///   - items: `(url, tags)`。界面传的是行的 draft（工作副本），
    ///     所以检查器里刚改还没保存的值也会一起转 —— 与「文件名 ↔ 标签」的取值口径一致。
    ///   - policy: `.simplified` = 繁→简，`.traditional` = 简→繁。`.none` 直接返回空计划。
    ///   - fields: 参与的字段白名单。
    public static func planTags(_ items: [(url: URL, tags: Tags)],
                                to policy: ChineseVariantPolicy,
                                fields: [TagEdit.Field] = defaultFields) -> ChineseTagPlan {
        var plan = ChineseTagPlan()
        guard !policy.isIdentity else {
            plan.untouchedFileCount = items.count
            return plan
        }

        for (url, tags) in items {
            var edit = TagEdit()
            var touched = false
            for field in fields {
                guard let old = tags.value(for: field), !old.isEmpty else { continue }
                let new = ChineseVariant.convert(old, to: policy)
                guard new != old else { continue }        // ① 只改会变的字段
                edit.set(field, new)
                plan.changes.append(ChineseTagChange(url: url, field: field, old: old, new: new))
                touched = true
            }
            if touched { plan.edits.append((url, edit)) } else { plan.untouchedFileCount += 1 }
        }
        return plan
    }

    // MARK: 文件名

    /// 为一批文件生成「文件名简繁转换」的重命名计划。
    ///
    /// 复用 `RenameService` 的净化与执行：`sanitizeComponent`（`/` `:` 换全角、掐控制字符）、
    /// `clampLength`（255 字节上限）、以及 `RenameService.apply(_:journal:history:)` ——
    /// 撤消、伴随文件搬运、历史库路径同步全部沿用同一套，不另起炉灶。
    ///
    /// 冲突判定与 `RenameService` 的模板/正则路径同口径：
    /// 名字没变 → `.unchanged`；同批撞名 / 磁盘已存在 → `.invalid`，逐条标失败不中断整批。
    public static func planFilenames(_ urls: [URL],
                                     to policy: ChineseVariantPolicy,
                                     options: RenameOptions = .default) -> [RenamePlanItem] {
        guard !policy.isIdentity else { return [] }
        let fm = FileManager.default
        var claimed: [String: URL] = [:]
        var plans: [RenamePlanItem] = []

        for url in urls {
            let dir = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let currentName = url.lastPathComponent
            // 只转主名，扩展名一个字都不碰（`.FLAC` 不该变成别的东西）。
            let oldBase = url.deletingPathExtension().lastPathComponent
            let converted = ChineseVariant.convert(oldBase, to: policy)
            let base = RenameService.clampLength(RenameService.sanitizeComponent(converted))

            guard !base.isEmpty else {
                plans.append(RenamePlanItem(sourceURL: url, newName: "", targetURL: url,
                                            companions: [],
                                            status: .invalid("转换后的文件名为空")))
                continue
            }

            let newName = ext.isEmpty ? base : "\(base).\(ext)"
            let target = dir.appendingPathComponent(newName)
            let key = target.path.lowercased()

            if newName == currentName {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [],
                                            status: .unchanged("文件名不含需要转换的字符")))
                continue
            }
            if let other = claimed[key] {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [],
                                            status: .invalid("同批内目标文件名重复（与「\(other.lastPathComponent)」撞名）")))
                continue
            }
            if fm.fileExists(atPath: target.path), key != url.path.lowercased() {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [],
                                            status: .invalid("目标文件已存在：\(newName)")))
                continue
            }

            claimed[key] = url
            let companions = options.renameCompanions
                ? companionMoves(of: url, oldBase: oldBase, newBase: base,
                                 options: options, claimed: &claimed)
                : []
            plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                        companions: companions, status: .ready))
        }
        return plans
    }

    /// 同目录下与音频同名的 `.lrc` / 图片，跟着一起改名。
    /// （`RenameService.findCompanions` 是 private，这里按同样的规则重写一遍；
    /// 规则只有一条：目标没被占用才搬，绝不让伴随文件拖垮主文件的重命名。）
    private static func companionMoves(of url: URL,
                                       oldBase: String,
                                       newBase: String,
                                       options: RenameOptions,
                                       claimed: inout [String: URL]) -> [RenamePlanItem.CompanionMove] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        var out: [RenamePlanItem.CompanionMove] = []

        for ext in options.companionExtensions {
            for candidateExt in [ext, ext.uppercased()] {
                let from = dir.appendingPathComponent("\(oldBase).\(candidateExt)")
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = dir.appendingPathComponent("\(newBase).\(candidateExt)")
                let key = to.path.lowercased()
                guard claimed[key] == nil, !fm.fileExists(atPath: to.path) else { continue }
                claimed[key] = from
                out.append(RenamePlanItem.CompanionMove(from: from, to: to))
            }
        }
        return out
    }

    // MARK: 摘要

    /// 重命名计划的一行摘要，与 `ChineseTagPlan.summary` 同口径。
    public static func summary(for plans: [RenamePlanItem]) -> String {
        let ready = plans.filter { $0.status.isReady }.count
        let invalid = plans.filter { if case .invalid = $0.status { return true }; return false }.count
        let unchanged = plans.count - ready - invalid
        guard ready > 0 else {
            if invalid > 0 { return "没有可执行的行（\(invalid) 行有冲突）" }
            return unchanged > 0 ? "\(unchanged) 个文件名都不含需要转换的字符，无需修改"
                                 : "没有可转换的文件"
        }
        var s = "将重命名 \(ready) 个文件"
        var tail: [String] = []
        if unchanged > 0 { tail.append("\(unchanged) 个无需修改") }
        if invalid > 0 { tail.append("\(invalid) 个有冲突") }
        if !tail.isEmpty { s += "（另有 " + tail.joined(separator: "、") + "）" }
        return s
    }
}

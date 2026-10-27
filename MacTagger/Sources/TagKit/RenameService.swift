//
//  RenameService.swift
//  MacTagger — 批量重命名（标签 → 文件名）
//
//  对应原版 FormMain 里泄露的方法名 `RenameFiles` / `FormFilenameRel.StartRenameFiles`。
//
//  两段式：先 `plan(...)` 出一张预览表（界面实时显示、逐条标失败原因，不碰磁盘），
//  再 `apply(...)` 真正搬文件。冲突检测全在 plan 阶段完成：
//    · 生成的文件名为空
//    · 目标文件已存在
//    · 同一批内两个文件算出了同一个目标名
//  逐条标失败、**不中断整批**，统计沿用 `BatchSummary`（成功/失败/忽略/总共）。
//

import Foundation

// MARK: - 选项

public struct RenameOptions: Sendable, Equatable {

    /// 同步重命名同名的 Lrc 与图片文件（原版「重命名相关 Lrc 文件和图片文件」）。
    public var renameCompanions: Bool
    /// 视作「伴随文件」的扩展名（小写）。
    public var companionExtensions: [String]
    /// 渲染细节（音轨补零等）。
    public var render: FilenameRenderOptions

    public init(renameCompanions: Bool = true,
                companionExtensions: [String] = ["lrc", "jpg", "jpeg", "png", "bmp", "gif", "webp"],
                render: FilenameRenderOptions = .default) {
        self.renameCompanions = renameCompanions
        self.companionExtensions = companionExtensions
        self.render = render
    }

    public static let `default` = RenameOptions()
}

// MARK: - 预览行

/// 一行重命名预览。界面直接照着画，`status` 决定颜色与是否可执行。
public struct RenamePlanItem: Sendable, Identifiable, Equatable {

    public enum Status: Sendable, Equatable {
        /// 可以执行。
        case ready
        /// 无需处理（文件名没变）。
        case unchanged(String)
        /// 不能执行，附中文原因。
        case invalid(String)

        public var isReady: Bool { if case .ready = self { return true }; return false }

        public var reason: String? {
            switch self {
            case .ready: return nil
            case .unchanged(let r), .invalid(let r): return r
            }
        }
    }

    public var id: URL { sourceURL }
    public var sourceURL: URL
    /// 目标文件名（含扩展名）。不可执行时可能为空串。
    public var newName: String
    public var targetURL: URL
    /// 伴随文件的搬运计划（.lrc / 图片）。
    public var companions: [CompanionMove]
    public var status: Status

    public var currentName: String { sourceURL.lastPathComponent }

    public struct CompanionMove: Sendable, Equatable {
        public var from: URL
        public var to: URL
    }
}

// MARK: - 服务

public enum RenameService {

    // MARK: 文件名净化

    /// 文件名里的非法字符替换表。
    /// macOS 的路径分隔符是 `/`，而 `:` 在访达里显示成 `/`（HFS 遗留），两者都不能进文件名。
    public static let illegalReplacements: [Character: Character] = [
        "/": "／",      // U+FF0F FULLWIDTH SOLIDUS
        ":": "："       // U+FF1A FULLWIDTH COLON
    ]

    /// 把任意文本净化成一个合法的文件名成分（不含扩展名）。
    public static func sanitizeComponent(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        for ch in raw {
            if let replacement = illegalReplacements[ch] {
                out.append(replacement)
            } else if ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                out.append(" ")                       // 控制字符（含 \0 \n \t）一律换成空格
            } else {
                out.append(ch)
            }
        }
        // 首尾空白与尾部的点：APFS 允许，但访达与压缩包工具常出问题，掐掉更稳。
        out = out.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        // 前导点会把文件变成隐藏文件，同样掐掉。
        while out.hasPrefix(".") { out.removeFirst() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// macOS 单个路径成分上限 255 字节（UTF-8）。超长按字符截断到安全长度。
    static func clampLength(_ name: String, maxBytes: Int = 200) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var out = ""
        for ch in name {
            if out.utf8.count + String(ch).utf8.count > maxBytes { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 生成预览

    /// 模板方式：按 `template` 为每个文件算出目标名。
    public static func plan(items: [(url: URL, tags: Tags)],
                            template: FilenameTemplate,
                            options: RenameOptions = .default) -> [RenamePlanItem] {
        buildPlan(items: items, options: options) { url, tags in
            template.render(tags: tags, options: options.render)
        }
    }

    /// 正则方式：用正则匹配当前文件名，把已映射捕获组替换成标签值。
    public static func plan(items: [(url: URL, tags: Tags)],
                            regex rule: FilenameRegexRule,
                            options: RenameOptions = .default) -> [RenamePlanItem] {
        buildPlan(items: items, options: options) { url, tags in
            try rule.renderRename(currentName: url.lastPathComponent,
                                  tags: tags,
                                  options: options.render)
        }
    }

    /// 两种方式共用的成表逻辑：算名 → 净化 → 冲突检测。
    private static func buildPlan(items: [(url: URL, tags: Tags)],
                                  options: RenameOptions,
                                  makeBaseName: (URL, Tags) throws -> String) -> [RenamePlanItem] {

        let fm = FileManager.default
        // 同批内已占用的目标路径（小写比较：macOS 默认大小写不敏感）。
        var claimed: [String: URL] = [:]
        var plans: [RenamePlanItem] = []

        for (url, tags) in items {
            let dir = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let currentName = url.lastPathComponent

            var base: String
            do {
                base = try makeBaseName(url, tags)
            } catch let e as FilenameTemplateError {
                plans.append(RenamePlanItem(sourceURL: url, newName: "", targetURL: url,
                                            companions: [], status: .invalid(e.message)))
                continue
            } catch {
                plans.append(RenamePlanItem(sourceURL: url, newName: "", targetURL: url,
                                            companions: [], status: .invalid(error.localizedDescription)))
                continue
            }

            base = clampLength(sanitizeComponent(base))
            guard !base.isEmpty else {
                plans.append(RenamePlanItem(sourceURL: url, newName: "", targetURL: url,
                                            companions: [],
                                            status: .invalid("生成的文件名为空（相关标签都是空的）")))
                continue
            }

            let newName = ext.isEmpty ? base : "\(base).\(ext)"
            let target = dir.appendingPathComponent(newName)
            let key = target.path.lowercased()

            // ① 没变：忽略。
            if newName == currentName {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [], status: .unchanged("文件名未变化")))
                continue
            }
            // ② 同批内重名。
            if let other = claimed[key] {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [],
                                            status: .invalid("同批内目标文件名重复（与「\(other.lastPathComponent)」撞名）")))
                continue
            }
            // ③ 磁盘上已存在。只差大小写时放行（macOS 默认大小写不敏感，改大小写属于合法重命名）。
            if fm.fileExists(atPath: target.path), key != url.path.lowercased() {
                plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                            companions: [],
                                            status: .invalid("目标文件已存在：\(newName)")))
                continue
            }

            claimed[key] = url
            let companions = options.renameCompanions
                ? findCompanions(of: url, newBase: base, options: options, claimed: &claimed)
                : []
            plans.append(RenamePlanItem(sourceURL: url, newName: newName, targetURL: target,
                                        companions: companions, status: .ready))
        }
        return plans
    }

    /// 找同目录下与音频同名的 `.lrc` / 图片，给出它们的搬运计划。
    /// 伴随文件的目标若已被占用则直接跳过（不让它拖垮主文件的重命名）。
    private static func findCompanions(of url: URL,
                                       newBase: String,
                                       options: RenameOptions,
                                       claimed: inout [String: URL]) -> [RenamePlanItem.CompanionMove] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let oldBase = url.deletingPathExtension().lastPathComponent
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

    // MARK: 执行

    /// 执行结果：统计 + 实际发生的搬运（供刷新列表与写日志）。
    public struct RenameOutcome: Sendable {
        public var summary: BatchSummary
        /// 主文件的 old → new。
        public var moved: [(from: URL, to: URL)]
        /// 伴随文件的 old → new。
        public var movedCompanions: [(from: URL, to: URL)]

        public init(summary: BatchSummary,
                    moved: [(from: URL, to: URL)] = [],
                    movedCompanions: [(from: URL, to: URL)] = []) {
            self.summary = summary
            self.moved = moved
            self.movedCompanions = movedCompanions
        }
    }

    /// 真正搬文件。
    ///
    /// - `.ready` 逐条 `moveItem`，失败只记这一条，不中断整批；
    /// - `.unchanged` 计入「忽略」；
    /// - `.invalid` 计入「失败」（原因已在 plan 阶段写好）；
    /// - 成功后同步搬伴随文件、更新历史库里的路径、写重命名日志（供撤消）。
    @discardableResult
    public static func apply(_ plans: [RenamePlanItem],
                             journal: RenameJournal? = nil,
                             history: TagsHistoryStore? = nil,
                             progress: ((BatchProgress) -> Void)? = nil) -> RenameOutcome {

        let fm = FileManager.default
        let started = Date()
        var summary = BatchSummary(total: plans.count)
        var moved: [(from: URL, to: URL)] = []
        var movedCompanions: [(from: URL, to: URL)] = []
        var journalItems: [RenameJournalItem] = []

        for (i, plan) in plans.enumerated() {
            defer { progress?(BatchProgress(completed: i + 1, total: plans.count, currentPath: plan.sourceURL.path)) }

            switch plan.status {
            case .unchanged(let reason):
                summary.ignored += 1
                summary.ignoredItems.append((plan.sourceURL, reason))
                continue
            case .invalid(let reason):
                summary.failed += 1
                summary.failures.append((plan.sourceURL, .invalidArgument(reason)))
                continue
            case .ready:
                break
            }

            do {
                try fm.moveItem(at: plan.sourceURL, to: plan.targetURL)
            } catch {
                summary.failed += 1
                summary.failures.append((plan.sourceURL, .writeFailed(error.localizedDescription)))
                continue
            }
            summary.succeeded += 1
            moved.append((plan.sourceURL, plan.targetURL))
            journalItems.append(RenameJournalItem(from: plan.sourceURL.path,
                                                  to: plan.targetURL.path,
                                                  isCompanion: false))

            // 历史库里记的是绝对路径，不同步的话「撤消标签保存」就找不到这个文件了。
            _ = try? history?.updateFilePath(from: plan.sourceURL.path, to: plan.targetURL.path)

            for c in plan.companions {
                guard (try? fm.moveItem(at: c.from, to: c.to)) != nil else { continue }
                movedCompanions.append((c.from, c.to))
                journalItems.append(RenameJournalItem(from: c.from.path, to: c.to.path, isCompanion: true))
            }
        }

        if !journalItems.isEmpty { try? journal?.record(journalItems) }
        summary.elapsed = Date().timeIntervalSince(started)
        return RenameOutcome(summary: summary, moved: moved, movedCompanions: movedCompanions)
    }
}

//
//  RenameJournal.swift
//  MacTagger — 重命名日志与「撤消重命名」
//
//  对应原版 FormMain 里泄露的方法名 `UndoRename`。
//
//  原版的撤消重命名只回退**最近一批**。这里照做，但把日志落盘（应用支持目录的 JSON），
//  所以关掉 App 再打开一样能撤回。批次上限 50，超出丢最老的。
//
//  日志位置：`~/Library/Application Support/MacTagger/rename-journal.json`
//  与标签历史库（tagshistory.db）同目录，probe 与 App 共用同一份，便于交叉验证。
//

import Foundation

// MARK: - 记录

/// 一次搬运：old → new。
public struct RenameJournalItem: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    /// 是否是伴随文件（.lrc / 图片）。
    public var isCompanion: Bool
    /// **跨卷复制**产生的条目（源文件可能还在）。撤消口径与移动完全不同，见
    /// `RenameJournal.undoLastBatch(history:)`：源还在就删掉目标副本，源没了才反向复制回去。
    public var isCopy: Bool
    /// 跨卷复制后源文件是否已被删掉。`isCopy == false` 时无意义。
    public var sourceDeleted: Bool

    public init(from: String,
                to: String,
                isCompanion: Bool = false,
                isCopy: Bool = false,
                sourceDeleted: Bool = false) {
        self.from = from
        self.to = to
        self.isCompanion = isCompanion
        self.isCopy = isCopy
        self.sourceDeleted = sourceDeleted
    }

    public var fromURL: URL { URL(fileURLWithPath: from) }
    public var toURL: URL { URL(fileURLWithPath: to) }

    // 旧日志（本功能上线前落盘的 JSON）没有 isCopy / sourceDeleted 两个键，
    // 合成的 Codable 会直接解码失败、把整份日志判废。所以手写解码补默认值。
    private enum CodingKeys: String, CodingKey {
        case from, to, isCompanion, isCopy, sourceDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        isCompanion = try c.decodeIfPresent(Bool.self, forKey: .isCompanion) ?? false
        isCopy = try c.decodeIfPresent(Bool.self, forKey: .isCopy) ?? false
        sourceDeleted = try c.decodeIfPresent(Bool.self, forKey: .sourceDeleted) ?? false
    }
}

/// 一批搬运是哪个功能产生的。撤消入口靠它区分：
/// 「撤消重命名」只认 `.rename`，「撤消整理」只认 `.organize`，
/// 免得用户点了「撤消整理」却把上一次重命名回退掉。
public enum RenameJournalKind: String, Codable, Sendable, Equatable {
    case rename
    case organize

    public var localizedName: String {
        switch self {
        case .rename:   return "重命名"
        case .organize: return "整理到文件夹"
        }
    }
}

/// 一批重命名 / 整理（一次「应用」按钮产生的全部搬运）。
public struct RenameJournalBatch: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var items: [RenameJournalItem]
    /// 这一批是谁产生的。旧日志没有这个键，解码时补 `.rename`。
    public var kind: RenameJournalKind
    /// 本批**新建**出来的目录（深的在后）。撤消时按相反顺序、且**只删真正空的**。
    public var createdDirectories: [String]

    public init(id: String = UUID().uuidString,
                date: Date = Date(),
                items: [RenameJournalItem],
                kind: RenameJournalKind = .rename,
                createdDirectories: [String] = []) {
        self.id = id
        self.date = date
        self.items = items
        self.kind = kind
        self.createdDirectories = createdDirectories
    }

    /// 主文件数（不含伴随文件）。
    public var fileCount: Int { items.filter { !$0.isCompanion }.count }
    public var companionCount: Int { items.filter(\.isCompanion).count }
    /// 跨卷复制的条目数（含伴随文件）。
    public var copyCount: Int { items.filter(\.isCopy).count }

    private enum CodingKeys: String, CodingKey {
        case id, date, items, kind, createdDirectories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        items = try c.decode([RenameJournalItem].self, forKey: .items)
        kind = try c.decodeIfPresent(RenameJournalKind.self, forKey: .kind) ?? .rename
        createdDirectories = try c.decodeIfPresent([String].self, forKey: .createdDirectories) ?? []
    }
}

// MARK: - 日志

/// 可持久化的重命名日志。线程安全（内部串行化）。
public final class RenameJournal: @unchecked Sendable {

    /// 批次上限。超出后丢最老的。
    public static let maxBatches = 50

    private let fileURL: URL
    private let lock = NSLock()
    private var batches: [RenameJournalBatch]

    // MARK: 生命周期

    /// 默认日志位置：`~/Library/Application Support/MacTagger/rename-journal.json`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent("MacTagger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rename-journal.json")
    }

    /// 全局实例。App 与 mactagger-probe 共用同一份日志文件。
    public static let shared: RenameJournal? = {
        guard let url = try? defaultURL() else { return nil }
        return RenameJournal(fileURL: url)
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.batches = RenameJournal.load(from: fileURL)
    }

    // MARK: 读

    /// 全部批次，最新的在前。
    public func allBatches() -> [RenameJournalBatch] {
        lock.lock(); defer { lock.unlock() }
        return batches.reversed()
    }

    /// 最近一批（没有则 nil）。
    public func lastBatch() -> RenameJournalBatch? {
        lock.lock(); defer { lock.unlock() }
        return batches.last
    }

    public func batchCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return batches.count
    }

    // MARK: 写

    /// 记一批。空批不记。
    public func record(_ items: [RenameJournalItem],
                       kind: RenameJournalKind = .rename,
                       createdDirectories: [URL] = []) throws {
        guard !items.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        batches.append(RenameJournalBatch(items: items,
                                          kind: kind,
                                          createdDirectories: createdDirectories.map(\.path)))
        if batches.count > RenameJournal.maxBatches {
            batches.removeFirst(batches.count - RenameJournal.maxBatches)
        }
        try persistLocked()
    }

    /// 清空全部日志。
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        batches.removeAll()
        try? persistLocked()
    }

    // MARK: 按时间裁剪（BP-G 轮，给保留策略用）

    /// 删掉 `date < cutoff` 的批次并写回磁盘。返回裁剪前批次数与删掉的批次数。
    ///
    /// - 没有可删的批次时**不写盘**（文件原样，mtime 不动）。
    /// - 写盘失败时内存里的批次**不变**并抛错 —— 内存与磁盘始终一致，
    ///   不会出现「内存里删了、磁盘上还在，下次 `record` 又原样写回」的分叉。
    /// - 与 `record` / `undoLastBatch` 同一把锁，保留策略在后台线程调用也安全。
    ///
    /// 为什么要有实例方法而不是直接改文件：本进程的 `RenameJournal.shared` 早已把日志载入内存，
    /// 绕过它改文件的话，它下一次 `record` 会把内存里那份（含过期批次）原样写回，裁剪白做。
    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> (before: Int, removed: Int) {
        lock.lock(); defer { lock.unlock() }
        let before = batches.count
        let kept = batches.filter { $0.date >= cutoff }
        guard kept.count < before else { return (before, 0) }
        let old = batches
        batches = kept
        do {
            try persistLocked()
        } catch {
            batches = old
            throw error
        }
        return (before, before - kept.count)
    }

    /// 按**文件路径**裁剪 —— 给只知道日志 URL 的维护入口用（`UndoService.maintain`）。
    ///
    /// - 路径就是本进程 `shared` 的那份日志 → 转给 `shared.prune(olderThan:)`，内存与磁盘一起裁；
    /// - 其它路径（probe / 测试用的临时日志）→ 直接读文件、裁剪、原子写回。
    ///   文件不存在 → `(0, 0)`；读得到但解不开 → **抛错且不动文件**（宁可留着，也不能把撤消记录写坏）。
    @discardableResult
    public static func prune(journalAt url: URL, olderThan cutoff: Date) throws -> (before: Int, removed: Int) {
        if let s = shared,
           s.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path {
            // 与磁盘上的那份对一次：文件在但解不开时不能拿内存覆盖它（内存在载入时已按空处理）。
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try decodeStrict(Data(contentsOf: url))
            }
            return try s.prune(olderThan: cutoff)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        let batches = try decodeStrict(Data(contentsOf: url))
        let kept = batches.filter { $0.date >= cutoff }
        guard kept.count < batches.count else { return (batches.count, 0) }
        try encode(kept).write(to: url, options: .atomic)
        return (batches.count, batches.count - kept.count)
    }

    // MARK: 撤消

    /// 撤消结果。
    public struct UndoOutcome: Sendable {
        public var summary: BatchSummary
        /// 实际回退的搬运：`from` 是撤消前的路径（即当初的新名），`to` 是恢复后的路径（当初的旧名）。
        public var restored: [(from: URL, to: URL)]
        /// 本次撤消的批次时间；没有可撤消的批次时为 nil。
        public var batchDate: Date?
        /// 本次撤消的批次种类；没有可撤消的批次时为 nil。
        public var batchKind: RenameJournalKind?
        /// 撤消时删掉的、本批新建且现在确实空了的目录。
        public var removedDirectories: [URL]
        /// 撤消时删掉的跨卷复制副本（源还在，所以只需删副本）。
        public var deletedCopies: [URL]

        public init(summary: BatchSummary,
                    restored: [(from: URL, to: URL)] = [],
                    batchDate: Date? = nil,
                    batchKind: RenameJournalKind? = nil,
                    removedDirectories: [URL] = [],
                    deletedCopies: [URL] = []) {
            self.summary = summary
            self.restored = restored
            self.batchDate = batchDate
            self.batchKind = batchKind
            self.removedDirectories = removedDirectories
            self.deletedCopies = deletedCopies
        }
    }

    /// 撤回最近一批搬运（重命名或整理）。
    ///
    /// 三种条目，三种口径：
    /// - **移动**（`isCopy == false`）：把 `to` 搬回 `from`；
    /// - **跨卷复制且源还在**（`isCopy && !sourceDeleted`）：删掉 `to` 那份副本，源原地不动；
    /// - **跨卷复制且源已删**（`isCopy && sourceDeleted`）：把 `to` 反向复制回 `from`，
    ///   校验通过后再删掉 `to`。
    ///
    /// 失败口径不变：目标已被别的文件占用、文件已不在 `to` 的位置 → 该条失败，其余继续；
    /// 成功撤回的条目从日志里剔除，整批都撤回后该批次删除，还有残留时批次保留。
    ///
    /// 全部条目撤完后，按**从深到浅**的顺序清掉本批新建的目录 ——
    /// **只删 `contentsOfDirectory` 真的返回空的那些**，里面还剩任何东西（包括用户后放进去的）
    /// 一律留着。
    @discardableResult
    public func undoLastBatch(history: TagsHistoryStore? = nil) -> UndoOutcome {
        lock.lock()
        guard let batch = batches.last else {
            lock.unlock()
            return UndoOutcome(summary: BatchSummary(total: 0))
        }
        let index = batches.count - 1
        // 倒序回退：伴随文件与主文件的顺序与写入时相反，避免中间态撞名。
        let ordered = Array(batch.items.reversed())
        lock.unlock()

        let fm = FileManager.default
        let started = Date()
        var summary = BatchSummary(total: ordered.count)
        var restored: [(from: URL, to: URL)] = []
        var deletedCopies: [URL] = []
        var doneIDs = Set<String>()

        for item in ordered {
            let current = item.toURL      // 现在磁盘上的名字
            let original = item.fromURL   // 要恢复成的名字
            let key = item.from + "\u{1}" + item.to

            guard fm.fileExists(atPath: current.path) else {
                summary.failed += 1
                summary.failures.append((current, .fileNotFound("文件已不在 \(current.lastPathComponent)，可能被再次改名或移走")))
                continue
            }

            // ① 跨卷复制且源还在：源就是原样，撤消 = 删掉那份副本。
            if item.isCopy, !item.sourceDeleted {
                guard fm.fileExists(atPath: original.path) else {
                    // 源被用户自己删了 —— 这时删副本等于把文件彻底弄丢，宁可不撤。
                    summary.failed += 1
                    summary.failures.append((current, .writeFailed("源文件已不在 \(original.path)，不删除副本以免丢失")))
                    continue
                }
                do { try fm.removeItem(at: current) }
                catch {
                    summary.failed += 1
                    summary.failures.append((current, .writeFailed(error.localizedDescription)))
                    continue
                }
                summary.succeeded += 1
                deletedCopies.append(current)
                doneIDs.insert(key)
                continue
            }

            if fm.fileExists(atPath: original.path),
               original.path.lowercased() != current.path.lowercased() {
                summary.failed += 1
                summary.failures.append((current, .writeFailed("原文件名已被占用：\(original.lastPathComponent)")))
                continue
            }

            do {
                if item.isCopy {
                    // ② 跨卷复制且源已删：反向复制回去，校验通过后才删副本。
                    try fm.createDirectory(at: original.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: current, to: original)
                    guard FileCopyVerifier.matches(current, original) else {
                        try? fm.removeItem(at: original)
                        throw TagError.writeFailed("反向复制后校验不一致，已删掉不完整的回写文件")
                    }
                    try? fm.removeItem(at: current)
                } else {
                    // ③ 普通移动。
                    try fm.createDirectory(at: original.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.moveItem(at: current, to: original)
                }
            } catch {
                summary.failed += 1
                let message = (error as? TagError)?.localizedDescription ?? error.localizedDescription
                summary.failures.append((current, .writeFailed(message)))
                continue
            }
            summary.succeeded += 1
            restored.append((current, original))
            doneIDs.insert(key)
            _ = try? history?.updateFilePath(from: current.path, to: original.path)
        }

        // 剔除已撤回的条目。
        lock.lock()
        if batches.indices.contains(index), batches[index].id == batch.id {
            batches[index].items.removeAll { doneIDs.contains($0.from + "\u{1}" + $0.to) }
            if batches[index].items.isEmpty { batches.remove(at: index) }
        }
        try? persistLocked()
        lock.unlock()

        // 清掉本批新建、现在确实空了的目录（深的先删，父目录才有机会跟着空掉）。
        var removedDirectories: [URL] = []
        if summary.failed == 0 {
            for path in batch.createdDirectories.sorted(by: { $0.count > $1.count }) {
                let dir = URL(fileURLWithPath: path, isDirectory: true)
                guard RenameJournal.removeIfTrulyEmpty(dir) else { continue }
                removedDirectories.append(dir)
            }
        }

        summary.elapsed = Date().timeIntervalSince(started)
        return UndoOutcome(summary: summary,
                           restored: restored,
                           batchDate: batch.date,
                           batchKind: batch.kind,
                           removedDirectories: removedDirectories,
                           deletedCopies: deletedCopies)
    }

    /// 删掉一个**真正空**的目录。里面还有任何一项（含 `.DS_Store`）都不动，返回 false。
    ///
    /// 为什么连 `.DS_Store` 都不肯忽略：那是用户目录里的文件，
    /// 「顺手删一个看起来没用的文件」正是最容易出事的那种自作主张。
    @discardableResult
    static func removeIfTrulyEmpty(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty else { return false }
        return (try? fm.removeItem(at: dir)) != nil
    }

    // MARK: 落盘

    private func persistLocked() throws {
        let data = try Self.encode(batches)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 落盘编码口径（唯一一处）：带缩进、键排序、iso8601 日期。
    static func encode(_ batches: [RenameJournalBatch]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(batches)
    }

    /// 严格解码：解不开就抛（`load` 是容错版，解不开当空）。
    static func decodeStrict(_ data: Data) throws -> [RenameJournalBatch] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RenameJournalBatch].self, from: data)
    }

    private static func load(from url: URL) -> [RenameJournalBatch] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decodeStrict(data)) ?? []
    }
}

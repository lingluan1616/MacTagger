//
//  ImportService.swift
//  MacTagger — 文件导入与目录扫描
//
//  对应原版「添加文件 / 添加目录 / 管理目录」。过滤规则照原版规格实现：
//
//    1. 扩展名白名单（默认 17 项，可自定义、可一键还原默认）
//    2. 是否递归子目录
//    3. 按最短时长过滤（不过滤 / 10 / 20 / 30 / 40 / 50 / 60 秒）
//    4. 忽略 MP4 视频文件（不含音频轨，或本身就是视频容器）
//
//  纯 Swift + TagKit，不依赖 AppKit / AVFoundation：MP4 轨道类型靠自带的
//  ISO-BMFF box 走查判断，避免为一个开关引入整套 AVFoundation。
//

import Foundation

// MARK: - 选项

public struct ImportOptions: Sendable {

    /// 是否递归扫描子目录。
    public var includeSubdirectories: Bool

    /// 扩展名白名单（一律小写、不带点）。
    public var allowedExtensions: Set<String>

    /// 最短时长过滤，`nil` 表示不过滤。
    public var minimumDuration: TimeInterval?

    /// 忽略 MP4 视频文件（不含音频轨的、或视频容器扩展名且含视频轨的）。
    public var ignoreVideoMP4: Bool

    /// 读取并发度。本地 IO + TagLib 解析，默认 4。
    public var concurrency: Int

    public init(includeSubdirectories: Bool = true,
                allowedExtensions: Set<String> = ImportOptions.defaultExtensions,
                minimumDuration: TimeInterval? = nil,
                ignoreVideoMP4: Bool = true,
                concurrency: Int = 4) {
        self.includeSubdirectories = includeSubdirectories
        self.allowedExtensions = allowedExtensions
        self.minimumDuration = minimumDuration
        self.ignoreVideoMP4 = ignoreVideoMP4
        self.concurrency = max(1, concurrency)
    }

    public static var `default`: ImportOptions { ImportOptions() }

    /// 原版默认白名单，顺序即原版设置框中的顺序。
    public static let defaultExtensionList: [String] = [
        "aiff", "aif", "aifc", "ape", "dff", "dsf", "flac", "mpc", "mp3",
        "mp4", "m4a", "ogg", "opus", "wav", "wma", "wv", "tta"
    ]

    public static var defaultExtensions: Set<String> { Set(defaultExtensionList) }

    /// 原版「最短时长」下拉框的取值（`nil` = 不过滤）。
    public static let minimumDurationChoices: [TimeInterval?] = [nil, 10, 20, 30, 40, 50, 60]

    /// 还原默认白名单。
    public mutating func resetExtensionsToDefault() {
        allowedExtensions = ImportOptions.defaultExtensions
    }

    public var isExtensionListDefault: Bool {
        allowedExtensions == ImportOptions.defaultExtensions
    }

    /// 供设置界面显示/编辑的 `aiff,aif,...` 串（默认项保持原版顺序，自定义项追加在后）。
    public var extensionListString: String {
        let known = ImportOptions.defaultExtensionList.filter { allowedExtensions.contains($0) }
        let extra = allowedExtensions.subtracting(known).sorted()
        return (known + extra).joined(separator: ",")
    }

    /// 解析用户输入的扩展名串，容忍 `.mp3`、空格、分号、换行、大写。
    public static func parseExtensionList(_ raw: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: ",;、 \t\r\n|")
        let parts = raw.components(separatedBy: separators)
        var out = Set<String>()
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            if !t.isEmpty { out.insert(t) }
        }
        return out
    }

    /// 最短时长的中文描述（用于设置界面与日志）。
    public var minimumDurationDescription: String {
        guard let d = minimumDuration else { return "不过滤" }
        return "\(Int(d)) 秒"
    }
}

// MARK: - 结果

public struct ImportResult: Sendable {

    /// 成功读出的文件，顺序与扫描顺序一致。
    public var files: [AudioFile]

    /// 被规则挡掉的文件及原因（中文）。
    public var skipped: [(url: URL, reason: String)]

    /// 读取过程中出错的文件。
    public var failures: [(url: URL, error: TagError)]

    /// 任务被取消时为 true，此时结果是部分结果。
    public var isCancelled: Bool

    public init(files: [AudioFile] = [],
                skipped: [(url: URL, reason: String)] = [],
                failures: [(url: URL, error: TagError)] = [],
                isCancelled: Bool = false) {
        self.files = files
        self.skipped = skipped
        self.failures = failures
        self.isCancelled = isCancelled
    }

    /// 扫描到的候选总数（成功 + 忽略 + 失败）。
    public var total: Int { files.count + skipped.count + failures.count }

    /// 与原版批量结果同款文案。
    public var summary: String {
        "成功: \(files.count), 失败: \(failures.count), 忽略: \(skipped.count), 总共: \(total)"
    }

    /// 按原因归并的忽略统计，界面上可折叠展示。
    public var skipReasonCounts: [(reason: String, count: Int)] {
        var m: [String: Int] = [:]
        for s in skipped { m[s.reason, default: 0] += 1 }
        return m.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (reason: $0.key, count: $0.value) }
    }
}

// MARK: - 阶段一的产物

/// 枚举阶段认出的一个候选文件。
///
/// 大小与修改时间是**顺带**取的：目录枚举器已经按 `includingPropertiesForKeys`
/// 预取过这两项，从 `resourceValues` 读几乎不花钱，而列表的「大小 / 修改时间」两列
/// 正好只需要它们 —— 于是占位行一上来就不是空壳。
public struct EnumeratedFile: Sendable {
    public var url: URL
    public var fileSize: Int64
    public var modifiedAt: Date?

    public init(url: URL, fileSize: Int64 = 0, modifiedAt: Date? = nil) {
        self.url = url
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

/// 枚举阶段每 N 个文件吐一批。
public struct EnumerateBatch: Sendable {
    public var files: [EnumeratedFile]
    /// 零成本判掉的（隐藏文件 / 扩展名不在白名单 / 重复路径）。
    public var skipped: [(url: URL, reason: String)]
    /// 最后一批（枚举结束）。
    public var isFinal: Bool

    public init(files: [EnumeratedFile] = [],
                skipped: [(url: URL, reason: String)] = [],
                isFinal: Bool = false) {
        self.files = files
        self.skipped = skipped
        self.isFinal = isFinal
    }

    public var urls: [URL] { files.map(\.url) }
}

// MARK: - 导入服务

public enum ImportService {

    // MARK: 阶段一：只枚举，不读标签

    /// 只走目录树、只做**零成本**过滤（隐藏文件 / 扩展名白名单 / 重复路径），
    /// 每 `batchSize` 个文件 yield 一批。
    ///
    /// 时长过滤与「MP4 是不是视频」都必须打开文件才判得出来，因此**推迟到第二阶段**
    /// （`TagReader.drain`）执行；界面上这些行先以「待判定」的占位行出现，
    /// 读到标签后若被规则挡掉再从列表里撤下。
    ///
    /// - Note: 枚举在一条 detached 后台线程上**单线程**推进 —— 可移动卷上并发走目录
    ///         只会让主控来回寻道，反而更慢。
    /// - Note: 支持取消：`Task` 取消或调用方提前结束遍历，都会让枚举线程停下来。
    public static func enumerate(urls: [URL],
                                 options: ImportOptions,
                                 batchSize: Int = 200) -> AsyncThrowingStream<EnumerateBatch, Error> {

        AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                var batch: [EnumeratedFile] = []
                var skipped: [(url: URL, reason: String)] = []
                var seen = Set<String>()
                batch.reserveCapacity(batchSize)

                func flush(final: Bool) {
                    guard final || !batch.isEmpty || !skipped.isEmpty else { return }
                    continuation.yield(EnumerateBatch(files: batch, skipped: skipped, isFinal: final))
                    batch.removeAll(keepingCapacity: true)
                    skipped.removeAll(keepingCapacity: true)
                }

                /// 一个候选文件过完零成本规则后落进本批。
                func take(_ url: URL, _ values: URLResourceValues?) {
                    var candidates: [URL] = []
                    consider(file: url, into: &candidates, seen: &seen,
                             skipped: &skipped, options: options)
                    guard let kept = candidates.first else { return }
                    batch.append(EnumeratedFile(
                        url: kept,
                        fileSize: Int64(values?.fileSize ?? 0),
                        modifiedAt: values?.contentModificationDate))
                    if batch.count >= batchSize { flush(final: false) }
                }

                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                              .contentModificationDateKey]
                var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles,
                                                                     .skipsPackageDescendants]
                if !options.includeSubdirectories { opts.insert(.skipsSubdirectoryDescendants) }

                for root in urls {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
                        skipped.append((root, "路径不存在"))
                        continue
                    }
                    if isDir.boolValue {
                        guard let e = FileManager.default.enumerator(
                            at: root, includingPropertiesForKeys: keys, options: opts) else {
                            skipped.append((root, "目录无法枚举"))
                            continue
                        }
                        for case let url as URL in e {
                            if Task.isCancelled {
                                flush(final: true)
                                continuation.finish(throwing: CancellationError())
                                return
                            }
                            let values = try? url.resourceValues(forKeys: Set(keys))
                            guard values?.isRegularFile == true else { continue }
                            take(url, values)
                        }
                    } else {
                        take(root, try? root.resourceValues(forKeys: Set(keys)))
                    }
                }
                flush(final: true)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: 一步到位（旧路径，probe 与小批量仍在用）

    /// 扫描给定的文件/目录，读出全部标签。
    ///
    /// - Parameters:
    ///   - urls: 文件或目录混合列表。
    ///   - options: 过滤规则。
    ///   - progress: `(已完成, 总数)`，在读取阶段回调；总数在枚举完成后才确定，
    ///               枚举阶段会先回调一次 `(0, 候选数)`。
    /// - Note: 支持 `Task` 取消；取消后返回**部分结果**且 `isCancelled == true`。
    public static func scan(urls: [URL],
                            options: ImportOptions,
                            progress: (@Sendable (Int, Int) -> Void)?) async -> ImportResult {

        var result = ImportResult()

        // ---- ① 枚举 ----
        var candidates: [URL] = []
        var seen = Set<String>()

        for root in urls {
            if Task.isCancelled { result.isCancelled = true; break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
                result.failures.append((root, .fileNotFound(root.path)))
                continue
            }
            if isDir.boolValue {
                enumerate(directory: root,
                          recursive: options.includeSubdirectories,
                          into: &candidates,
                          seen: &seen,
                          skipped: &result.skipped,
                          options: options)
            } else {
                consider(file: root, into: &candidates, seen: &seen,
                         skipped: &result.skipped, options: options)
            }
        }

        let total = candidates.count
        progress?(0, total)
        if result.isCancelled || total == 0 { return result }

        // ---- ② 读取（有序并发） ----
        let counter = ProgressCounter(total: total, callback: progress)
        let outcomes = await ConcurrentWork.orderedMap(candidates,
                                                       concurrency: options.concurrency) { url in
            let outcome = readOne(url, options: options)
            counter.advance(url.path)
            return outcome
        }

        for (url, outcome) in zip(candidates, outcomes) {
            switch outcome {
            case .ok(let f):        result.files.append(f)
            case .skip(let reason): result.skipped.append((url, reason))
            case .fail(let e):      result.failures.append((url, e))
            case .cancelled:        result.isCancelled = true
            case .none:             result.isCancelled = true   // 取消导致未执行
            }
        }
        if Task.isCancelled { result.isCancelled = true }
        return result
    }

    /// 只枚举、不读标签。给「管理目录」里预估文件数用，很快。
    public static func enumerateCandidates(urls: [URL], options: ImportOptions) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        var skipped: [(url: URL, reason: String)] = []
        for root in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                enumerate(directory: root, recursive: options.includeSubdirectories,
                          into: &out, seen: &seen, skipped: &skipped, options: options)
            } else {
                consider(file: root, into: &out, seen: &seen, skipped: &skipped, options: options)
            }
        }
        return out
    }

    // MARK: - 内部

    enum FileOutcome: Sendable {
        case ok(AudioFile)
        case skip(String)
        case fail(TagError)
        case cancelled
    }

    private static func enumerate(directory: URL,
                                  recursive: Bool,
                                  into candidates: inout [URL],
                                  seen: inout Set<String>,
                                  skipped: inout [(url: URL, reason: String)],
                                  options: ImportOptions) {
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles,
                                                             .skipsPackageDescendants]
        if !recursive { opts.insert(.skipsSubdirectoryDescendants) }

        guard let e = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: opts) else {
            skipped.append((directory, "目录无法枚举"))
            return
        }
        for case let url as URL in e {
            if Task.isCancelled { return }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            consider(file: url, into: &candidates, seen: &seen, skipped: &skipped, options: options)
        }
    }

    /// 扩展名/隐藏文件这类**零成本**判断在枚举阶段做掉，避免进读取队列。
    private static func consider(file url: URL,
                                 into candidates: inout [URL],
                                 seen: inout Set<String>,
                                 skipped: inout [(url: URL, reason: String)],
                                 options: ImportOptions) {
        let name = url.lastPathComponent
        // macOS 在非 HFS 卷上生成的资源分支伴生文件，内容不是音频。
        if name.hasPrefix("._") {
            skipped.append((url, "资源分支伴生文件")); return
        }
        if name.hasPrefix(".") {
            skipped.append((url, "隐藏文件")); return
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, options.allowedExtensions.contains(ext) else {
            skipped.append((url, "扩展名不在白名单"))
            return
        }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard seen.insert(key).inserted else {
            skipped.append((url, "重复路径"))
            return
        }
        candidates.append(url)
    }

    /// 需要打开文件的判断（MP4 轨道、时长、标签读取）在这里做。
    ///
    /// 一步到位的 `scan` 与两段式的 `TagReader.drain` 共用同一段逻辑，
    /// 保证「哪些文件会被忽略」两条路径给出的答案一模一样。
    static func readOne(_ url: URL, options: ImportOptions) -> FileOutcome {
        if Task.isCancelled { return .cancelled }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size == 0 { return .skip("空文件") }

        let ext = url.pathExtension.lowercased()
        if options.ignoreVideoMP4, MP4Inspector.isISOContainer(extension: ext) {
            switch MP4Inspector.classify(url) {
            case .noAudioTrack:  return .skip("MP4 不含音频轨")
            case .videoFile:     return .skip("MP4 视频文件（含视频轨）")
            case .audioOnly, .unknown: break
            }
        }

        let file: AudioFile
        do { file = try TagService.read(url) }
        catch let e as TagError { return .fail(e) }
        catch { return .fail(.unknown(error.localizedDescription)) }

        if let minimum = options.minimumDuration {
            let d = file.technical.duration
            // 时长读不出来（0）时放行，宁可多收也别误杀。
            if d > 0 && d < minimum {
                return .skip(String(format: "时长 %.1f 秒 < 最短 %.0f 秒", d, minimum))
            }
        }
        return .ok(file)
    }
}

// MARK: - 进度计数（线程安全）

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let callback: (@Sendable (Int, Int) -> Void)?

    init(total: Int, callback: (@Sendable (Int, Int) -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func advance(_ path: String? = nil) {
        lock.lock(); done += 1; let d = done; lock.unlock()
        callback?(d, total)
    }
}

// MARK: - 有序并发工具（ImportService / BatchEngine 共用）

enum ConcurrentWork {

    /// 以固定并发度跑完 `items`，**按输入顺序**返回结果。
    /// 任务取消时已排队但未执行的项不会执行，返回数组长度仍等于输入长度
    /// （未执行的位置由 `fallback` 补齐）。
    static func orderedMap<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        concurrency: Int,
        _ body: @escaping @Sendable (Input) -> Output
    ) async -> [Output?] {
        if items.isEmpty { return [] }
        let width = max(1, min(concurrency, items.count))
        var results = [Output?](repeating: nil, count: items.count)

        await withTaskGroup(of: (Int, Output?).self) { group in
            var next = 0
            func submit(_ i: Int) {
                let item = items[i]
                group.addTask {
                    if Task.isCancelled { return (i, nil) }
                    return (i, body(item))
                }
            }
            while next < width { submit(next); next += 1 }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < items.count && !Task.isCancelled {
                    submit(next); next += 1
                }
            }
        }
        return results
    }
}

// MARK: - MP4 / ISO-BMFF 轨道类型判定

enum MP4Inspector {

    enum Classification: Sendable {
        case audioOnly
        case videoFile
        case noAudioTrack
        case unknown        // 解析失败，交给 TagLib 定夺
    }

    /// 视频味道更重的容器扩展名：这些扩展名下发现视频轨即判为视频文件。
    private static let videoish: Set<String> = ["mp4", "m4v", "mov", "qt"]
    private static let isoish: Set<String> = ["mp4", "m4a", "m4b", "m4p", "m4v", "mov", "qt", "3gp"]

    static func isISOContainer(extension ext: String) -> Bool { isoish.contains(ext) }

    static func classify(_ url: URL) -> Classification {
        guard let handlers = handlerTypes(at: url) else { return .unknown }
        if handlers.isEmpty { return .unknown }
        let hasAudio = handlers.contains("soun")
        let hasVideo = handlers.contains("vide")
        if !hasAudio { return .noAudioTrack }
        let ext = url.pathExtension.lowercased()
        if hasVideo && videoish.contains(ext) { return .videoFile }
        return .audioOnly
    }

    /// 走查 `moov → trak → mdia → hdlr`，收集 handler_type（`soun` / `vide` / `text` …）。
    /// 返回 nil 表示不是可解析的 ISO-BMFF。
    static func handlerTypes(at url: URL) -> Set<String>? {
        guard let fh = try? FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? fh.close() }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 16 else { return nil }

        var offset: UInt64 = 0
        var sawTopLevelBox = false
        // 顶层 box 走查，只找 moov。
        while offset + 8 <= UInt64(fileSize) {
            guard let header = read(fh, at: offset, count: 8), header.count == 8 else { break }
            var size = UInt64(be32(header, 0))
            let type = fourCC(header, 4)
            guard isPlausibleType(type) else { break }
            sawTopLevelBox = true
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let ext = read(fh, at: offset + 8, count: 8), ext.count == 8 else { break }
                size = be64(ext, 0)
                headerSize = 16
            } else if size == 0 {
                size = UInt64(fileSize) - offset
            }
            guard size >= headerSize, offset + size <= UInt64(fileSize) else { break }

            if type == "moov" {
                let payloadLen = size - headerSize
                // moov 一般 < 几 MB；设 64 MB 上限防御畸形文件。
                guard payloadLen <= 64 * 1024 * 1024,
                      let body = read(fh, at: offset + headerSize, count: Int(payloadLen)) else {
                    return nil
                }
                var found = Set<String>()
                collectHandlers(in: body, into: &found, depth: 0)
                return found
            }
            offset += size
        }
        return sawTopLevelBox ? Set<String>() : nil
    }

    // 需要下钻的容器 box。
    private static let containers: Set<String> = ["trak", "mdia", "minf", "stbl", "edts",
                                                  "moov", "udta", "mvex"]

    private static func collectHandlers(in data: Data, into found: inout Set<String>, depth: Int) {
        if depth > 8 { return }
        var i = 0
        let n = data.count
        while i + 8 <= n {
            var size = Int(be32(data, i))
            let type = fourCC(data, i + 4)
            guard isPlausibleType(type) else { return }
            var headerSize = 8
            if size == 1 {
                guard i + 16 <= n else { return }
                let big = be64(data, i + 8)
                guard big <= UInt64(Int.max) else { return }
                size = Int(big)
                headerSize = 16
            } else if size == 0 {
                size = n - i
            }
            guard size >= headerSize, i + size <= n else { return }

            if type == "hdlr" {
                // hdlr payload: version/flags(4) pre_defined(4) handler_type(4)
                let p = i + headerSize
                if p + 12 <= n { found.insert(fourCC(data, p + 8)) }
            } else if containers.contains(type) {
                let sub = data.subdata(in: (i + headerSize)..<(i + size))
                collectHandlers(in: sub, into: &found, depth: depth + 1)
            }
            i += size
        }
    }

    // MARK: 字节工具

    private static func read(_ fh: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return nil }
        do {
            try fh.seek(toOffset: offset)
            return try fh.read(upToCount: count)
        } catch { return nil }
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        guard b + 4 <= d.endIndex else { return 0 }
        return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16)
             | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    }

    private static func be64(_ d: Data, _ i: Int) -> UInt64 {
        let b = d.startIndex + i
        guard b + 8 <= d.endIndex else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(d[b + k]) }
        return v
    }

    private static func fourCC(_ d: Data, _ i: Int) -> String {
        let b = d.startIndex + i
        guard b + 4 <= d.endIndex else { return "" }
        let bytes = [d[b], d[b + 1], d[b + 2], d[b + 3]]
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// box 类型必须是 4 个可打印 ASCII（`©nam` 这类版权符号也放行）。
    private static func isPlausibleType(_ s: String) -> Bool {
        guard s.utf16.count == 4 else { return false }
        for u in s.unicodeScalars {
            let v = u.value
            if !((v >= 0x20 && v <= 0x7E) || v == 0xA9) { return false }
        }
        return true
    }
}

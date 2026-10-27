//
//  TagReadQueue.swift
//  MacTagger — 标签读取队列（两段式导入的第二阶段）
//
//  为什么要单独一个队列：
//
//  「添加目录」原先是**枚举 + 逐个读标签一步到位**，3 万首在 TF 卡上要等好几分钟，
//  期间列表空白且无法取消。拆成两段之后：
//
//    阶段一 `ImportService.enumerate` —— 只走目录、只看扩展名，边走边上表；
//    阶段二 本文件 —— 后台按需读标签，读到一批就换掉表里的占位行。
//
//  队列要满足三件事：
//
//  1. **可插队**：界面把当前可见的行送进来（`prioritize`），它们要排到最前面 ——
//     用户盯着哪一屏，哪一屏先出标签，这是「感觉快」的关键。
//  2. **可取消**：`Task` 一取消立刻停，已读的保留，没读的仍是待读状态，随时能续。
//  3. **按介质定并发**：TF 卡 / U 盘主控缓存小，并发只会互相拖慢（与 `WritePacer`
//     同一个结论，见 research/X- 报告），所以可移动卷 1–2 条、内置卷 4 条。
//
//  队列本身用 NSLock 保护，不用 actor：TagLib 读取是**阻塞式**磁盘 IO，
//  放进 actor 会把整个 actor 占住，反而串行化了本该并发的读取。
//

import Foundation

// MARK: - 一批读取结果

/// 一次回调交付的一批标签。三个数组互斥：读成功 / 被规则挡掉 / 读失败。
public struct TagReadBatch: Sendable {

    /// 读成功的文件。
    public var files: [AudioFile]
    /// 第二阶段才判定得出的忽略项（时长过滤、MP4 无音频轨、空文件）。
    public var skipped: [(url: URL, reason: String)]
    /// 读取出错的文件。
    public var failures: [(url: URL, error: TagError)]

    public init(files: [AudioFile] = [],
                skipped: [(url: URL, reason: String)] = [],
                failures: [(url: URL, error: TagError)] = []) {
        self.files = files
        self.skipped = skipped
        self.failures = failures
    }

    /// 本批处理掉的文件总数（三类相加）。
    public var count: Int { files.count + skipped.count + failures.count }

    public var isEmpty: Bool { count == 0 }
}

// MARK: - 可插队的待读队列

/// 线程安全的待读 URL 队列，支持把「可见行」插到最前面。
///
/// 内部两条队列：
/// - `priority`：界面送进来的可见行，**后来的排更前**（用户最新看的那一屏最要紧）；
/// - `normal`：全量顺序队列，用游标推进，不做 `removeFirst`（那是 O(n)）。
///
/// `dispatched` 记录已经派发出去的路径，保证同一个文件不会被两条队列各读一遍。
public final class TagReadQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var normal: [URL]
    private var cursor: Int = 0
    private var priority: [URL] = []
    /// 已派发（不论是否已完成）的路径。
    private var dispatched = Set<String>()
    /// 还没派发的数量，`remainingCount` 直接读它，避免每次扫数组。
    private var remaining: Int

    public init(_ urls: [URL] = []) {
        normal = urls
        remaining = urls.count
    }

    /// 队列里还没派发出去的数量。
    public var remainingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return remaining
    }

    /// 插队队列里还剩多少（按需模式靠它判断该不该收工）。
    public var priorityCount: Int {
        lock.lock(); defer { lock.unlock() }
        return priority.count
    }

    /// 整队重来（「继续读取标签」用：拿当前还是待读状态的行重建）。
    public func reset(with urls: [URL]) {
        lock.lock()
        normal = urls
        cursor = 0
        priority.removeAll()
        dispatched.removeAll()
        remaining = urls.count
        lock.unlock()
    }

    /// 追加到普通队列末尾（阶段一边枚举边喂给阶段二）。
    public func append(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        lock.lock()
        normal.append(contentsOf: urls)
        remaining += urls.count
        lock.unlock()
    }

    /// 把这些 URL 插到最前面。已经派发过的会被忽略。
    ///
    /// 新来的一批整体排在上一批插队之前 —— 用户滚到哪儿，哪儿最新最要紧。
    public func prioritize(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        lock.lock()
        let fresh = urls.filter { !dispatched.contains($0.path) }
        if !fresh.isEmpty { priority.insert(contentsOf: fresh, at: 0) }
        lock.unlock()
    }

    /// 取下一个待读 URL。
    /// - Parameter priorityOnly: true = 只吃插队队列（按需模式），空了就返回 nil 收工。
    public func next(priorityOnly: Bool) -> URL? {
        lock.lock(); defer { lock.unlock() }
        while !priority.isEmpty {
            let url = priority.removeFirst()
            if dispatched.insert(url.path).inserted {
                remaining -= 1
                return url
            }
        }
        if priorityOnly { return nil }
        while cursor < normal.count {
            let url = normal[cursor]
            cursor += 1
            if dispatched.insert(url.path).inserted {
                remaining -= 1
                return url
            }
        }
        return nil
    }

    /// 一次取一小撮，减少锁竞争。
    public func nextChunk(_ n: Int, priorityOnly: Bool) -> [URL] {
        var out: [URL] = []
        out.reserveCapacity(n)
        // 插队队列必须**一个一个**取：取到一半可能又有新的插进来，
        // 那时应当立刻回到最前面。所以插队模式下一次只给 1 个的整数倍。
        let want = priorityOnly ? min(n, 4) : n
        while out.count < want, let u = next(priorityOnly: priorityOnly) { out.append(u) }
        return out
    }
}

// MARK: - 让出节流

/// 「已读多少首」的全局计数器，`TagReader.drain` 的让出节流用。
///
/// 可移动卷上的大目录改成**低速后台读**（不再「只列不读」）之后，
/// 需要一个口子定期把执行权交出去：交给 MainActor 上的刷表、也交给卡的主控喘口气。
/// 计数是全局的（不是每条 worker 各数各的），所以「每 200 首」说的就是真的 200 首。
private final class ReadPaceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let step: Int

    init(step: Int) { self.step = step }

    /// 记上这一批，返回**是否跨过了一个 `step` 边界**（跨过就该让出一次）。
    func add(_ n: Int) -> Bool {
        guard step > 0, n > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        let before = count / step
        count += n
        return count / step > before
    }
}

// MARK: - 读取驱动

public enum TagReader {

    /// 按介质给并发度：可移动 / 外置 / 网络卷 2 条，内置卷 4 条。
    ///
    /// 与 `BatchEngine.recommendedConcurrency` 同一个判据（`VolumeInfo.isSlowMedia`），
    /// 区别是读取比写入轻，可移动卷上给到 2 而不是 1。
    public static func recommendedConcurrency(for urls: [URL]) -> Int {
        VolumeInfo.containsRemovable(Array(urls.prefix(8))) ? 2 : 4
    }

    /// 可移动卷上大目录的**低速后台读**：每这么多首让出一次。0 = 不节流（内置卷）。
    ///
    /// 为什么要有它：原先「可移动卷上的大目录干脆不自动读」，用户滚到哪读到哪 ——
    /// 结果是表上长期挂着一片「读取中…」。改成照读，但读得慢一点：
    /// 并发 2（见 `recommendedConcurrency`）+ 每 200 首让出一次，
    /// 既不会把 TF 卡的主控打满，也不会让主线程的刷表排在几百次阻塞读之后。
    public static let removableYieldStep = 200

    /// 这批文件要不要节流；返回 `drain(yieldEvery:)` 该传的值。
    public static func recommendedYieldEvery(for urls: [URL]) -> Int {
        VolumeInfo.containsRemovable(Array(urls.prefix(8))) ? removableYieldStep : 0
    }

    /// 让出时顺带歇一小口气。600 首也只歇 3 次共 30 ms，可以忽略不计，
    /// 但足以让卡的主控把队列里的请求排空，实测比纯 `Task.yield()` 稳。
    private static let yieldBreath: Duration = .milliseconds(10)

    /// 排空队列。每读完 `chunkSize` 个文件回调一次 `onBatch`。
    ///
    /// - Parameters:
    ///   - queue: 待读队列，可以在读取过程中继续 `append` / `prioritize`。
    ///   - options: 过滤规则（时长 / MP4 视频判定在这一阶段才生效）。
    ///   - concurrency: 并发度，见 `recommendedConcurrency`。
    ///   - priorityOnly: true = 只读插队队列，读完就返回（界面「按需读取」模式）。
    ///   - chunkSize: 每批多少个文件回调一次。
    ///   - yieldEvery: 每读这么多首让出一次执行权（0 = 不让，内置卷用）。见 `recommendedYieldEvery`。
    ///   - onBatch: 任意线程回调，调用方自行切回主线程。
    /// - Note: 支持 `Task` 取消 —— 取消后**已读完的那一批仍会回调**，未读的留在队列里。
    public static func drain(queue: TagReadQueue,
                             options: ImportOptions,
                             concurrency: Int,
                             priorityOnly: Bool = false,
                             chunkSize: Int = 24,
                             yieldEvery: Int = 0,
                             onBatch: @escaping @Sendable (TagReadBatch) -> Void) async {

        let width = max(1, concurrency)
        let pace = ReadPaceCounter(step: yieldEvery)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<width {
                group.addTask {
                    while !Task.isCancelled {
                        let chunk = queue.nextChunk(chunkSize, priorityOnly: priorityOnly)
                        if chunk.isEmpty { return }
                        var batch = TagReadBatch()
                        for url in chunk {
                            if Task.isCancelled { break }
                            switch ImportService.readOne(url, options: options) {
                            case .ok(let f):        batch.files.append(f)
                            case .skip(let r):      batch.skipped.append((url, r))
                            case .fail(let e):      batch.failures.append((url, e))
                            case .cancelled:        break
                            }
                        }
                        // 取消时也把已读的这几个交出去，用户看到的进度才是真的。
                        if !batch.isEmpty { onBatch(batch) }
                        // 插队队列（= 用户正看的那一屏）不节流：它要的就是「立刻」。
                        if !priorityOnly, pace.add(chunk.count) {
                            await Task.yield()
                            try? await Task.sleep(for: yieldBreath)
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }
}

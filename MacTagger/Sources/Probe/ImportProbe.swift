//
//  ImportProbe.swift
//  mactagger-probe — 两段式导入（阈值 + 可取消 + 懒加载）实测
//
//    import2 <dir> [--threshold N] [--cancel-after-ms N] [--concurrency N] [--batch N]
//            [--min-duration N] [--visible N] [--no-visible] [--race]
//            [--auto-read auto|always|never] [--restore] [--leading N] [--priority-check]
//            [--no-read] [--resume] [--materialize] [--quiet]
//
//  量什么：
//    ① 阶段一（`ImportService.enumerate`）每一批到达主线程的时刻 —— 「多久能看见列表」
//    ② 阶段二（`TagReader.drain`）的读取吞吐（首/秒）
//    ③ `--cancel-after-ms` 下取消的**生效延迟**，以及取消后「已列出 / 已读取 / 未读取」三数
//    ④ 全程主线程心跳（50 ms），最大停顿 = 界面被卡住的最长时间
//    ⑤ **`--threshold`**：≤ 阈值走「直接路径」（后台一次读完再整表上屏），
//       > 阈值走两段式。断言「表第一次出现时标签齐不齐」
//    ⑥ **最终态断言**：结束时 `pending` / `loaded` 各是多少、
//       `displayRows` 里还有没有待读行、**最后一次刷表是不是在最后一次读完之后**
//    ⑦ **`--auto-read`**：复刻 `AppModel.shouldAutoReadTags(listed:direct:)`。
//       阈值优先于卷类型 —— ≤ 阈值的目录**在可移动卷上也**一次读完再显示，
//       `never` 是唯一例外；> 阈值的目录在可移动卷上照读，只是并发 2 + 每 200 首让出一次。
//    ⑧ **`--priority-check`**：量「上表 → 前 80 行全部读到标签」的耗时（目标 ≤ 1 s）。
//       这是「用户打开任何目录，屏幕上看得到的行 1 秒内有标签」那条要求的口径。
//
//  为什么要在 probe 里复刻主线程：`Sources/Probe` 是 `type: tool`，看不见 `Sources/App`，
//  所以这里按 `AppModel` 的做法逐句复刻了它在主线程上干的活 —— 包括 `allRows` /
//  `displayRows` 两张表与它们各自的索引、250 ms 攒批、收尾必刷、可见行插队，
//  以及 `finishListing` 结束时那次「欠着的全量读取交接」。调度方式（后台枚举 /
//  后台读取 / 主线程只做数组操作）与 App 完全一致，所以这里量到的心跳就是界面的流畅度，
//  这里的最终态就是用户在表上看到的最终态。
//

import Foundation

// MARK: - 主线程心跳

/// 相邻两次触发的最大间隔 = 主线程被占住的最长时间。
private final class Import2Heartbeat {
    private var timer: Timer?
    private var last = Date()
    private(set) var maxGap: Double = 0
    private(set) var ticks = 0
    private(set) var stalls: [Double] = []
    let interval: Double

    init(interval: Double = 0.05) { self.interval = interval }

    func start() {
        last = Date()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.last)
            self.last = now
            self.ticks += 1
            if gap > self.maxGap { self.maxGap = gap }
            if gap > self.interval * 2 { self.stalls.append(gap) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - 主线程上的行（`FileRow` 的等价替身）

/// probe 看不见 `Sources/App`，这里复刻 `FileRow` 在主线程上的那部分开销：
/// 占位行只带枚举顺带取到的大小 / 修改时间，读到标签后整行换掉。
struct Import2Row {
    var url: URL
    var fileSize: Int64
    var modifiedAt: Date?
    var isPending: Bool
    var isFailed = false
    var title: String?
    var artist: String?
    var durationMS: Int
}

/// 跨线程持有两个阶段的任务，供定时取消用。
///
/// 只在主线程上读写（工作全在 `@MainActor` 上，取消定时器也派到主队列），
/// 所以不上锁，`@unchecked Sendable` 是对「就这一条线程」的声明。
private final class Import2Runner: @unchecked Sendable {
    var phase1: Task<Void, Never>?
    var phase2: Task<Void, Never>?
    /// `Task` 是值类型，比不了身份，用运行号认「这条收尾属不属于当前这一轮」。
    var phase2RunID = 0
    var cancelRequestedAt: Date?
    var cancelObservedAt: Date?
    /// 取消命中了哪个阶段（1 / 2 / 0 = 没赶上）。
    var cancelledPhase = 0
    /// 读取部分收工了（阶段二结束 / 压根没起）。续读与兜底还可能在后面。
    var done = false
    /// **整条流程**都收工了。底下那个 RunLoop 泵靠它决定还要不要转 ——
    /// 只认 `done` 的话，`--resume` / `--materialize` 会在收尾 0.4 s 里被掐断。
    var allDone = false
}

// MARK: - 子命令

func cmdImport2(_ dirPath: String, args: [String]) {

    let dir = URL(fileURLWithPath: dirPath)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
        fail("目录不存在：\(dir.path)")
    }

    func intArg(_ flag: String) -> Int? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }
    func strArg(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let cancelAfterMS = intArg("--cancel-after-ms")
    let batchSize = intArg("--batch") ?? 200
    let noRead = args.contains("--no-read")
    /// 取消之后再走一遍「继续读取标签」（= App 右键菜单的 resumeTagRead）。
    let resume = args.contains("--resume")
    /// 取消之后按「批量操作前的同步兜底」补读（= `AppModel.materializePendingTags(in:)`，
    /// 保存标签 / 清除标签 / 自动匹配 / **下载歌词** 四条批量入口开工前走的就是这一条）。
    let materialize = args.contains("--materialize")
    // 时长过滤：验证「必须打开文件才判得出的规则推迟到第二阶段生效」。
    let minDuration = intArg("--min-duration")
    let quiet = args.contains("--quiet")
    /// 直接路径的门槛。默认取 App 的出厂值 500；0 = 总是两段式。
    let threshold = intArg("--threshold") ?? 500
    /// 模拟界面「一屏能看见多少行」——这些行会走 `noteRowVisible` → 插队队列。
    let visibleWindow = intArg("--visible") ?? 30
    let simulateVisible = !args.contains("--no-visible")
    /// 死磕根因的那一组：**强行**制造「阶段一结束时按需任务正在跑」。
    let race = args.contains("--race")
    /// 把修复关掉（不做交接），用来证明上面那一组断言真的抓得住这个 bug。
    let noHandover = args.contains("--no-handover")
    /// = `AppSettings.autoReadTags` 三档。
    let autoReadMode = (strArg("--auto-read") ?? "auto").lowercased()
    /// = `AppModel.importIsRestore`（启动「接着上次」那条路）。
    let isRestore = args.contains("--restore")
    /// = `AppModel.leadingPriorityRows`：导入结束后立刻排到队首的行数。
    let leadingRows = intArg("--leading") ?? 80
    /// 量「上表 → 前 leadingRows 行全部读到标签」的耗时。
    let priorityCheck = args.contains("--priority-check")

    guard ["auto", "always", "never"].contains(autoReadMode) else {
        fail("--auto-read 只能是 auto / always / never，收到：\(autoReadMode)")
    }

    let traits = VolumeInfo.traits(of: dir)
    let concurrency = intArg("--concurrency") ?? TagReader.recommendedConcurrency(for: [dir])
    /// = `TagReader.recommendedYieldEvery`：可移动卷上的全量读取每 200 首让出一次。
    let yieldEvery = TagReader.recommendedYieldEvery(for: [dir])

    /// = `AppModel.shouldAutoReadTags(listed:direct:)`。**阈值优先于卷类型**。
    func shouldAutoRead(listed: Int, direct: Bool) -> Bool {
        switch autoReadMode {
        case "always": return true
        case "never":  return false
        default:
            if direct { return true }          // ≤ 阈值：任何卷都读完再显示
            if isRestore && listed > 2000 { return false }
            return true                        // 可移动卷不再「只列不读」，改为低速后台读
        }
    }

    hr("两段式导入实测")
    out("目录        : \(dir.path)")
    out("卷          : \(traits.summary)")
    out("懒加载阈值  : \(threshold)" + (threshold == 0 ? "（0 = 总是两段式）"
                                                     : "（≤ \(threshold) 首走直接路径）"))
    out("自动读标签  : \(autoReadMode)" + (isRestore ? "（--restore：启动恢复路径）" : ""))
    out("  ≤ 阈值时  : " + (shouldAutoRead(listed: 1, direct: true)
                            ? "读（阈值优先于卷类型，可移动卷上也一次读完再显示）"
                            : "不读（「从不」是唯一例外）"))
    out("  > 阈值时  : " + (shouldAutoRead(listed: 999_999, direct: false)
                            ? "读（后台全量" + (yieldEvery > 0 ? "，每 \(yieldEvery) 首让出一次）" : "）")
                            : "不读（只列文件 + 按需）"))
    out("阶段一批大小: \(batchSize) 个/批")
    out("阶段二并发  : \(concurrency) 条" + (traits.isSlowMedia ? "（可移动/外置卷）" : "（内置本地卷）"))
    out("让出节流    : " + (yieldEvery > 0 ? "每 \(yieldEvery) 首让出一次（可移动/外置卷）"
                                          : "关（内置本地卷，全速读）"))
    out("前 N 行优先 : \(leadingRows) 行（导入结束立刻排到队首）"
        + (priorityCheck ? " · --priority-check：量「上表 → 前 \(leadingRows) 行全读到」" : ""))
    out("可见行模拟  : " + (simulateVisible ? "开，一屏 \(visibleWindow) 行（onAppear → 插队）" : "关"))
    if race { out("竞态组      : --race，强行让按需任务与阶段一结束重叠") }
    if noHandover { out("修复开关    : --no-handover，**关掉**全量读取交接（复现修复前的行为）") }
    if let ms = cancelAfterMS { out("取消计划    : 开始后 \(ms) ms") }
    if materialize { out("取消后      : 走一遍 materializePendingTags（批量入口的同步兜底）") }
    if noRead { out("阶段二      : 跳过（--no-read）") }

    var options = ImportOptions.default
    if let d = minDuration {
        options.minimumDuration = TimeInterval(d)
        out("时长过滤    : ≥ \(d) 秒（第二阶段才判得出，命中的行读到标签后从列表撤下）")
    }
    let runner = Import2Runner()
    let beat = Import2Heartbeat(interval: 0.05)
    let t0 = Date()
    func ms(_ from: Date = Date()) -> Double { from.timeIntervalSince(t0) * 1000 }
    func stamp() -> String { String(format: "%8.0fms", ms()) }

    // ---- 主线程状态（= App 的 allRows / displayRows / 两张索引 / 三个计数）
    var rows: [Import2Row] = []            // = allRows
    var index: [URL: Int] = [:]            // = allIndex
    var displayRows: [Import2Row] = []     // = displayRows（Table 的数据源）
    var displayIndex: [URL: Int] = [:]
    var pending = 0
    var loaded = 0
    var skippedPhase1 = 0
    var skippedPhase2 = 0
    var failedPhase2 = 0

    // ---- 观测点
    var batchStamps: [(seq: Int, at: Double, count: Int, total: Int)] = []
    var phase1End: Double = 0
    var phase1Cancelled = false
    var flushStamps: [(at: Double, loaded: Int)] = []
    var phase2Start: Double = 0
    var phase2End: Double = 0
    var dropReasons: [(String, Int)] = []
    var atCancel: (listed: Int, loaded: Int, unread: Int)?
    /// 走的是不是直接路径。
    var usedDirect = threshold > 0
    /// `displayRows` **第一次**非空的时刻，以及那一刻里已读标签的行数。
    var firstAppearAt: Double?
    var firstAppearTotal = 0
    var firstAppearLoaded = 0
    /// 前 `leadingRows` 行**全部**读到标签的时刻（= 用户「一眼看得到的那一屏」齐了）。
    var leadingDoneAt: Double?
    /// 全量读取（`priorityOnly == false`）到底有没有起过。`never` 档断言用它。
    var fullReadStarted = false
    /// 直接路径上到底读没读标签（`--auto-read never` 会让它保持 false）。
    var directTagsRead = false
    /// 最后一次 `onBatch` 到达 / 最后一次真正刷表的时刻。
    var lastReadAt: Date?
    var lastFlushAt: Date?
    var flushCount = 0
    /// 「阶段一结束时按需任务还在跑」这件事有没有发生过。
    var sawOverlap = false
    var events: [String] = []
    func ev(_ s: String) { events.append("  [\(stamp())] \(s)") }

    // ---- 复刻 AppModel 的表维护
    func reindex() {
        index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.url, $0.offset) })
        displayIndex = Dictionary(uniqueKeysWithValues:
            displayRows.enumerated().map { ($0.element.url, $0.offset) })
    }
    /// = `AppModel.rebuildDisplay()`。没有过滤词时就是整表复制 + 重排索引。
    func rebuildDisplay() {
        displayRows = rows
        reindex()
        noteFirstAppear()
        noteLeadingDone()
    }
    func noteFirstAppear() {
        guard firstAppearAt == nil, !displayRows.isEmpty else { return }
        firstAppearAt = ms()
        firstAppearTotal = displayRows.count
        firstAppearLoaded = displayRows.reduce(0) { $0 + ($1.isPending ? 0 : 1) }
    }
    /// 前 `leadingRows` 行是不是全读到了。只认第一次，之后不再改。
    func noteLeadingDone() {
        guard leadingDoneAt == nil, !displayRows.isEmpty else { return }
        let n = min(leadingRows, displayRows.count)
        for i in 0..<n where displayRows[i].isPending { return }
        leadingDoneAt = ms()
    }
    func recount() {
        pending = rows.reduce(0) { $0 + ($1.isPending ? 1 : 0) }
        loaded = rows.count - pending
    }

    beat.start()

    Task { @MainActor in

        // ================= 阶段一：只枚举 =================
        out("\n阶段一：枚举（每 \(batchSize) 个一批）")
        let p1 = Date()
        /// 直接路径下先攒着不上表的文件（= AppModel 里的 `held`）。
        let held = Import2Held()

        let phase1 = Task { @MainActor in
            do {
                for try await batch in ImportService.enumerate(urls: [dir],
                                                               options: options,
                                                               batchSize: batchSize) {
                    if Task.isCancelled { break }
                    skippedPhase1 += batch.skipped.count

                    if usedDirect {
                        held.append(batch.files)
                        guard held.count > threshold else { continue }
                        // 超阈值：退回两段式，攒下的一次推上表（= AppModel 的 backlog 分支）
                        usedDirect = false
                        let backlog = held.take()
                        ev("超过阈值 \(threshold) → 退回两段式，倒出 \(backlog.count) 行占位行")
                        appendListed(backlog)
                        continue
                    }
                    appendListed(batch.files)
                }
            } catch {
                phase1Cancelled = true
            }
            if Task.isCancelled { phase1Cancelled = true }
        }
        runner.phase1 = phase1

        /// = `AppModel.appendListedBatch`：只追加、绝不重排，两张表同时维护。
        @MainActor func appendListed(_ files: [EnumeratedFile]) {
            var fresh: [Import2Row] = []
            for f in files {
                guard index[f.url] == nil else { continue }
                index[f.url] = rows.count + fresh.count
                fresh.append(Import2Row(url: f.url, fileSize: f.fileSize,
                                        modifiedAt: f.modifiedAt, isPending: true,
                                        title: nil, artist: nil, durationMS: 0))
            }
            guard !fresh.isEmpty else { return }
            rows.append(contentsOf: fresh)
            let base = displayRows.count
            displayRows.append(contentsOf: fresh)
            for (i, r) in fresh.enumerated() { displayIndex[r.url] = base + i }
            recount()
            let seq = batchStamps.count + 1
            batchStamps.append((seq, ms(), fresh.count, rows.count))
            if !quiet, seq <= 10 || seq % 20 == 0 {
                out(String(format: "  [%@] 第 %3d 批 +%3d → 累计 %6d 首",
                           stamp(), seq, fresh.count, rows.count))
            }
            noteFirstAppear()
            renderTick()
        }

        /// = 直接路径的 `AppModel.appendLoadedBatch`：整行就是 `.loaded`，不碰 displayRows
        /// （紧接着的 rebuildDisplay 一次排好）。
        @MainActor func appendLoaded(_ files: [AudioFile], failures: [(url: URL, error: TagError)],
                                     from held: [EnumeratedFile]) {
            let meta = Dictionary(held.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            var fresh: [Import2Row] = []
            for f in files {
                guard index[f.url] == nil else { continue }
                index[f.url] = rows.count + fresh.count
                fresh.append(Import2Row(url: f.url,
                                        fileSize: meta[f.url]?.fileSize ?? f.technical.fileSizeBytes,
                                        modifiedAt: meta[f.url]?.modifiedAt, isPending: false,
                                        title: f.tags.title, artist: f.tags.artist,
                                        durationMS: f.technical.durationMilliseconds))
            }
            for (url, _) in failures {
                guard index[url] == nil else { continue }
                index[url] = rows.count + fresh.count
                fresh.append(Import2Row(url: url, fileSize: meta[url]?.fileSize ?? 0,
                                        modifiedAt: meta[url]?.modifiedAt, isPending: false,
                                        isFailed: true, title: nil, artist: nil, durationMS: 0))
            }
            rows.append(contentsOf: fresh)
            recount()
        }

        /// 模拟 SwiftUI 把可见的那一屏渲染出来 —— 待读行触发 `onAppear` → `noteRowVisible`。
        @MainActor func renderTick() {
            guard simulateVisible, pending > 0 else { return }
            let ids = displayRows.prefix(visibleWindow).filter(\.isPending).map(\.url)
            guard !ids.isEmpty else { return }
            visibleBox.note(ids)
        }

        // 定时取消：落在哪个阶段就取消哪个阶段。
        if let cancelMS = cancelAfterMS {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cancelMS)) {
                guard !runner.done, runner.cancelRequestedAt == nil else { return }
                runner.cancelRequestedAt = Date()
                if let t = runner.phase2 {
                    runner.cancelledPhase = 2
                    out("\n  [\(stamp())] >>> 取消：阶段二 <<<")
                    t.cancel()
                } else if let t = runner.phase1 {
                    runner.cancelledPhase = 1
                    out("\n  [\(stamp())] >>> 取消：阶段一 <<<")
                    t.cancel()
                }
            }
        }

        await phase1.value
        runner.phase1 = nil

        // ---------- 直接路径：后台一次读完，再整表上屏 ----------
        // **阈值优先于卷类型**：走到这里就一定读，除非用户把档位调到「从不」。
        let directReadNow = shouldAutoRead(listed: held.count, direct: true)
        if usedDirect && !directReadNow && held.count > 0 {
            out("\n直接路径：\(held.count) 首 ≤ 阈值 \(threshold)，但 --auto-read \(autoReadMode) "
                + "→ 只列文件，标签按需读")
        }
        if usedDirect && directReadNow && !noRead && !phase1Cancelled && held.count > 0 {
            directTagsRead = true
            let backlog = held.take()
            out("\n直接路径：\(backlog.count) 首 ≤ 阈值 \(threshold) —— 后台一次读完再整表上屏"
                + (traits.isSlowMedia ? "（可移动卷上也一样：阈值优先于卷类型）" : ""))
            phase2Start = ms()
            let pd = Date()
            let sink = Import2Sink()
            let queue = TagReadQueue(backlog.map(\.url))
            await TagReader.drain(queue: queue, options: options, concurrency: concurrency) { b in
                sink.add(b)
            }
            let r = sink.take()
            skippedPhase2 += r.skipped
            failedPhase2 += r.failures.count
            dropReasons = sink.reasonSnapshot()
            appendLoaded(r.files, failures: r.failures, from: backlog)
            // 没轮到的（取消）退回占位行
            let leftovers = backlog.filter { !r.handled.contains($0.url.path) }
            if !leftovers.isEmpty { appendListed(leftovers) }
            lastReadAt = Date()
            phase2End = ms()
            out(String(format: "直接读取结束: %d 首，用时 %.2f s", r.files.count,
                       Date().timeIntervalSince(pd)))
        } else if usedDirect {
            // 阈值以内但不读标签（--no-read / 取消）：仍要把攒下的推上表
            let backlog = held.take()
            if !backlog.isEmpty { appendListed(backlog) }
        }

        phase1End = ms()
        // = `AppModel.finishListing`：补一次排序 + 过滤，把表摆成用户设定的样子。
        recount()
        rebuildDisplay()
        lastFlushAt = Date()
        let p1sec = Date().timeIntervalSince(p1)
        out(String(format: "\n阶段一结束  : %d 首上表，用时 %.2f s%@",
                   rows.count, p1sec, phase1Cancelled ? "（已取消）" : ""))
        if runner.cancelledPhase == 1 {
            runner.cancelObservedAt = Date()
            atCancel = (rows.count, loaded, pending)
        }
        if !batchStamps.isEmpty {
            out(String(format: "  首批到达  : %.0f ms（%d 首）", batchStamps[0].at, batchStamps[0].count))
            if let firstK = batchStamps.first(where: { $0.total >= 1000 }) {
                out(String(format: "  前 1000 首: %.0f ms", firstK.at))
            }
        }
        out("  枚举挡掉  : \(skippedPhase1) 个（隐藏文件 / 扩展名不在白名单 / 重复路径）")

        // ================= 阶段二：读标签 =================
        // 只要表上还有待读行就走这里 —— 两段式固然要走，直接路径下被
        //「从不自动读取」挡掉的那一批也要走（它们靠前 N 行 + 可见窗口按需读）。
        if !noRead && !phase1Cancelled && !rows.isEmpty && pending > 0 {

            /// 复刻 AppModel 的攒批 + 刷表。**收尾必刷**由 `flush(final:)` 保证。
            let box = Import2Buffer()
            var flushScheduled = false

            @MainActor func flush(final: Bool) {
                flushScheduled = false
                let (files, drops, fails) = box.take()
                guard !files.isEmpty || !drops.isEmpty || !fails.isEmpty else {
                    if final { rebuildDisplay() }
                    return
                }
                for f in files {
                    guard let i = index[f.url] else { continue }
                    rows[i].isPending = false
                    rows[i].title = f.tags.title
                    rows[i].artist = f.tags.artist
                    rows[i].durationMS = f.technical.durationMilliseconds
                    // = AppModel 的 displayRows[j] = row
                    if let j = displayIndex[f.url] { displayRows[j] = rows[i] }
                }
                for u in fails {
                    guard let i = index[u] else { continue }
                    rows[i].isPending = false
                    rows[i].isFailed = true
                    if let j = displayIndex[u] { displayRows[j] = rows[i] }
                }
                // 时长过滤 / MP4 视频这类「打开文件才判得出」的忽略项，
                // 在第二阶段才有结论 —— 命中的行从两张表里一起撤下来（= AppModel 的 drops 分支）。
                if !drops.isEmpty {
                    let dropSet = Set(drops.map(\.path))
                    rows.removeAll { dropSet.contains($0.url.path) }
                    displayRows.removeAll { dropSet.contains($0.url.path) }
                    reindex()
                }
                skippedPhase2 += drops.count
                failedPhase2 += fails.count
                recount()
                flushCount += 1
                lastFlushAt = Date()
                flushStamps.append((ms(), loaded))
                if !quiet, flushStamps.count % 8 == 0 {
                    out(String(format: "  [%@] 已读 %6d/%6d", stamp(), loaded, rows.count))
                }
                noteLeadingDone()
                if final { rebuildDisplay() }
                renderTick()
            }

            @MainActor func scheduleFlush() {
                guard !flushScheduled else { return }
                flushScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    flush(final: false)
                }
            }

            let queue = TagReadQueue(rows.filter(\.isPending).map(\.url))
            var fullPending = false          // = AppModel.fullTagReadPending

            /// = `AppModel.startTagRead` + `finishTagRead` 的交接逻辑。
            @MainActor func startRead(priorityOnly: Bool) {
                guard runner.phase2 == nil else { return }
                if !priorityOnly, queue.remainingCount == 0, pending > 0 {
                    queue.reset(with: rows.filter(\.isPending).map(\.url))
                }
                guard queue.remainingCount > 0 else { return }
                if !priorityOnly { fullReadStarted = true }
                ev("阶段二开始 priorityOnly=\(priorityOnly) 待读=\(queue.remainingCount)"
                   + (priorityOnly || yieldEvery == 0 ? "" : " 让出=每 \(yieldEvery) 首"))
                let t = Task { @MainActor in
                    await TagReader.drain(queue: queue, options: options,
                                          concurrency: concurrency,
                                          priorityOnly: priorityOnly,
                                          yieldEvery: yieldEvery) { b in
                        box.add(b)
                        Task { @MainActor in
                            lastReadAt = Date()
                            scheduleFlush()
                        }
                    }
                }
                runner.phase2 = t
                runner.phase2RunID += 1
                let myRun = runner.phase2RunID
                Task { @MainActor in
                    await t.value
                    guard runner.phase2RunID == myRun else { return }
                    runner.phase2 = nil
                    // 收尾必刷（含取消 / 失败）
                    flush(final: true)
                    if priorityOnly {
                        if fullPending, pending > 0, !noHandover {
                            fullPending = false
                            ev("按需任务收工 → **交接**欠着的全量读取")
                            startRead(priorityOnly: false)
                            return
                        }
                        fullPending = false
                        ev("按需任务收工，插队队列剩 \(queue.priorityCount)")
                        if queue.priorityCount > 0 { startRead(priorityOnly: true) }
                        else { runner.done = true }
                        return
                    }
                    ev("全量任务收工 pending=\(pending)")
                    runner.done = true
                }
            }

            /// = `AppModel.prioritizeTagRead(_:startIfIdle:)`
            @MainActor func prioritize(_ urls: [URL], startIfIdle: Bool = true) {
                let wanted = urls.filter { index[$0].map { rows[$0].isPending } == true }
                guard !wanted.isEmpty else { return }
                if queue.remainingCount == 0 {
                    queue.reset(with: rows.filter(\.isPending).map(\.url))
                }
                queue.prioritize(wanted)
                if startIfIdle, runner.phase2 == nil { startRead(priorityOnly: true) }
            }
            visibleBox.sink = { ids in prioritize(ids) }

            /// = `AppModel.prioritizeLeadingRows(startIfIdle:)`：当前排序下的前 N 行排到队首。
            @MainActor @discardableResult
            func prioritizeLeading(startIfIdle: Bool) -> Int {
                let ids = displayRows.prefix(leadingRows).filter(\.isPending).map(\.url)
                guard !ids.isEmpty else { return 0 }
                prioritize(ids, startIfIdle: startIfIdle)
                return ids.count
            }

            /// = `AppModel.requestFullTagRead()` —— 阶段一结束后的那一次全量请求。
            @MainActor func requestFull() {
                if runner.phase2 == nil {
                    fullPending = false
                    startRead(priorityOnly: false)
                } else {
                    sawOverlap = true
                    fullPending = true
                    ev("阶段一结束时按需任务正在跑 → **欠着**一次全量读取（根因所在）")
                }
            }

            out("\n阶段二：读标签（并发 \(concurrency)，攒 250 ms 刷一次，收尾必刷）")
            if phase2Start == 0 { phase2Start = ms() }
            let p2 = Date()

            if race {
                // 强行制造根因场景：界面已经把**可见的那一屏**送进插队队列并起了按需任务，
                // 阶段一这时才结束 —— 修复前，这一次全量请求就是在这里被静默吞掉的。
                let visible = Array(rows.filter(\.isPending).prefix(visibleWindow).map(\.url))
                ev("--race：先起按需任务（插队可见的 \(visible.count) 行），再发全量请求")
                prioritize(visible)
            }

            // = `AppModel.finishListing` 的收尾两句。
            let autoReadNow = shouldAutoRead(listed: rows.count, direct: usedDirect)
            if autoReadNow {
                // 前 N 行先排到队首（**不**另起按需任务：马上就要起全量任务了）。
                // 全量读取一样先吃插队队列，所以「看得见的行先出标签」不会被几万首挤到后面。
                let n = prioritizeLeading(startIfIdle: false)
                if n > 0 { ev("前 \(n) 行排到队首（随后由全量读取先吃）") }
                requestFull()
            } else {
                // 不自动全读：至少把看得见的那一屏读出来（= 按需读取该兑现的样子）。
                let n = prioritizeLeading(startIfIdle: true)
                ev("--auto-read \(autoReadMode)：不起全量读取，只按需读前 \(n) 行")
            }
            // 阶段一之后界面还会再渲染一次
            renderTick()
            visibleBox.drainNow()
            // 一条读取任务都没起（never + --leading 0）：别在下面那个循环里干等。
            if runner.phase2 == nil { runner.done = true }

            let deadline2 = Date().addingTimeInterval(1200)
            while !runner.done && Date() < deadline2 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if runner.cancelledPhase == 2 { runner.cancelObservedAt = Date() }
            dropReasons = box.reasonSnapshot()
            flush(final: true)
            phase2End = ms()
            if runner.cancelledPhase == 2 { atCancel = (rows.count, loaded, pending) }
            out(String(format: "阶段二结束  : 已读 %d 首，用时 %.2f s", loaded,
                       Date().timeIntervalSince(p2)))

            // ===== 续读：复刻 AppModel.resumeTagRead =====
            let stillPending = rows.filter(\.isPending).map(\.url)
            if resume && !stillPending.isEmpty {
                out("\n续读（= 右键「继续读取标签」）：还剩 \(stillPending.count) 首")
                let p3 = Date()
                let queue2 = TagReadQueue()
                queue2.reset(with: stillPending)
                let box2 = Import2Buffer()
                await TagReader.drain(queue: queue2, options: options,
                                      concurrency: concurrency) { b in box2.add(b) }
                let (f2, s2, x2) = box2.take()
                if !s2.isEmpty {
                    let dropSet = Set(s2.map(\.path))
                    rows.removeAll { dropSet.contains($0.url.path) }
                    displayRows.removeAll { dropSet.contains($0.url.path) }
                    reindex()
                }
                for f in f2 {
                    guard let i = index[f.url] else { continue }
                    rows[i].isPending = false
                    rows[i].title = f.tags.title
                    rows[i].artist = f.tags.artist
                    if let j = displayIndex[f.url] { displayRows[j] = rows[i] }
                }
                skippedPhase2 += s2.count
                failedPhase2 += x2.count
                recount()
                lastFlushAt = Date()
                rebuildDisplay()
                out(String(format: "续读结束    : 补齐 %d 首，用时 %.2f s，剩余待读 %d 首",
                           f2.count, Date().timeIntervalSince(p3), pending))
            }
        }

        // ===== 批量入口的同步兜底：复刻 AppModel.materializePendingTags(in:) =====
        if materialize {
            let targets = rows.filter(\.isPending).map(\.url)
            out("\n批量入口兜底（= materializePendingTags）：待读 \(targets.count) 首")
            let pm = Date()
            let (files, failures) = TagService.readAll(targets)
            for f in files {
                guard let i = index[f.url] else { continue }
                rows[i].isPending = false
                rows[i].title = f.tags.title
                rows[i].artist = f.tags.artist
                if let j = displayIndex[f.url] { displayRows[j] = rows[i] }
            }
            recount()
            out(String(format: "  同步补读 %d 首（失败 %d），用时 %.2f s，剩余待读 %d 首",
                       files.count, failures.count, Date().timeIntervalSince(pm), pending))
        }

        runner.done = true
        runner.allDone = true
    }

    // 主线程空转 runloop：心跳与 @MainActor 都靠它派发。
    let deadline = Date().addingTimeInterval(1800)
    while !runner.allDone && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    // 收尾后可能还有一拍 250 ms 的定时刷在路上，给它一点时间再定格。
    let settle = Date().addingTimeInterval(0.4)
    while Date() < settle { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    beat.stop()
    let total = Date().timeIntervalSince(t0)

    // ================= 结论 =================
    hr("结果")
    out("路径                : " + (usedDirect ? "直接路径（≤ 阈值 \(threshold)，一次读完再显示）"
                                              : "两段式（> 阈值 \(threshold) 或阈值 = 0）"))
    out(String(format: "allRows             : %d 首（已读 %d / 待读 %d）", rows.count, loaded, pending))
    let dPending = displayRows.reduce(0) { $0 + ($1.isPending ? 1 : 0) }
    out(String(format: "displayRows（表）   : %d 行（待读 %d）", displayRows.count, dPending))
    out(String(format: "阶段二忽略 / 失败   : %d / %d", skippedPhase2, failedPhase2))
    for (reason, n) in dropReasons { out("    · \(reason)：\(n) 个") }

    out("\n耗时表")
    out("  " + pad("阶段", 24) + pad("耗时", 14) + "口径")
    out("  " + String(repeating: "-", count: 62))
    out("  " + pad("阶段一 首批可见", 24)
        + pad(String(format: "%.0f ms", batchStamps.first?.at ?? 0), 14)
        + "第 1 批 \(batchStamps.first?.count ?? 0) 首落表")
    out("  " + pad("表第一次出现", 24)
        + pad(String(format: "%.0f ms", firstAppearAt ?? 0), 14)
        + "\(firstAppearTotal) 行，其中标签已齐 \(firstAppearLoaded) 行")
    if let done = leadingDoneAt {
        let up = firstAppearAt ?? 0
        out("  " + pad("前 \(leadingRows) 行标签齐", 24)
            + pad(String(format: "%.0f ms", done), 14)
            + String(format: "上表 → 前 %d 行全读到：**%.0f ms**（刷表节拍 250 ms）",
                     leadingRows, max(0, done - up)))
    } else if leadingRows > 0 {
        out("  " + pad("前 \(leadingRows) 行标签齐", 24) + pad("—", 14) + "**始终没齐**")
    }
    out("  " + pad("全部上表", 24)
        + pad(String(format: "%.2f s", phase1End / 1000), 14) + "\(rows.count) 首")
    if phase2End > 0 {
        let sec = (phase2End - phase2Start) / 1000
        out("  " + pad("读完标签", 24)
            + pad(String(format: "%.2f s", sec), 14)
            + String(format: "%.0f 首/秒（并发 %d）", sec > 0 ? Double(loaded) / sec : 0, concurrency))
    }
    out("  " + pad("总计", 24) + pad(String(format: "%.2f s", total), 14) + "")

    // ---------------- 断言 ----------------
    hr("断言")
    var allPass = true
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { allPass = false }
        out("  \(ok ? "✔" : "✘") " + pad(name, 34) + detail)
    }
    let willAutoRead = shouldAutoRead(listed: rows.count, direct: usedDirect)
    let expectFull = !noRead && !phase1Cancelled && runner.cancelRequestedAt == nil && willAutoRead

    if usedDirect && rows.isEmpty {
        out("  — 上表时标签已齐              （表最终为空：文件全被规则挡掉，这条不适用）")
    } else if usedDirect && directTagsRead {
        check("走的是直接路径",
              usedDirect,
              "\(rows.count) 首 ≤ 阈值 \(threshold)"
              + (traits.isSlowMedia ? "，且在**可移动卷**上（阈值优先于卷类型）" : ""))
        check("上表时标签已齐",
              firstAppearLoaded == firstAppearTotal && firstAppearTotal > 0,
              "表第一次出现 \(firstAppearTotal) 行，标签已齐 \(firstAppearLoaded)/\(firstAppearTotal)")
    } else if usedDirect {
        check("直接路径但按用户设定不读",
              autoReadMode == "never" || noRead || phase1Cancelled,
              "--auto-read \(autoReadMode)：\(rows.count) 首先上占位行，标签按需读")
    } else {
        check("走的是两段式",
              !usedDirect,
              "表第一次出现 \(firstAppearTotal) 行，其中标签已齐 \(firstAppearLoaded)（占位行先上表）")
    }
    if !usedDirect && willAutoRead && !noRead && !phase1Cancelled {
        check("大目录起了全量后台读", fullReadStarted,
              "并发 \(concurrency)"
              + (yieldEvery > 0 ? " · 每 \(yieldEvery) 首让出一次（可移动卷低速后台读）"
                                : " · 不节流（内置卷）"))
    }
    if autoReadMode == "never" {
        check("「从不」不起全量读取", !fullReadStarted,
              fullReadStarted ? "**起了**，与设定不符" : "全程没起过全量任务")
        check("「从不」下待读行留着", pending > 0 || rows.isEmpty,
              "待读 \(pending) 首"
              + (leadingRows > 0 ? "（前 \(leadingRows) 行按需读掉了，其余原样留着）" : ""))
    }
    // 状态栏那句 5 秒提示（= `AppModel.showPendingHint` + `pendingHintText`）。
    let hintIdle = pending > 0 && runner.phase2 == nil
    if pending > 0 {
        check("状态栏提示可出现", hintIdle,
              hintIdle ? "「有 \(pending) 首未读取标签 · 点此读取」（点它 = resumeTagRead）"
                       : "还有任务在读，按设计不提示")
    }
    if priorityCheck {
        let up = firstAppearAt ?? 0
        let gap = (leadingDoneAt ?? .infinity) - up
        check("前 \(leadingRows) 行 1 秒内有标签", gap <= 1000,
              leadingDoneAt == nil ? "**前 \(leadingRows) 行始终没读齐**"
                                   : String(format: "上表 → 前 %d 行全读到 %.0f ms", leadingRows, gap))
    }
    if expectFull {
        check("结束时 pending = 0", pending == 0, "pending=\(pending)  loaded=\(loaded)")
        check("displayRows 无待读行", dPending == 0,
              "displayRows=\(displayRows.count) 待读=\(dPending)（**不靠切排序**）")
        check("allRows / displayRows 一致",
              rows.count == displayRows.count && pending == dPending,
              "allRows=\(rows.count)/待读\(pending)  displayRows=\(displayRows.count)/待读\(dPending)")
    }
    if let r = lastReadAt, let f = lastFlushAt {
        let gap = f.timeIntervalSince(r) * 1000
        check("最后一次刷表 ≥ 最后一次读完", gap >= 0,
              String(format: "最后读完 → 最后刷表 %+.1f ms", gap))
    }
    if race {
        check("竞态确有发生（否则这一组不算数）", sawOverlap,
              sawOverlap ? "阶段一结束时按需任务确实在跑，走了交接" : "没撞上，换参数重来")
    }
    out("\n  " + (allPass ? "全部通过" : "**有断言失败**"))

    if !events.isEmpty {
        out("\n事件流")
        for e in events { out(e) }
    }

    if let asked = runner.cancelRequestedAt {
        let observed = runner.cancelObservedAt ?? Date()
        let lag = observed.timeIntervalSince(asked)
        out("\n取消")
        out("  命中阶段          : 阶段\(runner.cancelledPhase)")
        out(String(format: "  发出 → 真正停下  : %.1f ms  %@",
                   lag * 1000, lag < 1.0 ? "✔ < 1 s" : "✘ ≥ 1 s"))
        let snap = atCancel ?? (rows.count, loaded, pending)
        out("  取消当刻三数      : 已列出 \(snap.listed) / 已读取 \(snap.loaded) / 未读取 \(snap.unread)")
    }

    out("\n主线程心跳（50 ms）")
    out(String(format: "  触发 %d 次（理想约 %d 次）", beat.ticks, Int(total / beat.interval)))
    out(String(format: "  **最大停顿 %.0f ms** %@", beat.maxGap * 1000,
               beat.maxGap < 0.1 ? "✔ < 100 ms，界面不卡" : "✘ ≥ 100 ms"))
    out("  超过 100 ms 的停顿 : \(beat.stalls.filter { $0 > 0.1 }.count) 次")
}

// MARK: - 直接路径下先攒着的枚举结果

/// = `AppModel.importURLs` 里的 `held`：阈值以内先不上表。
private final class Import2Held {
    private var files: [EnumeratedFile] = []
    var count: Int { files.count }
    func append(_ f: [EnumeratedFile]) { files.append(contentsOf: f) }
    func take() -> [EnumeratedFile] { defer { files = [] }; return files }
}

/// 模拟界面 `onAppear` 的 120 ms 攒批（= `AppModel.noteRowVisible`）。
@MainActor
private final class Import2VisibleBox {
    var sink: (([URL]) -> Void)?
    private var buffer: Set<URL> = []
    private var scheduled = false

    func note(_ ids: [URL]) {
        buffer.formUnion(ids)
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.drainNow()
        }
    }

    func drainNow() {
        scheduled = false
        let ids = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !ids.isEmpty else { return }
        sink?(Array(ids))
    }
}

@MainActor private let visibleBox = Import2VisibleBox()

// MARK: - 后台回调与主线程之间的缓冲

/// `TagReader.drain` 的回调在任意线程，这里攒着，主线程 250 ms 取一次。
private final class Import2Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [AudioFile] = []
    /// 第二阶段才判得出的忽略项（时长 / MP4 视频 / 空文件）。
    /// 必须按 URL 交出去 —— `AppModel.flushTagBuffer` 会把这些行**从表里撤下来**。
    private var drops: [URL] = []
    private var fails: [URL] = []
    private(set) var reasons: [String: Int] = [:]

    func add(_ b: TagReadBatch) {
        lock.lock()
        files.append(contentsOf: b.files)
        drops.append(contentsOf: b.skipped.map(\.url))
        fails.append(contentsOf: b.failures.map(\.url))
        for s in b.skipped {
            let key = s.reason.hasPrefix("时长") ? "时长不足" : s.reason
            reasons[key, default: 0] += 1
        }
        lock.unlock()
    }

    func take() -> ([AudioFile], [URL], [URL]) {
        lock.lock()
        defer { files = []; drops = []; fails = []; lock.unlock() }
        return (files, drops, fails)
    }

    func reasonSnapshot() -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        return reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }
}

/// 直接路径的收集器（= `AppModel.DirectReadSink`）。
private final class Import2Sink: @unchecked Sendable {
    struct Result {
        var files: [AudioFile]
        var failures: [(url: URL, error: TagError)]
        var skipped: Int
        var handled: Set<String>
    }
    private let lock = NSLock()
    private var files: [AudioFile] = []
    private var failures: [(url: URL, error: TagError)] = []
    private var skipped = 0
    private var handled = Set<String>()
    private var reasons: [String: Int] = [:]

    func add(_ b: TagReadBatch) {
        lock.lock()
        files.append(contentsOf: b.files)
        failures.append(contentsOf: b.failures)
        skipped += b.skipped.count
        for f in b.files { handled.insert(f.url.path) }
        for s in b.skipped {
            handled.insert(s.url.path)
            let key = s.reason.hasPrefix("时长") ? "时长不足" : s.reason
            reasons[key, default: 0] += 1
        }
        for f in b.failures { handled.insert(f.url.path) }
        lock.unlock()
    }

    func take() -> Result {
        lock.lock(); defer { lock.unlock() }
        return Result(files: files, failures: failures, skipped: skipped, handled: handled)
    }

    func reasonSnapshot() -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        return reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }
}

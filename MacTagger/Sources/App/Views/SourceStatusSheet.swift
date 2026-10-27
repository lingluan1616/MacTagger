//
//  SourceStatusSheet.swift
//  MacTagger — 逐源结果条 + 数据源状态面板
//
//  用户的原话：「看不出数据源是否正常」——搜索结果里没有 QQ，不知道是没搜到还是挂了。
//  这两件事的处置完全相反，界面却一直把它们画成同一个样子（都是「什么都没有」）。
//
//  两层解法，都在本文件：
//  · `SourceOutcomeBar`：**这一轮**的逐源结果条。每次匹配/搜歌词/搜封面的结果窗顶部各挂一条，
//    三态用颜色区分 —— 绿=有结果，灰=0 条（不是故障），红=失败并写明原因。
//  · `SourceStatusView`：**跨请求**的健康面板。每源最近 20 次请求的成败、平均延迟、
//    最近一次失败原因，外加「测试」按钮用固定探测曲主动打一枪。
//
//  面板刻意做成独立窗口而不是 sheet：用户排查数据源时往往要一边看面板一边重跑匹配，
//  sheet 会把主窗口锁死。
//

import SwiftUI
import AppKit

// MARK: - 逐源结果条

/// 一次搜索里每个源的结果，一行 chips。
///
///     数据源  ● iTunes 8   ● 网易云 5   ● QQ ✘ 超时   ● 酷狗 0   ● MusicBrainz 503×4→通
///
/// 判读规则只有一条：**颜色说的是「这个源这次怎么样」，数字说的是「给了几条」**。
/// 灰色的 `0` 是正常的（源活着，只是没这首歌）；红色才需要用户操心。
struct SourceOutcomeBar: View {

    let outcomes: [SourceOutcome]
    /// 标题词。逐首复核叫「数据源」，专辑组头空间紧张时传 nil 省掉。
    var label: String? = "数据源"
    /// 当前被选中的筛选源（B4：点 chip 只看这个源的候选）。nil = 不筛选。
    var selectedSourceID: String? = nil
    /// 传了就把 chip 变成可点的按钮；不传就是纯展示。
    var onTap: ((String) -> Void)? = nil
    /// 右侧附加说明（如「共 23 条候选」）。
    var trailingNote: String? = nil

    var body: some View {
        if outcomes.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: Theme.Spacing.xs) {
                if let label {
                    Text(label)
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.tertiary)
                }
                ForEach(outcomes) { o in
                    chip(o)
                }
                if let trailingNote {
                    Text(trailingNote)
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func chip(_ o: SourceOutcome) -> some View {
        let selected = selectedSourceID == o.sourceID
        let content = HStack(spacing: Theme.Spacing.xs) {
            StatusDot(color: SourceOutcomeBar.color(o), size: 6)
            Text(o.chipLabel)
                .font(Theme.Typo.badge)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(SourceOutcomeBar.textColor(o))
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 1)
        .background(selected ? Theme.Colors.accentSoft : Theme.Colors.chipFill, in: Capsule())
        .overlay {
            if selected { Capsule().strokeBorder(Color.accentColor.opacity(0.5)) }
        }

        if let onTap {
            Button { onTap(o.sourceID) } label: { content }
                .buttonStyle(.plain)
                .help(o.helpText + "\n\n点一下"
                      + (selected ? "取消筛选" : "只看来自\(o.displayName)的候选"))
        } else {
            content.help(o.helpText)
        }
    }

    /// 四态语义色。灰色的 0 条**不是**故障，绝不能和红色混为一谈；
    /// 熔断暂停用**灰橙**：橙说明「有问题」，比红浅说明「会自动恢复，不用你去修」。
    static func color(_ o: SourceOutcome) -> Color {
        switch o.tint {
        case .ok:     return Theme.Colors.matched
        case .none:   return Theme.Colors.ignored
        case .bad:    return Theme.Colors.failed
        case .paused: return Theme.Colors.warning
        }
    }

    static func textColor(_ o: SourceOutcome) -> Color {
        switch o.tint {
        case .ok:     return .secondary
        case .none:   return Theme.Colors.placeholderText
        case .bad:    return Theme.Colors.failed
        case .paused: return Theme.Colors.warning.opacity(0.9)
        }
    }
}

// MARK: - 由既有信息还原结果条
//
// 歌词批量复核与封面搜索这两处，结果模型是别的模块的（本轮不动它们），
// 手里只有「哪个源给出了结果」与一句 `源：原因；源：原因` 的错误摘要。
// 下面这两个函数把它们还原成同一套三态结果条 —— 界面语言必须全应用一致，
// 不能这个窗口用 chips、那个窗口只有一句红字。

extension SourceOutcome {

    /// 解析 `errorSummary` 的 `源：原因；源：原因` 格式（由 TagKit 各 Outcome 自己生成，格式固定）。
    static func parseErrorSummary(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for piece in text.components(separatedBy: "；") {
            let seg = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seg.isEmpty else { continue }
            guard let r = seg.range(of: "：") else { continue }
            let id = String(seg[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let why = String(seg[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !why.isEmpty else { continue }
            out[id] = why
        }
        return out
    }

    /// 由「参与的源 + 每源命中数 + 错误摘要」拼一条结果条。
    static func derive(sourceIDs: [String],
                       hits: [String: Int],
                       errorSummary: String?) -> [SourceOutcome] {
        let errs = parseErrorSummary(errorSummary)
        var ids = sourceIDs
        for id in errs.keys where !ids.contains(id) { ids.append(id) }
        for id in hits.keys where !ids.contains(id) { ids.append(id) }
        return ids.map { id -> SourceOutcome in
            if let why = errs[id], (hits[id] ?? 0) == 0 {
                return SourceOutcome(sourceID: id, status: .failed(shorten(why)), detail: why)
            }
            let n = hits[id] ?? 0
            return SourceOutcome(sourceID: id, status: n > 0 ? .hits(n) : .empty,
                                 detail: errs[id])
        }
        .sortedByPriority()
    }
}

// MARK: - 面板的状态

@MainActor
final class SourceStatusModel: ObservableObject {

    @Published var snapshots: [SourceHealthSnapshot] = []
    /// 正在测的源。
    @Published var testing: Set<String> = []
    /// 每源最近一次「测试」的结果，覆盖在表里给即时反馈。
    @Published var lastTest: [String: SourceOutcome] = [:]
    @Published var isTestingAll = false

    init() { SourceBootstrap.registerAll() }

    var sourceIDs: [String] { SourceBootstrap.searchableIDs }

    func refresh() async {
        let ids = sourceIDs
        snapshots = await SourceHealth.shared.snapshots(ids: ids)
    }

    func test(_ id: String) async {
        testing.insert(id)
        defer { testing.remove(id) }
        let outcome = await SourceHealth.shared.testConnection(id)
        lastTest[id] = outcome
        await refresh()
    }

    func testAll() async {
        guard !isTestingAll else { return }
        isTestingAll = true
        defer { isTestingAll = false }
        for id in sourceIDs {
            await test(id)
        }
    }
}

// MARK: - 数据源状态面板

struct SourceStatusView: View {

    @StateObject private var model = SourceStatusModel()

    private enum Col {
        static let source: CGFloat = 150
        static let light: CGFloat = 78
        static let recent: CGFloat = 130
        static let latency: CGFloat = 78
        /// 源专属设置槽。目前只有 iTunes 用它放曲库地区选择器；
        /// 其余行留空，好让「测试」按钮整列对齐。
        static let extras: CGFloat = 212
        static let action: CGFloat = 64
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "antenna.radiowaves.left.and.right",
                          title: "数据源状态",
                          subtitle: "每个源最近 \(SourceHealth.capacity) 次请求的成败与延迟。"
                                  + "「测试」用固定探测曲（稻香 / Blank Space）主动打一枪，"
                                  + "能把「这首歌没有」和「这个源挂了」分开。") {
                if model.isTestingAll {
                    ProgressView().controlSize(.small)
                }
            }

            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshots) { snap in
                        row(snap)
                        Divider().opacity(0.35)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
            }
            .frame(maxHeight: .infinity)

            SheetButtonBar {
                Text(legend)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }
                Button("全部测试") { Task { await model.testAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTestingAll)
            }
        }
        // 加了「源设置」一列（iTunes 曲库地区）之后，原来的 620/680 会把
        // 「最近失败原因」那一列挤没。宽度按新增列的实际占位加上去。
        .frame(minWidth: 840, idealWidth: 920, minHeight: 380, idealHeight: 460)
        .task { await model.refresh() }
    }

    private var legend: String {
        "绿 = 正常　橙 = 不稳定（近期有失败）　红 = 异常（半数以上失败）　灰 = 本次会话还没请求过"
        + "　⏸ = 连续超时已熔断，暂停中会自动恢复"
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("数据源").frame(width: Col.source, alignment: .leading)
            Text("状态").frame(width: Col.light, alignment: .leading)
            Text("最近结果").frame(width: Col.recent, alignment: .leading)
            Text("平均延迟").frame(width: Col.latency, alignment: .trailing)
            Text("最近失败原因").frame(minWidth: 140, alignment: .leading)
            Spacer()
            Text("源设置 · 搜索路径").frame(width: Col.extras, alignment: .trailing)
            Color.clear.frame(width: Col.action, height: 1)
        }
        .font(Theme.Typo.sectionHeader)
        .foregroundStyle(.secondary)
        .tracking(0.4)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.chipFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ snap: SourceHealthSnapshot) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(snap.displayName)
                .font(Theme.Typo.tableCell)
                .lineLimit(1)
                .frame(width: Col.source, alignment: .leading)
                .help(snap.sourceID)

            HStack(spacing: Theme.Spacing.xs) {
                // 灯要叠上「本次探测」的结论：只看 HTTP 会把「请求全 200 但搜什么都是 0 条」
                // 的源画成绿灯，而那正是用户说的「看不出数据源是否正常」。
                let light = snap.light(withTest: model.lastTest[snap.sourceID])
                // 熔断暂停中优先显示暂停 —— 此刻「不稳定/异常」都不如「已暂停，会自动恢复」有用。
                if let paused = snap.pausedText {
                    StatusDot(color: Theme.Colors.warning)
                    Text(paused)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .monospacedDigit()
                } else {
                    StatusDot(color: lightColor(light))
                    Text(SourceHealthSnapshot.label(for: light))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Col.light, alignment: .leading)
            .help(helpFor(snap))

            Text(snap.recentSummary)
                .font(Theme.Typo.digitsSmall)
                .foregroundStyle(.secondary)
                .frame(width: Col.recent, alignment: .leading)
                .help("最近 \(snap.sampleCount) 次请求：成功 \(snap.okCount)、空结果 \(snap.emptyCount)、失败 \(snap.failedCount)")

            Text(snap.latencyText)
                .font(Theme.Typo.digitsSmall)
                .foregroundStyle(.secondary)
                .frame(width: Col.latency, alignment: .trailing)

            Text(failureText(snap))
                .font(Theme.Typo.badge)
                .foregroundStyle(snap.lastFailure == nil ? Theme.Colors.placeholderText
                                                         : Theme.Colors.failed)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 140, alignment: .leading)
                .help(failureHelp(snap))

            Spacer(minLength: Theme.Spacing.xs)

            // 源专属设置。iTunes 的曲库地区放在**它自己那一行**上：
            // 用户会来这个面板正是因为「iTunes 那一格总是 0」，
            // 换地区的开关就该出现在他看到 0 的同一行，而不是藏在另一个偏好窗里。
            Group {
                if snap.sourceID == "itunes" {
                    ITunesRegionInlineRow()
                } else if let route = snap.searchRouteText {
                    // QQ 的搜索是三级降级链（官方搜索 → smartbox → 桌面搜索）。
                    // 「它现在走的是哪一级」放在**它自己那一行**上：用户来这张表正是因为
                    // 「QQ 那一格总是 0」，而三级各自的处置完全不同，
                    // 这句话是把「0 条」翻译成「该做什么」的唯一线索。
                    Text(route)
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(routeHelp(snap))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Col.extras, alignment: .trailing)

            if model.testing.contains(snap.sourceID) {
                ProgressView().controlSize(.small).frame(width: Col.action)
            } else {
                Button("测试") { Task { await model.test(snap.sourceID) } }
                    .controlSize(.small)
                    .frame(width: Col.action)
                    .disabled(model.isTestingAll)
            }
        }
        .frame(height: Theme.Size.tableRowHeight + 4)
    }

    private func lightColor(_ l: SourceHealthSnapshot.Light) -> Color {
        switch l {
        case .unknown:  return Theme.Colors.placeholderText
        case .ok:       return Theme.Colors.matched
        case .degraded: return Theme.Colors.warning
        case .down:     return Theme.Colors.failed
        }
    }

    private func failureText(_ snap: SourceHealthSnapshot) -> String {
        if let t = model.lastTest[snap.sourceID], t.status.isFailure,
           case .failed(let why) = t.status { return why }
        guard let f = snap.lastFailure else { return "—" }
        return f.reason ?? "未知错误"
    }

    /// 搜索路径那一格的悬停提示。把三级各自的含义与处置写清楚 ——
    /// 光看「smartbox」这四个字没人知道它意味着什么。
    private func routeHelp(_ snap: SourceHealthSnapshot) -> String {
        var lines = ["\(snap.displayName)的搜索走的是三级降级链，逐级往下退："]
        lines.append("① 官方搜索（client_search_cp）—— 首选，一发就带回专辑/年份/音轨号/时长")
        lines.append("② smartbox（联想接口）—— 兜底，最稳但只给曲名和歌手，详情要再补一发")
        lines.append("③ 桌面搜索（musicu.fcg）—— 最后一级，字段最全但实测约七成会被拒（code 2001）")
        lines.append("")
        lines.append("最近一次走通的是：\(snap.searchRoute ?? "—")")
        if let e = snap.searchEffectiveText {
            lines.append("最近 \(QQSearchTelemetry.window) 次搜索的\(e)")
        }
        if let b = snap.searchRouteBreakdown {
            lines.append("各级命中：\(b)")
        }
        return lines.joined(separator: "\n")
    }

    private func failureHelp(_ snap: SourceHealthSnapshot) -> String {
        if let t = model.lastTest[snap.sourceID] { return t.helpText }
        guard let f = snap.lastFailure else { return "最近没有失败记录" }
        return (f.reason ?? "未知错误") + "\n" + Self.stamp.string(from: f.at)
    }

    private func helpFor(_ snap: SourceHealthSnapshot) -> String {
        var head = ""
        if let p = snap.pausedText {
            head = "\(p)：这个源连续超时已触发熔断，暂时不对它发请求，到点会自动放一发探测恢复。\n\n"
        } else if snap.circuitTrips > 0 {
            head = "本次会话熔断过 \(snap.circuitTrips) 次，现已恢复。\n\n"
        }
        guard snap.sampleCount > 0 else {
            return head + "本次会话还没有向\(snap.displayName)发过请求。点「测试」用探测曲打一枪。"
        }
        var s = head + "最近 \(snap.sampleCount) 次：成功 \(snap.okCount)、空 \(snap.emptyCount)、失败 \(snap.failedCount)"
        if let t = model.lastTest[snap.sourceID] { s += "\n\n最近一次测试：\n" + t.helpText }
        return s
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 独立窗口

/// 「标签 › 数据源状态…」的落点。
///
/// 用独立 `NSWindow` 而不是 sheet：排查数据源时用户要一边看这张表一边重跑匹配，
/// sheet 会把主窗口整个锁住。同时这样也不必去动 `MacTaggerApp` 的 sheet 挂载链
/// （那里另有并行改动，多一行都是冲突风险）。
@MainActor
enum SourceStatusWindow {

    private static var window: NSWindow?

    static func present() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }
        let host = NSHostingController(rootView: SourceStatusView())
        let w = NSWindow(contentViewController: host)
        w.title = "数据源状态"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 920, height: 460))
        w.isReleasedWhenClosed = false      // 关掉后还要能再打开同一个实例
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

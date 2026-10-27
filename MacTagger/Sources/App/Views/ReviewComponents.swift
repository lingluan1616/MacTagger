//
//  ReviewComponents.swift
//  MacTagger — 两个复核窗共用的构件
//
//  ── 为什么要有这个文件 ──
//  专辑模式与逐首模式是同一件事的两种组织方式，复核表却各写了一份行布局，
//  于是「封面太小」这类毛病要改两遍、还容易改出两种样子。这里把
//  **专辑卡组头 / 曲目行 / 封面悬停预览 / 密度切换** 收成一套，两个窗都从这里取。
//
//  ── 判读规则（整套界面只有这一条，两个窗共用）──
//  1. 一组的第一决定是「这张专辑对不对」，而人眼判专辑靠的是**封面**，不是那行小字。
//     所以组头是一张 160pt 大封面的专辑卡；文件原本有封面时，右下角叠一张 48pt 的
//     「原封面」——新旧同框才比得出来。
//  2. 一行的第一决定是「这个文件对到的曲子对不对」，所以主行只留
//     `文件名 → 新标题`：左边是磁盘上的事实，右边是即将写入的结果。
//  3. 颜色只表达一件事：**绿 = 从无到有（新增），蓝 = 覆盖已有值（修改），灰 = 本次不动。**
//     原值一律灰色 + 删除线，新值一律正文色 —— 不靠记忆，靠视觉。
//

import SwiftUI
import AppKit

// MARK: - 显示密度

/// 复核表的行密度。舒适 = 两行制（默认），紧凑 = 单行制。
enum ReviewDensity: String, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .comfortable: return "舒适"
        case .compact:     return "紧凑"
        }
    }

    /// 行高。两行制 44，单行制 30。
    var rowHeight: CGFloat {
        switch self {
        case .comfortable: return Theme.Size.reviewRowHeight
        case .compact:     return Theme.Size.reviewRowHeightCompact
        }
    }

    var isTwoLine: Bool { self == .comfortable }
}

/// 两个复核窗共用的显示偏好。密度与「只看有改动的字段」在两个窗之间是同一份设置 ——
/// 用户在哪个窗里调，另一个窗也是那个样子。
@MainActor
final class ReviewDisplayStore: ObservableObject {

    static let shared = ReviewDisplayStore()

    private enum Key {
        static let density = "MacTagger.review.density"
        static let onlyChanged = "MacTagger.review.onlyChangedFields"
    }

    /// 离屏渲染工装把它置 false：渲染进程不该往任何偏好域里写东西。
    nonisolated(unsafe) static var persists = true

    @Published var density: ReviewDensity {
        didSet {
            guard Self.persists else { return }
            UserDefaults.standard.set(density.rawValue, forKey: Key.density)
        }
    }

    /// 打开后隐藏「本次不动」的灰 chips，只剩真正会写入的那几个。
    @Published var onlyChangedFields: Bool {
        didSet {
            guard Self.persists else { return }
            UserDefaults.standard.set(onlyChangedFields, forKey: Key.onlyChanged)
        }
    }

    private init() {
        let d = UserDefaults.standard
        density = ReviewDensity(rawValue: d.string(forKey: Key.density) ?? "") ?? .comfortable
        onlyChangedFields = d.bool(forKey: Key.onlyChanged)
    }
}

/// 顶部工具条上的「紧凑 / 舒适」分段控件。
struct DensityToggle: View {
    @Binding var density: ReviewDensity

    var body: some View {
        Picker("", selection: $density) {
            ForEach(ReviewDensity.allCases) { d in
                Text(d.localizedName).tag(d)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("舒适：每个文件两行，第二行摆艺术家、音轨与变更 chips。\n紧凑：每个文件一行，只留文件名 → 新标题与变更 chips。")
    }
}

// MARK: - 封面元信息与悬停预览

/// 一张封面的元信息。悬停预览面板把它摊开：多大、多少字节、什么格式、哪来的。
struct ArtworkMeta: Equatable {
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var mime: String
    /// 「网易云音乐」「文件内嵌」这类来源说明。
    var source: String
    /// 「新封面 · 将写入」/「原封面 · 文件内现有」。
    var role: String

    init(pixelWidth: Int, pixelHeight: Int, byteCount: Int,
         mime: String, source: String, role: String) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.mime = mime
        self.source = source
        self.role = role
    }

    /// 从字节 + 解好的图构造。尺寸以解码结果为准（源声明的尺寸经常说谎）。
    init(data: Data, image: NSImage?, source: String, role: String) {
        let rep = image?.representations.first
        let w = rep?.pixelsWide ?? Int(image?.size.width ?? 0)
        let h = rep?.pixelsHigh ?? Int(image?.size.height ?? 0)
        self.init(pixelWidth: w, pixelHeight: h, byteCount: data.count,
                  mime: ArtworkMeta.mime(of: data), source: source, role: role)
    }

    /// 靠魔数判类型 —— 下载回来的封面只有字节，没有文件名可依。
    static func mime(of data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return "image/jpeg"
    }

    /// `600×600 · 48 KB · image/jpeg · 网易云音乐`
    var line: String {
        var parts = ["\(pixelWidth)×\(pixelHeight)"]
        if byteCount > 0 { parts.append(Formatters.fileSize(Int64(byteCount))) }
        parts.append(mime)
        if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }
}

/// 悬停预览面板。**单独抽出来是为了能被离屏渲染** —— popover 截不到，
/// 但把同一个面板当静态视图画出来就能验收它长什么样。
struct ArtworkPreviewPanel: View {
    let image: NSImage?
    let meta: ArtworkMeta?
    /// 放大态：边长翻倍（320 → 640）。
    var enlarged: Bool = false
    /// 点一下切换放大。离屏渲染时传 nil，面板就是纯静态的。
    var onToggleSize: (() -> Void)?

    private var side: CGFloat {
        enlarged ? Theme.Size.reviewPreview * 2 : Theme.Size.reviewPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let meta {
                Text(meta.role)
                    .font(Theme.Typo.sectionHeader)
                    .foregroundStyle(.secondary)
            }
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ArtworkPlaceholder(corner: Theme.Radius.m)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Theme.Colors.artworkStroke))
            .shadow(color: Theme.Colors.artworkShadow, radius: 8, y: 2)

            if let meta {
                Text(meta.line)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            Text(enlarged ? "点一下缩回 \(Int(Theme.Size.reviewPreview)) pt"
                          : "点一下放大到 \(Int(Theme.Size.reviewPreview) * 2) pt")
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .contentShape(Rectangle())
        .onTapGesture { onToggleSize?() }
    }
}

/// 封面缩略图 + 悬停 300 ms 弹出的预览。
///
/// 为什么要延迟：复核表里封面密集，鼠标划过就弹会闪成一片。300 ms 是
/// 「确实停在这张图上」与「还在往别处走」的分界，与 macOS 工具提示同一量级。
struct ArtworkHoverPreview: View {

    let image: NSImage?
    let meta: ArtworkMeta?
    var size: CGFloat
    var corner: CGFloat = Theme.Radius.s
    /// 没有图时画不画占位方块。行内缩略图不占位，组头大图要占位。
    var showsPlaceholder: Bool = true
    var help: String = ""

    @State private var showPreview = false
    @State private var enlarged = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Theme.Colors.artworkStroke))
            .help(help.isEmpty ? (meta?.line ?? "") : help)
            .onHover { inside in
                hoverTask?.cancel()
                guard image != nil || meta != nil else { return }
                if inside {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        showPreview = true
                    }
                } else {
                    showPreview = false
                    enlarged = false
                }
            }
            .popover(isPresented: $showPreview, arrowEdge: .trailing) {
                ArtworkPreviewPanel(image: image, meta: meta, enlarged: enlarged) {
                    enlarged.toggle()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if showsPlaceholder {
            ArtworkPlaceholder(corner: corner)
        } else {
            Color.clear
        }
    }
}

// MARK: - 变更 chips

/// 一个字段的变更种类。**颜色只表达这一件事**，不做装饰。
enum ReviewChangeKind {
    /// 原本是空的 → 从无到有。
    case added
    /// 原本有值 → 会被覆盖。这是最需要人眼把关的一类。
    case modified
    /// 本次不动它。
    case unchanged
    /// 专辑级字段上**与组级值不同**：专辑卡摘要说的是一套，这一行走的是另一套。
    /// 一组里通常一枚都不该有 —— 有，就是这一行被换过候选或自带另一张封面。
    case groupDiffers

    var color: Color {
        switch self {
        case .added:        return Theme.Colors.matched
        case .modified:     return Color.accentColor
        case .unchanged:    return Color.secondary
        case .groupDiffers: return Theme.Colors.warning
        }
    }

    /// chip 文字色。橙的那一类要连字一起变色 —— 它是整屏唯一需要被找出来的东西。
    var textColor: Color {
        switch self {
        case .unchanged:    return Theme.Colors.placeholderText
        case .groupDiffers: return Theme.Colors.warning
        default:            return Color.secondary
        }
    }

    var localizedName: String {
        switch self {
        case .added:        return "新增"
        case .modified:     return "修改"
        case .unchanged:    return "不变"
        case .groupDiffers: return "与组级值不同"
        }
    }
}

/// 行尾那一串小标签里的一个。
struct ReviewChangeChip: Identifiable, Equatable {
    var id: String
    var label: String
    var kind: ReviewChangeKind
    /// 悬停提示：原 → 新。
    var help: String = ""

    // MARK: 可勾选（按文件选写哪几个字段）

    /// 这枚 chip 背后是哪一个写入项。nil = 纯展示（「本次不动」的灰 chip），点不动。
    var key: ReviewFieldKey?
    /// 已被排除：**灰 + 划线**，本文件不写这个字段。
    var excluded: Bool = false

    /// 能不能点。只有「背后真有一处改动」的 chip 才可切换。
    var isToggleable: Bool { key != nil }

    static func == (a: ReviewChangeChip, b: ReviewChangeChip) -> Bool {
        a.id == b.id && a.label == b.label && a.help == b.help
            && a.key == b.key && a.excluded == b.excluded
    }
}

/// 变更 chip 的样子：一个语义色圆点 + 字段名。灰的那些是「本次不动」。
///
/// ── 三种态，一眼分得开 ──
/// **正常**：语义色圆点 + 字段名 —— 这个字段会写。
/// **已排除**：空心圆点 + 灰字 + 删除线 —— 这个文件不写它（用户自己划掉的）。
/// **不变**（`key == nil`）：灰点灰字，本次本来就不动它 —— 点不动，也没什么可排除的。
///
/// 「已排除」与「不变」刻意长得不一样：前者是**用户的决定**，后者是**匹配的事实**，
/// 把两者画成同一个灰会让人分不清「我划掉的」和「本来就没有的」。
struct ReviewChangeChipView: View {
    let chip: ReviewChangeChip
    /// 点一下切换排除/恢复。nil = 只读（离屏渲染、没有接线的场合）。
    var onToggle: (() -> Void)?

    private var canToggle: Bool { chip.isToggleable && onToggle != nil }

    var body: some View {
        Group {
            if canToggle {
                Button(action: { onToggle?() }) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .help(fullHelp)
    }

    private var label: some View {
        HStack(spacing: 3) {
            dot
            Text(chip.label)
                .font(Theme.Typo.badge)
                .foregroundStyle(chip.excluded ? Theme.Colors.placeholderText : chip.kind.textColor)
                .strikethrough(chip.excluded, color: Theme.Colors.placeholderText)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.xs2)
        .padding(.vertical, 1)
        .background(background, in: Capsule())
        .contentShape(Capsule())
    }

    /// 排除态用**空心**圆点：实心是「会写」，空心是「不写了」，
    /// 与删除线一起给出两道彼此独立的线索（色盲用户只看得见后者）。
    @ViewBuilder
    private var dot: some View {
        if chip.excluded {
            Circle()
                .strokeBorder(Theme.Colors.placeholderText, lineWidth: 1)
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .fill(chip.kind.color)
                .frame(width: 5, height: 5)
                .opacity(chip.kind == .unchanged ? 0.55 : 1)
        }
    }

    private var background: some ShapeStyle {
        if chip.excluded { return AnyShapeStyle(Theme.Colors.chipFill.opacity(0.45)) }
        switch chip.kind {
        case .groupDiffers: return AnyShapeStyle(Theme.Colors.warning.opacity(0.16))
        case .unchanged:    return AnyShapeStyle(Theme.Colors.chipFill.opacity(0.6))
        default:            return AnyShapeStyle(Theme.Colors.chipFill)
        }
    }

    private var fullHelp: String {
        var s = chip.help.isEmpty ? "\(chip.label)：\(chip.kind.localizedName)" : chip.help
        guard canToggle else { return s }
        s += chip.excluded
            ? "\n\n已排除：这个文件不写该字段。点击可恢复。"
            : "\n\n点击可排除/恢复：排除后这个文件不写该字段（其它文件不受影响）。"
        return s
    }
}

// MARK: - 「原 → 新」行内一格（删除线口径）

/// 复核表新口径的差异格：**原值灰色删除线，新值正文色**。
///
/// 与 `OldNewCell`（展开区仍在用）的区别只在配色口径：那一版把新值涂成强调色，
/// 一屏几十格全是蓝的，等于没有重点；这一版让「会被划掉的东西」自己说明自己，
/// 强调色让位给真正的状态标记（chips 与状态点）。
struct DiffInline: View {
    let label: String?
    let old: String
    /// nil = 本次不改这个字段。
    let new: String?
    var font: Font = Theme.Typo.badge
    var mono: Bool = false
    /// 不改动时显示什么。
    var unchangedText: String = "—"
    var help: String = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let label {
                Text(label)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
            }
            if let new {
                Text(old.isEmpty ? "（空）" : old)
                    .foregroundStyle(Theme.Colors.placeholderText)
                    .strikethrough(!old.isEmpty, color: Theme.Colors.placeholderText)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                Text(new)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
            } else {
                Text(unchangedText)
                    .foregroundStyle(Theme.Colors.placeholderText)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .font(font)
        .monospacedDigit()
        .modifier(ReviewMonoIfNeeded(on: mono))
        .help(fullHelp)
    }
    /// 行内两侧都是中截断，长值只剩头尾；tooltip 必须给出**完整**的原值与新值，
    /// 调用方传进来的 `help` 只当抬头。
    private var fullHelp: String {
        var lines: [String] = []
        if !help.isEmpty { lines.append(help) }
        if let new {
            lines.append("原：" + (old.isEmpty ? "（空）" : old))
            lines.append("新：" + new)
        } else {
            lines.append(old.isEmpty ? "（空）" : old)
        }
        return lines.joined(separator: "\n")
    }

}

private struct ReviewMonoIfNeeded: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.fontDesign(.monospaced) } else { content }
    }
}

// MARK: - 专辑卡（组头）

/// 组头要摆出来的一条组级差异。
struct AlbumCardDiff: Identifiable {
    var id: String { label }
    var label: String
    var old: String
    /// nil = 整组都不改这个字段。
    var new: String?
    var help: String = ""

    /// 封面也是专辑级字段，它同样只该在组级摘要里说一次。
    ///
    /// 左边那张 160pt 大图回答的是「这是哪张专辑」，这一格回答的是
    /// 「它会替掉什么」—— 两码事，所以卡上两样都要有。整组不写封面就返回 nil。
    static func artwork(new: Data?, old: Data?, count: Int) -> AlbumCardDiff? {
        guard let new else { return nil }
        let img = NSImage(data: new)
        let meta = ArtworkMeta(data: new, image: img, source: "", role: "")
        let newText = "\(meta.pixelWidth)×\(meta.pixelHeight)"
        return AlbumCardDiff(
            label: "封面",
            old: old != nil ? "原封面" : "",
            new: newText,
            help: "封面：本组 \(count) 个文件会写入同一张 \(meta.line)\n"
                + (old != nil
                   ? "会替换掉这些文件现在的封面（大图右下角那张小图）"
                   : "这些文件现在没有封面")
                + "\n某一行若要写的不是这张，会在那一行单独亮一枚橙色「封面 ≠ 组」")
    }
}

/// 一张专辑卡要画的全部内容。两个复核窗各自把自己的模型转成它。
struct AlbumCardInfo {
    var albumTitle: String
    var artist: String?
    var year: String?
    /// 「45 首」这类曲目表规模。
    var trackCountText: String?
    var sourceName: String?
    /// 专辑模式才有的文件夹名。
    var folderName: String?
    /// 「对齐 5/6」。逐首模式传「本组 4 首」。
    var alignedText: String?
    var diffs: [AlbumCardDiff] = []
    /// 组级 diff 摘要末尾那句灰色小字：「以上应用到本组 5 首」。
    /// 没有它，摘要读起来像是「这张专辑的属性」，而不是「本次会写进这 5 个文件的值」。
    var diffFootnote: String?

    /// 将写入的新封面字节。
    var newArtwork: Data?
    /// 组内文件原本就有的封面 —— 有它才谈得上「原 → 新」对比。
    var oldArtwork: Data?
    var artworkSource: String = ""
    /// 「写入本组 5 个文件」。
    var artworkNote: String?

    /// 未匹配组：整张卡降调成灰卡。
    var isUnmatched: Bool = false
    /// 卡上要说的一句话（未匹配原因、整组警告）。
    var note: String?
}

/// 组头 = 一张专辑卡。左边 160pt 大封面，右边身份 + 组级 diff，右上角操作。
///
/// 高度约 176（封面 160 + 卡片内边距 8×2），是整个复核窗里唯一一处「大」，
/// 因为它承载的正是唯一一个真正要人眼定夺的决定。
struct AlbumCardHeader<Actions: View>: View {

    let info: AlbumCardInfo
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)?
    @ViewBuilder var actions: Actions

    private var newImage: NSImage? { info.newArtwork.flatMap { NSImage(data: $0) } }
    private var oldImage: NSImage? { info.oldArtwork.flatMap { NSImage(data: $0) } }

    /// 「未匹配」这一组压根没有专辑，也就没有封面可看 ——
    /// 给它留 160pt 的音符占位框纯属浪费一屏，压成一张矮灰卡即可。
    private var isSlim: Bool { info.isUnmatched && info.newArtwork == nil }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            artStack
            VStack(alignment: .leading, spacing: Theme.Spacing.xs2) {
                titleLine
                metaLine
                if let note = info.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(info.isUnmatched ? Color.secondary : Theme.Colors.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 组级 diff 压到卡片底部，与大封面的下沿齐平：
                // 上半是「这是哪张专辑」（身份），下半是「它会改掉什么」（后果），
                // 中间那口气就是两件事的分界。
                Spacer(minLength: Theme.Spacing.s)
                if !info.diffs.isEmpty {
                    diffWrap
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.s)
        .frame(height: isSlim ? nil : Theme.Size.reviewAlbumArt + Theme.Spacing.s * 2)
        .background(info.isUnmatched ? Theme.Colors.chipFill : Color.clear)
    }

    // MARK: 左侧封面（新 + 右下角叠的原）

    private var artStack: some View {
        ZStack(alignment: .bottomTrailing) {
            ArtworkHoverPreview(
                image: newImage,
                meta: info.newArtwork.map {
                    ArtworkMeta(data: $0, image: newImage,
                                source: info.artworkSource,
                                role: "新封面 · 本次将写入")
                },
                size: side,
                corner: Theme.Radius.l,
                help: newArtHelp)
            .shadow(color: Theme.Colors.artworkShadow, radius: 6, y: 2)

            if info.oldArtwork != nil {
                ArtworkHoverPreview(
                    image: oldImage,
                    meta: info.oldArtwork.map {
                        ArtworkMeta(data: $0, image: oldImage,
                                    source: "文件内嵌",
                                    role: "原封面 · 文件里现有的")
                    },
                    size: Theme.Size.reviewArtInset,
                    corner: Theme.Radius.s,
                    help: "原 → 新：左上是即将写入的新封面，这张小图是组内文件现在的封面。\n悬停任一张看大图与尺寸/字节/格式。")
                .background(Theme.Colors.cardFill,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .padding(Theme.Spacing.xs)
                .shadow(color: Theme.Colors.artworkShadow, radius: 4, y: 1)
            }
        }
        .frame(width: side, height: side)
    }

    private var side: CGFloat {
        isSlim ? Theme.Size.reviewArtInset : Theme.Size.reviewAlbumArt
    }

    private var newArtHelp: String {
        guard info.newArtwork != nil else { return "本次不写入封面" }
        var s = "新封面 · 本次将写入"
        if let n = info.artworkNote { s += "\n" + n }
        s += "\n悬停 0.3 秒看大图，点一下再放大一倍。"
        return s
    }

    // MARK: 右侧两行 + 操作

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            if let onToggleCollapse {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.Typo.caption)
                }
                .buttonStyle(.borderless)
                .help("折叠/展开这一组")
            }
            Text(info.albumTitle)
                .font(Theme.Typo.heroTitle)
                .foregroundStyle(info.isUnmatched ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.middle)
                .help(info.albumTitle)

            Spacer(minLength: Theme.Spacing.s)

            actions
                .controlSize(.small)
        }
    }

    private var metaLine: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs2) {
                ForEach(Array(metaParts.enumerated()), id: \.offset) { i, t in
                    if i > 0 {
                        Text("·").font(Theme.Typo.badge).foregroundStyle(.tertiary)
                    }
                    Text(t)
                        .font(Theme.Typo.heroSubtitle)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1).truncationMode(.tail)
                }
                if let s = info.sourceName { Chip(text: s) }
                Spacer(minLength: 0)
            }
            // 「艺术家 · 年份 · N 首」，艺术家一长就被尾截断；全文挂 tooltip。
            .help(metaParts.joined(separator: " · "))
            HStack(spacing: Theme.Spacing.xs2) {
                if let f = info.folderName {
                    Label(f, systemImage: "folder")
                        .font(Theme.Typo.badge)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("来源文件夹：" + f)
                }
                if let al = info.alignedText {
                    Chip(text: al, tinted: !info.isUnmatched)
                }
                Spacer(minLength: 0)
            }
            // 封面的尺寸/字节。悬停预览里也有，但摆在这里是给「不动鼠标的那一眼」看的：
            // 600×600 与 100×100 的差别，光看缩略图是看不出来的。
            if let line = artworkLine {
                Text(line)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private var artworkLine: String? {
        guard let data = info.newArtwork else { return nil }
        var s = ArtworkMeta(data: data, image: newImage,
                            source: "", role: "").line
        if info.oldArtwork != nil { s += " · 右下角是原封面" }
        if let n = info.artworkNote?.split(separator: "；").first { s = String(n) + " · " + s }
        return s
    }

    /// 艺术家 · 年份 · 曲目表规模。分隔点只摆在**两项之间** ——
    /// 未匹配组没有艺术家，无条件前置一个「·」会变成「· 2 首」这种孤儿标点。
    private var metaParts: [String] {
        var parts: [String] = []
        if let a = info.artist, !a.isEmpty { parts.append(a) }
        if let y = info.year, !y.isEmpty { parts.append(y) }
        if let t = info.trackCountText, !t.isEmpty { parts.append(t) }
        return parts
    }

    /// 组级 diff 摘要。**专辑级字段只在这里说一次** —— 专辑 / 专辑艺术家 / 年份 /
    /// 流派 / 封面 / 单碟碟号。行里不再重复，只有与这里不同的那一行才会亮一枚橙 chip。
    private var diffWrap: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(Array(stride(from: 0, to: info.diffs.count, by: 2)), id: \.self) { i in
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(info.diffs[i..<min(i + 2, info.diffs.count)]) { d in
                        DiffInline(label: d.label, old: d.old, new: d.new,
                                   unchangedText: d.old.isEmpty ? "—" : d.old,
                                   help: d.help)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
            if let f = info.diffFootnote {
                Text(f)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help("以上几项整组同一个值，行里不再逐首重复。"
                        + "\n某一行若在这些字段上与组不同（换过候选、自带别的封面），"
                        + "会在那一行单独亮一枚橙色 chip。")
            }
        }
    }
}

extension AlbumCardHeader where Actions == EmptyView {
    init(info: AlbumCardInfo, isCollapsed: Bool = false, onToggleCollapse: (() -> Void)? = nil) {
        self.init(info: info, isCollapsed: isCollapsed,
                  onToggleCollapse: onToggleCollapse) { EmptyView() }
    }
}

// MARK: - 曲目行

/// 曲目行的几个固定列宽。泛型结构体里放不了静态存储属性，所以摆在外面。
private enum TrackRowCol {
    static let check: CGFloat = 18
    static let dot: CGFloat = 12
    static let chevron: CGFloat = 16
    /// 副行缩进到文件名那一列。
    static var indent: CGFloat { check + dot + Theme.Spacing.s * 2 }
}

/// 一个文件一行（舒适密度两层，紧凑密度一层）。两个复核窗共用同一份布局。
///
/// 主行只回答「这个文件对到的曲子对不对」：`文件名 → 新标题`。
/// 左边是磁盘上的事实，右边是即将写入的结果，中间一个箭头 —— 不必再记哪一列是哪个字段。
///
/// **行内 chips 只留这一首自己的事**：歌词、多碟时的碟号、与专辑封面不同的封面……
/// 专辑级字段（专辑/专辑艺术家/年份/流派/封面/单碟碟号）归专辑卡说一次，见 `ReviewGroupContext`。
struct TrackReviewRow<Trailing: View>: View {

    let item: AutoMatchReviewItem
    @Binding var accepted: Bool
    var density: ReviewDensity = .comfortable
    var onlyChangedFields: Bool = false
    /// 组头那张专辑封面的字节。行内缩略图**只在与它不同时**才出现。
    var albumArtwork: Data?
    /// 组级字段口径。传了它，专辑级字段就从这一行的 chips 里消失；
    /// 本行在这些字段上与组不同时，才回来一枚橙色的。
    var group: ReviewGroupContext?
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)?
    /// 点某枚 chip = 这个文件不写那个字段（再点恢复）。nil = 只读（离屏渲染用）。
    var onToggleField: ((ReviewFieldKey) -> Void)?
    /// 「换候选 ▾」由各窗自己接线（专辑模式换的是同一张曲目表里的曲目，逐首模式换的是搜索候选）。
    @ViewBuilder var trailing: Trailing

    /// 行内封面：只有和整组那张不一样才画。一样就不占位 —— 一列一模一样的缩略图是纯噪音。
    private var inlineArtwork: Data? {
        guard let mine = item.artwork else { return nil }
        if let album = albumArtwork ?? group?.artwork, album == mine { return nil }
        return mine
    }

    private var chips: [ReviewChangeChip] {
        item.changeChips(includeUnchanged: !onlyChangedFields, group: group)
    }

    /// 主行高度。舒适密度下主行 26 + 副行 18 = 44，与 `reviewRowHeight` 严格相等 ——
    /// 行高是这次重设计要拿渲染像素对账的数，不能靠 padding 凑。
    private var mainLineHeight: CGFloat {
        density == .compact ? Theme.Size.reviewRowHeightCompact : 26
    }
    private var subLineHeight: CGFloat { Theme.Size.reviewRowHeight - 26 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainLine
            if density.isTwoLine {
                subLine
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: density.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onToggleExpand?() }
        .opacity(item.isReloading ? 0.5 : 1)
        // 紧凑密度把副行整条收掉了，那些信息不能就此消失 —— 悬停整行就是它们的去处。
        .modifier(ReviewRowHelp(text: density == .compact ? compactHelp : nil))
    }

    // MARK: 主行：勾选 · 状态点 · 文件名 → 新标题 ·（紧凑时）音轨 · 行内封面 · 换候选 ▾

    private var mainLine: some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: $accepted)
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!item.hasSomethingToWrite)
                .frame(width: TrackRowCol.check)
                .help(rowCheckHelp)

            StatusDot(color: TrackReviewRow.statusColor(item.status))
                .frame(width: TrackRowCol.dot)
                .help(item.statusLabel + (item.ignoredReason.map { "：" + $0 } ?? ""))

            fileToTitle

            Spacer(minLength: Theme.Spacing.s)

            // 紧凑密度**不摆 chips**：30 pt 一行里塞五枚小胶囊，谁也读不出来，
            // 只会把「文件名 → 标题」这条主线挤没。留下的只有每首必然不同的音轨号。
            if density == .compact {
                trackCell.fixedSize()
            }

            if let data = inlineArtwork {
                let img = NSImage(data: data)
                ArtworkHoverPreview(
                    image: img,
                    meta: ArtworkMeta(data: data, image: img,
                                      source: item.sourceName ?? "",
                                      role: "本行单独的封面 · 与专辑封面不同"),
                    size: Theme.Size.reviewInlineThumb,
                    corner: Theme.Radius.xs,
                    help: "这一行要写入的封面与组头那张不是同一张。悬停看大图。")
            }

            trailing

            if let onToggleExpand {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Typo.caption)
                }
                .buttonStyle(.borderless)
                .frame(width: TrackRowCol.chevron)
                .help("展开完整字段级差异（含歌词、注释这类长文本）")
            }
        }
        .frame(height: mainLineHeight)
    }

    /// 整行勾选框的提示。**字段被逐个划掉之后必须说出来** ——
    /// 否则「勾着却什么都没写」会变成一次无声的失败。
    private var rowCheckHelp: String {
        guard item.hasSomethingToWrite else { return "这一行没有任何可写入的改动" }
        let excluded = item.excludedKeys
        guard !excluded.isEmpty else { return "勾选后本行会被写入（共 \(item.changeCount) 处）" }
        let names = excluded.sorted { $0.sortRank < $1.sortRank }.map(\.localizedName)
        if item.writesSomething {
            return "勾选后本行会被写入 \(item.acceptedChangeCount)/\(item.changeCount) 处。"
                + "\n已排除：" + names.joined(separator: "、")
        }
        return "本行的字段被逐个排除干净了，即便勾着也不会写任何东西。"
            + "\n已排除：" + names.joined(separator: "、")
    }

    /// `文件名 → 新标题`：左边磁盘事实（次要色），右边写入结果（正文色加粗）。
    private var fileToTitle: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(item.fileName)
                .font(Theme.Typo.tableCell)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(item.fileName)
                .layoutPriority(1)

            if let t = item.change(.title)?.newDisplay {
                Image(systemName: "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
                Text(t)
                    .font(Theme.Typo.tableCell.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(2)
                    .help("标题\n原：\(item.change(.title)?.oldDisplay ?? "")\n新：\(t)")
            } else {
                Image(systemName: "arrow.right")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.quaternary)
                Text(item.currentValue(.title).isEmpty ? "标题不改动" : item.currentValue(.title))
                    .font(Theme.Typo.tableCell)
                    .foregroundStyle(Theme.Colors.placeholderText)
                    .lineLimit(1).truncationMode(.middle)
                    .help("标题：本次不改动")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 副行：艺术家 原→新 · 音轨 原→新 · 变更 chips

    /// 音轨那一格。舒适密度摆在副行，紧凑密度提到主行 —— 两处必须是同一格，
    /// 否则同一个数在两种密度下会长成两个样子。
    ///
    /// 专辑模式有曲目表，能算出「1-07/24」这种位置；逐首模式没有曲目表，
    /// 位置恒为 nil —— 那就退回要写入的那个值，否则这一格会假装「本次不改」。
    private var trackCell: some View {
        DiffInline(label: "音轨",
                   old: item.currentValue(.track),
                   new: item.change(.track) == nil ? nil
                        : (item.trackPositionDisplay ?? item.change(.track)?.newDisplay),
                   mono: true,
                   unchangedText: item.trackPositionDisplay ?? (item.currentValue(.track).isEmpty ? "—" : item.currentValue(.track)),
                   help: item.trackHelp ?? "本次不改动音轨号")
    }

    private var subLine: some View {
        HStack(spacing: Theme.Spacing.m) {
            DiffInline(label: "艺术家",
                       old: item.currentValue(.artist),
                       new: item.change(.artist)?.newDisplay,
                       unchangedText: item.currentValue(.artist).isEmpty ? "—" : item.currentValue(.artist),
                       help: TrackReviewRow.fieldHelp(item, .artist))
                .fixedSize()

            trackCell.fixedSize()

            chipStrip

            if item.status != .matched, let reason = item.ignoredReason ?? item.errorText {
                Label(reason.replacingOccurrences(of: "\n", with: " / "),
                      systemImage: "info.circle")
                    .font(Theme.Typo.badge)
                    .foregroundStyle(Theme.Colors.warning)
                    .lineLimit(1).truncationMode(.tail)
                    // 失败原因常常是一整串「源：原因；源：原因」，一行装不下，
                    // 而这一行恰恰是用户唯一能据以判断「为什么没匹配上」的信息。
                    .help(reason)
            }

            Spacer(minLength: 0)

            if item.manuallyChosen {
                Chip(text: "已手动确认", tinted: true, systemImage: "hand.point.up.left.fill")
            }
            if let s = item.sourceName {
                Text(s)
                    .font(Theme.Typo.badge)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, TrackRowCol.indent)
        .padding(.trailing, TrackRowCol.chevron)
        .frame(height: subLineHeight)
    }

    private var chipStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(chips) { c in
                ReviewChangeChipView(chip: c, onToggle: toggleAction(for: c))
            }
        }
    }

    /// 只给「背后真有一处改动」的 chip 接线，灰色的「不变」chip 保持不可点。
    private func toggleAction(for chip: ReviewChangeChip) -> (() -> Void)? {
        guard let key = chip.key, let onToggleField else { return nil }
        return { onToggleField(key) }
    }

    /// 紧凑密度下整行的悬停提示：把被压掉的那一层（艺术家、变更 chips、忽略原因）
    /// 原样说出来。**紧凑是「少画」，不是「少知道」**。
    private var compactHelp: String {
        var lines: [String] = [item.fileName]
        if let c = item.change(.title) {
            lines.append("标题：\(c.oldDisplay) → \(c.newDisplay)")
        }
        if let c = item.change(.artist) {
            lines.append("艺术家：\(c.oldDisplay) → \(c.newDisplay)")
        } else {
            let v = item.currentValue(.artist)
            lines.append("艺术家：" + (v.isEmpty ? "本次不改动" : v + "（不改动）"))
        }
        if let t = item.trackHelp {
            lines.append(t.replacingOccurrences(of: "\n", with: " · "))
        }
        let cs = chips
        if !cs.isEmpty {
            lines.append("变更：" + cs.map { chip -> String in
                if chip.excluded { return chip.label + "（已排除）" }
                return chip.kind == .unchanged ? chip.label + "（不变）" : chip.label
            }.joined(separator: " · "))
        }
        if let reason = item.ignoredReason ?? item.errorText {
            lines.append(reason.replacingOccurrences(of: "\n", with: " / "))
        }
        if item.manuallyChosen { lines.append("已手动确认") }
        if let s = item.sourceName { lines.append("来源：" + s) }
        return lines.joined(separator: "\n")
    }

    static func statusColor(_ s: AutoMatchResult.Status) -> Color {
        switch s {
        case .matched: return Theme.Colors.matched
        case .ignored: return Theme.Colors.ignored
        case .failed:  return Theme.Colors.failed
        case .noQuery: return Theme.Colors.warning
        }
    }

    static func fieldHelp(_ item: AutoMatchReviewItem, _ f: TagEdit.Field) -> String {
        let name = f.localizedName
        guard let c = item.change(f) else {
            let v = item.currentValue(f)
            return v.isEmpty ? "\(name)：现在是空的，本次也不写" : "\(name)：\(v)（本次不改动）"
        }
        return "\(name)\n原：\(c.oldDisplay)\n新：\(c.newDisplay)"
    }
}

extension TrackReviewRow where Trailing == EmptyView {
    init(item: AutoMatchReviewItem,
         accepted: Binding<Bool>,
         density: ReviewDensity = .comfortable,
         onlyChangedFields: Bool = false,
         albumArtwork: Data? = nil,
         group: ReviewGroupContext? = nil,
         isExpanded: Bool = false,
         onToggleExpand: (() -> Void)? = nil,
         onToggleField: ((ReviewFieldKey) -> Void)? = nil) {
        self.init(item: item, accepted: accepted, density: density,
                  onlyChangedFields: onlyChangedFields, albumArtwork: albumArtwork,
                  group: group, isExpanded: isExpanded,
                  onToggleExpand: onToggleExpand,
                  onToggleField: onToggleField) { EmptyView() }
    }
}

/// 整行的悬停提示。`nil` 时一个修饰符都不挂 —— 舒适密度下行内每一格已经各有各的
/// 提示，再往整行糊一层会把它们全盖掉。
private struct ReviewRowHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

// MARK: - 顶部工具条

/// 密度切换 + 「只看有改动的字段」 + 右侧逐源结果条。两个复核窗共用。
struct ReviewToolbar<Trailing: View>: View {

    @ObservedObject var display: ReviewDisplayStore
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            DensityToggle(density: $display.density)

            Toggle("只看有改动的字段", isOn: $display.onlyChangedFields)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(Theme.Typo.badge)
                .help("打开后隐藏「本次不动」的灰色 chips，只剩真正会被写入的那几个字段。")

            trailing
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.chipFill)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 按文件选写哪几个字段
//
// ── 用户原话 ──「全部匹配后有些文件不想写碟号、有些不想写音轨号，现在改不了。」
//
// 同一件事给了四个入口，粒度从细到粗，共用同一份状态（每一行的 `acceptedFields`）：
//   ① 行内 chips 点一下      —— 一个文件的一个字段
//   ② 「>」展开里的勾选框     —— 同上，但看得见完整的「原 → 新」
//   ③ 专辑卡「本组字段」菜单   —— 一整组的一个字段（「整组不写碟号」）
//   ④ 工具条「全部字段」菜单   —— 整张复核表的一个字段（「一次性去掉所有音轨号」）
// 四个入口互相立刻可见：③④ 改完，行里那几枚 chip 当场变成划线态。

/// 一批文件在**某一个写入项**上的勾选统计。菜单靠它决定画勾、画横杠还是空。
struct ReviewFieldTally: Identifiable {
    let key: ReviewFieldKey
    /// 这一批里有几个文件真会改这个字段。
    let total: Int
    /// 其中有几个是勾中的。
    let accepted: Int

    var id: String { key.id }
    /// 全勾。
    var isOn: Bool { total > 0 && accepted == total }
    /// 一部分勾一部分没勾 —— 菜单项要画成横杠而不是勾，否则用户会以为「全都会写」。
    var isMixed: Bool { accepted > 0 && accepted < total }

    /// 菜单项右边那截：「音轨号  3/5」。
    var countText: String { accepted == total ? "\(total)" : "\(accepted)/\(total)" }

    /// 把一批复核行压成逐字段的统计。顺序 = 字段声明顺序，封面殿后。
    static func make(_ items: [AutoMatchReviewItem]) -> [ReviewFieldTally] {
        var total: [ReviewFieldKey: Int] = [:]
        var accepted: [ReviewFieldKey: Int] = [:]
        for item in items {
            for key in item.togglableKeys {
                total[key, default: 0] += 1
                if item.isAccepted(key) { accepted[key, default: 0] += 1 }
            }
        }
        return total.keys
            .sorted { $0.sortRank < $1.sortRank }
            .map { ReviewFieldTally(key: $0, total: total[$0] ?? 0, accepted: accepted[$0] ?? 0) }
    }
}

/// 「本组字段 ▾」/「全部字段 ▾」两个批量菜单共用的一个壳。
///
/// 菜单里**只列这一批真会改动的字段** —— 十二个字段全列出来，其中十个是灰的，
/// 等于让用户在一堆点不动的东西里找那两个能点的。
struct ReviewFieldMenu: View {

    let title: String
    var systemImage: String = "slider.horizontal.3"
    /// 「本组 5 首」「当前复核表 32 首」这类范围说明，进菜单抬头与 tooltip。
    let scopeNote: String
    let tallies: [ReviewFieldTally]
    /// (写入项, 开/关)。调用方负责把它落到这一批的每一行上。
    var onSet: (ReviewFieldKey, Bool) -> Void

    var body: some View {
        Menu {
            if tallies.isEmpty {
                Text("这一批没有任何会改动的字段")
            } else {
                Section(scopeNote) {
                    Button("全部写入") { for t in tallies { onSet(t.key, true) } }
                        .disabled(tallies.allSatisfy(\.isOn))
                    Button("全部不写") { for t in tallies { onSet(t.key, false) } }
                        .disabled(tallies.allSatisfy { $0.accepted == 0 })
                }
                Section("逐个字段") {
                    ForEach(tallies) { t in
                        Toggle(isOn: Binding(get: { t.isOn },
                                             set: { onSet(t.key, $0) })) {
                            // 混合态在文字里说清「3/5」——macOS 的菜单勾选框没有第三种画法，
                            // 光看勾的有无会把「一半会写」误读成「全都不写」。
                            Text(t.isMixed
                                 ? "\(t.key.localizedName)（\(t.countText)）"
                                 : t.key.localizedName)
                        }
                        .help(helpText(t))
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(Theme.Typo.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tallies.isEmpty)
        .help(tallies.isEmpty
              ? "\(scopeNote)没有任何会改动的字段"
              : "\(scopeNote)：逐个字段批量开/关。关掉的字段这一批一个文件都不写，"
              + "行里会变成灰色划线的 chip。")
    }

    private func helpText(_ t: ReviewFieldTally) -> String {
        if t.isOn { return "\(t.key.localizedName)：\(t.total) 个文件都会写。关掉 = 这一批都不写。" }
        if t.accepted == 0 { return "\(t.key.localizedName)：\(t.total) 个文件都已排除，都不会写。" }
        return "\(t.key.localizedName)：\(t.total) 个文件里有 \(t.accepted) 个会写。"
            + "打开 = 全都写，关掉 = 全都不写。"
    }
}

/// 「>」展开区里的一行字段级差异：**前面多一个勾选框**，与行内那枚 chip 是同一个开关。
///
/// 为什么展开区也要一份：chips 只有字段名，看不见值；决定「这个碟号要不要写」
/// 常常得先看清它到底要写成什么。这里是唯一同时给出勾选框与完整「原 → 新」的地方。
struct ReviewFieldDiffRow: View {
    let key: ReviewFieldKey
    let oldValue: String
    let newValue: String
    let accepted: Bool
    var fieldWidth: CGFloat = 66
    var oldWidth: CGFloat = 240
    /// nil = 只读（离屏渲染）。
    var onToggle: ((Bool) -> Void)?

    var body: some View {
        GridRow {
            Toggle("", isOn: Binding(get: { accepted },
                                     set: { onToggle?($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(onToggle == nil)
                .frame(width: 18)
                .help(accepted
                      ? "会写入这个字段。取消勾选 = 这个文件不写它。"
                      : "已排除：这个文件不写这个字段。勾上恢复。")
            Text(key.localizedName)
                .font(Theme.Typo.caption)
                .foregroundStyle(accepted ? Color.secondary : Theme.Colors.placeholderText)
                .strikethrough(!accepted, color: Theme.Colors.placeholderText)
                .frame(width: fieldWidth, alignment: .leading)
            Text(oldValue.isEmpty ? "（空）" : oldValue)
                .font(Theme.Typo.caption)
                .foregroundStyle(oldValue.isEmpty ? Theme.Colors.placeholderText : Color.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(oldValue)
                .frame(width: oldWidth, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(Theme.Typo.badge)
                .foregroundStyle(accepted ? AnyShapeStyle(.tertiary)
                                          : AnyShapeStyle(Theme.Colors.placeholderText))
                .frame(width: 14)
            // 被排除时新值整条划掉：这一格说的是「将写入什么」，
            // 排除之后它什么都不写，就不该再用强调色宣告自己。
            Text(newValue.isEmpty ? "（空）" : newValue)
                .font(Theme.Typo.caption)
                .foregroundStyle(accepted ? Color.accentColor : Theme.Colors.placeholderText)
                .strikethrough(!accepted, color: Theme.Colors.placeholderText)
                .lineLimit(1).truncationMode(.middle)
                .help(newValue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 展开区那张字段表的表头。列宽与 `ReviewFieldDiffRow` 必须一一对上。
struct ReviewFieldDiffHeader: View {
    var fieldWidth: CGFloat = 66
    var oldWidth: CGFloat = 240

    var body: some View {
        GridRow {
            Text("写").font(Theme.Typo.badge).foregroundStyle(.secondary)
                .frame(width: 18)
                .help("勾选 = 这个文件会写这个字段。与行尾那枚 chip 是同一个开关。")
            Text("字段").font(Theme.Typo.badge).foregroundStyle(.secondary)
                .frame(width: fieldWidth, alignment: .leading)
            Text("原值").font(Theme.Typo.badge).foregroundStyle(.secondary)
                .frame(width: oldWidth, alignment: .leading)
            Color.clear.frame(width: 14, height: 1)
            Text("新值").font(Theme.Typo.badge).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

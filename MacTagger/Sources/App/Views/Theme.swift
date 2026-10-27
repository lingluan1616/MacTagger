//
//  Theme.swift
//  MacTagger — 视觉规范（设计令牌）
//
//  方向：Apple 原生克制 + 专辑封面前置。
//  参照：Apple Music(Mac) 的侧栏与列表、Meta(Nightbirds) 的封面优先检查器、
//        Things 3 的留白与字级层次、访达的 inset 表格。
//  原则：尊重系统强调色与深浅色；一套间距/圆角/字级；语义色只用于状态，不做装饰。
//  所有视图从这里取值，不在视图里写魔法数字。
//

import SwiftUI
import AppKit

enum Theme {

    // MARK: 间距 / 圆角

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        /// 设计稿的 6：封面计数行图标与文字、状态栏内部小间隙
        static let xs2: CGFloat = 6
        static let s: CGFloat = 8
        /// 设计稿的 10：卡片之间、字段标签与输入框之间、Hero 内部、状态栏 gap
        static let s2: CGFloat = 10
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        /// 检查器大封面（设计稿 heroR=12）
        static let l: CGFloat = 12
        static let xl: CGFloat = 18
        /// 侧栏行 / 小按钮（设计稿 sbrow border-radius:7）
        static let row: CGFloat = 7
    }

    // MARK: 字级层次

    enum Typo {
        /// 检查器顶部的曲名（设计稿 heroTitle=18 / 600）
        static let heroTitle = Font.system(size: 18, weight: .semibold)
        /// 卡片标题（设计稿 card() 标题 11px / 600 次要色）
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// 表单左侧字段名（设计稿 field() 标签 12px）
        static let fieldLabel = Font.system(size: 12)
        /// 表单值（设计稿 field() 输入框 13px）
        static let value = Font.system(size: 13)
        /// 数字字段：等宽 13（设计稿 minifield 输入框 13px + MONO）
        static let valueMono = Font.system(size: 13, design: .monospaced)
        /// 数字列 / 技术参数：等宽数字
        static let mono = Font.system(.callout, design: .monospaced)
        static let caption = Font.caption
        /// 设计稿里反复出现的 11px 小字：封面计数行、状态栏、胶囊、minifield 标签、侧栏分组标题
        static let small = Font.system(size: 11)
        /// 表格单元格（设计稿 cell=12.5）
        static let tableCell = Font.system(size: 12.5)
        /// 表格里的派生列（设计稿"格式"列：次要色 + cell-1）
        static let tableCellSmall = Font.system(size: 11.5)
        /// 表格数字列：12.5 等宽（设计稿数字列同 cell 字号 + MONO）
        static let tableCellMono = Font.system(size: 12.5, design: .monospaced)
        /// 表头（设计稿 hdr：11px / 600 次要色）
        static let tableHeader = Font.system(size: 11, weight: .semibold)
        /// 侧栏一行目录名（设计稿 sbrow font-size:13）
        static let sidebarRow = Font.system(size: 13)
        /// 技术参数网格（设计稿 tech_inner：12px + MONO + tabular-nums）
        static let techLabel = Font.system(size: 12)
        static let techValue = Font.system(size: 12, design: .monospaced)

        // —— 以下为视觉重做新增 ——

        /// Sheet 顶部标题
        static let sheetTitle = Font.system(.title3, weight: .semibold)
        /// Sheet 标题下的一句说明
        static let sheetSubtitle = Font.caption
        /// 卡片内的字段分组小标签（基本 / 编号 / 更多）
        static let groupLabel = Font.system(.caption, weight: .medium)
        /// 胶囊徽章（设计稿 pill：11px + MONO）
        static let badge = Font.system(size: 11)
        /// Hero 区曲名下方的一行（设计稿 sub_line：13px 次要色）
        static let heroSubtitle = Font.system(size: 13)
        /// 空态标题
        static let emptyTitle = Font.system(.title3, weight: .medium)
        /// 等宽小字（复核表的差异、歌词预览）
        static let monoSmall = Font.system(.caption, design: .monospaced)
        /// 等宽数字（计数、匹配分）
        static let digits = Font.callout.monospacedDigit()
        static let digitsSmall = Font.caption.monospacedDigit()
    }

    // MARK: 语义色（只表达状态）

    enum Colors {

        // MARK: 明暗动态色的构造器
        //
        // 原则：**能用系统语义色的一律用系统色** —— 它们由 AppKit 自己按外观解析，
        // 视图里不需要任何 `@Environment(\.colorScheme)` 判断。
        // 只有系统压根没有对应值的（透明白/黑覆盖层、投影浓度、强调色浅底）才走下面的
        // `NSColor(name:dynamicProvider:)`，同样是外观驱动，同样不需要视图配合。

        /// 明暗各给一个 NSColor，交给 AppKit 按当前外观解析。
        private static func dynamic(light: @autoclosure @escaping () -> NSColor,
                                    dark: @autoclosure @escaping () -> NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark() : light()
            })
        }

        /// 覆盖层：浅色压黑、深色压白（macOS 深色的层次就是靠透明白堆出来的）。
        private static func overlay(lightBlack: CGFloat, darkWhite: CGFloat) -> Color {
            dynamic(light: NSColor(white: 0, alpha: lightBlack),
                    dark: NSColor(white: 1, alpha: darkWhite))
        }

        /// 强调色浅底：保留用户在系统设置里选的强调色，只按外观换透明度。
        private static func accentTint(light: CGFloat, dark: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                var accent = NSColor.controlAccentColor
                appearance.performAsCurrentDrawingAppearance {
                    accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
                }
                return accent.withAlphaComponent(isDark ? dark : light)
            })
        }

        // MARK: 状态色（全部是系统语义色，深浅自动）

        static let dirty = Color.accentColor                    // 有未保存改动
        static let matched = Color(nsColor: .systemGreen)       // 自动匹配：已匹配 #34C759 / #30D158
        static let ignored = Color.secondary                    // 自动匹配：低于阈值
        static let failed = Color(nsColor: .systemRed)          // 失败
        static let warning = Color(nsColor: .systemOrange)      // 文件诊断警告
        static let readOnly = Color.secondary

        /// 「—」「（空）」这类占位文字：比次要色再低一级。
        /// 原先散在各视图里的 `Color.secondary.opacity(0.55~0.65)` 全部收敛到这里 ——
        /// 那种写法在深色下会把本就半透明的白再乘一次，暗到几乎看不见。
        static let placeholderText = Color(nsColor: .tertiaryLabelColor)

        // MARK: 中性面与线

        /// 卡片底。深色下 `controlBackgroundColor` 与窗口底同为 #1E1E1E，卡片就不"浮起"了，
        /// 所以深色单独抬到 #262626（配色表：比窗口底浮起一级）。浅色仍走系统色（#FFFFFF）。
        static let cardFill = dynamic(light: .controlBackgroundColor,
                                      dark: NSColor(srgbRed: 38/255, green: 38/255, blue: 38/255, alpha: 1))
        static let cardStroke = overlay(lightBlack: 0.08, darkWhite: 0.09)

        /// 发丝线：系统 `separatorColor` 本身就是 黑10% / 白10%，与配色表一致，直接用系统色。
        static let hairline = Color(nsColor: .separatorColor)

        static let artworkPlaceholder = overlay(lightBlack: 0.06, darkWhite: 0.07)

        /// 表格斑马纹。当前列表用 SwiftUI 原生 `Table`（系统自带交替底色），
        /// 此令牌留给自绘列表/分组行，避免届时再写魔法数字。
        static let rowAlt = overlay(lightBlack: 0.030, darkWhite: 0.035)

        /// 输入框描边。当前输入框用系统 `TextField`（自带边框），
        /// 此令牌留给自绘输入区，同样避免魔法数字。
        static let fieldStroke = overlay(lightBlack: 0.12, darkWhite: 0.14)

        // MARK: 封面 / 装饰

        /// 封面缩略图的描边：深色模式下没有它，深色封面会糊进背景。
        static let artworkStroke = overlay(lightBlack: 0.12, darkWhite: 0.14)

        /// 封面投影。深色下必须**更重**才看得出浮起（浅色 18% → 深色 55%），
        /// 这跟"深色要调淡"的直觉相反：深底上淡投影等于没有。
        static let artworkShadow = dynamic(light: NSColor(white: 0, alpha: 0.18),
                                           dark: NSColor(white: 0, alpha: 0.55))

        /// 胶囊 / 徽章底色。深色下多给 3 个点，白 7% 压在 #262626 卡片上几乎看不见。
        static let chipFill = overlay(lightBlack: 0.07, darkWhite: 0.10)

        /// 强调色的浅底（"当前""已改"这类状态胶囊）。
        static let accentSoft = accentTint(light: 0.15, dark: 0.22)

        /// 拖放高亮：虚线描边用实色，内部铺一层同色浅底。
        static let dropTarget = Color.accentColor
        static let dropTargetFill = accentTint(light: 0.06, dark: 0.16)

        // MARK: 自绘顶栏（TopBarView）

        /// 工具栏 / 标题栏底：设计稿 tbBg = rgba(246,245,243,0.96) / #232323
        static let toolbarBg = dynamic(
            light: NSColor(srgbRed: 246/255, green: 245/255, blue: 243/255, alpha: 0.96),
            dark: NSColor(srgbRed: 35/255, green: 35/255, blue: 35/255, alpha: 1))

        /// 顶栏搜索框底：设计稿 search = rgba(0,0,0,0.05) / #1c1c1e
        static let searchFieldBg = dynamic(
            light: NSColor(white: 0, alpha: 0.05),
            dark: NSColor(srgbRed: 28/255, green: 28/255, blue: 30/255, alpha: 1))

        /// 顶栏按钮悬停底：设计稿没画悬停态，按 macOS 惯例给 黑6% / 白8%。
        static let hoverFill = overlay(lightBlack: 0.06, darkWhite: 0.08)
    }

    // MARK: 尺寸

    enum Size {
        /// 表格行高（设计稿 row=30）
        static let tableRowHeight: CGFloat = 30
        /// 表头高（设计稿 hdrH=28）
        static let tableHeaderHeight: CGFloat = 28
        /// 表格封面缩略图（设计稿 thumb=22，圆角 4）
        static let tableThumb: CGFloat = 22
        /// 检查器大封面（设计稿 hero=176）
        static let inspectorHero: CGFloat = 176
        /// 检查器可拖宽的下限。给 336（= 设计稿宽）会把这一栏钉死拖不动，所以放到 300。
        static let inspectorMinWidth: CGFloat = 300
        /// 检查器默认宽（设计稿 insp=336）
        static let inspectorIdealWidth: CGFloat = 336
        /// 侧栏可拖窄的下限
        static let sidebarMinWidth: CGFloat = 180

        // —— 以下为视觉重做新增 ——

        /// 侧栏默认宽（设计稿 sidebar=206）
        static let sidebarIdealWidth: CGFloat = 206
        /// 侧栏可拖宽的上限
        static let sidebarMaxWidth: CGFloat = 280
        /// 侧栏一行目录的高度（设计稿 sbrow height:30）
        static let sidebarRowHeight: CGFloat = 30
        /// 侧栏整体内边距（设计稿 padding:10px 10px）
        static let sidebarPadding: CGFloat = 10
        static let contentMinWidth: CGFloat = 480
        /// 检查器可拖宽的上限
        static let inspectorMaxWidth: CGFloat = 460

        /// 检查器表单：左侧字段名的固定宽度（设计稿 labelW=62）
        static let fieldLabelWidth: CGFloat = 62
        /// 检查器输入框高度（设计稿 fieldH=24）
        static let fieldHeight: CGFloat = 24
        /// 输入框左右内边距（设计稿 field() padding:0 9px）
        static let fieldPadding: CGFloat = 9
        /// 年份 / 音轨 / 碟号这类短输入框的宽度上限（设计稿改为三等分栅格，此值留给别处）
        static let numericFieldWidth: CGFloat = 132
        /// Hero 区多张封面时底部的圆点
        static let heroDot: CGFloat = 6
        /// 状态圆点（设计稿行首 / 曲名后的圆点都是 7）
        static let statusDot: CGFloat = 7
        /// 底部状态栏高度（设计稿 statusbar height:26）
        static let statusBarHeight: CGFloat = 26

        /// Sheet 三档宽度
        static let sheetNarrow: CGFloat = 480
        static let sheetMedium: CGFloat = 640
        static let sheetWide: CGFloat = 860
        /// 复核表专用的第四档：一行要同时摆下「原 → 新」的标题、艺术家、音轨与封面，
        /// 860 摆不开就只能靠展开逐行点开看，正是要消灭的那种交互。
        static let sheetExtraWide: CGFloat = 1100

        // —— 以下为复核表「专辑卡」重设计新增 ——
        //
        // 复核的第一决定是「这一组该用哪张专辑」，而判断一张专辑对不对，
        // 人眼靠的是**封面**，不是那行小字。原先封面只有 22pt（表格缩略图令牌），
        // 等于把唯一能一眼判对错的信息压成了一个色块 —— 这批令牌就是来纠正这件事的。

        /// 复核表组头（专辑卡）的大封面。检查器 Hero 是 176，组头略小一档但仍是「一眼可辨」量级。
        static let reviewAlbumArt: CGFloat = 160
        /// 大封面右下角叠的「原封面」小图：新旧同框才比得出来。
        static let reviewArtInset: CGFloat = 48
        /// 曲目行行高（舒适密度，两行制：文件名→新标题 / 次要字段与变更 chips）。
        static let reviewRowHeight: CGFloat = 44
        /// 曲目行行高（紧凑密度，单行制，与表格行高同为 30）。
        static let reviewRowHeightCompact: CGFloat = 30
        /// 行内封面缩略图。**只在该曲封面与专辑封面不同时才出现**，否则整列不占位。
        static let reviewInlineThumb: CGFloat = 32
        /// 封面悬停预览面板里的大图边长。点一下可切到两倍。
        static let reviewPreview: CGFloat = 320

        /// 主窗口
        static let windowDefaultWidth: CGFloat = 1280
        static let windowDefaultHeight: CGFloat = 800
        static let windowMinWidth: CGFloat = 960
        static let windowMinHeight: CGFloat = 600
    }
}

// MARK: - 可复用构件

/// 分组卡片：圆角填充 + 发丝描边 + 内边距。检查器与各 sheet 的分组都用它。
struct CardModifier: ViewModifier {
    /// 设计稿 cardPad=12、cardR=10（= Theme.Radius.m）
    var padding: CGFloat = Theme.Spacing.m
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Theme.Colors.cardStroke)
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.Spacing.m) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// 分组小标题：小号、加粗、次要色、字距略开。
struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title)
                .font(Theme.Typo.sectionHeader)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

/// 状态圆点：用于表格行首与自动匹配复核表。
struct StatusDot: View {
    let color: Color
    var size: CGFloat = Theme.Size.statusDot
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// 封面占位：无封面时的统一样式。
struct ArtworkPlaceholder: View {
    var corner: CGFloat = Theme.Radius.xs
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.Colors.artworkPlaceholder)
            .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
    }
}

// MARK: - 新增构件（视觉重做）

extension SectionHeader {
    /// 右侧带附件的分组标题（计数胶囊、小按钮等）。
    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.init(title)
        self.trailing = AnyView(trailing())
    }
}

/// 小胶囊：文件数、已选 N 项、状态词。默认次要色，`tinted` 时用强调色浅底。
struct Chip: View {
    let text: String
    var tinted: Bool = false
    var systemImage: String? = nil
    /// 设计稿：状态栏胶囊 padding 1px 8px、侧栏文件数胶囊 padding 1px 7px。
    var horizontalPadding: CGFloat = Theme.Spacing.s

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage).font(Theme.Typo.badge)
            }
            Text(text).font(Theme.Typo.badge).monospacedDigit()
        }
        .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 1)
        .background(tinted ? Theme.Colors.accentSoft : Theme.Colors.chipFill, in: Capsule())
    }
}

/// 卡片内的字段分组小标签：一行文字 + 一条发丝线，用来把「基本 / 编号 / 更多」分开。
struct FieldGroupLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Typo.groupLabel)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Theme.Colors.hairline)
                .frame(height: 1)
        }
    }
}

/// Sheet 顶部标题栏：图标 + 标题 + 副标题（+ 右侧附件）。所有 sheet 共用。
struct SheetTitleBar<Trailing: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.Typo.sheetTitle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.Typo.sheetSubtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Spacing.m)
                trailing
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.m)
            Divider()
        }
    }
}

extension SheetTitleBar where Trailing == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Sheet 底部按钮条：上方一条发丝线 + `.bar` 材质。取消靠左、主操作靠右由调用方摆。
struct SheetButtonBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.s) { content }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.m)
                .background(.bar)
        }
    }
}

/// 只读键值行：左标签次要色右对齐、右值可选等宽。技术参数与各处摘要共用。
struct KeyValueRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    /// 悬停提示。默认给全文 —— 这一行只显示一行且中间截断，鼠标停上去必须能看见完整值。
    var help: String? = nil

    var body: some View {
        GridRow {
            Text(label)
                .font(Theme.Typo.techLabel)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? Theme.Typo.techValue : Theme.Typo.techLabel)
                .foregroundStyle(value.isEmpty ? Theme.Colors.placeholderText : Color.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? value)
                .gridColumnAlignment(.leading)
        }
    }
}

/// 统一空态：图标 + 标题 + 一句引导 + 可选操作。撑满可用空间，避免面板塌陷。
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: Theme.Spacing.xs) {
                Text(title).font(Theme.Typo.emptyTitle)
                if let message {
                    Text(message)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            actions
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// 「原值 → 新值」两列对齐的差异行。自动匹配复核与歌词复核共用。
struct DiffRow: View {
    let field: String
    let oldValue: String
    let newValue: String
    var fieldWidth: CGFloat = 66
    var oldWidth: CGFloat = 240
    /// 悬停提示。默认给两侧各自的全文 —— 两列都是一行中间截断，长标题只靠界面看不全。
    var oldHelp: String? = nil
    var newHelp: String? = nil

    var body: some View {
        GridRow {
            Text(field)
                .font(Theme.Typo.caption)
                .foregroundStyle(.secondary)
                .frame(width: fieldWidth, alignment: .leading)
            Text(oldValue.isEmpty ? "（空）" : oldValue)
                .font(Theme.Typo.caption)
                .foregroundStyle(oldValue.isEmpty ? Theme.Colors.placeholderText : Color.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(oldHelp ?? oldValue)
                .frame(width: oldWidth, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(Theme.Typo.badge)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(newValue.isEmpty ? "（空）" : newValue)
                .font(Theme.Typo.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1).truncationMode(.middle)
                .help(newHelp ?? newValue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

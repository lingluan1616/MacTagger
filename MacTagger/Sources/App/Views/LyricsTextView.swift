//
//  LyricsTextView.swift
//  MacTagger — 歌词编辑器的文本控件
//
//  SwiftUI 的 TextEditor 给不了行号、时间轴高亮与「查找下一个」的选区滚动，
//  所以这里包一层 TextKit 1 的 NSTextView：
//      · 左侧行号槽（NSRulerView）
//      · 时间轴 `[mm:ss.xx]` 与头部标签 `[ti:..]` 分色高亮
//      · 供 FormFindReplace 用的查找/替换与选区跳转
//  刻意显式搭 TextKit 1 栈（storage + layoutManager + container），
//  否则 macOS 13+ 可能给出 TextKit 2 的 NSTextView，layoutManager 为 nil，行号槽画不出来。
//

import SwiftUI
import AppKit

// MARK: - 控制器

/// 视图与 NSTextView 之间的桥。查找替换、变换后的重设文本都经由它。
@MainActor
final class LyricsTextController: ObservableObject {

    weak var textView: NSTextView?

    // 查找与替换（原版 FormFindReplace）
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var matchCase = false
    @Published var findStatus = ""

    // 状态栏
    @Published var lineCount = 1
    @Published var caretLine = 1
    @Published var timestampCount = 0

    private var compareOptions: NSString.CompareOptions {
        matchCase ? [] : [.caseInsensitive]
    }

    // MARK: 查找

    @discardableResult
    func findNext(wrap: Bool = true) -> Bool {
        guard let tv = textView, !findText.isEmpty else { return false }
        let ns = tv.string as NSString
        let start = tv.selectedRange().location + tv.selectedRange().length
        var range = NSRange(location: NSNotFound, length: 0)
        if start < ns.length {
            range = ns.range(of: findText, options: compareOptions,
                             range: NSRange(location: start, length: ns.length - start))
        }
        if range.location == NSNotFound, wrap {
            range = ns.range(of: findText, options: compareOptions,
                             range: NSRange(location: 0, length: ns.length))
        }
        return select(range, notFound: "找不到「\(findText)」")
    }

    @discardableResult
    func findPrevious(wrap: Bool = true) -> Bool {
        guard let tv = textView, !findText.isEmpty else { return false }
        let ns = tv.string as NSString
        let end = tv.selectedRange().location
        var range = NSRange(location: NSNotFound, length: 0)
        if end > 0 {
            range = ns.range(of: findText, options: compareOptions.union(.backwards),
                             range: NSRange(location: 0, length: end))
        }
        if range.location == NSNotFound, wrap {
            range = ns.range(of: findText, options: compareOptions.union(.backwards),
                             range: NSRange(location: 0, length: ns.length))
        }
        return select(range, notFound: "找不到「\(findText)」")
    }

    private func select(_ range: NSRange, notFound: String) -> Bool {
        guard let tv = textView else { return false }
        guard range.location != NSNotFound else {
            findStatus = notFound
            NSSound.beep()
            return false
        }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
        findStatus = "第 \(lineNumber(at: range.location)) 行"
        return true
    }

    /// 替换当前选中的匹配项，然后跳到下一个。
    func replaceCurrentAndFindNext() {
        guard let tv = textView, !findText.isEmpty else { return }
        let sel = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: sel)
        if sel.length > 0, selected.compare(findText, options: compareOptions) == .orderedSame {
            if tv.shouldChangeText(in: sel, replacementString: replaceText) {
                tv.textStorage?.replaceCharacters(in: sel, with: replaceText)
                tv.didChangeText()
            }
        }
        findNext()
    }

    /// 原版「全部替换」。从后往前替，避免前面的替换挪动后面的下标。
    func replaceAll() {
        guard let tv = textView, !findText.isEmpty else { return }
        let ns = tv.string as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let found = ns.range(of: findText, options: compareOptions,
                                 range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            cursor = found.location + max(found.length, 1)
        }
        guard !ranges.isEmpty else {
            findStatus = "找不到「\(findText)」"
            NSSound.beep()
            return
        }
        tv.undoManager?.beginUndoGrouping()
        for range in ranges.reversed() where tv.shouldChangeText(in: range, replacementString: replaceText) {
            tv.textStorage?.replaceCharacters(in: range, with: replaceText)
            tv.didChangeText()
        }
        tv.undoManager?.endUndoGrouping()
        findStatus = "已替换 \(ranges.count) 处"
    }

    /// 当前有多少处匹配（输入时实时提示，避免盲替）。
    func matchCount() -> Int {
        guard let tv = textView, !findText.isEmpty else { return 0 }
        let ns = tv.string as NSString
        var count = 0, cursor = 0
        while cursor < ns.length {
            let found = ns.range(of: findText, options: compareOptions,
                                 range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { break }
            count += 1
            cursor = found.location + max(found.length, 1)
        }
        return count
    }

    // MARK: 位置

    func lineNumber(at location: Int) -> Int {
        guard let tv = textView else { return 1 }
        let ns = tv.string as NSString
        let clamped = min(max(0, location), ns.length)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: clamped),
                               options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }

    func refreshCounters() {
        guard let tv = textView else { return }
        let text = tv.string
        lineCount = text.isEmpty ? 1 : text.components(separatedBy: "\n").count
        caretLine = lineNumber(at: tv.selectedRange().location)
        timestampCount = LyricsHighlighter.timestampRanges(in: text as NSString).count
    }
}

// MARK: - 高亮

enum LyricsHighlighter {

    /// `[mm:ss]`、`[mm:ss.xx]`、`[mm:ss.xxx]`、`[mm:ss:xx]`
    static let timestampPattern = try? NSRegularExpression(
        pattern: "\\[\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?\\]")
    /// `[ti:..]` `[ar:..]` `[al:..]` `[by:..]` `[offset:..]` 之类
    static let headerPattern = try? NSRegularExpression(
        pattern: "\\[[A-Za-z_]{1,12}:[^\\]]*\\]")

    static func timestampRanges(in text: NSString) -> [NSRange] {
        guard let re = timestampPattern else { return [] }
        return re.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map(\.range)
    }

    static var bodyFont: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }
    static var stampFont: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .semibold) }

    /// 行距：等宽正文默认贴得太紧，长歌词读起来吃力。
    static var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return p
    }

    /// 给 `range` 覆盖的段落重新上色。只重画被编辑的段落，长歌词才不卡。
    static func highlight(_ storage: NSTextStorage, in range: NSRange) {
        let full = storage.string as NSString
        let safe = NSRange(location: min(range.location, full.length),
                           length: min(range.length, max(0, full.length - min(range.location, full.length))))
        let paragraph = full.paragraphRange(for: safe)
        guard paragraph.length > 0 || full.length == 0 else { return }

        storage.setAttributes([.font: bodyFont,
                               .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: paragraphStyle],
                              range: paragraph)

        // 头部标签只压成次要色 —— 整个编辑器只留「时间戳 = 强调色」一种彩色。
        if let re = headerPattern {
            for m in re.matches(in: storage.string, range: paragraph) {
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                       .font: bodyFont], range: m.range)
            }
        }
        if let re = timestampPattern {
            for m in re.matches(in: storage.string, range: paragraph) {
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                       .font: stampFont], range: m.range)
            }
        }
    }

    static func highlightAll(_ storage: NSTextStorage) {
        highlight(storage, in: NSRange(location: 0, length: (storage.string as NSString).length))
    }
}

// MARK: - 行号槽

final class LyricsLineNumberRuler: NSRulerView {

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scroll = scrollView else { return }

        // 与编辑区同底色，只靠一条发丝线分隔：深色模式下两块深色不会互相糊住。
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let text = textView.string as NSString
        let visible = scroll.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // 首个可见字符位于第几行
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let inset = textView.textContainerOrigin

        func draw(_ number: Int, charIndex: Int) {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            var effective = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: &effective)
            let y = fragment.minY + inset.y - visible.minY
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - Theme.Spacing.s,
                                   y: y + (fragment.height - size.height) / 2),
                       withAttributes: attrs)
        }

        if text.length == 0 {
            draw(1, charIndex: 0)
            return
        }

        var index = charRange.location
        let end = min(charRange.location + charRange.length, text.length)
        while index <= end {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            draw(lineNumber, charIndex: lineRange.location)
            lineNumber += 1
            let next = lineRange.location + max(lineRange.length, 1)
            if next <= index { break }
            index = next
            if index >= text.length { break }
        }
    }
}

// MARK: - SwiftUI 包装

struct LyricsSourceEditor: NSViewRepresentable {

    @Binding var text: String
    var controller: LyricsTextController
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 显式 TextKit 1 栈：保证 layoutManager 可用（行号槽依赖它）。
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = LyricsHighlighter.bodyFont
        textView.defaultParagraphStyle = LyricsHighlighter.paragraphStyle
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: Theme.Spacing.s, height: Theme.Spacing.s)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        LyricsHighlighter.highlightAll(storage)
        storage.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = textView

        let ruler = LyricsLineNumberRuler(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        controller.textView = textView
        DispatchQueue.main.async { controller.refreshCounters() }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // 只有外部改了文本（五个变换、导入 Lrc、采用搜索结果）才整体重设，
        // 否则打字时光标会被打回开头。
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            if let storage = textView.textStorage { LyricsHighlighter.highlightAll(storage) }
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.ruler?.needsDisplay = true
            DispatchQueue.main.async { controller.refreshCounters() }
        }
        if controller.textView !== textView { controller.textView = textView }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: 协调器

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let parent: LyricsSourceEditor
        weak var textView: NSTextView?
        weak var ruler: NSRulerView?

        init(_ parent: LyricsSourceEditor) { self.parent = parent }

        @objc func boundsChanged(_ note: Notification) {
            ruler?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            ruler?.needsDisplay = true
            Task { @MainActor [controller = parent.controller] in controller.refreshCounters() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            Task { @MainActor [controller = parent.controller] in controller.refreshCounters() }
        }

        func textStorage(_ storage: NSTextStorage,
                         didProcessEditing edited: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard edited.contains(.editedCharacters) else { return }
            // 在 didProcessEditing 里直接改属性是允许的（不能改字符）。
            LyricsHighlighter.highlight(storage, in: editedRange)
        }
    }
}

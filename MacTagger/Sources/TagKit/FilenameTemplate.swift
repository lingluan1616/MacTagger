//
//  FilenameTemplate.swift
//  MacTagger — 「文件名 ↔ 标签」模板与正则引擎
//
//  对应原版窗体 `FormFilenameRel`（B 报告 5.2 节 G 条）：
//
//    两种操作模式：重命名文件（标签 → 文件名） / 从文件名中匹配信息更改标签（文件名 → 标签）
//    两种匹配方式：模板 / 正则表达式（含捕获组编号 → 字段的映射）
//
//    模板参数：@0 无用途（通配丢弃）、@1 标题、@2 艺术家、@3 专辑、@4 碟号、
//              @5 音轨号、@6 年份、@7 注释、@8 专辑艺术家
//
//    校验规则（原版错误提示反推）：参数不能重复、不能相邻、不能为空、
//              「重命名」模式下不能用 @0、正则捕获组不能重复 / 不能为空。
//
//  本文件是纯 Swift 值类型，不依赖 AppKit，`mactagger-probe tpl …` 可逐条验证。
//

import Foundation

// MARK: - 操作模式

/// 「文件名 ↔ 标签」的两种操作方向。
public enum FilenameRelationMode: String, CaseIterable, Sendable, Identifiable, Codable {
    /// 标签 → 文件名。
    case rename
    /// 文件名 → 标签。
    case updateTags

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .rename:     return "重命名文件"
        case .updateTags: return "从文件名中匹配信息更改标签"
        }
    }

    /// 顶部分段控件用的短文案。
    public var shortName: String {
        switch self {
        case .rename:     return "重命名文件"
        case .updateTags: return "从文件名更改标签"
        }
    }
}

/// 两种匹配方式。
public enum FilenameMatchMethod: String, CaseIterable, Sendable, Identifiable, Codable {
    case template
    case regex

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .template: return "模板"
        case .regex:    return "正则表达式"
        }
    }
}

// MARK: - 模板参数

/// 模板参数 `@0`…`@8`。编号与原版逐一对齐，不可改动。
public enum FilenameField: Int, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    /// `@0` 无用途：解析时通配并丢弃匹配到的内容；重命名模式下禁止使用。
    case discard     = 0
    case title       = 1
    case artist      = 2
    case album       = 3
    case disc        = 4
    case track       = 5
    case year        = 6
    case comment     = 7
    case albumArtist = 8

    public var id: Int { rawValue }

    /// `@1`
    public var token: String { "@\(rawValue)" }

    public var localizedName: String {
        switch self {
        case .discard:     return "无用途"
        case .title:       return "标题"
        case .artist:      return "艺术家"
        case .album:       return "专辑"
        case .disc:        return "碟号"
        case .track:       return "音轨号"
        case .year:        return "年份"
        case .comment:     return "注释"
        case .albumArtist: return "专辑艺术家"
        }
    }

    /// 参数按钮上的文字：`@1 标题`
    public var buttonLabel: String { "\(token) \(localizedName)" }

    /// 对应的写入字段。`@0` 不写任何字段。
    public var tagField: TagEdit.Field? {
        switch self {
        case .discard:     return nil
        case .title:       return .title
        case .artist:      return .artist
        case .album:       return .album
        case .disc:        return .disc
        case .track:       return .track
        case .year:        return .year
        case .comment:     return .comment
        case .albumArtist: return .albumArtist
        }
    }

    /// 除 `@0` 外的全部参数，按编号排序（界面按钮条与下拉都用它）。
    public static var assignable: [FilenameField] {
        allCases.filter { $0 != .discard }.sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - 错误

/// 模板 / 正则的校验与匹配错误。`message` 已是可直接显示的中文。
public struct FilenameTemplateError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - 模板

/// 模板的一个片段：字面量或参数。
public enum FilenameTemplateSegment: Equatable, Sendable {
    case literal(String)
    case parameter(FilenameField)

    var isParameter: Bool { if case .parameter = self { return true }; return false }
    var isLiteral: Bool { if case .literal = self { return true }; return false }
}

/// 渲染 / 匹配的可调项。
public struct FilenameRenderOptions: Sendable, Equatable {
    /// 音轨号补零位数（`3` → `03`）。设 0 表示不补零。
    public var trackDigits: Int
    /// 碟号补零位数。
    public var discDigits: Int
    /// 年份是否只取前 4 位（`2023-05-01` → `2023`）。
    public var yearFirstFourOnly: Bool
    /// **碟号只在多碟时出现**。
    ///
    /// 开启后：单碟文件（见 `FilenameTemplate.isMultiDisc`）渲染 `@4` 得到空串，
    /// 于是「空字段跳过并连带丢掉一个紧邻分隔符」的既有规则会把 `@4-` 整段抹掉 ——
    /// `@4-@5 - @1` 在单碟专辑上自然变成 `05 - 稻香`，多碟专辑才出现 `2-05 - 稻香`。
    ///
    /// 「按标签整理到文件夹」默认开启（`FilenameRenderOptions.organize`）；
    /// 「文件名 ↔ 标签」的重命名默认关闭，行为与本开关上线前逐字一致。
    public var discOnlyWhenMultiDisc: Bool

    public init(trackDigits: Int = 2,
                discDigits: Int = 1,
                yearFirstFourOnly: Bool = true,
                discOnlyWhenMultiDisc: Bool = false) {
        self.trackDigits = trackDigits
        self.discDigits = discDigits
        self.yearFirstFourOnly = yearFirstFourOnly
        self.discOnlyWhenMultiDisc = discOnlyWhenMultiDisc
    }

    public static let `default` = FilenameRenderOptions()

    /// 「按标签整理到文件夹」的渲染口径：**音轨号两位补零 + 碟号仅多碟时出现**。
    /// 目录结构靠它才稳定 —— 补零保证 `02` 排在 `10` 前面，
    /// 单碟省略碟号段保证绝大多数专辑不会平白多出一层 `1-`。
    public static let organize = FilenameRenderOptions(trackDigits: 2,
                                                       discDigits: 1,
                                                       yearFirstFourOnly: true,
                                                       discOnlyWhenMultiDisc: true)
}

/// 一条已解析、已校验的模板。
///
/// 用 `parse(_:mode:)` 构造：解析不通过会抛出中文错误，构造出来的实例一定是合法的。
public struct FilenameTemplate: Equatable, Sendable {

    public let raw: String
    public let segments: [FilenameTemplateSegment]

    private init(raw: String, segments: [FilenameTemplateSegment]) {
        self.raw = raw
        self.segments = segments
    }

    /// 模板里出现的参数，按出现顺序。
    public var fields: [FilenameField] {
        segments.compactMap { if case .parameter(let f) = $0 { return f } else { return nil } }
    }

    /// 除 `@0` 外会被写回标签的参数。
    public var assignedFields: [FilenameField] { fields.filter { $0 != .discard } }

    // MARK: 解析与校验

    /// 解析并校验模板。
    /// - Parameter mode: 校验强度随模式变化 —— 重命名模式禁止 `@0`。
    /// - Throws: `FilenameTemplateError`，`message` 可直接显示给用户。
    public static func parse(_ raw: String,
                             mode: FilenameRelationMode = .updateTags) throws -> FilenameTemplate {

        // 规则「参数不能为空」的第一层：整条模板不能是空白。
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FilenameTemplateError("模板不能为空")
        }

        var segments: [FilenameTemplateSegment] = []
        var literal = ""
        var index = raw.startIndex

        func flushLiteral() {
            if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
        }

        while index < raw.endIndex {
            let ch = raw[index]
            guard ch == "@" else {
                literal.append(ch)
                index = raw.index(after: index)
                continue
            }

            let next = raw.index(after: index)
            // `@@` 转义成一个字面上的 @（原版没有这条，但不加的话文件名里就永远打不出 @）。
            if next < raw.endIndex, raw[next] == "@" {
                literal.append("@")
                index = raw.index(after: next)
                continue
            }

            // 收集 @ 后面连续的数字。多于一位一律判错，避免 `@12` 被悄悄读成 `@1` + 字面 `2`。
            var digits = ""
            var cursor = next
            while cursor < raw.endIndex, raw[cursor].isNumber {
                digits.append(raw[cursor])
                cursor = raw.index(after: cursor)
            }
            guard !digits.isEmpty else {
                throw FilenameTemplateError("「@」后面缺少参数编号，可用参数为 @0–@8（要输入字面的 @ 请写 @@）")
            }
            guard digits.count == 1, let n = Int(digits), let field = FilenameField(rawValue: n) else {
                throw FilenameTemplateError("无法识别的参数 @\(digits)，可用参数为 @0–@8")
            }
            flushLiteral()
            segments.append(.parameter(field))
            index = cursor
        }
        flushLiteral()

        let template = FilenameTemplate(raw: raw, segments: segments)
        if let problem = template.validationMessage(mode: mode) {
            throw FilenameTemplateError(problem)
        }
        return template
    }

    /// 只做校验、不抛错的版本：返回 nil 表示通过，否则是可直接显示的中文原因。
    public static func validate(_ raw: String, mode: FilenameRelationMode = .updateTags) -> String? {
        do { _ = try parse(raw, mode: mode); return nil }
        catch let e as FilenameTemplateError { return e.message }
        catch { return error.localizedDescription }
    }

    /// 结构性校验（解析成功之后跑）。
    private func validationMessage(mode: FilenameRelationMode) -> String? {

        // 规则「参数不能为空」：至少要有一个参数，否则模板不表达任何映射。
        guard !fields.isEmpty else {
            return "模板中至少要有一个参数（例如 @1 标题）"
        }

        // 规则「参数不能重复」。
        var seen = Set<FilenameField>()
        for f in fields {
            if !seen.insert(f).inserted {
                return "参数不能重复：\(f.token) \(f.localizedName) 出现了不止一次"
            }
        }

        // 规则「参数不能相邻」：`@1@2` 中间没有分隔符，切不开。
        for i in segments.indices.dropLast() {
            if case .parameter(let a) = segments[i], case .parameter(let b) = segments[i + 1] {
                return "参数不能相邻：\(a.token)\(b.token) 之间必须有分隔符，否则无法切分"
            }
        }

        // 规则「重命名模式下不能用 @0」。
        if mode == .rename, fields.contains(.discard) {
            return "「重命名文件」模式下不能使用 @0（它只用于丢弃内容，无法生成文件名）"
        }

        return nil
    }

    // MARK: 渲染（标签 → 文件名，不含扩展名）

    /// 按模板生成文件名主体（不含扩展名）。
    ///
    /// **空字段策略**：某个参数取不到值时，**跳过该参数并连带丢掉紧邻它的一个分隔符字面量**
    /// （优先丢前面的，模板开头的参数则丢后面的）。之后再把连续空白折叠成一个空格、
    /// 掐掉首尾的空白与 `-` `_`。
    ///
    /// 例：模板 `@5 - @2 - @1`，音轨为空 → `周杰伦 - 稻香`（不会留下开头的「 - 」）。
    public func render(tags: Tags, options: FilenameRenderOptions = .default) -> String {
        FilenameTemplate.tidy(FilenameTemplate.renderLevel(segments, tags: tags, options: options))
    }

    /// 渲染**一段**（一级目录，或最后一段的文件名主体）。返回未 tidy 的拼接结果。
    ///
    /// 空字段策略见 `render(tags:options:)` 的文档注释。分层之后每一段各跑一次
    /// ——「丢掉紧邻的分隔符」只在**本段内部**找邻居，绝不会跨过 `/` 去吃掉别的层级。
    static func renderLevel(_ segments: [FilenameTemplateSegment],
                            tags: Tags,
                            options: FilenameRenderOptions) -> String {

        var texts: [String] = []
        var dropped = Set<Int>()

        for (i, seg) in segments.enumerated() {
            switch seg {
            case .literal(let s):
                texts.append(s)
            case .parameter(let field):
                let value = FilenameTemplate.value(of: field, in: tags, options: options)
                texts.append(value)
                guard value.isEmpty else { continue }
                dropped.insert(i)
                // 连带丢掉一个紧邻的分隔符：优先前面那个（还没被丢过），否则后面那个。
                if i > 0, segments[i - 1].isLiteral, !dropped.contains(i - 1) {
                    dropped.insert(i - 1)
                } else if i + 1 < segments.count, segments[i + 1].isLiteral {
                    dropped.insert(i + 1)
                }
            }
        }

        return texts.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
            .joined()
    }

    /// 折叠多余空白 + 掐掉首尾的空白与 `-` `_`。
    static func tidy(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let trimSet = CharacterSet(charactersIn: " -_").union(.whitespacesAndNewlines)
        return collapsed.trimmingCharacters(in: trimSet)
    }

    // MARK: 分层渲染（标签 → 多级路径，「按标签整理到文件夹」用）

    /// 层级分隔符。模板里的 `/` 把模板切成若干段：前 n-1 段各是一级目录，
    /// 最后一段是文件名主体（不含扩展名）。
    public static let pathSeparator: Character = "/"

    /// 模板本身是否要求分层（含至少一个 `/`）。
    public var isLayered: Bool { levels.count > 1 }

    /// 按 `/` 把 `segments` 切成层级。字面量里的 `/` 会被切开，`/` 本身不进任何一段。
    ///
    /// 例：`@2/@3/@5 - @1` → `[[@2], [@3], [@5, " - ", @1]]`
    public var levels: [[FilenameTemplateSegment]] {
        var out: [[FilenameTemplateSegment]] = []
        var current: [FilenameTemplateSegment] = []

        for seg in segments {
            switch seg {
            case .parameter:
                current.append(seg)
            case .literal(let text):
                guard text.contains(FilenameTemplate.pathSeparator) else {
                    current.append(seg)
                    continue
                }
                // `split(omittingEmptySubsequences: false)`：`a//b` 要留出中间那个空段，
                // 否则「空段」这条错误规则就检不出来了。
                let pieces = text.split(separator: FilenameTemplate.pathSeparator,
                                        omittingEmptySubsequences: false)
                for (i, piece) in pieces.enumerated() {
                    if i > 0 { out.append(current); current = [] }
                    if !piece.isEmpty { current.append(.literal(String(piece))) }
                }
            }
        }
        out.append(current)
        return out
    }

    /// 渲染成**多级路径成分**（目标根之下的相对路径，最后一项是文件名主体，不含扩展名）。
    ///
    /// 每一级独立走一遍空字段清理与 `tidy`，再各自用 `RenameService.sanitizeComponent`
    /// 净化非法字符（`/` → `／`、`:` → `：`、控制字符 → 空格）并掐掉首尾空白与点，
    /// 最后按 macOS 单成分 255 字节的上限限长。**渲染成空的层级直接丢掉** ——
    /// 例如模板 `@8/@6 - @3/@1` 遇到没有年份、也没有专辑的文件时不会留下一个空目录。
    ///
    /// 注意：本方法**不**负责「缺字段填未知艺术家 / 未知专辑」——
    /// 那是 `LibraryOrganizer` 的策略，会在调用前先把标签补好。
    public func renderComponents(tags: Tags,
                                 options: FilenameRenderOptions = .default) -> [String] {
        levels
            .map { FilenameTemplate.tidy(FilenameTemplate.renderLevel($0, tags: tags, options: options)) }
            .map { RenameService.clampLength(RenameService.sanitizeComponent($0)) }
            .filter { !$0.isEmpty }
    }

    /// 「按标签整理到文件夹」的模板校验。返回 nil 表示通过。
    ///
    /// 在「重命名文件」模式的全部规则之上再加三条 —— 都是分层特有的：
    /// 1. 不能以 `/` 开头或结尾（前者生成空的一级，后者压根没有文件名）；
    /// 2. 不能出现连续的 `//`（中间那一级永远是空的）；
    /// 3. 最后一段至少要含一个参数，否则同一个目录里所有文件都会算出同一个名字。
    public static func validatePath(_ raw: String) -> String? {
        if let problem = validate(raw, mode: .rename) { return problem }
        guard let template = try? parse(raw, mode: .rename) else { return "模板不合法" }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return "模板不能以「/」开头（会生成一个没有名字的目录）" }
        if trimmed.hasSuffix("/") { return "模板不能以「/」结尾（最后一段是文件名，不能为空）" }
        if trimmed.contains("//") { return "模板里不能出现连续的「//」（中间那一级永远是空的）" }

        guard let last = template.levels.last, last.contains(where: { $0.isParameter }) else {
            return "最后一段是文件名，至少要含一个参数（例如 @1 标题），否则同一目录里的文件会全部重名"
        }
        return nil
    }

    /// 多碟判定：`discTotal > 1`，或碟号本身 > 1（「第 2 碟」不可能属于单碟专辑）。
    /// `FilenameRenderOptions.discOnlyWhenMultiDisc` 用它决定 `@4` 渲不渲染。
    public static func isMultiDisc(_ tags: Tags) -> Bool {
        if let total = tags.discTotal, total > 1 { return true }
        if let n = tags.discNumber, n > 1 { return true }
        return false
    }

    /// 取某个参数在这份标签里的文本值（已按 options 规范化，未做文件名净化）。
    public static func value(of field: FilenameField,
                             in tags: Tags,
                             options: FilenameRenderOptions = .default) -> String {
        func pad(_ n: Int?, _ digits: Int) -> String {
            guard let n, n > 0 else { return "" }
            return digits > 1 ? String(format: "%0\(digits)d", n) : String(n)
        }
        switch field {
        case .discard:     return ""
        case .title:       return tags.title ?? ""
        case .artist:      return tags.artist ?? ""
        case .album:       return tags.album ?? ""
        case .albumArtist: return tags.albumArtist ?? ""
        case .disc:
            // 单碟专辑渲染成空串，让「空字段清理」把 `@4-` 整段抹掉。见 discOnlyWhenMultiDisc。
            if options.discOnlyWhenMultiDisc, !isMultiDisc(tags) { return "" }
            return pad(tags.discNumber, options.discDigits)
        case .track:       return pad(tags.trackNumber, options.trackDigits)
        case .year:
            let raw = tags.year ?? ""
            return options.yearFirstFourOnly ? String(raw.prefix(4)) : raw
        case .comment:
            return (tags.comment ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
    }

    // MARK: 匹配（文件名 → 标签）

    /// 把模板编译成正则：`@0` → `(?:.*?)`（通配丢弃，不产生捕获组），
    /// 其它参数 → `(.+?)`（惰性，靠字面分隔符切分），字面量原样转义匹配。
    public var regexPattern: String {
        var pattern = "^"
        for seg in segments {
            switch seg {
            case .literal(let s):
                pattern += NSRegularExpression.escapedPattern(for: s)
            case .parameter(let f):
                pattern += (f == .discard) ? "(?:.*?)" : "(.+?)"
            }
        }
        return pattern + "$"
    }

    /// 捕获组顺序（第 1 个捕获组对应哪个参数）。`@0` 不占捕获组。
    public var capturedFields: [FilenameField] { fields.filter { $0 != .discard } }

    /// 用模板解析一个文件名。
    ///
    /// - Parameters:
    ///   - filename: 可以带扩展名；`stripExtension` 为 true 时先去掉扩展名再匹配。
    /// - Returns: 参数 → 解析出的文本（已 trim）。
    /// - Throws: 不匹配时抛出中文错误。
    public func match(filename: String,
                      stripExtension: Bool = true) throws -> [FilenameField: String] {
        let subject = stripExtension
            ? (filename as NSString).deletingPathExtension
            : filename
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
            throw FilenameTemplateError("模板无法编译成匹配规则")
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let m = regex.firstMatch(in: subject, range: range) else {
            throw FilenameTemplateError("文件名与模板不匹配")
        }
        var result: [FilenameField: String] = [:]
        let order = capturedFields
        for (i, field) in order.enumerated() {
            let g = m.range(at: i + 1)
            guard g.location != NSNotFound, let r = Range(g, in: subject) else { continue }
            let text = String(subject[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result[field] = text
        }
        guard !result.isEmpty else {
            throw FilenameTemplateError("文件名与模板不匹配")
        }
        return result
    }

    /// 不抛错的匹配。
    public func matchOrNil(filename: String, stripExtension: Bool = true) -> [FilenameField: String]? {
        try? match(filename: filename, stripExtension: stripExtension)
    }
}

// MARK: - 正则规则

/// 正则匹配方式：正则表达式 + 「捕获组编号 → 字段」的映射。
public struct FilenameRegexRule: Equatable, Sendable {

    public var pattern: String
    /// 捕获组编号（从 1 开始）→ 字段。
    public var groupFields: [Int: FilenameField]

    public init(pattern: String, groupFields: [Int: FilenameField]) {
        self.pattern = pattern
        self.groupFields = groupFields
    }

    /// 正则里的捕获组个数；正则非法时返回 nil。
    public var captureGroupCount: Int? {
        (try? NSRegularExpression(pattern: pattern))?.numberOfCaptureGroups
    }

    /// 校验：返回 nil 表示通过，否则是可直接显示的中文原因。
    public func validationMessage(mode: FilenameRelationMode) -> String? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "正则表达式不能为空"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "正则表达式有误，无法编译"
        }
        // 规则「捕获组不能为空」。
        let mapped = groupFields.filter { $0.value != .discard }
        guard !mapped.isEmpty else {
            return "捕获组不能为空：至少要给一个捕获组指定字段"
        }
        // 规则「捕获组不能重复」：同一个字段不能被两个组同时占用。
        var byField: [FilenameField: [Int]] = [:]
        for (g, f) in mapped { byField[f, default: []].append(g) }
        if let (field, groups) = byField.first(where: { $0.value.count > 1 }) {
            let list = groups.sorted().map { "第 \($0) 组" }.joined(separator: "、")
            return "捕获组不能重复：\(field.localizedName) 同时被\(list)占用"
        }
        // 组号必须真实存在。
        let count = regex.numberOfCaptureGroups
        if let bad = mapped.keys.sorted().first(where: { $0 < 1 || $0 > count }) {
            return "第 \(bad) 组不存在：正则中只有 \(count) 个捕获组"
        }
        if mode == .rename, groupFields.values.contains(.discard) {
            return "「重命名文件」模式下不能使用 @0（它只用于丢弃内容，无法生成文件名）"
        }
        return nil
    }

    /// 解析一个文件名（文件名 → 标签）。
    public func match(filename: String,
                      stripExtension: Bool = true) throws -> [FilenameField: String] {
        let subject = stripExtension ? (filename as NSString).deletingPathExtension : filename
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw FilenameTemplateError("正则表达式有误，无法编译")
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let m = regex.firstMatch(in: subject, range: range) else {
            throw FilenameTemplateError("文件名与正则不匹配")
        }
        var result: [FilenameField: String] = [:]
        for (group, field) in groupFields where field != .discard {
            guard group >= 1, group <= m.numberOfRanges - 1 else { continue }
            let g = m.range(at: group)
            guard g.location != NSNotFound, let r = Range(g, in: subject) else { continue }
            let text = String(subject[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result[field] = text
        }
        guard !result.isEmpty else { throw FilenameTemplateError("文件名与正则不匹配") }
        return result
    }

    /// 重命名方向：用正则匹配**当前文件名**，把每个已映射捕获组所占的那段文本
    /// 替换成对应标签值，其余部分原样保留。
    ///
    /// 例：`03 - unknown - song`，正则 `^(\d+) - (.+) - (.+)$`，
    /// 1→音轨号 2→艺术家 3→标题 ⇒ `05 - 周杰伦 - 稻香`。
    public func renderRename(currentName: String,
                             tags: Tags,
                             options: FilenameRenderOptions = .default,
                             stripExtension: Bool = true) throws -> String {
        let subject = stripExtension ? (currentName as NSString).deletingPathExtension : currentName
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw FilenameTemplateError("正则表达式有误，无法编译")
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let m = regex.firstMatch(in: subject, range: range) else {
            throw FilenameTemplateError("文件名与正则不匹配")
        }
        // 按位置倒序替换，避免前面的替换把后面的下标搞乱。
        var replacements: [(NSRange, String)] = []
        for (group, field) in groupFields where field != .discard {
            guard group >= 1, group <= m.numberOfRanges - 1 else { continue }
            let g = m.range(at: group)
            guard g.location != NSNotFound else { continue }
            replacements.append((g, FilenameTemplate.value(of: field, in: tags, options: options)))
        }
        guard !replacements.isEmpty else {
            throw FilenameTemplateError("没有任何捕获组映射到字段")
        }
        var out = subject as NSString
        for (r, text) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            out = out.replacingCharacters(in: r, with: text) as NSString
        }
        return FilenameTemplate.tidy(out as String)
    }
}

//
//  MacTaggerApp.swift
//  MacTagger — 应用入口
//

import SwiftUI
import AppKit

@main
struct MacTaggerApp: App {

    @StateObject private var settings = AppSettings()
    @StateObject private var columns = ColumnStore()
    @StateObject private var directories = DirectoryStore()
    @StateObject private var autoMatch = AutoMatchSettings()
    @StateObject private var model: AppModel

    /// 退出钩子（⌘Q / 注销 / 关机）：有未保存的改动先问「保存 / 放弃 / 取消」（BO#11）。
    @NSApplicationDelegateAdaptor(MacTaggerAppDelegate.self) private var appDelegate

    /// 「写入时自适应等待存储卡恢复」菜单勾选项的持久化背板。
    ///
    /// 键名直接取自数据层常量 `BatchEngine.adaptivePacingDefaultsKey`
    /// （= `MacTagger.adaptiveWritePacing`），所以菜单和 `BatchEngine`
    /// 读的是**同一个真相源**：打勾 → 写 UserDefaults → 下一次批量写入立刻生效。
    /// 缺省值 true 与数据层 getter 的「未设置过视为 true」兜底一致。
    @AppStorage(BatchEngine.adaptivePacingDefaultsKey) private var adaptivePacing = true

    /// 菜单勾选项用的绑定：写 `@AppStorage`（驱动勾选状态刷新）之余，
    /// 再显式把新值推给数据层总开关。两者本是同一个 UserDefaults 键，这行属于冗余保险 ——
    /// 万一将来数据层换成内存缓存，这里也不会脱节。
    private var adaptivePacingBinding: Binding<Bool> {
        Binding(
            get: { adaptivePacing },
            set: { newValue in
                adaptivePacing = newValue
                BatchEngine.adaptivePacingEnabled = newValue
            }
        )
    }

    init() {
        // 在线数据源必须在任何匹配发生前注册（AutoMatchSettings 初始化时也会兜一次）。
        SourceBootstrap.registerAll()
        let s = AppSettings(), c = ColumnStore(), d = DirectoryStore(), a = AutoMatchSettings()
        _settings = StateObject(wrappedValue: s)
        _columns = StateObject(wrappedValue: c)
        _directories = StateObject(wrappedValue: d)
        _autoMatch = StateObject(wrappedValue: a)
        _model = StateObject(wrappedValue: AppModel(settings: s, columns: c,
                                                    directories: d, autoMatchSettings: a))
        // 启动时把菜单开关的当前值对齐一次给数据层总开关。两边同键，属于显式兜底。
        BatchEngine.adaptivePacingEnabled = adaptivePacing
    }

    var body: some Scene {
        WindowGroup("MacTagger") {
            ContentView()
                // 「文件名 ↔ 标签」sheet 的挂载点。必须排在 environmentObject 之前 ——
                // 排后面的话 sheet 内容在环境注入之外，取不到 AppModel。
                .modifier(FilenameRelationSheetsModifier())
                .modifier(OrganizeSheetModifier())
                .modifier(LyricsFileOptionsSheetModifier())
                .modifier(ChineseConvertSheetModifier())
                .selectAllCommand(model)
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(columns)
                .environmentObject(directories)
                .environmentObject(autoMatch)
                .environmentObject(LyricsSettings.shared)
                .frame(minWidth: Theme.Size.windowMinWidth, minHeight: Theme.Size.windowMinHeight)
                .onAppear {
                    settings.applyAppearance()
                    appDelegate.model = model
                }
        }
        .defaultSize(width: Theme.Size.windowDefaultWidth, height: Theme.Size.windowDefaultHeight)
        // 顶栏按设计稿自绘（TopBarView 的 38px 标题栏行 + 50px 工具栏行），
        // 所以隐藏系统标题栏；红绿灯仍由系统画，标题行左侧已留 78pt 安全区。
        .windowStyle(.hiddenTitleBar)
        .commands {
            MacTaggerCommands(model: model, settings: settings,
                              sheets: SheetPresence.shared,
                              adaptivePacing: adaptivePacingBinding)
        }
    }
}

// MARK: - 退出钩子

/// 只做一件事：⌘Q / 注销 / 关机时把「要不要退出」交给 `AppModel.terminationReply(for:)`（BO#11）。
///
/// 没有未保存的改动 → 立刻退出；写入批在跑 → 当场问「等它完成 / 仍然退出」；
/// 有未保存的改动 → `.terminateLater`，问完「保存 / 放弃改动 / 取消」再回复 AppKit。
/// `model` 在主窗口第一次出现时接上；接上之前（窗口还没出来就退出）没有任何改动可丢，直接放行。
final class MacTaggerAppDelegate: NSObject, NSApplicationDelegate {

    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.terminationReply(for: sender)
    }
}

// MARK: - 菜单栏

/// 菜单栏命令（原先写在 `MacTaggerApp.body` 的 `.commands { }` 里，原样搬出来，只改启用条件）。
///
/// **启用条件的三道闸**（BO#5 / #14）：
///   * 会改数据的命令：批处理 / 导入 / 补读在跑（`isBusy`）时灰；
///   * **任何 sheet / 确认框 / 提示框开着时一律灰**（`AppModel.isAnySheetPresented`）——
///     否则 ⌘S、⇧⌘L 之类会越过前台的 sheet 落到主窗口，请求排到 sheet 关掉之后才弹，
///     还带着请求那一刻的旧快照去执行；
///   * 「保存标签」看 `canSave`（= 不忙 且 有未保存改动），**不要求有选中**：
///     无选中时 `requestSave` 本来就存全部未保存的行，与顶栏 / 检查器的保存按钮同一条件。
/// 纯设置类（外观、在线结果字形、自适应等待开关）与只读窗口（数据源状态）不受 sheet 限制。
struct MacTaggerCommands: Commands {

    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// 只用来在 AppKit 挂上 / 摘下 sheet 时让菜单重算启用状态（真值在 `model.isAnySheetPresented` 里读）。
    @ObservedObject var sheets: SheetPresence
    var adaptivePacing: Binding<Bool>

    /// 有 sheet / 确认框 / 提示框在前。
    private var blocked: Bool { model.isAnySheetPresented }
    /// 会改数据、且不能与批处理并发的命令。
    private var dataCommandDisabled: Bool { model.isBusy || blocked }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加文件…") { model.presentAddFiles() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(blocked)
            Button("添加目录…") { model.presentAddDirectory() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(blocked)
        }
        CommandGroup(after: .saveItem) {
            Button("保存标签") { model.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave || blocked)
            Button("撤消标签保存") { model.requestUndo() }
                .disabled(model.selection.isEmpty || dataCommandDisabled)
        }
        // 系统自带的「显示 › 隐藏边栏/显示边栏 ⌃⌘S」。装了它菜单里才有边栏开关，
        // 它靠 NavigationSplitView 的 columnVisibility 绑定工作（ContentView 里那个 @State）。
        SidebarCommands()
        // 挂进系统自带的「显示」菜单，而不是 CommandMenu("显示") ——
        // 后者会在菜单栏里多出第二个同名「显示」菜单（已实测）。
        CommandGroup(after: .toolbar) {
            Picker("外观", selection: $settings.appearance) {
                ForEach(AppSettings.AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        CommandMenu("标签") {
            // 原版把它放在「标签」菜单下。无选中时对全部文件执行。
            Button("自动匹配标签…") { model.presentAutoMatch() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(dataCommandDisabled)
            Button("文件名 ↔ 标签…") { model.presentFilenameRelation() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(dataCommandDisabled)
            Button("按文件夹统一标签…") { model.presentTagPropagation(grouping: .folder) }
                .disabled(dataCommandDisabled)
            Button("按标签整理到文件夹…") { model.presentOrganize() }
                .disabled(dataCommandDisabled)
            // 原版菜单里的四项（B 报告 5.2 节 F / K 条）。四项都先开预览表，
            // 不静默写盘；标签走「撤消标签保存」，文件名走「撤消重命名」。
            Menu("简繁转换") {
                Button("标签 简 → 繁") {
                    model.presentChineseConvert(scope: .tags, policy: .traditional)
                }
                Button("标签 繁 → 简") {
                    model.presentChineseConvert(scope: .tags, policy: .simplified)
                }
                Divider()
                Button("文件名 简 → 繁") {
                    model.presentChineseConvert(scope: .filenames, policy: .traditional)
                }
                Button("文件名 繁 → 简") {
                    model.presentChineseConvert(scope: .filenames, policy: .simplified)
                }
            }
            .disabled(dataCommandDisabled)
            // 开的是 AppKit sheet：另一张 sheet 开着时再点，会把当前那张直接换掉（BO#45），所以也看 blocked。
            Button("封面与写入选项…") { model.presentArtworkPolicy() }
                .disabled(blocked)
            Button("数据源状态…") { SourceStatusWindow.present() }
            Button("撤消重命名") { model.requestUndoRename() }
                .disabled(dataCommandDisabled)
            Button("撤消整理") { model.requestUndoOrganize() }
                .disabled(dataCommandDisabled)
            Divider()
            Picker("在线结果统一转为", selection: $settings.onlineChineseVariant) {
                ForEach(ChineseVariantPolicy.allCases) { p in
                    Text(p.menuLabel).tag(p)
                }
            }
            .help("所有在线源返回的标题/艺术家/专辑/流派/作曲/作词/歌词统一转成这种字形。"
                  + "iTunes 中区当前常返回 0 条并回退港区，拿回来的是繁体，所以默认转简体。")
            Divider()
            // 批量写入的「掉速就停几秒等卡缓过来」总开关。数据层唯一入口是
            // BatchEngine.adaptivePacingEnabled，与这里共用一个 UserDefaults 键。
            Toggle("写入时自适应等待存储卡恢复", isOn: adaptivePacing)
                .help("在 SD/TF 卡等可移动存储上批量写入时，检测到降速自动暂停几秒等待恢复；关闭后始终连续写入")
        }
        CommandMenu("歌词") {
            Button("编辑歌词…") { model.presentLyricsEditor() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty || dataCommandDisabled)
            Button("从网络搜索歌词…") { model.presentLyricsSearch() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.selection.isEmpty || dataCommandDisabled)
            Button("批量下载歌词…") { model.startLyricsBatchDownload() }
                .disabled(dataCommandDisabled)
            Divider()
            Button("导入 Lrc 文件…") { model.presentImportLRC() }
                .disabled(model.selection.isEmpty || dataCommandDisabled)
            Button("另存为歌词文件…") { model.presentExportLRC() }
                .disabled(model.selection.isEmpty || dataCommandDisabled)
            // 窗口根上的 sheet：别的 sheet 开着时点它只会排队到那张关掉之后才弹。
            Button("歌词文件选项…") { LyricsFileOptionsState.shared.isPresented = true }
                .disabled(blocked)
            Divider()
            Button("重置歌词") { model.requestResetLyrics() }
                .disabled(model.selection.isEmpty || dataCommandDisabled)
        }
        // 「全选 ⌘A」不在这里：SwiftUI 默认 `.pasteboard` 组已自带一项（发 `selectAll:` 走响应链），
        // 再加一项同绑 ⌘A 会被排在前面的系统项吃掉按键。文件表的兜底见 `SelectAllCommandBridge`。
        CommandGroup(after: .pasteboard) {
            // 确认框开着时改选择，会让「重置歌词」这类按选择执行的动作作用到别的文件上（BO 第 1 节）。
            Button("反选") { model.invertSelection() }
                .disabled(blocked)
            Button("取消选定") { model.clearSelection() }
                .disabled(blocked)
        }
    }
}

// MARK: - 「有 sheet 在前」（BO#14）

/// 盯着本 App 所有窗口的 sheet 挂上 / 摘下（`NSWindow.willBeginSheet` / `didEndSheet`）。
///
/// SwiftUI 的 `.sheet`、`.alert`、`.confirmationDialog`，`ArtworkSheetPresenter` 的 AppKit sheet，
/// 在 macOS 上最终都是 `beginSheet`，所以这一处能兜住所有入口 —— 包括以后新加、没登记进
/// `AppModel.openSheetName` 的 sheet。菜单栏靠它的变化重算启用状态。
@MainActor
final class SheetPresence: ObservableObject {

    static let shared = SheetPresence()

    /// 有窗口挂着 sheet（含正在收起、动画还没走完的那一小段）。
    @Published private(set) var appKitSheetAttached = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willBeginSheetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // 这一刻 attachedSheet 还没挂上，先置真；下一拍再按实况校正。
                self?.appKitSheetAttached = true
                self?.scheduleRecount()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRecount() }
        })
    }

    private func scheduleRecount() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.recount() }
        }
    }

    /// 按实况重算（离屏工装也用它校正）。
    func recount() {
        let attached = NSApp.windows.contains { $0.attachedSheet != nil }
        if attached != appKitSheetAttached { appKitSheetAttached = attached }
    }
}

extension AppModel {

    /// 当前开着的「内容 sheet」叫什么；没有就是 nil。**按状态派生**，不看 AppKit 动画：
    /// 按钮里「先 dismiss() 再发请求」时，这里已经是 nil，请求不会被当成「sheet 开着」拒掉。
    ///
    /// 不含根级的确认框 / 提示框（它们自己就是要判定的对象），也不含 `ContentView`
    /// 自己的三个 `@State` sheet（管理目录 / 标签历史 / 自定义显示列 —— 由 ContentView 自己补上）。
    var openSheetName: String? {
        if autoMatchReview != nil { return AlbumMatchStore.shared.review != nil ? "专辑匹配复核" : "自动匹配复核" }
        if showAutoMatchOptions { return "自动匹配选项" }
        if lyricsEditorContext != nil { return "编辑歌词" }
        if showLyricsSearch { return "搜索歌词" }
        if lyricsBatchReview != nil { return "批量下载歌词复核" }
        if showLrcExportOptions { return "另存为歌词文件" }
        if RenameState.shared.isPresented { return "文件名 ↔ 标签" }
        if OrganizeState.shared.isPresented { return "按标签整理到文件夹" }
        if ChineseConvertState.shared.isPresented { return "简繁转换" }
        if LyricsFileOptionsState.shared.isPresented { return "歌词文件选项" }
        // ArtworkSheetPresenter 的 AppKit sheet（封面与写入选项 / 按文件夹统一标签），开关状态是它的私有属性，
        // 只能按窗口标识认。`endSheet` 一返回 sheetParent 就已摘掉、isVisible 已是 false（BP-D 工装实测），
        // 所以「先 dismiss() 再 requestSave()」（调整封面那条路）发出的确认框不会被当成「sheet 还开着」。
        if NSApp.windows.contains(where: { $0.identifier?.rawValue == "MacTagger.artworkSheet"
                                           && $0.isVisible && $0.sheetParent != nil }) {
            return "封面 / 统一标签窗口"
        }
        return nil
    }

    /// 有任何 sheet / 确认框 / 提示框在前（菜单栏会改数据的命令据此一律置灰，BO#14）。
    ///
    /// 状态派生（`openSheetName`、`confirm`、`alert`）∪ AppKit 实况（`SheetPresence`，
    /// 兜住 `ContentView` 自己的三个 sheet 与以后新加的 sheet）。
    var isAnySheetPresented: Bool {
        confirm != nil || alert != nil || openSheetName != nil || SheetPresence.shared.appKitSheetAttached
    }
}

// MARK: - 编辑 › 全选（⌘A）

/// 「编辑 › 全选 ⌘A」在文件表以外的焦点下的接收者。
///
/// 菜单里只留系统 `.pasteboard` 组自带的「全选」：它发 `selectAll:` 走响应链。
/// 文本有焦点 → 字段编辑器 / NSTextView 接住，全选文字；文件表有焦点 → NSTableView 自己全选行。
/// 但焦点落在窗口本身（点工具栏、检查器、状态栏空白处后的常态）时响应链上没人接，
/// 焦点在侧栏时侧栏那张单选列表接住却什么也不做 —— 这两种情况 ⌘A 都没反应。
/// SwiftUI 的 `.onCommand(selectAll:)` 挂在根视图上实测接不到（焦点在窗口 / 宿主视图时同样落空），
/// 所以分两路补：
///   * **键盘**：本地 keyDown 监视器。本窗口是 key、没挂 sheet、第一响应者不是文本（`NSText`，
///     含字段编辑器）时，⌘A 直接 `model.selectAll()` 并吞掉事件。
///   * **菜单点击**：把本对象接在窗口后面进响应链，没人接 `selectAll:` 时由它全选，
///     否则「全选」菜单项在上述焦点下是灰的。
final class SelectAllCommandBridge: NSResponder {

    weak var model: AppModel?
    private(set) weak var window: NSWindow?
    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    /// 本次菜单跟踪期间临时改指向本对象的「全选」菜单项（见 `menuTrackingBegan`）。
    private weak var retargetedItem: NSMenuItem?

    init(model: AppModel) {
        self.model = model
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldHandleKeyDown(event) else { return event }
            self.model?.selectAll()
            return nil
        }
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                object: nil, queue: .main) { [weak self] note in
            let menu = note.object as? NSMenu
            MainActor.assumeIsolated { self?.menuTrackingBegan(menu) }
        })
        // SwiftUI 每次展开「编辑」菜单都会在 menuNeedsUpdate 里把菜单项整批重建（工装实测：项的实例每次都换），
        // 跟踪开始时改过的那一项随即作废。所以在新项加进来的当下再改一次 —— queue 必须是 nil（同步），
        // 赶在随后的启用态校验之前。
        menuObservers.append(center.addObserver(forName: NSMenu.didAddItemNotification,
                                                object: nil, queue: nil) { [weak self] note in
            guard let menu = note.object as? NSMenu,
                  let index = note.userInfo?["NSMenuItemIndex"] as? Int,
                  index >= 0, index < menu.numberOfItems else { return }
            let item = menu.item(at: index)
            MainActor.assumeIsolated {
                guard let item, item.action == #selector(NSResponder.selectAll(_:)) else { return }
                self?.retargetIfSidebarFocused(item)
            }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                object: nil, queue: .main) { [weak self] note in
            guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
            // 推到下一拍再还原：菜单项的动作在跟踪结束之后才发出，这里先还原的话点击就落空了。
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.restoreSelectAllTarget() } }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for o in menuObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 菜单路补丁：侧栏有焦点时点「编辑 › 全选」（BN 余留）

    /// 侧栏是单选列表（`NSTableView`，allowsMultipleSelection = false），有焦点时它排在响应链最前：
    /// 菜单「全选」的 `selectAll:` 被它接下却什么也不做，本对象排在窗口之后永远轮不到。
    /// 所以菜单栏开始跟踪时看一眼焦点：落在这种单选列表上，就把「全选」项**临时**直接指向本对象
    /// （菜单项随之可用，点了全选文件表）；跟踪结束后还原成原来的 nil（走响应链），
    /// 不影响文本框里 ⌘A 全选文字（键盘 ⌘A 另有 keyDown 监视器，不经过这里）。
    private func menuTrackingBegan(_ menu: NSMenu?) {
        guard let menu, menu === NSApp.mainMenu else { return }
        restoreSelectAllTarget()
        if let item = Self.item(action: #selector(NSResponder.selectAll(_:)), in: menu) {
            retargetIfSidebarFocused(item)
        }
    }

    /// 只动主菜单栏里的「全选」，且只在「本窗口在前、没挂 sheet、焦点在单选列表上」时动。
    private func retargetIfSidebarFocused(_ item: NSMenuItem) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, model != nil,
              item.target == nil, Self.isInMainMenu(item),
              let table = window.firstResponder as? NSTableView, !table.allowsMultipleSelection else { return }
        item.target = self
        retargetedItem = item
    }

    private static func isInMainMenu(_ item: NSMenuItem) -> Bool {
        var menu = item.menu
        while let m = menu {
            if m === NSApp.mainMenu { return true }
            menu = m.supermenu
        }
        return false
    }

    private func restoreSelectAllTarget() {
        if let item = retargetedItem, item.target === self { item.target = nil }
        retargetedItem = nil
    }

    private static func item(action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for it in menu.items {
            if it.action == action { return it }
            if let sub = it.submenu, let hit = item(action: action, in: sub) { return hit }
        }
        return nil
    }

    /// 接到 `window` 的响应链末尾（窗口之后、窗口原来的 nextResponder 之前）。重复调用幂等。
    func attach(to newWindow: NSWindow?) {
        if let newWindow, newWindow === window, isInChain(of: newWindow) { return }
        detach()
        guard let newWindow else { return }
        nextResponder = newWindow.nextResponder
        newWindow.nextResponder = self
        window = newWindow
    }

    func detach() {
        guard let window else { return }
        // 只在自己仍是窗口直接后继时拆，别把后来别人接上的链剪断。
        if window.nextResponder === self { window.nextResponder = nextResponder }
        nextResponder = nil
        self.window = nil
    }

    private func isInChain(of window: NSWindow) -> Bool {
        var r = window.nextResponder
        while let x = r { if x === self { return true }; r = x.nextResponder }
        return false
    }

    /// 键盘路：只认本窗口在前台、没挂 sheet、焦点不在文本上的纯 ⌘A。
    func shouldHandleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              model != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" else { return false }
        return !(window.firstResponder is NSText)
    }

    // 菜单路：响应链上前面没人接 `selectAll:` 时落到这里（或侧栏焦点时由改指向的菜单项直接发来）。
    override func selectAll(_ sender: Any?) {
        // 兜底：改指向万一没还原、焦点却已在文本上 —— 交还给文本，别去全选文件表。
        if let item = sender as? NSMenuItem, item === retargetedItem,
           let text = window?.firstResponder as? NSText {
            restoreSelectAllTarget()
            text.selectAll(sender)
            return
        }
        model?.selectAll()
    }

    /// sheet 开着时 key window 是 sheet，`selectAll:` 的查找会一路落到主窗口链上来 ——
    /// 这时装作不认识它（菜单项随之变灰），别去全选 sheet 背后的文件表。
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(selectAll(_:)) { return model != nil && window?.attachedSheet == nil }
        return super.responds(to: aSelector)
    }
}

/// 把 `SelectAllCommandBridge` 接到宿主窗口上（窗口换了就改接，视图拆掉就拆链）。
private struct SelectAllCommandInstaller: NSViewRepresentable {
    let model: AppModel

    final class WindowTracker: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeCoordinator() -> SelectAllCommandBridge { SelectAllCommandBridge(model: model) }

    func makeNSView(context: Context) -> WindowTracker {
        let v = WindowTracker()
        let bridge = context.coordinator
        v.onWindow = { [weak bridge] w in bridge?.attach(to: w) }
        return v
    }

    func updateNSView(_ v: WindowTracker, context: Context) {
        context.coordinator.model = model
        context.coordinator.attach(to: v.window)
    }

    static func dismantleNSView(_ v: WindowTracker, coordinator: SelectAllCommandBridge) {
        v.onWindow = nil
        coordinator.detach()
    }
}

extension View {
    /// 「编辑 › 全选 ⌘A」在文件表以外的焦点下也全选文件表（见 `SelectAllCommandBridge`）。
    func selectAllCommand(_ model: AppModel) -> some View {
        background(SelectAllCommandInstaller(model: model))
    }
}

//
// ウィンドウのツールバーにドロップしたフォルダのアイコン＋名称＋⌄（パス階層メニュー）を表示する
//

import SwiftUI
import AppKit

// MARK: - ToolbarConfigurator (NSViewRepresentable)

/// ウィンドウへ NSToolbar を取り付け、ドロップしたフォルダのアイコン・名称を反映する。
/// `WindowSizeMatcher` と同じく、不可視の補助ビューを `background` に置いて使う。
struct ToolbarConfigurator: NSViewRepresentable {
    /// タイトルに表示するルートフォルダ（未ドロップ、またはファイル等のフラット表示なら nil ＝ 空白）
    let folderURL: URL?
    /// アクションボタン（展開/閉じる/プリント）を有効にするか（＝リストが表示されているか）。
    /// folderURL とは独立：フラット表示はタイトル空白（folderURL=nil）でもボタンは有効にする。
    let hasContent: Bool
    /// ファイル等のフラット表示か（true のときツールバー左に「ファイル一覧」を出す。folderURL は nil）
    let isFlatList: Bool
    /// 「バージョン」列スイッチの状態
    let versionOn: Bool
    /// スイッチ切替時のコールバック
    let onToggleVersion: (Bool) -> Void
    /// バージョン取得精度（詳細 / 簡易）。ツールバーのセグメンテッドコントロールの選択表示に使う
    let versionDetail: VersionDetail
    /// 精度切替時のコールバック
    let onSetVersionDetail: (VersionDetail) -> Void
    /// ツールバーボタン：すべて展開／すべて閉じる／プリント
    var onExpandAll: (() -> Void)?
    var onCollapseAll: (() -> Void)?
    var onPrint: (() -> Void)?

    func makeCoordinator() -> ToolbarCoordinator {
        ToolbarCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = ToolbarHostView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onToggleVersion = onToggleVersion
        context.coordinator.onSetVersionDetail = onSetVersionDetail
        context.coordinator.onExpandAll = onExpandAll
        context.coordinator.onCollapseAll = onCollapseAll
        context.coordinator.onPrint = onPrint
        context.coordinator.update(folderURL: folderURL, hasContent: hasContent,
                                   isFlatList: isFlatList,
                                   versionOn: versionOn, versionDetail: versionDetail)
    }
}

// MARK: - ToolbarHostView

/// ウィンドウに載った瞬間にツールバーを取り付けるための不可視ビュー。
final class ToolbarHostView: NSView {
    weak var coordinator: ToolbarCoordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        coordinator?.install(on: window)
    }
}

// MARK: - ToolbarCoordinator

/// NSToolbar の生成・デリゲート・タイトル項目の更新を担当する。
final class ToolbarCoordinator: NSObject, NSToolbarDelegate, NSToolbarItemValidation {

    private static let titleItemID = NSToolbarItem.Identifier("FolderTitle")
    private static let switchItemID = NSToolbarItem.Identifier("VersionSwitch")
    private static let detailItemID = NSToolbarItem.Identifier("VersionDetail")
    private static let expandItemID = NSToolbarItem.Identifier("ExpandAll")
    private static let collapseItemID = NSToolbarItem.Identifier("CollapseAll")
    private static let printItemID = NSToolbarItem.Identifier("PrintList")

    private weak var window: NSWindow?
    private let titleView = FolderTitleView()
    private let versionSwitch = NSSwitch()
    /// バージョン精度のセグメンテッドコントロール（詳細 / 簡易の択一）
    private let detailSegmented = NSSegmentedControl()
    /// 現在の精度（項目生成時の選択セグメント決定に使う）
    private var versionDetailState: VersionDetail = .full
    private var pendingURL: URL?
    private var pendingIsFlatList = false
    /// リスト表示中のみツールバーボタンを有効にする（validateToolbarItem で参照）
    private var hasContent = false
    /// macOS 13/14 用：表示モードを `.iconOnly` に固定するための KVO（macOS 15+ は API で禁止）
    private var displayModeObservation: NSKeyValueObservation?

    /// スイッチ切替時のコールバック（SwiftUI 側のモデルを更新する）
    var onToggleVersion: ((Bool) -> Void)?
    /// バージョン精度切替時のコールバック
    var onSetVersionDetail: ((VersionDetail) -> Void)?
    /// ツールバーボタンのコールバック
    var onExpandAll: (() -> Void)?
    var onCollapseAll: (() -> Void)?
    var onPrint: (() -> Void)?

    override init() {
        super.init()
        versionSwitch.target = self
        versionSwitch.action = #selector(versionSwitchChanged(_:))
        // ラベルなしスイッチのため、ツールチップで機能（Adobe書類限定）を示す
        versionSwitch.toolTip = String(localized: "Adobe Document Creation Version")

        // バージョン精度：詳細 / 簡易 を択一するセグメンテッドコントロール
        detailSegmented.segmentCount = 2
        detailSegmented.setLabel(String(localized: "Detailed"), forSegment: 0)
        detailSegmented.setLabel(String(localized: "Simple"), forSegment: 1)
        detailSegmented.trackingMode = .selectOne
        detailSegmented.selectedSegment = 0
        detailSegmented.target = self
        detailSegmented.action = #selector(detailSegmentChanged(_:))
        detailSegmented.toolTip = String(localized: "Version Detail")
    }

    // MARK: 取り付け

    func install(on window: NSWindow) {
        // 同じウィンドウに二重設定しない
        guard self.window !== window else {
            titleView.update(folderURL: pendingURL, isFlatList: pendingIsFlatList)
            return
        }
        self.window = window

        let toolbar = NSToolbar(identifier: "AFVerDesktopToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = true

        // 右クリックの「アイコンとテキスト／アイコンのみ」で表示モードを変えられると
        // 項目ビュー（タイトル・スイッチ）がラベル分だけ上にずれるため、.iconOnly に固定する。
        if #available(macOS 15.0, *) {
            // メニュー自体を出さない（公式API）
            toolbar.allowsDisplayModeCustomization = false
        } else {
            // macOS 13/14：メニューは出るが、変更されたら即座に .iconOnly へ戻す
            displayModeObservation = toolbar.observe(\.displayMode, options: [.new]) { tb, _ in
                guard tb.displayMode != .iconOnly else { return }
                DispatchQueue.main.async { tb.displayMode = .iconOnly }
            }
        }

        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden

        // 取り付け前に届いていた値を反映
        titleView.update(folderURL: pendingURL, isFlatList: pendingIsFlatList)
    }

    // MARK: 更新

    func update(folderURL: URL?, hasContent: Bool, isFlatList: Bool,
                versionOn: Bool, versionDetail: VersionDetail) {
        pendingURL = folderURL
        pendingIsFlatList = isFlatList
        titleView.update(folderURL: folderURL, isFlatList: isFlatList)
        self.hasContent = hasContent
        window?.toolbar?.validateVisibleItems()

        let desired: NSControl.StateValue = versionOn ? .on : .off
        if versionSwitch.state != desired { versionSwitch.state = desired }

        // セグメンテッドコントロールの選択を精度に合わせる
        versionDetailState = versionDetail
        detailSegmented.selectedSegment = (versionDetail == .fast) ? 1 : 0

        // ウィンドウメニュー／Mission Control 用にタイトルも設定
        if let url = folderURL {
            window?.title = FileManager.default.displayName(atPath: url.path)
        } else if isFlatList {
            // ファイル等のフラット表示：ツールバー左・ウィンドウメニューとも「ファイル一覧」。
            window?.title = String(localized: "File List")
        } else {
            window?.title = ""
        }
    }

    @objc private func versionSwitchChanged(_ sender: NSSwitch) {
        onToggleVersion?(sender.state == .on)
    }

    @objc private func detailSegmentChanged(_ sender: NSSegmentedControl) {
        onSetVersionDetail?(sender.selectedSegment == 1 ? .fast : .full)
    }

    // MARK: ツールバーボタンのアクション

    @objc private func expandAllClicked(_ sender: Any?) {
        onExpandAll?()
    }

    @objc private func collapseAllClicked(_ sender: Any?) {
        onCollapseAll?()
    }

    @objc private func printClicked(_ sender: Any?) {
        onPrint?()
    }

    /// 画像ベースのツールバー項目（展開/閉じる・プリント）の有効/無効。
    /// リスト未表示（フォルダ未ドロップ）の間はディムする。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        hasContent
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.titleItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = titleView
            item.visibilityPriority = .high
            return item
        case Self.switchItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = versionSwitch
            item.label = ""            // ラベルなし（仕様）
            item.visibilityPriority = .high
            return item
        case Self.detailItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            // 詳細 / 簡易 を択一するセグメンテッドコントロールを埋め込む
            detailSegmented.selectedSegment = (versionDetailState == .fast) ? 1 : 0
            item.view = detailSegmented
            item.label = String(localized: "Version Detail")
            item.toolTip = String(localized: "Version Detail")
            item.visibilityPriority = .high
            return item
        case Self.expandItemID:
            return makeButtonItem(id: itemIdentifier, symbol: "chevron.down",
                                  title: String(localized: "Expand All"),
                                  action: #selector(expandAllClicked(_:)))
        case Self.collapseItemID:
            return makeButtonItem(id: itemIdentifier, symbol: "chevron.up",
                                  title: String(localized: "Collapse All"),
                                  action: #selector(collapseAllClicked(_:)))
        case Self.printItemID:
            return makeButtonItem(id: itemIdentifier, symbol: "printer",
                                  title: String(localized: "Print…"),
                                  action: #selector(printClicked(_:)))
        default:
            return nil
        }
    }

    /// アイコンのみのツールバーボタンを作る（ホバーでカプセル型ハイライト）。
    private func makeButtonItem(id: NSToolbarItem.Identifier, symbol: String,
                                title: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.label = title
        item.toolTip = title
        item.isBordered = true
        item.target = self
        item.action = action
        item.visibilityPriority = .high
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 左端にタイトル、右側に［展開］［閉じる］［プリント］、間隔を空けてスイッチ
        [Self.titleItemID, .flexibleSpace,
         Self.expandItemID, Self.collapseItemID, Self.printItemID,
         .space, Self.detailItemID, Self.switchItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.titleItemID, .flexibleSpace,
         Self.expandItemID, Self.collapseItemID, Self.printItemID,
         .space, Self.detailItemID, Self.switchItemID]
    }
}

// MARK: - FolderTitleView

/// アイコン＋名称＋⌄ を横並びで表示するツールバー用ビュー。
/// ⌄ ボタン（左クリック）でパス階層メニューを表示する。
/// （右クリックは NSToolbar 標準の表示モードメニューに横取りされるため、明示的なボタンを採用）
final class FolderTitleView: NSView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chevronButton = NSButton()
    private var folderURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // Finder のウィンドウタイトル風：少し大きめ・Bold・通常の文字色（グレーにしない）
        nameLabel.font = .systemFont(ofSize: 14, weight: .bold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.image = NSImage(systemSymbolName: "chevron.down",
                                      accessibilityDescription: String(localized: "Show Path"))
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.target = self
        chevronButton.action = #selector(showPathMenu(_:))
        chevronButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameLabel, chevronButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: 更新

    func update(folderURL: URL?, isFlatList: Bool = false) {
        self.folderURL = folderURL
        if let url = folderURL {
            // フォルダ表示：アイコン＋名称＋⌄
            isHidden = false
            iconView.isHidden = false
            chevronButton.isHidden = false
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            iconView.image = icon
            nameLabel.stringValue = FileManager.default.displayName(atPath: url.path)
        } else if isFlatList {
            // ファイル等のフラット表示：アイコン・⌄ は出さず、タイトル「ファイル一覧」だけ
            isHidden = false
            iconView.isHidden = true
            chevronButton.isHidden = true
            nameLabel.stringValue = String(localized: "File List")
        } else {
            // 未ドロップ（空ウィンドウ）：何も出さない
            isHidden = true
        }
    }

    // MARK: パス階層メニュー（⌄ ボタン）

    @objc private func showPathMenu(_ sender: NSButton) {
        guard let url = folderURL else { return }

        // Finder のタイトル階層に合わせる：
        //   フォルダ → 親 → … → 「ボリュームのマウントポイント」で止め、最後に「コンピュータ」を足す。
        //   /Volumes や起動ボリューム配下の内部構造は Finder では見せないため辿らない。
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        let volumePath = volumeURL?.standardizedFileURL.path

        let menu = NSMenu()
        var current = url.standardizedFileURL
        while true {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: current.path),
                                  action: #selector(openPathComponent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = current
            let icon = NSWorkspace.shared.icon(forFile: current.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)

            if current.path == volumePath { break }  // ボリュームのマウントポイントで終了
            if current.path == "/" { break }          // 念のための安全策
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        // 最後に「コンピュータ」（Mac本体）を追加
        let computerName = Host.current().localizedName ?? "Computer"
        let computerItem = NSMenuItem(title: computerName,
                                      action: #selector(openComputer(_:)),
                                      keyEquivalent: "")
        computerItem.target = self
        computerItem.representedObject = volumeURL  // クリック時にコンピュータ階層で選択表示
        if let computerIcon = NSImage(named: NSImage.computerName) {
            computerIcon.size = NSSize(width: 16, height: 16)
            computerItem.image = computerIcon
        }
        menu.addItem(computerItem)

        // ⌄ ボタンの直下に表示
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // 「コンピュータ」階層を Finder で開く（ボリュームを選択した状態で表示）
        if let volumeURL = sender.representedObject as? URL {
            NSWorkspace.shared.activateFileViewerSelecting([volumeURL])
        }
    }
}

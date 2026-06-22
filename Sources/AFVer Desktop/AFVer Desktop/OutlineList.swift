import SwiftUI
import AppKit
import Quartz   // Quick Look（QLPreviewPanel）

// MARK: - OutlineListColumn

struct OutlineListColumn {
    let id: String
    let title: String
    var minWidth: CGFloat = 60
    var width: CGFloat?
    var maxWidth: CGFloat?
    var alignment: NSTextAlignment = .natural
}

// MARK: - SortState

struct SortState: Equatable {
    var columnID: String
    var ascending: Bool
}

// MARK: - OutlineTreeActions

/// 表示メニュー「すべて展開／すべて閉じる」用に、モデル側へ渡すツリー操作。
struct OutlineTreeActions {
    /// 読み込み済みのフォルダをすべて展開する（未読み込みフォルダには触れない）
    let expandAllLoaded: () -> Void
    /// すべてのフォルダを閉じる
    let collapseAll: () -> Void
}

// MARK: - OutlineList

struct OutlineList: NSViewRepresentable {
    let columns: [OutlineListColumn]
    @Binding var rootItems: [FileItem]
    @Binding var sortState: SortState
    var columnWidths: [String: CGFloat]
    /// バージョン取得が進むたびに変わるトークン。変化したら再描画する。
    var versionRefreshToken: Int = 0
    /// 設定「フォルダのダブルクリック」が「新規ウインドウで表示」なら true（既定 false＝展開/閉じる）。
    /// 素のフォルダのダブルクリックを `onOpenInNewWindow` に振り向ける（▶ のインライン展開は両モードで有効）。
    var folderDoubleClickOpensNewWindow = false
    /// 設定「リストの背景をストライプにする」（既定 false＝横グリッド線。true で交互背景＋グリッド線オフ）。
    var stripeBackground = false
    /// 設定「拡張子が偽装されていたら種類を赤文字にする」（既定 false）。
    /// false＝先頭の警告記号 ⚠ だけ赤・種類名は通常色／true＝種類名も赤。
    var kindMismatchRedText = false
    var onColumnWidthChanged: ((String, CGFloat) -> Void)?
    /// ヘッダのドラッグで列順が変わったとき、名前列を除いた「表示中の列ID順」を通知する。
    var onColumnOrderChanged: (([String]) -> Void)?
    var onExpandItem: ((FileItem, @escaping () -> Void) -> Void)?
    var onSelectionChanged: ((FileItem?) -> Void)?
    /// 選択行数の変化を親へ通知する（ステータスバーの「N項目中のM項目を選択」表示用）。
    var onSelectionCountChanged: ((Int) -> Void)?
    /// 現在「表示されている行」の集計（総数・アプリ系統別ドット数）を親へ通知する。
    /// 展開状態を反映するため、展開/折りたたみ・データ/バージョン更新のたびに呼ぶ。
    var onVisibleSummaryChanged: ((_ total: Int, _ familyCounts: [AppFamily: Int]) -> Void)?
    /// 印刷用：現在の表示行（展開状態を反映した行＋階層）のスナップショットを返す
    /// プロバイダを親に登録する（makeNSView で一度だけ呼ばれる）
    var onRegisterPrintRowProvider: ((@escaping () -> [PrintRow]) -> Void)?
    /// ツリー操作（すべて展開／すべて閉じる）を親に登録する（makeNSView で一度だけ呼ばれる）
    var onRegisterTreeActions: ((OutlineTreeActions) -> Void)?
    /// 右クリック「新規ウインドウで表示」（単一フォルダ）：フォルダの中身を新規ウインドウで開く
    var onOpenInNewWindow: ((URL) -> Void)?
    /// 右クリック「新規ウインドウで表示」（ファイル単体／複数選択／混在）：選択項目をフラットに並べた新規ウインドウで開く
    var onOpenItemsInNewWindow: (([URL]) -> Void)?
    /// 複数の新規ウインドウを続けて開く直前に、これから開く内容ウインドウ枚数を通知する
    /// （Dock ドロップと同じカスケード整列を働かせるため）。
    var onBeginNewWindowBatch: ((Int) -> Void)?

    /// リストヘッダ／ヘッダセルの背景色。リスト本体（行）と同じ地色にして
    /// Finder のリスト表示風に地続きにする（ライトで白、ダークはシステム追従）。
    static let headerBackgroundColor: NSColor = .controlBackgroundColor

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 行背景を設定に応じて適用する。
    /// ・OFF（既定）：交互背景なし＋横方向のグレー境界線（従来の見た目）
    /// ・ON：Finder 風の交互背景（ストライプ）＋グリッド線オフ（角丸なし＝システム標準）
    ///
    /// AppKit 標準の `usesAlternatingRowBackgroundColors` は使わない（常に false）。空白領域の
    /// ファントム行が OFF 時に再描画されず古い縞が残るため。ストライプは `ShiftedDisclosureOutlineView`
    /// の `drawBackground` で自前描画する（`stripeBackground` で切替＝OFF でも確実に消える）。
    private func applyRowBackground(_ ov: NSOutlineView) {
        ov.usesAlternatingRowBackgroundColors = false
        (ov as? ShiftedDisclosureOutlineView)?.stripeBackground = stripeBackground
        ov.gridStyleMask = stripeBackground ? [] : .solidHorizontalGridLineMask
        ov.gridColor = .separatorColor
    }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = ShiftedDisclosureOutlineView()
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        // ダブルクリック：フォルダは展開/閉じるをトグル、ファイルは何もしない
        ov.target = context.coordinator
        ov.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        // 右クリックメニュー（行外の右クリックでは出さない — menu(for:) 参照）：
        //   「新規ウインドウで表示」（フォルダ行のみ）／「Finderに表示」（全行）
        let contextMenu = NSMenu()
        let newWindowItem = NSMenuItem(title: String(localized: "Open in New Window"),
                                       action: #selector(Coordinator.openClickedInNewWindow(_:)),
                                       keyEquivalent: "")
        newWindowItem.target = context.coordinator
        newWindowItem.tag = ShiftedDisclosureOutlineView.openInNewWindowTag
        contextMenu.addItem(newWindowItem)
        let revealItem = NSMenuItem(title: String(localized: "Show in Finder"),
                                    action: #selector(Coordinator.revealClickedInFinder(_:)),
                                    keyEquivalent: "")
        revealItem.target = context.coordinator
        contextMenu.addItem(revealItem)
        contextMenu.addItem(.separator())
        // コピー（TSV）／パスをコピー。ショートカット表示も付ける（Edit メニュー側と一致）。
        let copyItem = NSMenuItem(title: String(localized: "Copy"),
                                  action: #selector(Coordinator.copySelectionAsTSV(_:)),
                                  keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = context.coordinator
        contextMenu.addItem(copyItem)
        let copyPathItem = NSMenuItem(title: String(localized: "Copy as Pathname"),
                                      action: #selector(Coordinator.copySelectionAsPaths(_:)),
                                      keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .option]
        copyPathItem.target = context.coordinator
        contextMenu.addItem(copyPathItem)
        ov.menu = contextMenu
        // 背景：設定により「横グリッド線のみ（既定）」または「ストライプ（交互背景）」を適用する
        applyRowBackground(ov)
        context.coordinator.lastStripe = stripeBackground
        context.coordinator.lastKindMismatchRedText = kindMismatchRedText
        ov.style = .fullWidth
        ov.intercellSpacing = .zero
        ov.focusRingType = .none
        ov.rowHeight = 20
        ov.allowsMultipleSelection = true
        // 名前列（最初の列）だけウィンドウ幅に追随する — Finder と同じ
        ov.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // 列の並べ替えを許可。名前列は先頭固定（Coordinator の shouldReorderColumn で制御）。
        ov.allowsColumnReordering = true
        ov.indentationPerLevel = 16
        ov.autosaveExpandedItems = false

        for col in columns {
            ov.addTableColumn(makeColumn(col, isFirst: col.id == columns.first?.id,
                                         isLast: col.id == columns.last?.id))
        }

        ov.outlineTableColumn = ov.tableColumns.first

        // コンパクトなヘッダ（高さのみカスタム）
        ov.headerView = CompactHeaderView()

        // ヘッダ文字色をスイッチ状態に応じて適用（Finder 風：変更日・サイズ等はグレー）
        applyHeaderTextColors(ov)

        let sv = NSScrollView()
        sv.documentView = ov
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.borderType = .noBorder
        sv.autohidesScrollers = true
        // スクロールビューに行と同じ基調色の不透明背景を持たせる（フォールバック）。
        // 通常はアウトラインビューがクリップ全域を塗る（自前ストライプ含む）ので不可視だが、
        // 万一テーブルが満たさない瞬間でも白地でなく基調色が見えるようにしておく。
        sv.drawsBackground = true
        sv.backgroundColor = ov.backgroundColor

        context.coordinator.outlineView = ov

        // 印刷用スナップショットのプロバイダを登録
        let coord = context.coordinator
        onRegisterPrintRowProvider?({ [weak coord] in coord?.printRows() ?? [] })

        // ツリー操作（すべて展開／すべて閉じる）を登録
        onRegisterTreeActions?(OutlineTreeActions(
            expandAllLoaded: { [weak coord] in coord?.expandAllLoaded() },
            collapseAll: { [weak coord] in coord?.collapseAllItems() }
        ))

        // 列幅の変更を KVO で監視して保存する。
        // （NSTableView.columnDidResizeNotification は NSOutlineView では発火しないため、
        //   通知ではなく各列 width の KVO で確実に検知する）
        context.coordinator.observeColumnWidths(of: ov)

        return sv
    }

    /// 1つの列定義から NSTableColumn を生成する。
    private func makeColumn(_ col: OutlineListColumn, isFirst: Bool, isLast: Bool) -> NSTableColumn {
        let tc = NSTableColumn(identifier: .init(col.id))
        tc.minWidth = col.minWidth
        // 保存幅があれば優先、なければ定義の既定幅
        tc.width = columnWidths[col.id] ?? col.width ?? col.minWidth
        if let max = col.maxWidth { tc.maxWidth = max }
        // 名前列以外はヘッダ文字も列パディング(+5)、最終列は右マージン(+15)を適用
        let isName = (col.id == "name")
        let headerCell = PaddedHeaderCell(textCell: col.title)
        // "size" 列はセルを右揃え、ヘッダは左揃え
        headerCell.alignment = (col.id == "size") ? .natural : col.alignment
        headerCell.font = tc.headerCell.font
        headerCell.leftPadding  = isName ? 0 : 5
        headerCell.rightPadding = isName ? 0 : (isLast ? 15 : 5)
        tc.headerCell = headerCell
        // Finder と同様、最初の列（名前列）だけウィンドウ追随で伸縮させる
        tc.resizingMask = isFirst ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
        // ソートディスクリプタをセットしておくと標準ヘッダクリックでソートが発火する
        tc.sortDescriptorPrototype = NSSortDescriptor(
            key: col.id, ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        return tc
    }

    /// ヘッダ文字色（Finder のリスト表示に準拠。行セルの `makeTextCell` と同じ基準色）。
    /// 名前・バージョンは黒（`labelColor`）、変更日・サイズは常にグレー（`secondaryLabelColor`）、
    /// 種類はスイッチON（バージョン表示中）のとき黒・OFF のときグレー。
    private func headerTitleColor(_ columnID: String, versionMode: Bool) -> NSColor {
        switch columnID {
        case "date", "size": return .secondaryLabelColor
        case "kind":         return versionMode ? .labelColor : .secondaryLabelColor
        default:             return .labelColor   // name, version
        }
    }

    /// 全ヘッダセルの文字色を現在のスイッチ状態に合わせて設定する。
    /// 種類列のセルはスイッチ切替で作り直されないため、切替のたびにここで更新する必要がある。
    private func applyHeaderTextColors(_ ov: NSOutlineView) {
        let versionMode = columns.contains { $0.id == "version" }
        for tc in ov.tableColumns {
            (tc.headerCell as? PaddedHeaderCell)?.textColor =
                headerTitleColor(tc.identifier.rawValue, versionMode: versionMode)
        }
        ov.headerView?.needsDisplay = true
    }

    /// 列構成（`columns`）に合わせてテーブルの列を増減・並べ替えする。
    /// バージョン列の出入りに合わせてウィンドウ幅も増減し、名前列が詰まらないようにする。
    private func reconcileColumns(ov: NSOutlineView, coord: Coordinator) {
        let desiredIDs = columns.map(\.id)
        let currentIDs = ov.tableColumns.map { $0.identifier.rawValue }
        guard desiredIDs != currentIDs else { return }

        // ここでの moveColumn はプログラム的な調整。outlineViewColumnDidMove が発火しても
        // 保存しないようガードする（保存はユーザーのドラッグ確定時のみ）。
        coord.isAdjustingColumns = true
        defer { coord.isAdjustingColumns = false }

        // バージョン列の追加/削除に伴うウィンドウ幅の増減量を先に決める
        let hadVersion = currentIDs.contains("version")
        let wantVersion = desiredIDs.contains("version")
        var widthDelta: CGFloat = 0
        if wantVersion && !hadVersion {
            // 追加：これから付くバージョン列の幅ぶんウィンドウを広げる
            widthDelta = columnWidths["version"]
                ?? (columns.first { $0.id == "version" }?.width ?? 140)
        } else if !wantVersion && hadVersion {
            // 削除：今ある列の実幅ぶんウィンドウを狭める
            widthDelta = -(ov.tableColumns.first { $0.identifier.rawValue == "version" }?.width ?? 140)
        }

        // 不要な列を削除
        for tc in ov.tableColumns where !desiredIDs.contains(tc.identifier.rawValue) {
            ov.removeTableColumn(tc)
        }
        // 足りない列を追加
        for col in columns where !ov.tableColumns.contains(where: { $0.identifier.rawValue == col.id }) {
            ov.addTableColumn(makeColumn(col, isFirst: col.id == columns.first?.id,
                                         isLast: col.id == columns.last?.id))
        }
        // 望ましい順序へ並べ替え
        for (target, col) in columns.enumerated() {
            if let cur = ov.tableColumns.firstIndex(where: { $0.identifier.rawValue == col.id }),
               cur != target {
                ov.moveColumn(cur, toColumn: target)
            }
        }
        ov.outlineTableColumn = ov.tableColumns.first

        // 種類列の色はスイッチ状態で変わる。種類列セルは作り直されないため毎回適用する。
        applyHeaderTextColors(ov)

        // 列の増減に合わせて KVO 監視を貼り直す（新しい列も保存対象にする）
        coord.observeColumnWidths(of: ov)

        // ウィンドウ幅を増減（名前列は firstColumnOnly 自動調整で元幅を保つ）
        if widthDelta != 0, let window = ov.window {
            var frame = window.frame
            frame.size.width += widthDelta
            window.setFrame(frame, display: true, animate: false)
        }

        // 種類列の上書き有無（versionMode）が切り替わるので再描画して反映する
        ov.reloadData()
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard let ov = coord.outlineView else { return }

        // データ/バージョン/列構成/ソートの更新後、可視行の集計を親へ反映する（全 return 経路で）。
        defer { coord.pushVisibleSummary() }

        // 列構成の変更（バージョン列の表示/非表示）を反映
        reconcileColumns(ov: ov, coord: coord)

        // 背景設定（ストライプ）の変更をライブ反映する（共有 AppSettings 変更で body 再評価→ここに来る）。
        // ストライプは ShiftedDisclosureOutlineView.drawBackground で自前描画するため、
        // applyRowBackground で stripeBackground を更新し needsDisplay すれば全域（空白含む）が描き直される。
        if coord.lastStripe != stripeBackground {
            coord.lastStripe = stripeBackground
            applyRowBackground(ov)
            ov.needsDisplay = true
            sv.needsDisplay = true
        }

        // 「種類名も赤」設定の変更をライブ反映する。種類セルの着色は viewFor で行うため、
        // 変化時は reloadData して全行を作り直す（展開状態は保持される）。
        if coord.lastKindMismatchRedText != kindMismatchRedText {
            coord.lastKindMismatchRedText = kindMismatchRedText
            ov.reloadData()
        }

        // バージョン取得が進んだら再描画（展開状態は保持される）。
        // 「種類」列ソート中はバージョン確定で並びが変わりうるので並べ替えてから再描画。
        if coord.lastVersionToken != versionRefreshToken {
            coord.lastVersionToken = versionRefreshToken
            if sortState.columnID == "version" || sortState.columnID == "kind" {
                coord.applySortToAll(items: &coord.displayItems)
            }
            ov.reloadData()
        }

        // 保存された列幅を初回のみ適用
        if !coord.columnWidthsApplied {
            coord.columnWidthsApplied = true
            for tc in ov.tableColumns {
                if let w = columnWidths[tc.identifier.rawValue] {
                    tc.width = w
                }
            }
        }

        // ソート変更
        if coord.currentSort != sortState {
            coord.currentSort = sortState
            coord.applySortToAll(items: &coord.displayItems)
            syncSortIndicator(ov: ov, sort: sortState)
            ov.reloadData()
            return
        }

        // ルートデータ更新
        let newIDs = rootItems.map(\.id)
        if newIDs != coord.rootIDs {
            coord.rootIDs = newIDs
            coord.displayItems = rootItems
            coord.applySortToAll(items: &coord.displayItems)
            syncSortIndicator(ov: ov, sort: sortState)
            ov.reloadData()
        }
    }

    /// ヘッダのソートインジケータ（▲▼）を更新
    private func syncSortIndicator(ov: NSOutlineView, sort: SortState) {
        if let tc = ov.tableColumns.first(where: { $0.identifier.rawValue == sort.columnID }) {
            ov.sortDescriptors = [NSSortDescriptor(
                key: sort.columnID, ascending: sort.ascending,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )]
            _ = tc  // suppress warning
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: OutlineList
        var displayItems: [FileItem] = []
        var rootIDs: [UUID] = []
        var currentSort: SortState = SortState(columnID: "name", ascending: true)
        var columnWidthsApplied = false
        var lastVersionToken = 0
        /// 最後に適用したストライプ設定（makeNSView で種付け。変化時のみ updateNSView で再適用）
        var lastStripe: Bool?
        /// 最後に適用した「種類名も赤」設定（変化時のみ updateNSView で reloadData して再着色）
        var lastKindMismatchRedText: Bool?
        weak var outlineView: NSOutlineView?
        var widthObservers: [NSKeyValueObservation] = []
        /// reconcileColumns によるプログラム的な列移動中は true。ユーザー操作と区別し保存を抑止する。
        var isAdjustingColumns = false

        init(parent: OutlineList) {
            self.parent = parent
        }

        /// バージョン列が表示中か（＝スイッチON）。種類列の上書き適用可否に使う。
        var versionMode: Bool { parent.columns.contains { $0.id == "version" } }

        // MARK: ソート

        func applySortToAll(items: inout [FileItem]) {
            sortItems(&items, sort: currentSort)
        }

        private func sortItems(_ items: inout [FileItem], sort: SortState) {
            items.sort {
                let cmp = cellValue(for: $0, columnID: sort.columnID)
                             .localizedStandardCompare(cellValue(for: $1, columnID: sort.columnID))
                return sort.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
            for item in items {
                guard var ch = item.children else { continue }
                sortItems(&ch, sort: sort)
                item.children = ch
            }
        }

        private func cellValue(for item: FileItem, columnID: String) -> String {
            switch columnID {
            case "name": return item.name
            case "date": return item.displayDate
            case "size": return item.fileSize.map { String($0) } ?? ""
            case "version": return VersionInfo.versionSortString(item.versionText)
            case "kind": return item.displayKind(versionMode: versionMode)
            default: return ""
            }
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return displayItems.count }
            return (item as? FileItem)?.children?.count ?? 0
        }

        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil { return displayItems[index] }
            return (item as! FileItem).children![index]
        }

        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let fi = item as? FileItem else { return false }
            return fi.isDirectory && !fi.isPackage && !fi.isSymlink
        }

        // MARK: NSOutlineViewDelegate — セル

        func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tc = tableColumn, let fi = item as? FileItem else { return nil }
            switch tc.identifier.rawValue {
            case "name":    return makeNameCell(ov: ov, item: fi)
            case "version": return makeVersionCell(ov: ov, item: fi)
            default:        return makeTextCell(ov: ov, colID: tc.identifier.rawValue, item: fi)
            }
        }

        // MARK: NSOutlineViewDelegate — 行ビュー

        /// 行ビューの背景を透明にする。ストライプは `ShiftedDisclosureOutlineView.drawBackground` で
        /// 全域（行＋空白）に自前描画するため、行ビューが不透明（既定は基調色）だと行部分でその縞が
        /// 隠れて白く見える。透明にすると行部分も背景の縞（OFF 時は基調色＋グリッド線）が透ける。
        /// 選択ハイライトは別経路（`isSelected`）なので影響しない。
        func outlineView(_ ov: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
            rowView.backgroundColor = .clear
        }

        // MARK: NSOutlineViewDelegate — ソート（標準ヘッダクリックで発火）

        func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let desc = ov.sortDescriptors.first, let key = desc.key else { return }
            let newSort = SortState(columnID: key, ascending: desc.ascending)
            guard newSort != parent.sortState else { return }
            parent.sortState = newSort  // → updateNSView でソート＆再描画
        }

        // MARK: NSOutlineViewDelegate — 展開

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let fi = notification.userInfo?["NSObject"] as? FileItem,
                  fi.needsLoading else { return }
            fi.needsLoading = false

            parent.onExpandItem?(fi) { [weak self] in
                guard let self, let ov = self.outlineView else { return }
                // キャンセルされた場合（needsLoading が立て直されている）：
                // 仕様により中途半端に展開されたフォルダは閉じた状態に戻す
                if fi.needsLoading {
                    ov.animator().collapseItem(fi)
                    return
                }
                if var ch = fi.children {
                    self.sortItems(&ch, sort: self.currentSort)
                    fi.children = ch
                }
                if ov.isItemExpanded(fi) {
                    // 子0件のまま展開アニメーションが先行している初回展開。
                    // ここで reloadItem(reloadChildren:) すると進行中のアニメーションと
                    // 干渉してリスト全体が並べ替わったように見えるため、
                    // 子行だけを無アニメーションで挿入する。
                    let count = fi.children?.count ?? 0
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0
                        ov.insertItems(at: IndexSet(integersIn: 0..<count),
                                       inParent: fi, withAnimation: [])
                    }
                    // 読み込み失敗時のグレーアウト等、親行自体の表示を更新
                    ov.reloadItem(fi)
                } else {
                    ov.expandItem(fi)
                }
                // 遅延読み込みで子行が挿入された後の可視行数を反映する。
                self.pushVisibleSummary()
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            pushVisibleSummary()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            pushVisibleSummary()
        }

        // MARK: 可視行の集計（ステータスバー用）

        /// 現在表示中の行（展開状態を反映）から総数とアプリ系統別ドット数を集計し、親へ通知する。
        /// `@Published` への書き込みがビュー更新中に走らないよう次ランループへ遅らせる。
        func pushVisibleSummary() {
            guard let cb = parent.onVisibleSummaryChanged else { return }
            let (total, counts) = computeVisibleSummary()
            DispatchQueue.main.async { cb(total, counts) }
        }

        private func computeVisibleSummary() -> (Int, [AppFamily: Int]) {
            guard let ov = outlineView else { return (0, [:]) }
            var counts: [AppFamily: Int] = [:]
            let rows = ov.numberOfRows
            for row in 0..<rows {
                if let fi = ov.item(atRow: row) as? FileItem, let f = fi.appFamily {
                    counts[f, default: 0] += 1
                }
            }
            return (rows, counts)
        }

        // MARK: セル生成

        private func makeNameCell(ov: NSOutlineView, item: FileItem) -> NSView {
            let id = NSUserInterfaceItemIdentifier("nameCell")
            let cell = ov.makeView(withIdentifier: id, owner: self) as? NameCell ?? {
                let c = NameCell(); c.identifier = id; return c
            }()
            cell.configure(icon: item.icon, name: item.name, dimmed: item.isDimmed)
            return cell
        }

        /// バージョン列：行頭にアプリ系統のカラードット＋バージョン文字列。
        /// 取得失敗で文字列が空でもドットは残るので「対象ファイル」が一目で分かる。
        private func makeVersionCell(ov: NSOutlineView, item: FileItem) -> NSView {
            let id = NSUserInterfaceItemIdentifier("versionCell")
            let cell = ov.makeView(withIdentifier: id, owner: self) as? VersionCell ?? {
                let c = VersionCell(); c.identifier = id; return c
            }()
            cell.configure(version: item.displayVersion,
                           family: item.appFamily,
                           dimmed: item.isDimmed)
            return cell
        }

        private func makeTextCell(ov: NSOutlineView, colID: String, item: FileItem) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("cell_\(colID)")
            let cellView: NSTableCellView
            let field: NSTextField
            if let reused = ov.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView,
               let tf = reused.textField {
                cellView = reused; field = tf
            } else {
                cellView = NSTableCellView(); cellView.identifier = cellID
                field = NSTextField(labelWithString: "")
                field.font = .systemFont(ofSize: 12)
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                field.alignment = parent.columns.first { $0.id == colID }?.alignment ?? .natural
                cellView.addSubview(field); cellView.textField = field
                let isLast = (colID == parent.columns.last?.id)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(
                        equalTo: cellView.leadingAnchor, constant: 7),
                    field.trailingAnchor.constraint(
                        equalTo: cellView.trailingAnchor,
                        constant: isLast ? -17 : -7),
                    field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }
            switch colID {
            case "date":    field.stringValue = item.displayDate
            case "size":    field.stringValue = item.displaySize
            case "version": field.stringValue = item.displayVersion
            case "kind":    field.stringValue = item.displayKindForList(versionMode: versionMode)
            default:        field.stringValue = ""
            }
            // 文字色：
            // - 種類列でスイッチON かつ拡張子偽装なら、先頭の警告記号 ⚠ を常に赤にし、
            //   種類名は設定「種類名も赤」で 赤(ON)／通常色(OFF・既定) を切り替える（2色塗り）
            // - 読み込み失敗等でグレーアウト中の行は最も薄いグレー
            // - それ以外は Finder のリスト表示のように変更日/サイズ/種類を補助色（グレー）。
            //   変更日・サイズは常にグレー。種類列だけはスイッチON の対象ファイル
            //   （バージョンのドットが付く行）で通常色にして強調する。
            if colID == "kind" && versionMode && item.kindMismatch {
                let full = item.displayKindForList(versionMode: versionMode)
                let nameColor: NSColor = parent.kindMismatchRedText
                    ? .kindMismatchWarning
                    : (item.appFamily != nil ? .labelColor : .secondaryLabelColor)
                let attr = NSMutableAttributedString(string: full)
                let whole = NSRange(location: 0, length: attr.length)
                let glyphLen = min((FileItem.kindMismatchWarningPrefix as NSString).length, attr.length)
                let pstyle = NSMutableParagraphStyle()
                pstyle.lineBreakMode = .byTruncatingTail
                attr.addAttributes([.font: field.font ?? NSFont.systemFont(ofSize: 12),
                                    .paragraphStyle: pstyle,
                                    .foregroundColor: nameColor], range: whole)
                attr.addAttribute(.foregroundColor, value: NSColor.kindMismatchWarning,
                                  range: NSRange(location: 0, length: glyphLen))
                field.attributedStringValue = attr
            } else if item.isDimmed {
                field.textColor = .tertiaryLabelColor
            } else {
                let isTargetKind = colID == "kind" && versionMode && item.appFamily != nil
                field.textColor = isTargetKind ? .labelColor : .secondaryLabelColor
            }
            return cellView
        }

        /// 行のダブルクリック：フォルダは展開/閉じるをトグル。ファイルは何もしない。
        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let item = sender.item(atRow: row) as? FileItem else { return }
            // 設定「新規ウインドウで表示」：素のフォルダはダブルクリックで新規ウインドウに開く
            //（ファイル/パッケージ/エイリアスは対象外＝何もしない。▶ でのインライン展開は両モードで有効）。
            if parent.folderDoubleClickOpensNewWindow {
                if item.isDirectory && !item.isPackage && !item.isSymlink {
                    parent.onOpenInNewWindow?(item.url)
                }
                return
            }
            // 既定：展開/閉じるをトグル（展開可能な行のみ）
            guard sender.isExpandable(item) else { return }
            if sender.isItemExpanded(item) {
                sender.animator().collapseItem(item)
            } else {
                sender.animator().expandItem(item)
            }
        }

        // MARK: すべて展開／すべて閉じる

        /// 読み込み済みのフォルダをすべて展開する。未読み込み（needsLoading）のフォルダは
        /// 触らない（モデル側が事前に再帰読み込みを済ませてから呼ぶ。キャンセル時は残る）。
        /// 新しく読み込まれた子に現在のソートを適用してから展開する。
        func expandAllLoaded() {
            guard let ov = outlineView else { return }
            applySortToAll(items: &displayItems)
            ov.reloadData()
            func expand(_ items: [FileItem]) {
                for item in items {
                    guard let ch = item.children, !item.needsLoading, !ch.isEmpty else { continue }
                    ov.expandItem(item)   // 親から順に展開（子はその後で展開可能になる）
                    expand(ch)
                }
            }
            expand(displayItems)
        }

        /// すべてのフォルダを閉じる。
        func collapseAllItems() {
            outlineView?.collapseItem(nil, collapseChildren: true)
        }

        /// 印刷用：現在表示中の行（展開状態を反映）を上から順にスナップショットする。
        func printRows() -> [PrintRow] {
            guard let ov = outlineView else { return [] }
            return (0..<ov.numberOfRows).compactMap { row in
                guard let fi = ov.item(atRow: row) as? FileItem else { return nil }
                return PrintRow(item: fi,
                                level: ov.level(forRow: row),
                                isExpandable: ov.isExpandable(fi),
                                isExpanded: ov.isItemExpanded(fi))
            }
        }

        /// 右クリック対象の行集合。menu(for:) で選択は正規化済み（選択範囲外を右クリックした場合は
        /// その行だけが選択されている）ため、現在の選択行をそのまま対象とする。
        private func contextItems() -> [FileItem] {
            guard let ov = outlineView else { return [] }
            return ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? FileItem }
        }

        /// 右クリックメニューの「Finderに表示」。対象（選択範囲）をまとめて reveal する。
        @objc func revealClickedInFinder(_ sender: Any?) {
            let items = contextItems()
            guard !items.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(items.map { $0.url })
        }

        // MARK: コピー（⌘C＝TSV／⌥⌘C＝パス）

        /// 選択行を TSV（タブ区切り）でクリップボードへコピーする。
        /// 列は現在の表示順（名前 / 変更日 / サイズ / [バージョン] / 種類）に従い、ヘッダ行は付けない。
        /// 名前はツリーのインデントを付けず素のファイル名にする（メール・メモへの貼り付け向け）。
        /// レスポンダチェーンの copy(_:) と右クリックメニューの両方から呼ばれる。
        @objc func copySelectionAsTSV(_ sender: Any?) {
            let items = contextItems()
            guard !items.isEmpty else { return }
            let cols = parent.columns
            let vmode = versionMode
            let tsv = items.map { item in
                cols.map { col -> String in
                    switch col.id {
                    case "name":    return item.name
                    case "date":    return item.displayDate
                    case "size":    return item.displaySize
                    case "version": return item.displayVersion
                    case "kind":    return item.displayKind(versionMode: vmode)
                    default:        return ""
                    }
                }.joined(separator: "\t")
            }.joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(tsv, forType: .string)
        }

        /// 選択行のフルパス（POSIX パス）を1行1件でクリップボードへコピーする。
        @objc func copySelectionAsPaths(_ sender: Any?) {
            let items = contextItems()
            guard !items.isEmpty else { return }
            let paths = items.map { $0.url.path }.joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(paths, forType: .string)
        }

        /// 右クリックメニューの「新規ウインドウで表示」。
        /// Dock アイコンドロップ（`application(_:open:)`）と同じ振り分け：
        /// ・素のフォルダ（`isDirectory && !isPackage && !isSymlink`）→ それぞれ中身を 1 つずつ新規ウインドウに
        /// ・それ以外（ファイル／パッケージ／エイリアス）→ まとめて 1 枚のフラットウインドウに
        @objc func openClickedInNewWindow(_ sender: Any?) {
            let items = contextItems()
            guard !items.isEmpty else { return }
            let isPlainFolder: (FileItem) -> Bool = { $0.isDirectory && !$0.isPackage && !$0.isSymlink }
            let folders = items.filter(isPlainFolder)
            let files   = items.filter { !isPlainFolder($0) }
            // これから開く内容ウインドウ枚数（フォルダ各1枚＋ファイル群1枚）を先に通知し、
            // 2枚以上なら Dock ドロップと同じカスケード整列を働かせる。
            parent.onBeginNewWindowBatch?(folders.count + (files.isEmpty ? 0 : 1))
            for folder in folders {
                parent.onOpenInNewWindow?(folder.url)
            }
            if !files.isEmpty {
                parent.onOpenItemsInNewWindow?(files.map { $0.url })
            }
        }

        // MARK: NSOutlineViewDelegate — 選択（ファイルメニュー「Finderに表示」用）

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let ov = notification.object as? NSOutlineView else { return }
            let item = ov.selectedRow >= 0 ? ov.item(atRow: ov.selectedRow) as? FileItem : nil
            parent.onSelectionChanged?(item)
            parent.onSelectionCountChanged?(ov.selectedRowIndexes.count)

            // Quick Look パネル表示中なら選択に追随して内容を更新
            if QLPreviewPanel.sharedPreviewPanelExists(),
               let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.reloadData()
            }
        }

        // MARK: NSOutlineViewDelegate — 列の並べ替え

        /// 名前列を先頭に固定する（Finder のリスト表示と同じ）。
        /// 名前列自体の移動と、他列を先頭(0)に割り込ませる操作を拒否する。
        func outlineView(_ ov: NSOutlineView,
                         shouldReorderColumn columnIndex: Int,
                         toColumn newColumnIndex: Int) -> Bool {
            guard ov.tableColumns.indices.contains(columnIndex) else { return false }
            if ov.tableColumns[columnIndex].identifier.rawValue == "name" { return false }
            if newColumnIndex == 0 { return false }
            return true
        }

        /// 並べ替え確定。名前列を除いた「表示中の列ID順」を親へ通知して保存させる。
        /// reconcileColumns によるプログラム的な moveColumn は isAdjustingColumns で無視する。
        func outlineViewColumnDidMove(_ notification: Notification) {
            guard !isAdjustingColumns, let ov = outlineView else { return }
            let order = ov.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "name" }
            DispatchQueue.main.async { [weak self] in
                self?.parent.onColumnOrderChanged?(order)
            }
        }

        /// 各列の width を KVO で監視し、変化を `onColumnWidthChanged` に通知する。
        /// 列の増減時にも呼ばれるため、既存の監視を破棄してから貼り直す。
        func observeColumnWidths(of ov: NSOutlineView) {
            widthObservers = ov.tableColumns.map { tc in
                tc.observe(\.width, options: [.new]) { [weak self] col, _ in
                    self?.parent.onColumnWidthChanged?(col.identifier.rawValue, col.width)
                }
            }
        }
    }
}

// MARK: - NameCell

private class NameCell: NSTableCellView {
    private let iconView = NSImageView()
    private let label   = NSTextField(labelWithString: "")

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        // Finder のリスト表示に準拠し、名前が収まらないときは末尾ではなく中央付近を省略する。
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView); addSubview(label)
        imageView = iconView; textField = label
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage, name: String, dimmed: Bool) {
        iconView.image = icon
        label.stringValue = name
        label.textColor = dimmed ? .tertiaryLabelColor : .labelColor
    }
}

// MARK: - VersionCell

/// バージョン列のセル。行頭にアプリ系統のカラードット（対象ファイルのみ）を表示する。
private class VersionCell: NSTableCellView {
    private let dot   = NSView()
    private let label = NSTextField(labelWithString: "")
    private var currentFamily: AppFamily?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(version: String, family: AppFamily?, dimmed: Bool) {
        label.stringValue = version
        label.textColor = dimmed ? .tertiaryLabelColor : .labelColor
        currentFamily = family
        dot.isHidden = (family == nil)
        applyDotColor()
    }

    /// ドット色を現在の外観（ライト/ダーク）で解決して適用する。
    /// CALayer に渡す CGColor は動的 NSColor（PDF の secondaryLabelColor）を自動追従しないため、
    /// `.cgColor` 変換時の外観で固定値に焼き付く。ダークモードで濃いグレーのまま埋もれるのを防ぐため、
    /// effectiveAppearance で解決し、外観変更のたびに再解決する。
    private func applyDotColor() {
        guard let family = currentFamily else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = family.markerColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
    }
}

// MARK: - ShiftedDisclosureOutlineView

/// ディスクロージャ三角形を右にシフトする NSOutlineView。
/// frameOfOutlineCell のシフトだけでは collapse のヒットテストが効かないため、
/// mouseDown で展開・閉じの両方を自前ハンドリングする。
private class ShiftedDisclosureOutlineView: NSOutlineView {
    static let shift: CGFloat = 10
    /// コンテキストメニュー「新規ウインドウで表示」項目の識別タグ
    static let openInNewWindowTag = 1

    /// Finder 風のストライプ（交互背景）を自前で描くか。
    /// AppKit 標準の `usesAlternatingRowBackgroundColors` は「最終行より下の空白領域」に描いた
    /// ファントム行を OFF 時に描き直さない癖があり、空白に古い縞が残る。そこで標準機能は使わず、
    /// ここ（`drawBackground`）で全域（行＋空白）に縞を自前描画する。OFF 切替時も `needsDisplay` で
    /// このメソッドが走り、縞を描かない＝確実に消える。
    var stripeBackground = false {
        didSet { if oldValue != stripeBackground { needsDisplay = true } }
    }

    /// 行背景の描画。ストライプ ON のとき、行高ごとの帯を交互色で全域（空白領域含む）に塗る。
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)   // 基調色（＋OFF時はグリッド線）
        guard stripeBackground else { return }
        let bandHeight = rowHeight + intercellSpacing.height
        guard bandHeight > 0 else { return }
        let colors = NSColor.alternatingContentBackgroundColors
        guard colors.count >= 2 else { return }
        colors[1].setFill()   // 交互色（淡いティント）。基調色は super が塗済み
        // clipRect に掛かる帯のうち奇数番だけ塗る（行0=基調 / 行1=ティント / …＝Finder と同じ）
        let firstBand = max(0, Int((clipRect.minY / bandHeight).rounded(.down)))
        let lastBand = Int((clipRect.maxY / bandHeight).rounded(.up))
        guard lastBand >= firstBand else { return }
        for band in firstBand...lastBand where band % 2 == 1 {
            let bandRect = NSRect(x: clipRect.minX,
                                  y: CGFloat(band) * bandHeight,
                                  width: clipRect.width,
                                  height: bandHeight).intersection(clipRect)
            if !bandRect.isEmpty { bandRect.fill() }
        }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        r.origin.x += Self.shift
        return r
    }

    /// 右クリックメニューは行の上でのみ表示する（空白部分では出さない）。
    /// 右クリックした行が選択範囲外ならその行だけを選択する（macOS 標準。範囲内なら選択を保つ）ことで、
    /// メニュー操作が「右クリックした対象（または選択範囲全体）」に作用するようにする。
    /// 「新規ウインドウで表示」はファイル・フォルダ・複数選択を問わず常に表示する。
    override func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        let row = row(at: loc)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let row = self.row(at: loc)
        if row >= 0, let fi = item(atRow: row) {
            let original = super.frameOfOutlineCell(atRow: row)
            if !original.isEmpty {
                let shifted = original.offsetBy(dx: Self.shift, dy: 0)
                if shifted.contains(loc) {
                    // animator() 経由でシステムアニメーションを維持
                    if isItemExpanded(fi) {
                        animator().collapseItem(fi)
                    } else {
                        animator().expandItem(fi)
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: コピー（レスポンダチェーン）

    /// 標準 Edit メニューの「コピー」(⌘C) はレスポンダチェーンの copy: を辿る。
    /// リストがファーストレスポンダのときだけここに届き、テキスト入力中はフィールド側が優先される
    /// （＝⌘C を横取りしない）。実体は Coordinator に集約。
    @objc func copy(_ sender: Any?) {
        (delegate as? OutlineList.Coordinator)?.copySelectionAsTSV(sender)
    }

    /// 「パスをコピー」(⌥⌘C)。Edit メニュー項目から NSApp.sendAction でここへ届く。
    @objc func copyAsPath(_ sender: Any?) {
        (delegate as? OutlineList.Coordinator)?.copySelectionAsPaths(sender)
    }

    /// コピー系メニュー項目は選択があるときだけ有効化する。
    /// （validateMenuItem は NSResponder の override 対象ではない informal protocol のため override を付けない。
    ///   それ以外の項目は「このビューがアクションに応答できるか」＝AppKit 既定と同じ判定にフォールバックする。）
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) || menuItem.action == #selector(copyAsPath(_:)) {
            return selectedRowIndexes.count > 0
        }
        if let action = menuItem.action { return responds(to: action) }
        return true
    }

    // MARK: Quick Look（スペースキーでプレビュー）

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            togglePreviewPanel()
            return
        }
        super.keyDown(with: event)
    }

    private func togglePreviewPanel() {
        guard selectedRow >= 0, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // レスポンダチェーン経由のパネル制御（AppKit が自動で呼ぶ）
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Quick Look データソース／デリゲート

extension ShiftedDisclosureOutlineView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedRowIndexes.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let rows = selectedRowIndexes.sorted()
        guard index >= 0, index < rows.count,
              let fi = item(atRow: rows[index]) as? FileItem else { return nil }
        return fi.url as NSURL
    }

    /// パネル表示中の ↑↓・スペースをリストに転送（選択移動でプレビューも追随する）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126, 49:   // ↓ / ↑ / スペース
            keyDown(with: event)
            return true
        default:
            return false
        }
    }

    /// ズームアニメーションの始点（プレビュー対象の項目に対応する行の画面上の位置）
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let window, let qurl = (item as? NSURL) as URL? else { return .zero }
        let row = selectedRowIndexes.sorted().first {
            (self.item(atRow: $0) as? FileItem)?.url == qurl
        }
        guard let row else { return .zero }
        let rowRect = rect(ofRow: row)
        guard visibleRect.intersects(rowRect) else { return .zero }
        return window.convertToScreen(convert(rowRect, to: nil))
    }
}

// MARK: - PaddedHeaderCell

/// ヘッダのタイトルとソート▲▼を左右パディングつきで描画する。
private class PaddedHeaderCell: NSTableHeaderCell {
    var leftPadding: CGFloat = 0
    var rightPadding: CGFloat = 0

    private func inset(_ frame: NSRect) -> NSRect {
        var f = frame
        f.origin.x += leftPadding
        f.size.width -= (leftPadding + rightPadding)
        return f
    }

    /// 標準のグレーのベゼルを描かず、背景をリスト本体と同じ地色で塗ったうえで、
    /// タイトル（`drawInterior`）と列右端の縦区切り線を描く。
    /// ソート▲▼は `NSTableHeaderView` が列の本来の右端に自前で描くため、ここでは描かない
    /// （明示的に描くと非名前列でインセット位置とズレ、二重表示になる）。
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        OutlineList.headerBackgroundColor.setFill()
        cellFrame.fill()
        // タイトルを縦中央へ。NSTableHeaderCell は与えた枠の上端寄りに描くため、
        // テキスト高ぶんの枠を縦中央に置いてから渡す（横パディングは drawInterior override が適用）。
        var titleFrame = cellFrame
        let textH = attributedStringValue.size().height
        if textH > 0, textH < cellFrame.height {
            titleFrame.origin.y += ((cellFrame.height - textH) / 2).rounded()
            titleFrame.size.height = textH
        }
        drawInterior(withFrame: titleFrame, in: controlView)
        if let header = controlView as? NSTableHeaderView {
            // 列の右端に縦の区切り線（標準ベゼルが描いていた分の再現）。
            // 最終列の右端＝ウィンドウ右端には引かない（位置で判定＝並べ替えにも追従）。
            if cellFrame.maxX < header.bounds.maxX - 0.5 {
                // 旧仕様に合わせ、上下にマージンを取った短い区切り線にする（縦中央）。
                // ヘッダ高 22px − 上下マージン 3px×2 = 縦線 16px（旧仕様の実測に一致）。
                let vInset: CGFloat = 3
                NSColor.separatorColor.setFill()
                NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + vInset,
                       width: 1, height: max(0, cellFrame.height - vInset * 2)).fill()
            }
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: inset(cellFrame), in: controlView)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect,
                                    in controlView: NSView,
                                    ascending: Bool,
                                    priority: Int) {
        super.drawSortIndicator(withFrame: inset(cellFrame),
                                in: controlView,
                                ascending: ascending,
                                priority: priority)
    }
}

// MARK: - CompactHeaderView

/// ヘッダの高さを調整するだけのサブクラス。
/// ソート・リサイズは標準の NSTableHeaderView の動作に任せる。
class CompactHeaderView: NSTableHeaderView {
    private let headerHeight: CGFloat = 22

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: headerHeight)
    }
    override func layout() {
        super.layout()
        if frame.height != headerHeight { frame.size.height = headerHeight }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 列ヘッダで埋まらない領域（列移動のドラッグ中の隙間・末尾など）も白地にする保険。
        // 各列はヘッダセルが自前で塗るので、ここは非セル領域の地色担当。
        OutlineList.headerBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

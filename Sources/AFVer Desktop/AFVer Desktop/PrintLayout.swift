//
// プリント機能：画面とは別の印刷専用レイアウト
//
// - 印刷対象はリストの「現在の展開状態」のスナップショット（PrintRow の配列）
// - ヘッダ（1ページ目のみ）：フォルダ/ボリュームのアイコン＋名称＋合計サイズ
// - 列ヘッダ：全ページに表示
// - フッタ：ページ番号（全ページ）
// - ページネーションは自前（knowsPageRange / rectForPage で1ページずつ描画する方式。
//   行が途中で切れず、印刷ダイアログでの用紙サイズ・向き変更にも追随する）
//

import AppKit

// MARK: - PrintRow

/// 印刷する1行分のスナップショット（アイテム＋ツリー階層＋展開状態）
struct PrintRow {
    let item: FileItem
    let level: Int
    /// 展開可能なフォルダか（シェブロン表示の対象）
    let isExpandable: Bool
    /// 展開中か（true=「∨」、false=「>」）
    let isExpanded: Bool
}

// MARK: - PrintHeaderInfo

/// 1ページ目ヘッダに表示する情報
struct PrintHeaderInfo {
    /// アイコン（フラット表示＝ファイル一覧では nil ＝ 描画しない）
    let icon: NSImage?
    let title: String
    /// 合計サイズ（取得不可・タイムアウト時、またはフラット表示では nil → 表示しない）
    let totalSize: Int64?
}

// MARK: - PrintLayoutView

final class PrintLayoutView: NSView {

    // MARK: レイアウト定数

    private enum Metrics {
        static let rowHeight: CGFloat = 14     // 行間 -3pt（17→14）
        static let rowFontSize: CGFloat = 9    // 文字サイズ -1pt
        static let iconSize: CGFloat = 11
        static let indentPerLevel: CGFloat = 14
        static let chevronWidth: CGFloat = 10
        static let columnGap: CGFloat = 8
        static let headerBlockHeight: CGFloat = 38     // 1ページ目のタイトルブロック（上下マージンを圧縮）
        static let fileListHeaderHeight: CGFloat = 22  // フラット表示（ファイル一覧）：タイトル＋日時の低いヘッダ
        static let columnHeaderHeight: CGFloat = 18
        static let footerHeight: CGFloat = 24
        static let dateWidth: CGFloat = 86        // "yyyy/MM/dd HH:mm"（約80pt）に余白
        static let sizeWidth: CGFloat = 50        // 最大 "999 bytes"（約45pt）に余白
        static let versionWidth: CGFloat = 96     // 行頭カラードット（7pt+余白）ぶん拡張
        static let kindWidth: CGFloat = 170
        static let nameMinWidth: CGFloat = 120
    }

    /// 行の文字色（画面表示の labelColor / secondaryLabelColor / tertiaryLabelColor に対応）。
    /// 用紙は白前提なので固定グレーで表現する。
    private enum RowColor {
        static let primary = NSColor.black                   // labelColor（名前・バージョン・対象種類）
        static let secondary = NSColor(white: 0.5, alpha: 1) // secondaryLabelColor（変更日・サイズ・非対象種類）
        static let dimmed = NSColor(white: 0.68, alpha: 1)   // tertiaryLabelColor（グレーアウト行）
    }

    // MARK: 入力

    private let rows: [PrintRow]
    private let columns: [OutlineListColumn]
    private let versionMode: Bool
    private let header: PrintHeaderInfo
    /// 列の表示オプション（印刷パネルのアクセサリで切替）。OFF の列は幅計算・描画から外す。
    /// 印刷確定後の本描画でも参照するため、ビューが強参照して生かしておく。
    private let columnOptions: PrintColumnOptions
    /// 設定「拡張子が偽装されていたら種類を赤文字にする」。false（既定）＝警告記号 ⚠ だけ赤・
    /// 種類名は黒／true＝種類名も赤。画面（OutlineList）と同じ方針を印刷にも適用する。
    private let kindMismatchRedText: Bool

    // MARK: ページネーション状態（knowsPageRange で計算）

    private var pageRowRanges: [Range<Int>] = []
    private var currentPage = 1
    private var columnX: [String: (x: CGFloat, width: CGFloat)] = [:]
    /// 用紙が縦向きか。縦は種類列が狭く拡張子の括弧書きが切れやすいため、
    /// 種類文字列から " (.pdf)" 等を省くかどうかの判定に使う。
    private var isPortrait = true

    init(rows: [PrintRow], columns: [OutlineListColumn],
         versionMode: Bool, header: PrintHeaderInfo,
         columnOptions: PrintColumnOptions,
         kindMismatchRedText: Bool) {
        self.rows = rows
        self.columns = columns
        self.versionMode = versionMode
        self.header = header
        self.columnOptions = columnOptions
        self.kindMismatchRedText = kindMismatchRedText
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 実際に描画する列。表示オプションで OFF の「変更日／サイズ」を除外する。
    private var effectiveColumns: [OutlineListColumn] {
        columns.filter { col in
            switch col.id {
            case "date": return columnOptions.showDate
            case "size": return columnOptions.showSize
            default:     return true
            }
        }
    }

    /// 1ページ目ヘッダの高さ（フラット表示は日時のみで低い）
    private var headerBlockHeight: CGFloat {
        header.icon == nil ? Metrics.fileListHeaderHeight : Metrics.headerBlockHeight
    }

    // MARK: ページネーション

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        layoutForCurrentPrintInfo()
        range.pointee = NSRange(location: 1, length: max(1, pageRowRanges.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        currentPage = page
        return bounds
    }

    /// 印刷ダイアログの用紙サイズ・向きに合わせてページ分割と列位置を計算する。
    private func layoutForCurrentPrintInfo() {
        guard let info = NSPrintOperation.current?.printInfo else { return }
        let contentW = info.paperSize.width - info.leftMargin - info.rightMargin
        let contentH = info.paperSize.height - info.topMargin - info.bottomMargin
        setFrameSize(NSSize(width: contentW, height: contentH))
        isPortrait = info.paperSize.height >= info.paperSize.width

        computeColumnPositions(contentWidth: contentW)

        // 行領域の高さ：1ページ目はタイトルブロックぶん少ない
        let firstPageRows = max(1, Int((contentH - headerBlockHeight
                                        - Metrics.columnHeaderHeight
                                        - Metrics.footerHeight) / Metrics.rowHeight))
        let otherPageRows = max(1, Int((contentH - Metrics.columnHeaderHeight
                                        - Metrics.footerHeight) / Metrics.rowHeight))

        pageRowRanges = []
        var index = 0
        var isFirst = true
        repeat {
            let capacity = isFirst ? firstPageRows : otherPageRows
            let end = min(index + capacity, rows.count)
            pageRowRanges.append(index..<end)
            index = end
            isFirst = false
        } while index < rows.count
    }

    /// 各列の x 位置と幅を決める。固定幅列を確保した残りを名前列に割り当てる。
    /// 種類列の幅は「全列を表示したときの値」で決め、表示中の列構成では変えない。
    /// こうすることで、変更日／サイズを外しても種類列は伸び戻らず、空いた幅はすべて名前列に回る。
    private func computeColumnPositions(contentWidth: CGFloat) {
        let baseFixed: [String: CGFloat] = [
            "date": Metrics.dateWidth,
            "size": Metrics.sizeWidth,
            "version": Metrics.versionWidth,
            "kind": Metrics.kindWidth,
        ]

        // 種類列の幅は全列（変更日・サイズを含む）を基準に決める。
        // 全列表示で名前列が最小幅を割る場合だけ、種類列を詰めて名前 120pt を確保する（下限 100pt）。
        var kindWidth = Metrics.kindWidth
        let gapsAll = CGFloat(columns.count - 1) * Metrics.columnGap
        let fixedAll = columns.compactMap { baseFixed[$0.id] }.reduce(0, +)
        let nameIfAllShown = contentWidth - gapsAll - fixedAll
        if nameIfAllShown < Metrics.nameMinWidth {
            kindWidth = max(100, Metrics.kindWidth - (Metrics.nameMinWidth - nameIfAllShown))
        }

        // 実際に表示する列で配置。種類は上で決めた固定幅、名前が残り（外した列ぶんも吸収）を取る。
        var fixed = baseFixed
        fixed["kind"] = kindWidth
        let cols = effectiveColumns
        let gaps = CGFloat(cols.count - 1) * Metrics.columnGap
        let fixedTotal = cols.compactMap { fixed[$0.id] }.reduce(0, +)
        let nameWidth = max(Metrics.nameMinWidth, contentWidth - gaps - fixedTotal)

        columnX = [:]
        var x: CGFloat = 0
        for col in cols {
            let w = (col.id == "name") ? nameWidth : (fixed[col.id] ?? 80)
            columnX[col.id] = (x, w)
            x += w + Metrics.columnGap
        }
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard !pageRowRanges.isEmpty else { return }
        let page = min(max(currentPage, 1), pageRowRanges.count)

        var y: CGFloat = 0
        if page == 1 {
            drawHeaderBlock(atY: y)
            y += headerBlockHeight
        }
        drawColumnHeader(atY: y)
        y += Metrics.columnHeaderHeight

        for i in pageRowRanges[page - 1] {
            drawRow(rows[i], atY: y)
            y += Metrics.rowHeight
        }

        drawFooter(page: page, pageCount: pageRowRanges.count)
    }

    /// ヘッダ右端に表示する印刷日時（ビュー生成時に確定）
    private let printedAt = Date()

    private static let printedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    /// 1ページ目のタイトルブロック：アイコン＋名称＋合計サイズ。右端に印刷日時
    private func drawHeaderBlock(atY y: CGFloat) {
        let dateWidth: CGFloat = 110
        let dateStr = Self.printedAtFormatter.string(from: printedAt)

        // 印刷日時（右端・タイトルと同じ行。常時）
        drawText(dateStr,
                 in: NSRect(x: bounds.width - dateWidth, y: y + 6,
                            width: dateWidth, height: 12),
                 font: .systemFont(ofSize: 8),
                 color: NSColor(white: 0.4, alpha: 1), alignment: .right)

        // アイコン（フォルダ表示のみ。ファイル一覧では nil ＝ 描画せず、タイトルは左端から始める）
        let iconSide: CGFloat = 24
        var textX: CGFloat = 0
        if let icon = header.icon {
            icon.draw(in: NSRect(x: 0, y: y + 3, width: iconSide, height: iconSide),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
            textX = iconSide + 10
        }

        drawText(header.title,
                 in: NSRect(x: textX, y: y + 3,
                            width: bounds.width - textX - dateWidth - 10, height: 16),
                 font: .boldSystemFont(ofSize: 12), color: .black)
        if let total = header.totalSize {
            let sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            drawText(sizeText,
                     in: NSRect(x: textX, y: y + 19, width: bounds.width - textX, height: 14),
                     font: .systemFont(ofSize: 9), color: NSColor(white: 0.4, alpha: 1))
        }
    }

    /// 列ヘッダ（全ページ）：列タイトル＋下端の罫線
    private func drawColumnHeader(atY y: CGFloat) {
        for col in effectiveColumns {
            guard let pos = columnX[col.id] else { continue }
            drawText(col.title,
                     in: NSRect(x: pos.x, y: y + 2, width: pos.width, height: 13),
                     font: .systemFont(ofSize: 8, weight: .semibold),
                     color: NSColor(white: 0.35, alpha: 1))
        }
        NSColor(white: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: y + Metrics.columnHeaderHeight - 3,
               width: bounds.width, height: 0.5).fill()
    }

    /// 1行を描画
    private func drawRow(_ row: PrintRow, atY y: CGFloat) {
        let item = row.item
        let dimmed = item.isDimmed
        // 画面表示と同じ色分け：
        //  - グレーアウト行は全列を薄いグレー
        //  - 名前・バージョンは通常色（黒）
        //  - 変更日・サイズは Finder 風に補助色（グレー）。種類はスイッチON の
        //    対象ファイル（ドット付き）のみ通常色、それ以外はグレー
        let textColor: NSColor = dimmed ? RowColor.dimmed : RowColor.primary
        let secondaryColor: NSColor = dimmed ? RowColor.dimmed : RowColor.secondary
        let font = NSFont.systemFont(ofSize: Metrics.rowFontSize)
        let textY = y + (Metrics.rowHeight - 13) / 2

        // 名前以外の列を先に背景として描く（変更日・サイズなどは後で名前を重ねる土台になる）。
        for col in effectiveColumns where col.id != "name" {
            guard let pos = columnX[col.id] else { continue }
            switch col.id {
            case "date":
                drawText(item.displayDate,
                         in: NSRect(x: pos.x, y: textY, width: pos.width, height: 13),
                         font: font, color: secondaryColor)
            case "size":
                drawText(item.displaySize,
                         in: NSRect(x: pos.x, y: textY, width: pos.width, height: 13),
                         font: font, color: secondaryColor, alignment: .right)
            case "version":
                // 対象ファイルは行頭にアプリ系統のカラードット（画面表示と同じ）
                var verX = pos.x
                var verW = pos.width
                if let family = item.appFamily {
                    let d: CGFloat = 6
                    let dotRect = NSRect(x: pos.x, y: y + (Metrics.rowHeight - d) / 2,
                                         width: d, height: d)
                    family.markerColor.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                    let shift = d + 5
                    verX += shift
                    verW = max(0, verW - shift)
                }
                drawText(item.displayVersion,
                         in: NSRect(x: verX, y: textY, width: verW, height: 13),
                         font: font, color: textColor)
            case "kind":
                var text = item.displayKindForList(versionMode: versionMode)
                // 縦向きは種類列が狭く PDF の " (.pdf)" だけが切れやすいので、それを省く。
                // 一致(黒)時は displayKind が既に全拡張子を省くため、ここは主に拡張子偽装の
                // PDF を縦向きで詰めるのに効く。
                if isPortrait && versionMode {
                    text = Self.kindWithoutPDFSuffix(text)
                }
                let kindRect = NSRect(x: pos.x, y: textY, width: pos.width, height: 13)
                if versionMode && item.kindMismatch {
                    // 偽装：先頭の警告記号 ⚠ は常に赤。種類名は設定 ON＝赤／OFF＝通常色。2色で描く。
                    let nameColor: NSColor = kindMismatchRedText
                        ? .kindMismatchWarningPrint
                        : (item.appFamily != nil ? RowColor.primary : RowColor.secondary)
                    drawKindMismatch(text, in: kindRect, font: font, nameColor: nameColor)
                } else {
                    // グレーアウト＞対象ファイルは通常色＞それ以外はグレー
                    let color: NSColor
                    if dimmed {
                        color = RowColor.dimmed
                    } else if versionMode && item.appFamily != nil {
                        color = RowColor.primary
                    } else {
                        color = RowColor.secondary
                    }
                    drawText(text, in: kindRect, font: font, color: color)
                }
            default:
                break
            }
        }

        // 名前列は最前面に描く。名前は重要なので途中省略（…）せず、必要なら右側の列
        // （変更日・サイズなど）の上に重ねて全文を描画する。変更日・サイズはグレー文字
        // なので、その上に黒い名前を重ねても読める。
        if let pos = columnX["name"] {
            let indent = CGFloat(row.level) * Metrics.indentPerLevel
            // シェブロン領域は全行に確保（同階層のファイルとフォルダのアイコンを揃える）
            if row.isExpandable {
                drawChevron(in: NSRect(x: pos.x + indent, y: y,
                                       width: Metrics.chevronWidth,
                                       height: Metrics.rowHeight),
                            expanded: row.isExpanded)
            }
            let iconX = pos.x + indent + Metrics.chevronWidth
            item.icon.draw(in: NSRect(x: iconX,
                                      y: y + (Metrics.rowHeight - Metrics.iconSize) / 2,
                                      width: Metrics.iconSize, height: Metrics.iconSize),
                           from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            let textX = iconX + Metrics.iconSize + 4
            // 用紙右端まで描画領域を広げ、省略はせずクリップのみ（… を付けない）
            let w = max(0, bounds.width - textX)
            drawText(item.name, in: NSRect(x: textX, y: textY, width: w, height: 13),
                     font: font, color: textColor, lineBreakMode: .byClipping)
        }
    }

    /// フォルダの展開状態シェブロン：展開中は「∨」、閉じていれば「>」
    private func drawChevron(in rect: NSRect, expanded: Bool) {
        let path = NSBezierPath()
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let cx = rect.midX
        let cy = rect.midY
        if expanded {
            // ∨（flipped 座標なので +y が下）
            path.move(to: NSPoint(x: cx - 3, y: cy - 1.5))
            path.line(to: NSPoint(x: cx, y: cy + 1.5))
            path.line(to: NSPoint(x: cx + 3, y: cy - 1.5))
        } else {
            // >
            path.move(to: NSPoint(x: cx - 1.5, y: cy - 3))
            path.line(to: NSPoint(x: cx + 1.5, y: cy))
            path.line(to: NSPoint(x: cx - 1.5, y: cy + 3))
        }
        NSColor(white: 0.35, alpha: 1).setStroke()
        path.stroke()
    }

    /// フッタ：ページ番号（中央揃え）
    private func drawFooter(page: Int, pageCount: Int) {
        drawText("\(page) / \(pageCount)",
                 in: NSRect(x: 0, y: bounds.height - Metrics.footerHeight + 8,
                            width: bounds.width, height: 12),
                 font: .systemFont(ofSize: 8),
                 color: NSColor(white: 0.4, alpha: 1), alignment: .center)
    }

    /// 種類文字列の末尾にある PDF の括弧書き " (.pdf)" だけを取り除く。
    /// .indd や .ai など他の拡張子の括弧は残す。
    private static func kindWithoutPDFSuffix(_ s: String) -> String {
        guard let r = s.range(of: #"\s*\(\.pdf\)\s*$"#,
                              options: [.regularExpression, .caseInsensitive]) else {
            return s
        }
        return String(s[..<r.lowerBound])
    }

    private func drawText(_ string: String, in rect: NSRect,
                          font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .natural,
                          lineBreakMode: NSLineBreakMode = .byTruncatingTail) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        style.alignment = alignment
        (string as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    /// 偽装行の種類列を2色で描く：先頭の警告記号 ⚠ は赤（kindMismatchWarningPrint）、
    /// 以降の種類名は `nameColor`。truncating tail は画面と同様に維持する。
    private func drawKindMismatch(_ string: String, in rect: NSRect,
                                 font: NSFont, nameColor: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attr = NSMutableAttributedString(string: string)
        let whole = NSRange(location: 0, length: attr.length)
        attr.addAttributes([.font: font, .paragraphStyle: style, .foregroundColor: nameColor],
                           range: whole)
        let glyphLen = min((FileItem.kindMismatchWarningPrefix as NSString).length, attr.length)
        attr.addAttribute(.foregroundColor, value: NSColor.kindMismatchWarningPrint,
                          range: NSRange(location: 0, length: glyphLen))
        attr.draw(in: rect)
    }
}

// MARK: - PrintColumnOptions

/// 印刷時の任意列（変更日／サイズ）の表示状態。印刷パネルのアクセサリと
/// PrintLayoutView が共有する。PrintLayoutView が強参照するため、印刷パネルを
/// 閉じた後の本描画でも確定値が残る（毎回 printList で生成するので既定は両方ON）。
final class PrintColumnOptions {
    var showDate = true
    var showSize = true
}

// MARK: - PrintColumnOptionsController

/// 印刷パネルに「変更日／サイズ」の表示チェックボックスを足すアクセサリ。
/// チェック変更は共有の PrintColumnOptions に書き戻し、KVO 対応プロパティの変更で
/// プレビューを再描画させる（keyPathsForValuesAffectingPreview）。
final class PrintColumnOptionsController: NSViewController, NSPrintPanelAccessorizing {
    private let options: PrintColumnOptions
    @objc dynamic var showDate: Bool
    @objc dynamic var showSize: Bool

    init(options: PrintColumnOptions) {
        self.options = options
        self.showDate = options.showDate
        self.showSize = options.showSize
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Print Columns")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let dateBox = NSButton(checkboxWithTitle: String(localized: "Date Modified"),
                               target: self, action: #selector(toggleDate(_:)))
        dateBox.state = options.showDate ? .on : .off
        let sizeBox = NSButton(checkboxWithTitle: String(localized: "Size"),
                               target: self, action: #selector(toggleSize(_:)))
        sizeBox.state = options.showSize ? .on : .off

        let stack = NSStackView(views: [dateBox, sizeBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 84))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        view = container
    }

    @objc private func toggleDate(_ sender: NSButton) {
        let on = (sender.state == .on)
        options.showDate = on   // 本描画用に共有モデルを更新
        showDate = on           // KVO 発火 → プレビュー再描画
    }

    @objc private func toggleSize(_ sender: NSButton) {
        let on = (sender.state == .on)
        options.showSize = on
        showSize = on
    }

    // チェック変更でプレビューを更新させる
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["showDate", "showSize"] }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        var shown: [String] = []
        if options.showDate { shown.append(String(localized: "Date Modified")) }
        if options.showSize { shown.append(String(localized: "Size")) }
        let desc = shown.isEmpty ? String(localized: "None") : shown.joined(separator: ", ")
        return [[.itemName: String(localized: "Print Columns"), .itemDescription: desc]]
    }
}

// MARK: - PrintTotalSize

/// ヘッダに表示する合計サイズの取得（HANDOFF §3 の方針）
/// - ボリュームのルート：容量−空き で即時取得
/// - 通常フォルダ：再帰走査（3秒タイムアウト。タイムアウト時は nil＝表示しない）
enum PrintTotalSize {

    static func resolve(for url: URL) async -> Int64? {
        // ボリュームのルートなら容量から即時計算
        if let rv = try? url.resourceValues(forKeys:
            [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           rv.isVolume == true,
           let total = rv.volumeTotalCapacity,
           let available = rv.volumeAvailableCapacity {
            return Int64(total) - Int64(available)
        }
        // フォルダ（または容量が取れない特殊ボリューム）：再帰走査＋タイムアウト
        return await recursiveSize(of: url, timeout: 3.0)
    }

    private static func recursiveSize(of url: URL, timeout: TimeInterval) async -> Int64? {
        let deadline = Date().addingTimeInterval(timeout)
        return await Task.detached(priority: .userInitiated) {
            scanTotalSize(of: url, deadline: deadline)
        }.value
    }

    /// 再帰列挙の本体。NSEnumerator の for-in（makeIterator）は async コンテキストでは
    /// 使用不可（Swift 6 でエラー）のため、同期関数に分離して Task から呼ぶ。
    /// バックグラウンド（detached）から呼ぶため nonisolated。
    private nonisolated static func scanTotalSize(of url: URL, deadline: Date) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return nil }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Date() > deadline { return nil }   // タイムアウト：中途半端な値は出さない
            guard let rv = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            if rv.isRegularFile == true {
                total += Int64(rv.fileSize ?? 0)
            }
        }
        return total
    }
}

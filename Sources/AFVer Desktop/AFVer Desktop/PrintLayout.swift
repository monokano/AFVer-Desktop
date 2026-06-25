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
        static let kindWidth: CGFloat = 150
        static let kindWidthNoVersion: CGFloat = 120  // バージョン列OFF時は種類列を狭め、名前列を広く
        static let nameMinWidth: CGFloat = 170  // 名前列の下限。バージョンON・縦向きの窮屈ケースで名前を広げる効果（種類が縮んで吸収）
    }

    /// 行の文字色（画面表示の labelColor / secondaryLabelColor / tertiaryLabelColor に対応）。
    /// 用紙は白前提なので固定グレーで表現する。
    private enum RowColor {
        static let primary = NSColor.black                   // labelColor（名前・バージョン・対象種類）
        static let secondary = NSColor(white: 0.4, alpha: 1) // 補助グレー（変更日・サイズ・非対象種類）。見出し・ページ番号と同じ濃さ
        static let dimmed = NSColor(white: 0.55, alpha: 1)   // グレーアウト行（読み込み失敗等）。補助より少し薄い
    }

    // MARK: 入力

    private let rows: [PrintRow]
    private let columns: [OutlineListColumn]
    private let versionMode: Bool
    private let header: PrintHeaderInfo
    /// 列の表示オプション（印刷パネルのアクセサリで切替）。OFF の列は幅計算・描画から外す。
    /// 印刷確定後の本描画でも参照するため、ビューが強参照して生かしておく。
    private let columnOptions: PrintColumnOptions
    /// 設定「拡張子の偽装または非Ai/PsのEPSは種類を赤文字にする」。false（既定）＝警告記号 ⚠ だけ赤・
    /// 種類名は黒／true＝種類名も赤。画面（OutlineList）と同じ方針を印刷にも適用する。
    private let kindMismatchRedText: Bool

    // MARK: ページネーション状態（knowsPageRange で計算）

    private var pageRowRanges: [Range<Int>] = []
    /// 各行の高さ（折り返しON で名前・種類が複数行になると伸びる。OFF は一律 Metrics.rowHeight）。
    private var rowHeights: [CGFloat] = []
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

        // 各行の高さを算出（折り返しON なら名前・種類の折り返し行数で伸びる）。
        rowHeights = rows.map { measuredRowHeight($0) }

        // ページ分割：1ページ目はタイトルブロックぶん行領域が狭い。
        // 行高が可変なので、容量を超える手前で改ページする。1行が1ページに収まらない
        // 極端なケースは無限ループ回避のため最低1行は載せる（クリップされる）。
        let firstCap = contentH - headerBlockHeight - Metrics.columnHeaderHeight - Metrics.footerHeight
        let otherCap = contentH - Metrics.columnHeaderHeight - Metrics.footerHeight

        pageRowRanges = []
        var index = 0
        var isFirst = true
        while index < rows.count {
            let capacity = isFirst ? firstCap : otherCap
            let start = index
            var used: CGFloat = 0
            while index < rows.count, used + rowHeights[index] <= capacity || index == start {
                used += rowHeights[index]
                index += 1
            }
            pageRowRanges.append(start..<index)
            isFirst = false
        }
    }

    /// 変更日・サイズ・バージョン列を「ヘッダと内容の最長幅＋余白 pad」に合わせて算出する。
    /// 固定値ではなく実データ依存（その印刷で実際に出る最長文字列に合わせる）。
    /// ・内容は本文フォント(9pt)、ヘッダ（列タイトル）は列ヘッダのフォント(8pt semibold)で測る。
    /// ・バージョンは行頭のカラードット＋余白(11pt)を内容幅に加える（drawRow と一致）。
    /// ・ヘッダも含めるのは「バージョン」見出しが版数より長く、内容だけだと見出しが切れるため。
    private func contentFittedFixedWidths() -> [String: CGFloat] {
        let rowFont = NSFont.systemFont(ofSize: Metrics.rowFontSize)
        let headerFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let pad: CGFloat = 4
        let dotShift: CGFloat = 6 + 5   // ドット直径6 + 余白5（drawRow の version と一致）

        func width(_ s: String, _ f: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width
        }
        func headerWidth(_ id: String) -> CGFloat {
            guard let title = columns.first(where: { $0.id == id })?.title else { return 0 }
            return width(title, headerFont)
        }

        var dateMax = headerWidth("date")
        var sizeMax = headerWidth("size")
        var versionMax = headerWidth("version")
        for row in rows {
            let item = row.item
            dateMax = max(dateMax, width(item.displayDate, rowFont))
            sizeMax = max(sizeMax, width(item.displaySize, rowFont))
            let vShift = item.appFamily != nil ? dotShift : 0
            versionMax = max(versionMax, vShift + width(item.displayVersion, rowFont))
        }
        return ["date": ceil(dateMax) + pad,
                "size": ceil(sizeMax) + pad,
                "version": ceil(versionMax) + pad]
    }

    /// 全行の名前を1行で表示するのに必要な「名前列の最大幅」。
    /// 先頭オフセット（インデント＋▶＋アイコン＋余白4）＋名前テキスト幅 の行ごとの最大値。
    /// 名前列が余っているとき内容幅まで詰める判定に使う（ZWSP は幅0なので素の name で測れる）。
    private func longestNameColumnWidth() -> CGFloat {
        let rowFont = NSFont.systemFont(ofSize: Metrics.rowFontSize)
        var maxW: CGFloat = 0
        for row in rows {
            let lead = CGFloat(row.level) * Metrics.indentPerLevel
                + Metrics.chevronWidth + Metrics.iconSize + 4
            let textW = (row.item.name as NSString).size(withAttributes: [.font: rowFont]).width
            maxW = max(maxW, lead + textW)
        }
        return maxW
    }

    /// 各列の x 位置と幅を決める。固定幅列を確保した残りを名前列に割り当てる。
    /// 種類列の幅は「全列を表示したときの値」で決め、表示中の列構成では変えない。
    /// こうすることで、変更日／サイズを外しても種類列は伸び戻らず、空いた幅はすべて名前列に回る。
    private func computeColumnPositions(contentWidth: CGFloat) {
        // 種類列の基準幅。バージョン列OFF（縦向き・種類が主役でない）では狭めて、
        // 空いた幅を名前列へ回す。
        let baseKindWidth = versionMode ? Metrics.kindWidth : Metrics.kindWidthNoVersion
        // 変更日・サイズ・バージョンは内容に合わせた幅（最長文字列＋余白）。
        let fitted = contentFittedFixedWidths()
        let baseFixed: [String: CGFloat] = [
            "date": fitted["date"] ?? Metrics.dateWidth,
            "size": fitted["size"] ?? Metrics.sizeWidth,
            "version": fitted["version"] ?? Metrics.versionWidth,
            "kind": baseKindWidth,
        ]

        // 種類列の幅は全列（変更日・サイズを含む）を基準に決める。
        // 全列表示で名前列が最小幅を割る場合だけ、種類列を詰めて名前の最小幅(nameMinWidth)を確保する（種類の下限 100pt）。
        var kindWidth = baseKindWidth
        let gapsAll = CGFloat(columns.count - 1) * Metrics.columnGap
        let fixedAll = columns.compactMap { baseFixed[$0.id] }.reduce(0, +)
        let nameIfAllShown = contentWidth - gapsAll - fixedAll
        if nameIfAllShown < Metrics.nameMinWidth {
            kindWidth = max(100, baseKindWidth - (Metrics.nameMinWidth - nameIfAllShown))
        }

        // 実際に表示する列で配置。種類は上で決めた固定幅、名前が残り（外した列ぶんも吸収）を取る。
        var fixed = baseFixed
        fixed["kind"] = kindWidth
        let cols = effectiveColumns
        let gaps = CGFloat(cols.count - 1) * Metrics.columnGap
        let fixedTotal = cols.compactMap { fixed[$0.id] }.reduce(0, +)
        var nameWidth = max(Metrics.nameMinWidth, contentWidth - gaps - fixedTotal)

        // 名前列が「実際の最長名＋9pt」より広く余る場合は、名前をその幅に詰めて
        // 余りをすべて種類列へ回す（名前がブカブカなときだけ働く。長い名前で詰まって
        // いるときは nameWidth ≤ 上限なので変化しない）。
        let kindShown = cols.contains { $0.id == "kind" }
        let nameCap = longestNameColumnWidth() + 9
        if kindShown, nameWidth > nameCap {
            fixed["kind"] = (fixed["kind"] ?? kindWidth) + (nameWidth - nameCap)
            nameWidth = nameCap
        }

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
            drawRow(rows[i], atY: y, rowH: rowHeights[i])
            y += rowHeights[i]
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
    // MARK: 行高の計算（折り返し対応）

    /// 9pt フォント1行ぶんの高さ（折り返しOFF 相当の基準）。
    private var singleLineTextHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: Metrics.rowFontSize)
        return ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height)
    }

    /// 1行ぶんの高さを返す。折り返しON のときは名前・種類を各列幅で折り返したときの
    /// 最大高さで伸ばす（短い行は Metrics.rowHeight のまま）。OFF は一律 Metrics.rowHeight。
    private func measuredRowHeight(_ row: PrintRow) -> CGFloat {
        guard columnOptions.wrap else { return Metrics.rowHeight }
        let font = NSFont.systemFont(ofSize: Metrics.rowFontSize)
        let line = singleLineTextHeight
        var maxText = line
        // 名前：アイコン・シェブロン・インデントを除いた名前列内の幅で折り返す
        if let pos = columnX["name"] {
            let indent = CGFloat(row.level) * Metrics.indentPerLevel
            let textX = pos.x + indent + Metrics.chevronWidth + Metrics.iconSize + 4
            let w = max(10, pos.x + pos.width - textX)
            // 名前はファイル名なので基準名は任意位置で改行（拡張子は分割しない）。byWordWrapping＋ZWSP。
            maxText = max(maxText, wrappedTextHeight(breakableFileName(row.item.name),
                                                     width: w, font: font))
        }
        // 種類：列幅で折り返す（折り返し時は (.pdf) 省略をせず全文を出す）
        if let pos = columnX["kind"] {
            let text = row.item.displayKindForList(versionMode: versionMode)
            maxText = max(maxText, wrappedTextHeight(text, width: pos.width, font: font))
        }
        // 単一行と同じ上下パディングを保って行高へ変換（1行なら Metrics.rowHeight に一致）
        return ceil(maxText) + (Metrics.rowHeight - line)
    }

    /// 指定幅で折り返したときのテキスト全体の高さ。lineBreakMode で改行規則を切替える
    /// （名前は文字単位 .byCharWrapping、種類は単語単位 .byWordWrapping）。
    private func wrappedTextHeight(_ s: String, width: CGFloat, font: NSFont,
                                  lineBreakMode: NSLineBreakMode = .byWordWrapping) -> CGFloat {
        guard !s.isEmpty, width > 0 else { return singleLineTextHeight }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        let r = (s as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: style])
        return r.height
    }

    /// 行頭にできない約物・小書き仮名・長音等（その手前では改行しない＝直前に ZWSP を入れない）
    private static let noBreakBefore = Set<Character>(
        ")]}）］｝〕〉》」』】、。，．・：；！？‐ー〜～々ゝゞヽヾ"
        + "ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ"
        + ".,;:!?’”")
    /// 行末にできない始め括弧・起こし引用符（その直後では改行しない＝直後に ZWSP を入れない）
    private static let noBreakAfter = Set<Character>("([{（［｛〔〈《「『【‘“")

    /// ファイル名を「拡張子を分割せず、約物の禁則を守って折り返す」用の文字列へ変換する。
    /// 基準名（拡張子を除いた部分）の文字間にゼロ幅スペース U+200B を挟んで任意位置で改行可に
    /// するが、行頭禁則文字の手前／行末禁則文字の直後には入れない（「(」の直後や「)」「。」の
    /// 手前では改行させない）。末尾の拡張子（".indd" 等）は直前の文字に繋げて塊で保持する
    /// （"." は行頭禁則なので手前に改行機会を置かない）。ZWSP は幅0なので見た目・行幅は変わらず、
    /// 改行機会だけが増える（.byWordWrapping と併用）。
    private func breakableFileName(_ name: String) -> String {
        let zwsp: Character = "\u{200B}"
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : (ns.deletingPathExtension as String)

        let chars = Array(base)
        var result = ""
        result.reserveCapacity(chars.count * 2)
        for (i, c) in chars.enumerated() {
            result.append(c)
            guard i < chars.count - 1 else { continue }
            let next = chars[i + 1]
            // 禁則：始め括弧の直後・終わり括弧や句読点の手前では改行機会を作らない
            if Self.noBreakAfter.contains(c) || Self.noBreakBefore.contains(next) { continue }
            result.append(zwsp)
        }
        return ext.isEmpty ? result : result + "." + ext
    }

    private func drawRow(_ row: PrintRow, atY y: CGFloat, rowH: CGFloat) {
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
        let wrap = columnOptions.wrap
        // 折り返し列に与える描画高さ：先頭行の上端から行の下端まで
        let wrapH = max(13, rowH - (textY - y))

        // 名前以外の列を先に背景として描く（変更日・サイズなどは後で名前を重ねる土台になる）。
        // アイコン・ドット・シェブロン・単一行テキストは「先頭行」に top 揃えで描く（y 基準のまま）。
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
                    if family == .epsOther {
                        // generic EPS は中空リング（輪郭）
                        family.markerColor.setStroke()
                        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
                        ring.lineWidth = 1
                        ring.stroke()
                    } else {
                        family.markerColor.setFill()
                        NSBezierPath(ovalIn: dotRect).fill()
                    }
                    let shift = d + 5
                    verX += shift
                    verW = max(0, verW - shift)
                }
                drawText(item.displayVersion,
                         in: NSRect(x: verX, y: textY, width: verW, height: 13),
                         font: font, color: textColor)
            case "kind":
                var text = item.displayKindForList(versionMode: versionMode)
                // 折り返しOFF・縦向きのときだけ PDF の " (.pdf)" を省いて1行に詰める。
                // 折り返しON では全文を出して列幅で折り返す。
                if !wrap && isPortrait && versionMode {
                    text = Self.kindWithoutPDFSuffix(text)
                }
                let mode: NSLineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
                let kindRect = NSRect(x: pos.x, y: textY, width: pos.width,
                                      height: wrap ? wrapH : 13)
                if versionMode && item.kindMismatch {
                    // 偽装：先頭の警告記号 ⚠ は常に赤。種類名は設定 ON＝赤／OFF＝通常色。2色で描く。
                    let nameColor: NSColor = kindMismatchRedText
                        ? .kindMismatchWarningPrint
                        : (item.appFamily != nil ? RowColor.primary : RowColor.secondary)
                    drawKindMismatch(text, in: kindRect, font: font,
                                     nameColor: nameColor, lineBreakMode: mode)
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
                    drawText(text, in: kindRect, font: font, color: color, lineBreakMode: mode)
                }
            default:
                break
            }
        }

        // 名前列。
        // - 折り返しON：名前列の幅内で折り返す（右の列には重ねない）。
        // - 折り返しOFF（従来）：用紙右端まで全幅1行で描き、省略せずクリップ（右のグレー列に重ねる）。
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
            if wrap {
                let w = max(0, pos.x + pos.width - textX)
                // 基準名は任意位置で改行・拡張子は分割しない（breakableFileName＋ZWSP）
                drawText(breakableFileName(item.name),
                         in: NSRect(x: textX, y: textY, width: w, height: wrapH),
                         font: font, color: textColor, lineBreakMode: .byWordWrapping)
            } else {
                let w = max(0, bounds.width - textX)
                drawText(item.name, in: NSRect(x: textX, y: textY, width: w, height: 13),
                         font: font, color: textColor, lineBreakMode: .byClipping)
            }
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
                                 font: NSFont, nameColor: NSColor,
                                 lineBreakMode: NSLineBreakMode = .byTruncatingTail) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
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

/// 印刷時のアクセサリ設定（変更日／サイズの表示・折り返し）。印刷パネルのアクセサリと
/// PrintLayoutView が共有する。PrintLayoutView が強参照するため、印刷パネルを閉じた後の
/// 本描画でも確定値が残る。各値は UserDefaults に永続化し、次回の印刷・次回起動でも復元する
/// （未設定の初回はすべて ON）。
final class PrintColumnOptions {
    private static let showDateKey = "printShowDate"
    private static let showSizeKey = "printShowSize"
    private static let wrapKey     = "printWrapText"

    var showDate: Bool { didSet { UserDefaults.standard.set(showDate, forKey: Self.showDateKey) } }
    var showSize: Bool { didSet { UserDefaults.standard.set(showSize, forKey: Self.showSizeKey) } }
    /// 名前・種類列をセル内で折り返すか（既定 ON）。OFF で従来の単一行
    /// （名前は用紙全幅に1行オーバーレイ・種類は末尾省略）に戻る。
    var wrap: Bool { didSet { UserDefaults.standard.set(wrap, forKey: Self.wrapKey) } }

    init() {
        let ud = UserDefaults.standard
        // 未設定（初回起動）は ON。object(forKey:) が nil のときだけ既定 true を採る。
        showDate = (ud.object(forKey: Self.showDateKey) as? Bool) ?? true
        showSize = (ud.object(forKey: Self.showSizeKey) as? Bool) ?? true
        wrap     = (ud.object(forKey: Self.wrapKey)     as? Bool) ?? true
    }
}

// MARK: - PrintColumnOptionsController

/// 印刷パネルに「変更日／サイズ」の表示チェックボックスを足すアクセサリ。
/// チェック変更は共有の PrintColumnOptions に書き戻し、KVO 対応プロパティの変更で
/// プレビューを再描画させる（keyPathsForValuesAffectingPreview）。
final class PrintColumnOptionsController: NSViewController, NSPrintPanelAccessorizing {
    private let options: PrintColumnOptions
    @objc dynamic var showDate: Bool
    @objc dynamic var showSize: Bool
    @objc dynamic var wrap: Bool

    init(options: PrintColumnOptions) {
        self.options = options
        self.showDate = options.showDate
        self.showSize = options.showSize
        self.wrap = options.wrap
        super.init(nibName: nil, bundle: nil)
        title = "AFVer Desktop"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let dateBox = NSButton(checkboxWithTitle: String(localized: "Date Modified"),
                               target: self, action: #selector(toggleDate(_:)))
        dateBox.state = options.showDate ? .on : .off
        let sizeBox = NSButton(checkboxWithTitle: String(localized: "Size"),
                               target: self, action: #selector(toggleSize(_:)))
        sizeBox.state = options.showSize ? .on : .off
        let wrapBox = NSButton(checkboxWithTitle: String(localized: "Wrap Text"),
                               target: self, action: #selector(toggleWrap(_:)))
        wrapBox.state = options.wrap ? .on : .off

        let stack = NSStackView(views: [dateBox, sizeBox, wrapBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 108))
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

    @objc private func toggleWrap(_ sender: NSButton) {
        let on = (sender.state == .on)
        options.wrap = on   // 本描画用に共有モデルを更新
        wrap = on           // KVO 発火 → プレビュー再描画
    }

    // チェック変更でプレビューを更新させる
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["showDate", "showSize", "wrap"] }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        var shown: [String] = []
        if options.showDate { shown.append(String(localized: "Date Modified")) }
        if options.showSize { shown.append(String(localized: "Size")) }
        if options.wrap { shown.append(String(localized: "Wrap Text")) }
        let desc = shown.isEmpty ? String(localized: "None") : shown.joined(separator: ", ")
        return [[.itemName: "AFVer Desktop", .itemDescription: desc]]
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

//
// InDesign の作成バージョン判定エンジン。
// File Ver Id の FileParser.swift を移植（enum FileParser → IdVersionParser にリネームのみ）。
// IDML(ZIP) 解析に ZIPFoundation を使用。表示文字列は VersionInfo.swift 側で組み立てる（HANDOFF §4）。
//

import Foundation
import ZIPFoundation

// MARK: - Model

struct InddVersionResult {
    var url: URL

    var isValid: Bool = false
    var errorMessage: String = ""
    var headerMajor: Int = 0
    var headerMinor: Int = 0

    var xrefResult: String = ""

    var headerResult: String = ""
    var timeTotalSeconds: Double = 0

    // ヘッダー内ファイル種別から判定したコンテンツの種類
    // "indd" / "indt" / "indb" / "indl" / "idml" / "" (未判定)
    var contentKind: String = ""

    // 拡張子とコンテンツの種類が一致しない（拡張子偽装）
    var isExtMismatch: Bool = false

    // IDML 情報
    var isIDML: Bool = false
    var idmlProduct: String = ""
    var idmlDOMVersion: String = ""
    var idmlResult: String = ""
}

// MARK: - IdVersionParser

nonisolated enum IdVersionParser {

    private static let magic: [UInt8] = [
        0x06, 0x06, 0xED, 0xF5, 0xD8, 0x1D, 0x46, 0xE5,
        0xBD, 0x31, 0xEF, 0xE7, 0xFE, 0x74, 0xB7, 0x1D
    ]

    private static let validFileTypes: Set<String> = ["DOCUMENT", "BOOKBOOK", "LIBRARY4", "LIBRARY2"]
    private static let validExtensions: Set<String> = [".indd", ".indb", ".indl", ".indt", ".idml"]

    // MARK: - Entry

    /// - Parameter headerOnly: true なら xref（ファイル全体読み込み）を行わず、
    ///   先頭ヘッダ（38バイト）だけで判定する。CD-R 等での高速取得用。
    static func parse(url: URL, headerOnly: Bool = false) -> InddVersionResult {
        var result = InddVersionResult(url: url)

        let ext = "." + url.pathExtension.lowercased()

        // ヘッダーを先に読み、magic 一致ならバイナリ解析へ進む。
        // magic 不一致のときのみ IDML(ZIP) を拡張子非依存で確認することで、
        // 通常の indd/indt で不要な ZIP オープン（末尾走査）を避ける。
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            // 開けない＝ZIP としても開けない → IDML ではない。拡張子で文言を分ける。
            result.errorMessage = validExtensions.contains(ext)
                ? "ファイルを開けませんでした"
                : "対応していない拡張子です"
            return result
        }
        defer { try? fh.close() }

        // ── ヘッダー読み込み（38バイト） ──
        let header = try? fh.read(upToCount: 0x26)

        let isBinary: Bool
        if let h = header, h.count >= 0x26, Array(h[0..<16]) == magic {
            isBinary = true
        } else {
            isBinary = false
        }

        guard isBinary, let header else {
            // magic 不一致 → IDML(ZIP) かどうかをコンテンツで確認（拡張子に依存しない）
            if isIDMLPackage(url: url) {
                parseIDML(url: url, result: &result)
                return result
            }
            if !validExtensions.contains(ext) {
                result.errorMessage = "対応していない拡張子です"
            } else if (header?.count ?? 0) < 0x26 {
                result.errorMessage = "ファイルが短すぎます"
            } else {
                result.errorMessage = "InDesignファイルではありません"
            }
            return result
        }

        // ファイル種別
        let fileTypeBytes = header[0x10..<0x18]
        let fileTypeStr = String(bytes: fileTypeBytes, encoding: .ascii) ?? ""
        guard validFileTypes.contains(fileTypeStr) else {
            result.errorMessage = "未知のファイル種別: \(fileTypeStr)"
            return result
        }

        // コンテンツ（ヘッダー内ファイル種別）ベースで種類を判定
        // DOCUMENT のみ拡張子で .indd / .indt を区別
        switch fileTypeStr {
        case "DOCUMENT":
            result.contentKind = (ext == ".indt") ? "indt" : "indd"
            // DOCUMENT は .indd / .indt 以外なら偽装
            if ext != ".indd" && ext != ".indt" {
                result.isExtMismatch = true
            }
        case "BOOKBOOK":
            result.contentKind = "indb"
            if ext != ".indb" { result.isExtMismatch = true }
        case "LIBRARY4", "LIBRARY2":
            result.contentKind = "indl"
            if ext != ".indl" { result.isExtMismatch = true }
        default: break
        }

        // フォーマット判別・major/minor取得
        let newFmt = Array(header[0x18..<0x1c]) == [0x01, 0x70, 0x0F, 0x00]
        if newFmt {
            result.headerMajor = Int(header[0x1d])
            result.headerMinor = Int(header[0x21])
        } else {
            result.headerMajor = Int(header[0x20])
            result.headerMinor = Int(header[0x24])
        }
        result.isValid = true

        // major 8〜13（CS6〜CC2018）はヘッダー minor が信頼できない（更新バグ）。
        //  ・indl：xref を持たないため常にメジャーのみ表示
        //  ・indd/indt：通常は xref で minor を確定するが、headerOnly（高速）時は
        //    xref を引かないので、誤った minor を出さないようメジャーのみ表示する
        let unreliableMinor = result.headerMajor >= 8 && result.headerMajor <= 13
        let majorOnly = unreliableMinor && (result.contentKind == "indl"
            || (headerOnly && (result.contentKind == "indd" || result.contentKind == "indt")))
        let hVer = majorOnly ? "\(result.headerMajor)" : "\(result.headerMajor).\(result.headerMinor)"
        result.headerResult = "InDesign \(appName(result.headerMajor, result.headerMinor)) (\(hVer))"

        // 高速モード：ファイル全体読み込み＋xref 走査を行わず、ヘッダ結果のまま返す
        if headerOnly { return result }

        try? fh.seek(toOffset: 0)
        guard let data = try? fh.readToEnd() else { return result }

        runXref(data: data, result: &result)

        return result
    }

    // MARK: - xref スキャン

    private static func runXref(data: Data, result: inout InddVersionResult) {
        let blockSize = 0x1000
        let blockCount = data.count / blockSize
        guard blockCount > 2 else { return }

        // ヘッダー minor の更新バグは major 8〜13（CS6〜CC2018）のみ。
        // それ以外（CS5.5 以前 / CC2019 以降）はヘッダー minor が信頼できるので minor まで絞り込む。
        let prefix = (result.headerMajor <= 7 || result.headerMajor >= 14)
            ? "\(result.headerMajor).\(result.headerMinor)."
            : "\(result.headerMajor)."
        let pre = [UInt8](prefix.utf8)

        var sentinelHits: [(globalOffset: Int, version: String, ts6: UInt64)] = []
        var lastHits:     [(globalOffset: Int, version: String, ts6: UInt64)] = []

        // バイト走査は Data 越しの subscript / range(of:) を避け、生ポインタ＋memchr で行う。
        // trailer (+0xff4) の bid=8/9 抽出・プレフィックス絞り込み・sentinel 判定・TS6 読み出し・
        // ブロック境界(4096)の扱いは、いずれも従来の Data 版とバイト単位で完全に同一。
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rawBase = raw.baseAddress else { return }
            let p = rawBase.assumingMemoryBound(to: UInt8.self)
            let n = raw.count

            // 各ブロックの trailer (+0xff4) を読み、bid==8 / bid==9 の候補を収集。
            var candidates: [Int] = []
            candidates.reserveCapacity(blockCount / 4 + 1)
            for i in 0..<blockCount {
                let t = i * blockSize + 0xff4
                if t + 4 <= n {
                    let bid = u32le(p, t)
                    if bid == 8 || bid == 9 { candidates.append(i) }
                }
            }

            for i in candidates {
                let chunkStart = i * blockSize
                let chunkEnd   = chunkStart + blockSize
                if chunkEnd > n { continue }

                var searchFrom = chunkStart
                while searchFrom < chunkEnd,
                      let found = memchr(rawBase + searchFrom, 0x2E, chunkEnd - searchFrom) {
                    let dotIndex = UnsafeRawPointer(found) - rawBase
                    guard let (vs, ve) = versionRangeFast(p, dotAt: dotIndex, lo: chunkStart, hi: chunkEnd),
                          startsWith(p, vs, ve, pre) else {
                        searchFrom = dotIndex + 1
                        continue
                    }
                    let afterEnd = min(ve + 24, chunkEnd)
                    let ts6 = readTS6Fast(p, from: ve, hi: chunkEnd)
                    let ver = String(decoding: UnsafeBufferPointer(start: p + vs, count: ve - vs), as: UTF8.self)
                    let globalOffset = vs
                    if hasSentinelFast(p, lo: ve, hi: afterEnd) {
                        sentinelHits.append((globalOffset, ver, ts6))
                    }
                    lastHits.append((globalOffset, ver, ts6))
                    searchFrom = ve
                }
            }
        }

        // 採用アルゴリズム: ts32（バージョン文字列直後 +2..+5 を LE u32、FILETIME hi32 を
        // 約 7 分粒度に切り詰めた保存時刻）を主キー、物理オフセットをタイブレーカーにして
        // 降順最大を採用。詳細は xref採用アルゴリズム解析.md
        let cmp: (
            (globalOffset: Int, version: String, ts6: UInt64),
            (globalOffset: Int, version: String, ts6: UInt64)
        ) -> Bool = { a, b in
            let aTS32 = (a.ts6 >> 16) & 0xFFFFFFFF
            let bTS32 = (b.ts6 >> 16) & 0xFFFFFFFF
            if aTS32 != bTS32 { return aTS32 < bTS32 }
            return a.globalOffset < b.globalOffset
        }

        let chosen: String?
        if let top = sentinelHits.max(by: cmp) {
            chosen = top.version
        } else if let top = lastHits.max(by: cmp) {
            chosen = top.version
        } else {
            chosen = nil
        }

        if let ver = chosen {
            let parts = ver.split(separator: ".")
            if parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) {
                result.xrefResult = "InDesign \(appName(major, minor)) (\(ver))"
            }
        }
    }

    // MARK: - xref バイト走査ヘルパー（生ポインタ版）
    //
    // バージョンレコードの形式:
    //   旧フォーマット（CS）:     [len] 0x40 [len] [version] [TS6]
    //   新フォーマット（CC以降）: [len] 0x40 [version] [TS6]
    // 長さプレフィックスを尊重して version を切り出す（貪欲マッチだと
    // 例: "12.1.0.56" が直後の TS6 先頭バイト '8'(=0x38) を食って "12.1.0.568" になる）。
    // いずれも [lo,hi) のブロック境界内だけを参照し、従来の Data 版とバイト単位で同一の結果を返す。

    @inline(__always) private static func u32le(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt32 {
        UInt32(p[i]) | (UInt32(p[i + 1]) << 8) | (UInt32(p[i + 2]) << 16) | (UInt32(p[i + 3]) << 24)
    }

    @inline(__always) private static func isDig(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    /// "." の位置から M.m.p.b を [lo,hi) 内で解析。返値は p への絶対 index 範囲 (start, end)。
    @inline(__always)
    private static func versionRangeFast(_ p: UnsafePointer<UInt8>, dotAt: Int, lo: Int, hi: Int) -> (Int, Int)? {
        guard dotAt > lo else { return nil }
        var start = dotAt - 1
        while start > lo && isDig(p[start - 1]) { start -= 1 }
        guard isDig(p[start]) else { return nil }

        var pos = dotAt + 1
        var dots = 1
        while pos < hi {
            let b = p[pos]
            if isDig(b) { pos += 1 }
            else if b == 0x2E && dots < 3 { dots += 1; pos += 1 }
            else { break }
        }
        guard dots == 3, pos > dotAt + 1, isDig(p[pos - 1]) else { return nil }

        // ── 長さプレフィックスでバージョン長を補正 ──
        // 新フォーマット: 直前バイト = 0x40、その前 = 長さ
        // 旧フォーマット: 直前バイト = 長さ、その前 = 0x40
        // 貪欲マッチが TS6 先頭バイトを数字として取り込む（例: "12.1.0.56" → "12.1.0.568"）と
        // ts6 読み出し位置が1バイトずれ ts32 が壊れるため、宣言長で切り詰める。
        let offsetFromStart = start - lo
        let greedyLen = pos - start
        if offsetFromStart >= 2 {
            if p[start - 1] == 0x40 {
                let d = Int(p[start - 2])
                if d >= 5 && d <= 15 && d <= greedyLen { return (start, start + d) }
            } else if p[start - 2] == 0x40 {
                let d = Int(p[start - 1])
                if d >= 5 && d <= 15 && d <= greedyLen { return (start, start + d) }
            }
        }
        return (start, pos)
    }

    /// バージョン文字列直後の6バイトを LE u48 として読む（hi で打ち切り）。
    @inline(__always)
    private static func readTS6Fast(_ p: UnsafePointer<UInt8>, from start: Int, hi: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<6 {
            let idx = start + i
            if idx >= hi { break }
            v |= UInt64(p[idx]) << (i * 8)
        }
        return v
    }

    /// センチネル: [lo,hi) で 0x40 を全走査し、直後に 6バイト以上 0x00 が続くものを検出。
    @inline(__always)
    private static func hasSentinelFast(_ p: UnsafePointer<UInt8>, lo: Int, hi: Int) -> Bool {
        var i = lo
        while i < hi {
            if p[i] == 0x40 && i + 7 <= hi {
                var ok = true
                for k in 1...6 where p[i + k] != 0x00 { ok = false; break }
                if ok { return true }
            }
            i += 1
        }
        return false
    }

    /// p[start..<end] が pre で始まるか（バイト比較）。
    @inline(__always)
    private static func startsWith(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ pre: [UInt8]) -> Bool {
        if end - start < pre.count { return false }
        for k in 0..<pre.count where p[start + k] != pre[k] { return false }
        return true
    }

    // MARK: - IDML パーサー

    private static func isIDMLPackage(url: URL) -> Bool {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            guard let entry = archive["mimetype"] else { return false }
            var raw = Data()
            _ = try archive.extract(entry) { raw.append($0) }
            let mime = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return mime == "application/vnd.adobe.indesign-idml-package"
        } catch {
            return false
        }
    }

    private static func parseIDML(url: URL, result: inout InddVersionResult) {
        if url.pathExtension.lowercased() != "idml" {
            result.isExtMismatch = true
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            result.errorMessage = "IDMLファイルを開けませんでした"
            return
        }
        guard let entry = archive["designmap.xml"] else {
            result.errorMessage = "designmap.xml が見つかりません"
            return
        }

        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { xmlData.append($0) }
        } catch {
            result.errorMessage = "designmap.xml を読み込めませんでした"
            return
        }

        let head = xmlData.prefix(2048)
        guard let text = String(data: head, encoding: .utf8) else {
            result.errorMessage = "designmap.xml をデコードできませんでした"
            return
        }

        let product = firstMatch(in: text, pattern: #"product="([^"]+)""#) ?? ""
        let dom     = firstMatch(in: text, pattern: #"DOMVersion="([^"]+)""#) ?? ""
        guard !product.isEmpty else {
            result.errorMessage = "product 属性が見つかりません"
            return
        }

        let mm: String
        if let lp = product.firstIndex(of: "(") {
            mm = String(product[..<lp])
        } else {
            mm = product
        }
        let mmParts = mm.split(separator: ".")
        let major = mmParts.first.flatMap { Int($0) } ?? 0
        let minor = mmParts.count >= 2 ? (Int(mmParts[1]) ?? 0) : 0

        result.isIDML = true
        result.contentKind = "idml"
        result.isValid = true
        result.headerMajor = major
        result.headerMinor = minor
        result.idmlProduct = product
        result.idmlDOMVersion = dom
        result.idmlResult = "InDesign \(appName(major, minor)) (\(major).\(minor))"
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - データ読み出しヘルパー

    static func appName(_ major: Int, _ minor: Int) -> String {
        switch major {
        case 3:  return "CS"
        case 4:  return "CS2"
        case 5:  return "CS3"
        case 6:  return "CS4"
        case 7:  return minor >= 5 ? "CS5.5" : "CS5"
        case 8:  return "CS6"
        case 9:  return "CC"
        case 10: return "CC 2014"
        case 11: return "CC 2015"
        case 12: return "CC 2017"
        case 13: return "CC 2018"
        case 14: return "CC 2019"
        default: return major >= 15 ? String(major + 2005) : "\(major)"
        }
    }
}

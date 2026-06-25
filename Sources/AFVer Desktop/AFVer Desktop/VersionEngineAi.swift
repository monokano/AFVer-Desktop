//
// Illustrator / Photoshop の作成バージョン判定エンジン。
// File Ver Ai の FileInfo.swift を移植（enum FileParser → AiVersionParser にリネームのみ）。
// 表示文字列（種類名・バージョン整形）の組み立ては VersionInfo.swift 側で行う（HANDOFF §4）。
//

import Foundation
import zlib

// MARK: - AiFileModel

struct AiFileModel {
    var url: URL

    var kind: String = ""               // "Ai" / "EPS" / "PDF" / "PSD" / "PSB"（PSD=8BPS version1 / PSB=version2）
    var appName: String = ""            // "Illustrator" or "Photoshop"
    var isIllustratorFile: Bool = false
    var isTemplate: Bool = false        // true = 本物の Illustrator テンプレート（.ait）形式
    var isPhotoshopEditablePDF: Bool = false  // true = Photoshop編集機能保持PDF（/PieceInfo/AdobePhotoshop）

    /// xref 経由で辿った AIMetaData オブジェクト番号（通常 .ai の A-2 経路でのみ非nil）。
    /// getFileKind で確定し、scanVersionCommentsFromPDF が再 traverse を省くために使う。
    var aiMetaDataObjNum: Int? = nil

    var finderInfoFileType: String = ""
    var finderInfoCreator: String = ""

    var creator1: String = ""
    var creator2: String = ""
    var ai8CreatorVersion: String = ""
    var hasCreator2: Bool = true

    // Photoshop バージョン（PSD/PSB=cinf psVersion / EPS=%%Creator）。例 "26.11.5"
    var psVersion: String = ""

    var determineCreated: String = ""
    var determineSaved: String = ""
    var isSavedLowerVersion: Bool = false
    var isTimeOut: Bool = false

    var timeCreator1: Double = 0
    var timeAI8CreatorVersion: Double = 0
    var timeCreator2: Double = 0
    var timeTotalSeconds: Double = 0
}

// MARK: - AiVersionParser

nonisolated enum AiVersionParser {

    // MARK: - 事前コンパイル済み正規表現
    // 呼び出しごとの NSRegularExpression 生成は CPU コストが高く、PDF 1 個の解析で
    // 同じパターン（特に pdfObjRef）を十数回コンパイルし直していた。定数パターンは
    // static に保持して使い回す。キー可変なものは既知キーを事前コンパイルし、未知キーのみ都度生成。

    /// "/Kids [ N 0 R ..." の最初の N
    private static let kidsRegex = try! NSRegularExpression(pattern: #"/Kids\s*\[\s*(\d+)\s+0\s+R"#)
    /// Photoshop EPS の %%Creator バージョン
    private static let epsCreatorVersionRegex =
        try! NSRegularExpression(pattern: #"%%Creator: Adobe Photoshop Version (\d+\.\d+\.\d+)"#)
    /// creator1 の Illustrator メジャーバージョン
    private static let illustratorMajorRegex = try! NSRegularExpression(pattern: "Illustrator[^ ]* ([.\\d]+)")
    /// 末尾のバージョン番号サフィックス
    private static let versionSuffixRegex = try! NSRegularExpression(pattern: "[.\\d]+$")
    /// 旧フォーマット creator1 のバージョントークン
    private static let legacyCreatorRegex =
        try! NSRegularExpression(pattern: #"Illustrator[^ ]*\s+(\d+(?:\.\d+)?[A-Za-z]?)"#)

    /// `/Key N 0 R` 用（既知キーのみ事前コンパイル。コンパイル失敗キーは欠落＝都度生成にフォールバック）
    private static let objRefRegexes: [String: NSRegularExpression] = {
        var d: [String: NSRegularExpression] = [:]
        for key in ["Root", "Pages", "Illustrator", "Private", "AIMetaData", "StandardImageFileData"] {
            d[key] = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)\s+0\s+R"#)
        }
        return d
    }()
    /// `/Key N`（整数値）用（Prev など）
    private static let intValRegexes: [String: NSRegularExpression] = {
        var d: [String: NSRegularExpression] = [:]
        for key in ["Prev"] {
            d[key] = try? NSRegularExpression(
                pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)"#)
        }
        return d
    }()

    // MARK: - Entry

    /// - Parameter fastScan: true なら通常PDF確定時の `/AIMetaData` 全体走査（ファイル末尾までの
    ///   逐次読み）を省略する。CD-R 等で全体読み込みが遅い高速モード用。
    static func parse(url: URL, timeLimit: Double, notDetectEPSCompatibleVer: Bool,
                      fastScan: Bool = false, detectPsVersion: Bool = false) -> AiFileModel {
        var fc = AiFileModel(url: url)
        let startTotal = Date()

        // 1. Finder info
        let (fileType, creator) = getFinderInfo(url: url)
        fc.finderInfoFileType = fileType
        fc.finderInfoCreator = creator

        // FileHandle を1本だけ開き、PDF／非PDF どちらの経路でも使い回す（1ファイル1オープン）。
        // PDF 経路は従来から集約済みだったが、非PDF（PSD/PSB/EPS/旧AI）は種類判定・cinf・%%Creator 等が
        // それぞれ open していた（PSD で最大4オープン＋無駄な16KB読み）。この共有ハンドルを各ヘルパーへ
        // 渡して集約する。各ヘルパーは読み取り前に seek(0) するため、逐次の使い回しで結果は不変。
        // 先頭5バイトの %PDF- 判定もこのハンドルで行う。HANDOFF §4。
        let fileFH: FileHandle? = try? FileHandle(forReadingFrom: url)
        defer { try? fileFH?.close() }
        let isPDF: Bool = {
            guard let fh = fileFH else { return false }
            try? fh.seek(toOffset: 0)
            return fh.readData(ofLength: 5).starts(with: Data("%PDF-".utf8))
        }()
        // PDF 経路は従来どおり pdfFH（＝共有ハンドル）を使う。非PDF のときは nil。
        let pdfFH: FileHandle? = isPDF ? fileFH : nil

        // xref を一度だけ解析して以降で共有する（XMP取得とバージョンスキャンの両方で使用）
        let pdfXref: (root: Int, offsets: [Int: UInt64], compressed: [Int: (stm: Int, idx: Int)])? =
            pdfFH.flatMap { parsePDFXref(fh: $0) }

        // 2. ファイル種別判定（拡張子非依存・コンテンツベース）
        fc.kind = getFileKind(fc: &fc, pdfXref: pdfXref, pdfFH: pdfFH, dataFH: fileFH, fastScan: fastScan)

        // ※ XMP CreatorTool 取得は廃止。Illustrator/Photoshop の判定は中身（PSマーカー・8BPS・
        //    cinf 等）だけで完結する。CreatorTool の全体走査（最大50MB）は速度低下の元凶のため一切読まない。

        // 3. バージョンコメントをスキャン
        if fc.isIllustratorFile {
            if let xref = pdfXref, let fh = pdfFH {
                // PDF構造: 解析済み xref ＋ 共有 FileHandle で AIMetaData を直接読む
                // （AIMetaData はストリームオブジェクトで ObjStm には入らないため offsets のみで足りる）
                scanVersionCommentsFromPDF(xref: (root: xref.root, offsets: xref.offsets),
                                           url: url, fh: fh, fc: &fc, fastScan: fastScan)
            } else {
                // 非PDF（EPS・旧来 AI 等）: 逐次スキャン
                scanVersionComments(url: url, fc: &fc, timeLimit: timeLimit,
                                    notDetectEPSCompatibleVer: notDetectEPSCompatibleVer,
                                    startTotal: startTotal, sharedFH: fileFH)
            }
            determineVersion(fc: &fc)
        } else {
            fc.hasCreator2 = false
        }

        // 4. アプリ名（中身ベースで確定。XMP は使わない）
        if fc.isIllustratorFile {
            fc.appName = "Illustrator"
        } else if isPhotoshopFile(url: url, kind: fc.kind, sharedFH: fileFH) || fc.isPhotoshopEditablePDF {
            fc.appName = "Photoshop"
        }

        // 5. Photoshop バージョン取得（表示専用）: PSD/PSB=cinf psVersion / EPS=%%Creator / 編集PDF=埋め込みcinf
        //    cinf 由来のネイティブ版検出（PSD/PSB・編集機能保持PDF）は重い経路（PSD は最悪 Layer&Mask 全走査、
        //    編集PDF は埋め込みストリームを inflate）。`detectPsVersion`（＝full かつ設定 ON のときだけ true。
        //    fast モードと設定 OFF を内包）で抑止する。EPS の %%Creator は16KBヘッダのテキスト走査で軽いため
        //    常時検出する（種類判定・カラードットは detectPsVersion に関係なく別途実施済み）。
        if fc.appName == "Photoshop" {
            if fc.kind == "PSD" || fc.kind == "PSB" {
                if detectPsVersion, let v = psVersionFromCinf(url: url, sharedFH: fileFH) { fc.psVersion = v }
            } else if fc.kind == "EPS" {
                if let v = psVersionFromEPSCreator(url: url, sharedFH: fileFH) { fc.psVersion = v }
            } else if fc.kind == "PDF" && fc.isPhotoshopEditablePDF,
                      let xref = pdfXref, let fh = pdfFH {
                if detectPsVersion,
                   let v = psVersionFromPhotoshopPDF(root: xref.root, offsets: xref.offsets, fh: fh) {
                    fc.psVersion = v
                }
            }
        }

        // 6. Illustrator/Photoshop いずれでもない EPS は最初の %%Creator（生成元）を creator1 にセット。
        //    isIllustratorFile=false ではバージョンスキャンが走らないため、既読16KBヘッダから1行抽出して補う。
        if fc.kind == "EPS" && !fc.isIllustratorFile && fc.appName != "Photoshop" {
            let tc = Date()
            fc.creator1 = epsCreatorLine(url: url) ?? ""
            fc.timeCreator1 = Date().timeIntervalSince(tc)
        }

        fc.timeTotalSeconds = Date().timeIntervalSince(startTotal)
        return fc
    }

    // MARK: - Finder Info

    static func getFinderInfo(url: URL) -> (fileType: String, creator: String) {
        let path = url.path
        let attrName = "com.apple.FinderInfo"
        var buf = [UInt8](repeating: 0, count: 32)
        let result = getxattr(path, attrName, &buf, 32, 0, 0)
        guard result >= 8 else { return ("", "") }
        let fileType = String(bytes: buf[0..<4], encoding: .macOSRoman) ?? ""
        let creator  = String(bytes: buf[4..<8], encoding: .macOSRoman) ?? ""
        return (fileType, creator)
    }

    // MARK: - File Kind

    /// ファイル種別を判定する（拡張子に依存しない・コンテンツベース）
    ///
    /// 判定順：
    /// - A. PDF 構造（先頭 `%PDF-`）
    ///     1. `/AIPDFPrivateData` あり → `kind="PDF"`, isIllustratorFile=true（Illustrator編集機能保持PDF）
    ///     2. AIMetaData オブジェクトあり → `kind="Ai"`, isIllustratorFile=true（通常の.ai形式）
    ///     3. それ以外 → `kind="PDF"`（通常PDF）
    /// - B. PostScript セクション（生PSヘッダ or バイナリEPSラッパ後のPS）
    ///     - 1行目に `EPSF-` を含む → `kind="EPS"`、`%%Creator:` で Illustrator/Photoshop を判定
    ///     - 含まない（純PSの旧.ai） → Illustrator マーカーがあれば `kind="Ai"`, isIllustratorFile=true
    /// - C. PSD/PSB ネイティブ（先頭4B = `8BPS`） → version(byte4-5) で `kind="PSD"`(=1) / `"PSB"`(=2)
    /// - D. それ以外 → `kind=""`
    ///
    /// Finder Creator/FileType（ART5/8BIM）は最初に短絡させる（クラシックMac互換）。
    static func getFileKind(fc: inout AiFileModel,
                            pdfXref: (root: Int, offsets: [Int: UInt64], compressed: [Int: (stm: Int, idx: Int)])?,
                            pdfFH: FileHandle?, dataFH: FileHandle? = nil, fastScan: Bool = false) -> String {
        // Finder 情報での早期判定（クラシックMac互換）
        if fc.finderInfoCreator == "ART5" {
            if ["TEXT", "PDF ", "AITm"].contains(fc.finderInfoFileType) {
                fc.isIllustratorFile = true
                if fc.finderInfoFileType == "AITm" { fc.isTemplate = true }
                return epsHeaderCheck(url: fc.url, sharedFH: dataFH) ? "EPS" : "Ai"
            } else if ["EPSF", "EPSP"].contains(fc.finderInfoFileType) {
                fc.isIllustratorFile = true
                return "EPS"
            }
        } else if fc.finderInfoCreator == "8BIM" && fc.finderInfoFileType == "EPSF" {
            fc.isIllustratorFile = false
            return "EPS"
        }

        // A. PDF 構造（共有 FileHandle pdfFH を使い回す。各判定は読み取り前に seek(0) する）
        if let xref = pdfXref, let fh = pdfFH {
            // A-1. /AIPDFPrivateData → Illustrator編集機能保持PDF
            if isAIPDFFormat(fh: fh) {
                fc.isIllustratorFile = true
                return "PDF"
            }
            // Page[0] 辞書を解決する（ObjStm 内の圧縮オブジェクトも辿る）。
            // 読めたら Illustrator/Photoshop の痕跡をその場で判定でき、無ければ確定でプレーンPDF。
            // → プレーンPDFのたびにファイル全体を走査する A-2.5 を踏まずに済む（速度の要）。
            if let pageStr = firstPageDict(root: xref.root, offsets: xref.offsets,
                                           compressed: xref.compressed, fh: fh) {
                // A-2. 通常の .ai 形式（PDF）：Page → /PieceInfo /Illustrator → /Private → /AIMetaData。
                //      辿れた AIMetaData obj 番号を保持し、バージョンスキャンでの再 traverse を省く。
                if let illusN  = pdfObjRef("Illustrator", in: pageStr),
                   let illusStr = pdfObjStr(num: illusN, offsets: xref.offsets,
                                            compressed: xref.compressed, fh: fh),
                   let privN   = pdfObjRef("Private", in: illusStr),
                   let privStr  = pdfObjStr(num: privN, offsets: xref.offsets,
                                            compressed: xref.compressed, fh: fh),
                   let metaN   = pdfObjRef("AIMetaData", in: privStr) {
                    fc.isIllustratorFile = true
                    fc.aiMetaDataObjNum = metaN
                    fc.isTemplate = isIllustratorTemplateFormat(fh: fh)
                    return "Ai"
                }
                // A-2.6. Photoshop編集機能保持PDF（Page → /PieceInfo /AdobePhotoshop）
                if pageStr.contains("/AdobePhotoshop") {
                    fc.isPhotoshopEditablePDF = true
                    return "PDF"
                }
                // Page 辞書を読めて Illustrator/Photoshop の痕跡なし → 確定でプレーンPDF（全走査しない）
                return "PDF"
            }
            // A-2.5. Page 辞書を構造的に読めなかった場合のみの前方探索フォールバック。
            //   巨大ページ辞書／壊れた参照など traverse が構造的に失敗しても、ファイル中に /AIMetaData が
            //   あれば通常の .ai と判定する。※ファイル全体を末尾まで読むため CD-R 等で遅い。高速モードでは
            //   省略し、直ちに通常PDF（A-3）とする（稀な特殊 .ai-PDF の取りこぼしは許容）。
            if !fastScan, fileContainsMarker(fh: fh, marker: "/AIMetaData") {
                fc.isIllustratorFile = true
                fc.isTemplate = isIllustratorTemplateFormat(fh: fh)
                return "Ai"
            }
            // A-3. それ以外 → 通常PDF
            return "PDF"
        }

        // C. PSD/PSB ネイティブ（8BPS マジック）。6バイトで判定でき安価なので、16KB を読む B より先に試す
        //    （PSD/PSB を B の PostScript 走査・無駄な16KB読みを経ずに即確定できる）。
        //    8BPS で始まる EPS／PS は存在しないため、B との順序入れ替えは判定結果に影響しない。
        if let fh = dataFH {
            try? fh.seek(toOffset: 0)
            let header = fh.readData(ofLength: 6)   // 署名4B + version2B
            if header.starts(with: Data("8BPS".utf8)) {
                // version（big-endian, byte 4-5）: 1=PSD / 2=PSB
                let version = header.count >= 6 ? (UInt16(header[4]) << 8 | UInt16(header[5])) : 1
                return version == 2 ? "PSB" : "PSD"
            }
        }

        // B. PostScript セクション
        if let ps = epsReadPSHeader(url: fc.url, length: 16384, sharedFH: dataFH) {
            let firstLine = ps.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            if firstLine.contains("%!PS-Adobe-") {
                let isIllustratorPS = ps.contains("%%AI8_CreatorVersion:")
                    || ps.contains("%%Creator: Adobe Illustrator")
                    || ps.contains("%%Creator: (Adobe Illustrator")
                if firstLine.contains("EPSF-") {
                    fc.isIllustratorFile = isIllustratorPS
                    return "EPS"
                }
                if isIllustratorPS {
                    // 旧形式.ai（純PostScript）
                    fc.isIllustratorFile = true
                    return "Ai"
                }
                // PS だが Illustrator/Photoshop でもない → 不明にフォールスルー
            }
        }

        // D. 不明
        return ""
    }

    /// ファイル先頭512バイトに "EPSF-" が含まれるか（EPS判定用）
    /// sharedFH を渡すと共有ハンドルを seek(0) して使い回す（新規 open を避ける）。
    private static func epsHeaderCheck(url: URL, sharedFH: FileHandle? = nil) -> Bool {
        let header: Data
        if let fh = sharedFH {
            try? fh.seek(toOffset: 0)
            header = fh.readData(ofLength: 512)
        } else {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
            header = fh.readData(ofLength: 512)
            try? fh.close()
        }
        return (String(data: header, encoding: .isoLatin1) ?? "").contains("EPSF-")
    }

    /// EPS ファイルの PS 部分先頭を文字列で返す共通ヘルパー
    /// バイナリ EPS（先頭 4 バイト = C5 D0 D3 C6）はオフセットを読んで PS 部分にシークする
    /// sharedFH を渡すと共有ハンドルを seek(0) して使い回す（新規 open を避ける）。
    private static func epsReadPSHeader(url: URL, length: Int, sharedFH: FileHandle? = nil) -> String? {
        let fh: FileHandle
        let ownsFH: Bool
        if let s = sharedFH {
            fh = s; ownsFH = false
            try? fh.seek(toOffset: 0)
        } else {
            guard let o = try? FileHandle(forReadingFrom: url) else { return nil }
            fh = o; ownsFH = true
        }
        defer { if ownsFH { try? fh.close() } }
        let magic = fh.readData(ofLength: 4)
        if magic == Data([0xC5, 0xD0, 0xD3, 0xC6]) {
            let offsetData = fh.readData(ofLength: 4)
            guard offsetData.count == 4 else { return nil }
            let psOffset = UInt64(offsetData[0])
                         | UInt64(offsetData[1]) << 8
                         | UInt64(offsetData[2]) << 16
                         | UInt64(offsetData[3]) << 24
            try? fh.seek(toOffset: psOffset)
        } else {
            try? fh.seek(toOffset: 0)
        }
        return String(data: fh.readData(ofLength: length), encoding: .isoLatin1)
    }

    /// EPS の PS ヘッダ（先頭16KB）から %%Creator 行の値を抽出する（生成元の表示用）。
    /// 例: `%%Creator: GPL Ghostscript 923 (eps2write)` → "GPL Ghostscript 923 (eps2write)"
    private static func epsCreatorLine(url: URL) -> String? {
        guard let ps = epsReadPSHeader(url: url, length: 16384),
              let regex = try? NSRegularExpression(pattern: #"%%Creator:[ \t]*(.+)"#) else { return nil }
        let range = NSRange(ps.startIndex..., in: ps)
        guard let m = regex.firstMatch(in: ps, range: range),
              let r = Range(m.range(at: 1), in: ps) else { return nil }
        var value = String(ps[r]).trimmingCharacters(in: .whitespaces)
        // PS 文字列形式 "(value)" の外側カッコを除去（内側カッコ eps2write 等は保持）。
        if value.hasPrefix("(") && value.hasSuffix(")") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// EPS ファイルが Illustrator 製かどうかを PS コメントで判定する
    /// %%Creator: は通常形式と PS 文字列形式（括弧付き）の両方に対応
    private static func epsIsIllustrator(url: URL) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384) else { return false }
        return ps.contains("%%AI8_CreatorVersion:")
            || ps.contains("%%Creator: Adobe Illustrator")
            || ps.contains("%%Creator: (Adobe Illustrator")
    }

    /// EPS ファイルが Photoshop 製かどうかを PS コメントで判定する
    private static func epsIsPhotoshop(url: URL, sharedFH: FileHandle? = nil) -> Bool {
        guard let ps = epsReadPSHeader(url: url, length: 16384, sharedFH: sharedFH) else { return false }
        return ps.contains("%%Creator: Adobe Photoshop")
    }

    /// Photoshop ファイルかどうかを判定する（コンテンツベース）
    private static func isPhotoshopFile(url: URL, kind: String, sharedFH: FileHandle? = nil) -> Bool {
        if kind == "PSD" || kind == "PSB" { return true }
        if kind == "EPS" { return epsIsPhotoshop(url: url, sharedFH: sharedFH) }
        return false
    }

    // MARK: - Photoshop バージョン取得（表示専用）

    /// PSD/PSB の cinf ブロックから psVersion（最終保存 Photoshop エンジン版・fix付き）を取得する。
    /// FileHandle のシークでセクション長を辿り、末尾の画素データ等は一切読まない（大容量でも高速）。
    /// ★長さフィールド幅は version ではなく **署名**で決まる（8BIM=4バイト / 8B64=8バイト）。
    private static func psVersionFromCinf(url: URL, sharedFH: FileHandle? = nil) -> String? {
        let fh: FileHandle
        let ownsFH: Bool
        if let s = sharedFH {
            fh = s; ownsFH = false
        } else {
            guard let o = try? FileHandle(forReadingFrom: url) else { return nil }
            fh = o; ownsFH = true
        }
        defer { if ownsFH { try? fh.close() } }

        func at(_ off: UInt64, _ n: Int) -> Data? {
            try? fh.seek(toOffset: off)
            let d = (try? fh.read(upToCount: n)) ?? nil
            return (d?.count == n) ? d : nil
        }
        func be(_ d: Data) -> UInt64 {
            var v: UInt64 = 0
            for b in d { v = (v << 8) | UInt64(b) }
            return v
        }

        guard let head = at(0, 6), head.prefix(4) == Data("8BPS".utf8) else { return nil }
        let isPSB = (be(head.suffix(2)) == 2)
        let lenW = isPSB ? 8 : 4

        var o: UInt64 = 26
        guard let cm = at(o, 4) else { return nil }    // Color Mode Data
        o += 4 + be(cm)
        guard let ir = at(o, 4) else { return nil }    // Image Resources
        o += 4 + be(ir)

        guard let lm = at(o, lenW) else { return nil } // Layer&Mask 長
        let lmLen = be(lm)
        o += UInt64(lenW)
        guard lmLen > 0 else { return nil }
        let lmEnd = o + lmLen

        guard let li = at(o, lenW) else { return nil } // Layer Info（画素データ含む→長さ分シーク）
        o += UInt64(lenW) + be(li)
        if o + 4 <= lmEnd, let gm = at(o, 4) {         // Global Layer Mask Info（長さは常に4B）
            o += 4 + be(gm)
        }

        let sig8BIM = Data("8BIM".utf8)
        let sig8B64 = Data("8B64".utf8)
        // 上限付きの read（要求 n に満たなくても得られた分を返す）。ブロックヘッダ一括読み用。
        func atUpTo(_ off: UInt64, _ n: Int) -> Data? {
            try? fh.seek(toOffset: off)
            return (try? fh.read(upToCount: n)) ?? nil
        }
        while o + 12 <= lmEnd {
            // ブロックヘッダ（署名4B＋キー4B＋長さ4/8B＝最大16B）を1回の read でまとめて取得し、
            // seek+read を 3→1 に削減する（連続オフセットなので1読みで足りる）。遅いメディア
            // （CD-R/ネットワーク）でのシーク往復削減が目的。旧コードの3分割 at() と判定はバイト同一：
            // count 不足は旧 at() の nil（＝return nil）と同義、署名不一致時の o+=1 リシンクも不変。
            guard let hdr = atUpTo(o, 16), hdr.count >= 4 else { return nil }
            let sigD = hdr.prefix(4)
            guard sigD == sig8BIM || sigD == sig8B64 else { o += 1; continue }
            let lenIs8 = (sigD == sig8B64)             // ★署名で長さ幅を判定
            let lw = lenIs8 ? 8 : 4
            guard hdr.count >= 8 + lw else { return nil }   // キー＋長さが未充足＝旧 at() の nil 相当
            let keyD = hdr.subdata(in: 4..<8)
            let key = String(decoding: keyD, as: UTF8.self)
            let lenD = hdr.subdata(in: 8..<(8 + lw))
            let blockLen = be(lenD)
            let dStart = o + 8 + UInt64(lw)
            if key == "cinf" {
                let cap = Int(min(blockLen, 65536))
                guard let cinf = at(dStart, cap) else { return nil }
                return parsePsVersionFromCinf(cinf)
            }
            o = dStart + blockLen + (blockLen & 1)      // データ長を偶数に切り上げ
        }
        return nil
    }

    /// cinf descriptor 内から psVersion(major.minor.fix) を抽出する。
    /// "psVersion" 文字列以降の major/minor/fix(long) を拾う（Vrsn=1.3.0 は psVersion より前に出るため取り違えない）。
    private static func parsePsVersionFromCinf(_ d: Data) -> String? {
        guard let r = d.range(of: Data("psVersion".utf8)) else { return nil }
        func longAfter(_ key: String) -> Int? {
            guard let kr = d.range(of: Data(key.utf8), in: r.upperBound..<d.endIndex) else { return nil }
            let valStart = kr.upperBound + 4          // key の直後 type(4B 'long') を飛ばす
            guard valStart + 4 <= d.endIndex else { return nil }
            var v: Int32 = 0
            for i in 0..<4 { v = (v << 8) | Int32(d[valStart + i]) }
            return Int(v)
        }
        guard let mj = longAfter("major"),
              let mn = longAfter("minor"),
              let fx = longAfter("fix") else { return nil }
        return "\(mj).\(mn).\(fx)"
    }

    /// Photoshop EPS の PS ヘッダ（既読の先頭16KB）から %%Creator のバージョンを抽出する（全体スキャン不要）。
    /// 例: `%%Creator: Adobe Photoshop Version 26.11.4 ...` → "26.11.4"
    private static func psVersionFromEPSCreator(url: URL, sharedFH: FileHandle? = nil) -> String? {
        guard let ps = epsReadPSHeader(url: url, length: 16384, sharedFH: sharedFH) else { return nil }
        let range = NSRange(ps.startIndex..., in: ps)
        guard let m = epsCreatorVersionRegex.firstMatch(in: ps, range: range),
              let r = Range(m.range(at: 1), in: ps) else { return nil }
        return String(ps[r])
    }

    /// Photoshop編集機能保持PDF の埋め込みデータから psVersion を取得する。
    /// Page → /PieceInfo /AdobePhotoshop << … /Private N 0 R >> → /StandardImageFileData（FlateDecode）→ cinf。
    /// /AdobePhotoshop はインライン辞書のため、その直後の /Private 参照を拾う。
    private static func psVersionFromPhotoshopPDF(root: Int, offsets: [Int: UInt64], fh: FileHandle) -> String? {
        guard let catStr   = pdfObjStr(num: root,    offsets: offsets, fh: fh),
              let pagesN   = pdfObjRef("Pages",      in: catStr),
              let pagesStr  = pdfObjStr(num: pagesN,  offsets: offsets, fh: fh),
              let pageN    = pdfFirstKid(in: pagesStr),
              let pageStr   = pdfObjStr(num: pageN,   offsets: offsets, fh: fh),
              let apr      = pageStr.range(of: "/AdobePhotoshop") else { return nil }
        let afterAP = String(pageStr[apr.upperBound...])
        guard let privN    = pdfObjRef("Private", in: afterAP),
              let privStr   = pdfObjStr(num: privN, offsets: offsets, fh: fh),
              let dataN    = pdfObjRef("StandardImageFileData", in: privStr),
              let inflated = readPDFObjStream(num: dataN, offsets: offsets, fh: fh) else { return nil }
        return parsePsVersionFromCinf(inflated)
    }

    // MARK: - PDF構造ファイル判定

    /// Illustrator編集機能保持PDF判定（.ai偽装検出用）
    /// 通常の .ai は /AIPrivateData、Illustrator編集機能保持PDFは /AIPDFPrivateData を持つ
    /// （%PDF- 判定は parse() が共有 FileHandle 上で済ませるため、旧 isPDFBased は廃止）
    private static func isAIPDFFormat(fh: FileHandle) -> Bool {
        try? fh.seek(toOffset: 0)
        let data = fh.readData(ofLength: 65536)
        return data.range(of: Data("/AIPDFPrivateData".utf8)) != nil
    }

    /// ファイル全体をチャンク読みして指定マーカーの有無を返す（前方探索フォールバック用）
    /// 全体を一度にメモリへ載せず、チャンク境界での取りこぼしを overlap で防ぐ。
    private static func fileContainsMarker(fh: FileHandle, marker: String) -> Bool {
        try? fh.seek(toOffset: 0)
        let needle = Data(marker.utf8)
        guard needle.count > 0 else { return false }
        let overlap = needle.count - 1
        let chunkSize = 1 << 20  // 1MB
        var carry = Data()
        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var buf = carry
            buf.append(chunk)
            if buf.range(of: needle) != nil { return true }
            // 末尾 overlap バイトを次回チャンクへ持ち越し、境界をまたぐマーカーを検出
            carry = buf.count > overlap ? buf.suffix(overlap) : buf
            if chunk.count < chunkSize { break }
        }
        return false
    }

    /// 本物のIllustratorテンプレート（.ait）判定
    /// 先頭2KBのdc:formatを文字列検索するだけ（XMLパースなし）
    /// 本物の.ait: dc:format = application/vnd.adobe.illustrator
    /// .aiを改名:  dc:format = application/pdf
    private static func isIllustratorTemplateFormat(fh: FileHandle) -> Bool {
        try? fh.seek(toOffset: 0)
        let data = fh.readData(ofLength: 2048)
        return data.range(of: Data("application/vnd.adobe.illustrator".utf8)) != nil
    }

    // MARK: - PDF AIMetaData スキャン
    //
    // Illustratorが保存したPDF構造ファイル（.ai/.pdf）には
    // AIMetaData オブジェクトに %%Creator / %%AI8_CreatorVersion が格納されている。
    //
    // ■ 高速パス（xref解析）
    //   PDF末尾の xref テーブルを読んで全オブジェクトのオフセットを把握し、
    //   Catalog → Pages → Page → PieceInfo/Illustrator → Private → AIMetaData
    //   のチェーンを最小限のシークで辿り、AIMetaData ストリームだけ読む。
    //   大きな XMP ブロブ等を読み飛ばせるため高速。
    //
    // ■ フォールバック（前方スキャン）
    //   xref 解析が失敗した場合（xref ストリーム形式など）は
    //   ファイル全体を Data で読み込んで /AIMetaData を前方検索する。

    // parse() で解析済みの xref を受け取ってバージョンスキャンを行う
    private static func scanVersionCommentsFromPDF(
        xref: (root: Int, offsets: [Int: UInt64]), url: URL, fh: FileHandle,
        fc: inout AiFileModel, fastScan: Bool
    ) {
        let streamData: Data
        if let d = aiMetaDataStream(xref: xref, fh: fh, cachedMetaNum: fc.aiMetaDataObjNum) {
            streamData = d
        } else if !fastScan, let d = aiMetaDataStreamForward(url: url) {
            // 高速モードでは前方フォールバックの全ファイル読み（Data(contentsOf:)）を行わない。
            // xref 経由で AIMetaData が取れなければバージョン空で確定する
            // （xref ストリーム形式の稀な .ai を取りこぼしうるが、§4「通常PDF誤判定は許容」と同方針）。
            streamData = d
        } else {
            return
        }

        // .eps 拡張子のファイルは kind を維持する（PDF構造の EPS ファイル対応）
        // kind="PDF"（.ai偽装PDF）も上書きしない
        if fc.kind != "EPS" && fc.kind != "PDF" { fc.kind = "Ai" }
        var t = Date()
        let lines = streamData.split(omittingEmptySubsequences: true) { $0 == 0x0D || $0 == 0x0A }
        for line in lines {
            processLineData(line, fc: &fc, t: &t, notDetectEPSCompatibleVer: false)
            if !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty {
                fc.hasCreator2 = false; return
            }
        }
    }

    // MARK: xref高速パス

    // 解析済み xref を使って AIMetaData ストリームを取得
    private static func aiMetaDataStream(
        xref: (root: Int, offsets: [Int: UInt64]), fh: FileHandle, cachedMetaNum: Int?
    ) -> Data? {
        // getFileKind で辿り済みなら再 traverse しない（A-2 経路）。未確定なら従来どおり辿る。
        guard let metaNum = cachedMetaNum
                ?? traverseToAIMetaDataObj(root: xref.root, offsets: xref.offsets, fh: fh)
        else { return nil }
        return readPDFObjStream(num: metaNum, offsets: xref.offsets, fh: fh)
    }

    /// xref（クラシック相互参照テーブル／PDF 1.5+ の相互参照ストリーム）を解析して、
    /// オブジェクト番号→ファイルオフセットの対応表（`offsets`：非圧縮オブジェクト）、
    /// オブジェクト番号→(ObjStm番号, 内部index)の対応表（`compressed`：オブジェクトストリーム内の圧縮オブジェクト）、
    /// および Root オブジェクト番号を返す。
    private static func parsePDFXref(fh: FileHandle)
        -> (root: Int, offsets: [Int: UInt64], compressed: [Int: (stm: Int, idx: Int)])? {
        // 末尾1KBから startxref の値を取得
        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else { return nil }
        try? fh.seek(toOffset: fileSize - min(1024, fileSize))
        guard let tail = String(data: fh.readData(ofLength: 1024), encoding: .isoLatin1) else { return nil }
        var xrefOff: UInt64?
        for line in tail.components(separatedBy: .newlines).reversed() {
            if let v = UInt64(line.trimmingCharacters(in: .whitespacesAndNewlines)) { xrefOff = v; break }
        }
        guard let startOff = xrefOff else { return nil }

        var offsets = [Int: UInt64]()
        var compressed = [Int: (stm: Int, idx: Int)]()
        var root: Int?
        var queue = [startOff]
        var seen  = Set<UInt64>()

        while !queue.isEmpty {
            let off = queue.removeFirst()
            guard !seen.contains(off) else { continue }
            seen.insert(off)

            // クラシック相互参照テーブル（"xref" 始まり）か相互参照ストリーム（"N G obj" 始まり）かを
            // 先頭16バイトで判別する。ストリーム形式をテーブルとして 32KB ずつ走査すると "trailer" が
            // 無くファイル全体を読んでしまうため、走査前に分岐する。
            try? fh.seek(toOffset: off)
            let peek = fh.readData(ofLength: 16)
            let isClassicTable = (String(data: peek, encoding: .isoLatin1)?
                .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("xref")) ?? false

            if isClassicTable {
                // xref テーブルが 32KB を超える大容量ファイルに対応するため、
                // "trailer" が見つかるまで 32KB ずつ読み足す
                try? fh.seek(toOffset: off)
                var xrefRaw = Data()
                let xrefChunk = 32768
                var trailerFound = false
                while !trailerFound {
                    let chunk = fh.readData(ofLength: xrefChunk)
                    if chunk.isEmpty { break }
                    xrefRaw.append(chunk)
                    if xrefRaw.range(of: Data("trailer".utf8)) != nil { trailerFound = true }
                    if chunk.count < xrefChunk { break }
                }
                guard let s = String(data: xrefRaw, encoding: .isoLatin1),
                      s.hasPrefix("xref") else { continue }

                // セクション解析: 行イテレータを使って "startObj count" → エントリ群 を処理
                // \r\n を先に \n に正規化してから分割する（\r と \n を個別に分割すると
                // \r\n 行末のエントリが空文字列を挟んでしまいオブジェクトIDがずれるため）
                let sNorm = s.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
                var iter = sNorm.components(separatedBy: "\n").makeIterator()
                _ = iter.next()  // "xref" 行をスキップ
                outer: while let line = iter.next() {
                    let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if l.hasPrefix("trailer") { break }
                    let parts = l.split(separator: " ")
                    guard parts.count == 2,
                          let secStart = Int(parts[0]), let secCount = Int(parts[1]) else { continue }
                    var objID = secStart
                    for _ in 0..<secCount {
                        guard let entry = iter.next() else { break outer }
                        let ep = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                        if ep.count >= 3, ep[2] == "n", let fileOff = UInt64(ep[0]) {
                            if offsets[objID] == nil { offsets[objID] = fileOff }
                        }
                        objID += 1
                    }
                }

                // trailer から Root / Prev（インクリメンタル更新・線形化）／XRefStm（ハイブリッド参照）を取得
                if let tRange = s.range(of: "trailer") {
                    let ts = String(s[tRange.upperBound...])
                    if root == nil { root = pdfObjRef("Root", in: ts) }
                    if let prev  = pdfIntVal("Prev",    in: ts) { queue.append(UInt64(prev)) }
                    if let xstm  = pdfIntVal("XRefStm", in: ts) { queue.append(UInt64(xstm)) }
                }
            } else {
                // PDF 1.5+ の相互参照ストリーム
                parseXrefStreamSection(fh: fh, offset: off,
                                       offsets: &offsets, compressed: &compressed,
                                       root: &root, queue: &queue)
            }
        }

        guard let r = root else { return nil }
        return (r, offsets, compressed)
    }

    /// 相互参照ストリーム（PDF 1.5+ の圧縮 xref。`/Type /XRef`）を解析し、
    /// type 1（非圧縮オブジェクト）のファイルオフセットを `offsets`、
    /// type 2（オブジェクトストリーム内の圧縮オブジェクト）の所在 (ObjStm番号, 内部index) を `compressed` に加え、
    /// 未確定なら `root` を、`/Prev` があれば `queue` を更新する。
    private static func parseXrefStreamSection(
        fh: FileHandle, offset: UInt64,
        offsets: inout [Int: UInt64], compressed: inout [Int: (stm: Int, idx: Int)],
        root: inout Int?, queue: inout [UInt64]
    ) {
        // 辞書部 + "stream" マーカーまでを読む（xref ストリームの辞書は小さい）
        try? fh.seek(toOffset: offset)
        let streamKey = Data("stream".utf8)
        var head = Data()
        while head.range(of: streamKey) == nil && head.count < 65536 {
            let part = fh.readData(ofLength: 8192)
            if part.isEmpty { break }
            head.append(part)
        }
        guard let skr = head.range(of: streamKey),
              let dict = String(data: head[head.startIndex..<skr.lowerBound], encoding: .isoLatin1)
        else { return }

        // 必須項目: /W [w1 w2 w3]
        guard let w = pdfIntArray("W", in: dict), w.count >= 3, w[0] >= 0, w[1] >= 0, w[2] >= 0 else { return }
        let (w1, w2, w3) = (w[0], w[1], w[2])
        let rowLen = w1 + w2 + w3
        guard rowLen > 0 else { return }

        // /Index 無しなら [0 Size]
        let size = pdfIntVal("Size", in: dict) ?? 0
        let index = pdfIntArray("Index", in: dict) ?? [0, size]
        guard index.count >= 2 else { return }

        if root == nil { root = pdfObjRef("Root", in: dict) }
        if let prev = pdfIntVal("Prev", in: dict) { queue.append(UInt64(prev)) }

        // stream 本体（xref ストリームの /Length は直接整数）
        guard let length = pdfIntVal("Length", in: dict), length > 0 else { return }
        var bodyStart = skr.upperBound
        if bodyStart < head.endIndex && head[bodyStart] == 0x0D { bodyStart = head.index(after: bodyStart) }
        if bodyStart < head.endIndex && head[bodyStart] == 0x0A { bodyStart = head.index(after: bodyStart) }
        let bodyFileOffset = offset + UInt64(bodyStart - head.startIndex)
        try? fh.seek(toOffset: bodyFileOffset)
        let rawStream = fh.readData(ofLength: length)
        guard rawStream.count == length else { return }

        let hasFilter = dict.contains("/FlateDecode")
        guard var decoded = hasFilter ? zlibInflate(rawStream) : rawStream else { return }

        // PNG プレディクタ（Predictor >= 10）。Columns = 1行のバイト数（= w1+w2+w3）
        let predictor = pdfIntVal("Predictor", in: dict) ?? 1
        if predictor >= 10 {
            let columns = pdfIntVal("Columns", in: dict) ?? rowLen
            guard let unfiltered = applyPNGPredictor(decoded, columns: columns) else { return }
            decoded = unfiltered
        }
        guard decoded.count >= rowLen else { return }

        // 行を /Index の (開始オブジェクト番号, 個数) ペアに従って割り当てる
        let bytes = [UInt8](decoded)
        func be(_ start: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v = (v << 8) | UInt64(bytes[start + i]) }
            return v
        }
        let totalRows = bytes.count / rowLen
        var rowNo = 0
        var p = 0
        while p + 1 < index.count {
            let startObj = index[p]
            let count = index[p + 1]
            p += 2
            for k in 0..<count {
                if rowNo >= totalRows { return }
                let base = rowNo * rowLen
                let type = (w1 == 0) ? 1 : be(base, w1)   // w1==0 のときの既定 type は 1
                let objNum = startObj + k
                if type == 1 {
                    if offsets[objNum] == nil { offsets[objNum] = be(base + w1, w2) }
                } else if type == 2 {
                    // type 2: field2 = 収容している ObjStm のオブジェクト番号, field3 = その中の index
                    if offsets[objNum] == nil && compressed[objNum] == nil {
                        compressed[objNum] = (stm: Int(be(base + w1, w2)), idx: Int(be(base + w1 + w2, w3)))
                    }
                }
                rowNo += 1
            }
        }
    }

    /// PDF プレディクタ（PNG, Predictor 10〜15）を解除して各行 `columns` バイトの素データを返す。
    /// 入力は「1バイトのフィルタタイプ + columns バイト」を1行とする。
    /// xref ストリームは Colors=1 / BitsPerComponent=8 のため bytes-per-pixel = 1。
    private static func applyPNGPredictor(_ data: Data, columns: Int) -> Data? {
        guard columns > 0 else { return nil }
        let bpp = 1
        let rowLen = columns + 1
        let src = [UInt8](data)
        guard src.count >= rowLen else { return nil }

        var prev = [UInt8](repeating: 0, count: columns)
        var out = [UInt8]()
        out.reserveCapacity((src.count / rowLen) * columns)

        var i = 0
        while i + rowLen <= src.count {
            let filter = src[i]
            var cur = Array(src[(i + 1)..<(i + rowLen)])
            switch filter {
            case 0: break                                   // None
            case 1:                                          // Sub
                for k in bpp..<columns { cur[k] = cur[k] &+ cur[k - bpp] }
            case 2:                                          // Up
                for k in 0..<columns { cur[k] = cur[k] &+ prev[k] }
            case 3:                                          // Average
                for k in 0..<columns {
                    let left = k >= bpp ? Int(cur[k - bpp]) : 0
                    cur[k] = cur[k] &+ UInt8((left + Int(prev[k])) / 2)
                }
            case 4:                                          // Paeth
                for k in 0..<columns {
                    let a = k >= bpp ? Int(cur[k - bpp]) : 0
                    let b = Int(prev[k])
                    let c = k >= bpp ? Int(prev[k - bpp]) : 0
                    let pp = a + b - c
                    let pa = abs(pp - a), pb = abs(pp - b), pc = abs(pp - c)
                    let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    cur[k] = cur[k] &+ UInt8(pred & 0xff)
                }
            default: return nil
            }
            out.append(contentsOf: cur)
            prev = cur
            i += rowLen
        }
        return Data(out)
    }

    /// `/Key [ n1 n2 … ]`（W や Index）の整数配列を返す。キーは直後が非英数字のもののみ一致させる。
    private static func pdfIntArray(_ key: String, in s: String) -> [Int]? {
        let token = "/" + key
        var searchStart = s.startIndex
        while let kr = s.range(of: token, range: searchStart..<s.endIndex) {
            // キー名の直後が英数字なら別キーの前方一致（例 /W が /Width に当たる）なので次を探す
            let nextOK = kr.upperBound == s.endIndex || !(s[kr.upperBound].isLetter || s[kr.upperBound].isNumber)
            if nextOK {
                let after = s[kr.upperBound...]
                guard let lb = after.firstIndex(of: "["),
                      let rb = after[after.index(after: lb)...].firstIndex(of: "]") else { return nil }
                let inner = after[after.index(after: lb)..<rb]
                let nums = inner.split { !($0.isNumber) }.compactMap { Int($0) }
                return nums.isEmpty ? nil : nums
            }
            searchStart = kr.upperBound
        }
        return nil
    }

    /// Catalog → Pages → Page[0] → PieceInfo/Illustrator → Private → AIMetaData の順に辿り
    /// AIMetaData オブジェクト番号を返す
    private static func traverseToAIMetaDataObj(root: Int, offsets: [Int: UInt64], fh: FileHandle) -> Int? {
        guard let catStr  = pdfObjStr(num: root,     offsets: offsets, fh: fh),
              let pagesN  = pdfObjRef("Pages",        in: catStr),
              let pagesStr = pdfObjStr(num: pagesN,   offsets: offsets, fh: fh),
              let pageN   = pdfFirstKid(in: pagesStr),
              let pageStr  = pdfObjStr(num: pageN,    offsets: offsets, fh: fh),
              let illusN  = pdfObjRef("Illustrator",  in: pageStr),
              let illusStr = pdfObjStr(num: illusN,   offsets: offsets, fh: fh),
              let privN   = pdfObjRef("Private",      in: illusStr),
              let privStr  = pdfObjStr(num: privN,    offsets: offsets, fh: fh),
              let metaN   = pdfObjRef("AIMetaData",   in: privStr) else { return nil }
        return metaN
    }

    /// Catalog → Pages → Page[0] の辞書を解決して返す（オブジェクトを構造的に読めなければ nil）。
    /// 読めた場合はその場で `/Illustrator`・`/AdobePhotoshop` の有無を判定でき、無ければ確定でプレーンPDF。
    /// → プレーンPDFのたびに全ファイル走査（fileContainsMarker）する必要がなくなる。
    /// `compressed`（ObjStm 内の圧縮オブジェクト）も辿るため、相互参照ストリーム形式のPDFでも解決できる。
    private static func firstPageDict(root: Int, offsets: [Int: UInt64],
                                      compressed: [Int: (stm: Int, idx: Int)], fh: FileHandle) -> String? {
        guard let catStr  = pdfObjStr(num: root,   offsets: offsets, compressed: compressed, fh: fh),
              let pagesN  = pdfObjRef("Pages",      in: catStr),
              let pagesStr = pdfObjStr(num: pagesN, offsets: offsets, compressed: compressed, fh: fh),
              let pageN   = pdfFirstKid(in: pagesStr),
              let pageStr  = pdfObjStr(num: pageN,  offsets: offsets, compressed: compressed, fh: fh)
        else { return nil }
        return pageStr
    }

    /// オブジェクト N の辞書部を文字列で返す。
    ///
    /// 既定は 4KB 読み（小さな辞書はこれで完結）。ただし巨大な Page 辞書（大量の Resources 参照を
    /// 持ち、末尾に `/PieceInfo<</Illustrator …>>` が来る .ai）では 4KB 窓に /PieceInfo が収まらず
    /// xref 辿りが失敗していた。最初の 4KB に `endobj` が無ければ巨大辞書とみなし、`endobj` に達するまで
    /// （上限 maxBytes まで）追加読みして辞書全体を確実に含める。
    /// 対象（Catalog/Pages/Page/Illustrator/Private）はいずれもストリームを持たない純辞書のため、
    /// `endobj` までで辞書全体が入る。
    ///
    /// `offsets` に無い番号は `compressed`（ObjStm 内の圧縮オブジェクト）から解決する。
    /// 相互参照ストリーム形式のPDFでは Catalog/Pages/Page が ObjStm に入ることが多いため、
    /// これにより構造 traverse が成立し、全ファイル走査フォールバックを避けられる。
    private static func pdfObjStr(num: Int, offsets: [Int: UInt64],
                                  compressed: [Int: (stm: Int, idx: Int)] = [:], fh: FileHandle,
                                  maxBytes: Int = 256 * 1024) -> String? {
        if let offset = offsets[num] {
            try? fh.seek(toOffset: offset)
            let endMarker = Data("endobj".utf8)
            var data = fh.readData(ofLength: 4096)
            while data.range(of: endMarker) == nil && data.count < maxBytes {
                let part = fh.readData(ofLength: 8192)
                if part.isEmpty { break }
                data.append(part)
            }
            guard let s = String(data: data, encoding: .isoLatin1),
                  s.hasPrefix("\(num) 0 obj") else { return nil }
            return s
        }
        // 非圧縮テーブルに無い → オブジェクトストリーム（ObjStm）内の圧縮オブジェクトを解決
        if let loc = compressed[num] {
            return objStrFromObjStm(stmNum: loc.stm, index: loc.idx, offsets: offsets, fh: fh)
        }
        return nil
    }

    /// オブジェクトストリーム（`/Type /ObjStm`）内の index 番目のオブジェクト本体（辞書文字列）を返す。
    /// ObjStm 自体は非圧縮（`offsets` にオフセットあり）。内部は「N 組の『objNum 相対オフセット』ヘッダ
    /// ＋ `/First` 以降に各オブジェクト本体を連結」した構造（PDF 7.5.7）。返す文字列は "N 0 obj" 接頭辞を
    /// 持たないが、呼び出し側（pdfObjRef / pdfFirstKid / contains）は辞書内をパターン検索するだけなので問題ない。
    private static func objStrFromObjStm(stmNum: Int, index: Int,
                                         offsets: [Int: UInt64], fh: FileHandle) -> String? {
        guard index >= 0, let offset = offsets[stmNum] else { return nil }
        try? fh.seek(toOffset: offset)
        let header = fh.readData(ofLength: 8192)
        guard let dictEnd = header.range(of: Data("stream".utf8))?.lowerBound,
              let dict = String(data: header[header.startIndex..<dictEnd], encoding: .isoLatin1),
              dict.contains("/ObjStm"),
              let first = pdfIntVal("First", in: dict),
              let inflated = readPDFObjStream(num: stmNum, offsets: offsets, fh: fh) else { return nil }
        let bytes = [UInt8](inflated)
        guard first > 0, first <= bytes.count else { return nil }
        // ヘッダ（先頭 first バイト）: 空白区切りの整数列 objNum0 off0 objNum1 off1 …
        let headerNums = String(decoding: bytes[0..<first], as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .compactMap { Int($0) }
        let offPos = index * 2 + 1
        guard offPos < headerNums.count else { return nil }
        let startRel = headerNums[offPos]
        let endRel   = (offPos + 2 < headerNums.count) ? headerNums[offPos + 2] : (bytes.count - first)
        let start = first + startRel
        let end   = min(first + endRel, bytes.count)
        guard startRel >= 0, start <= end, end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// オブジェクト N のストリームデータを返す（/Filter があれば zlib 展開）
    private static func readPDFObjStream(num: Int, offsets: [Int: UInt64], fh: FileHandle) -> Data? {
        guard let offset = offsets[num] else { return nil }
        try? fh.seek(toOffset: offset)
        let headerData = fh.readData(ofLength: 8192)

        // /Length 取得
        let lenKey = Data("/Length ".utf8)
        guard let lkr = headerData.range(of: lenKey) else { return nil }
        let afterLen = headerData[lkr.upperBound...]
        var lenEnd = afterLen.startIndex
        while lenEnd < afterLen.endIndex
            && afterLen[lenEnd] >= UInt8(ascii: "0")
            && afterLen[lenEnd] <= UInt8(ascii: "9") { lenEnd += 1 }
        guard let lenStr = String(data: afterLen[..<lenEnd], encoding: .ascii),
              let streamLen = Int(lenStr), streamLen > 0 else { return nil }

        // "stream" マーカーの直後をストリーム本体の先頭とする
        let streamKey = Data("stream".utf8)
        guard let skr = headerData.range(of: streamKey) else { return nil }
        var bodyIdx = skr.upperBound
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0D { bodyIdx += 1 }
        if bodyIdx < headerData.endIndex && headerData[bodyIdx] == 0x0A { bodyIdx += 1 }

        let hasFilter = headerData[headerData.startIndex..<skr.lowerBound]
            .range(of: Data("/Filter".utf8)) != nil

        // ストリーム本体をファイルから直接シークして読む
        let bodyFileOffset = offset + UInt64(bodyIdx - headerData.startIndex)
        try? fh.seek(toOffset: bodyFileOffset)
        let raw = fh.readData(ofLength: streamLen)
        guard raw.count == streamLen else { return nil }

        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: PDF パースヘルパー

    /// "/Key N 0 R" の N を返す
    private static func pdfObjRef(_ key: String, in s: String) -> Int? {
        let re: NSRegularExpression
        if let cached = objRefRegexes[key] {
            re = cached
        } else if let compiled = try? NSRegularExpression(
            pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)\s+0\s+R"#) {
            re = compiled
        } else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    /// "/Kids [ N 0 R ..." の最初の N を返す
    private static func pdfFirstKid(in s: String) -> Int? {
        guard let m = kidsRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    /// "/Key N" の整数値 N を返す（Prev など）
    private static func pdfIntVal(_ key: String, in s: String) -> Int? {
        let re: NSRegularExpression
        if let cached = intValRegexes[key] {
            re = cached
        } else if let compiled = try? NSRegularExpression(
            pattern: "/" + NSRegularExpression.escapedPattern(for: key) + #"\s+(\d+)"#) {
            re = compiled
        } else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    // MARK: フォールバック（前方スキャン）

    /// xref 解析が失敗した場合: ファイル全体から /AIMetaData を前方検索してストリームを返す
    private static func aiMetaDataStreamForward(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let aiMetaKey = Data("/AIMetaData ".utf8)
        guard let keyRange = data.range(of: aiMetaKey) else { return nil }
        let after = data[keyRange.upperBound...]
        guard let spaceIdx = after.firstIndex(where: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ">") }) else { return nil }
        guard let numStr = String(data: after[after.startIndex..<spaceIdx], encoding: .ascii),
              let objNum = Int(numStr) else { return nil }

        let objMarker = Data("\(objNum) 0 obj".utf8)
        guard let objRange = data.range(of: objMarker) else { return nil }
        let objHead = data[objRange.upperBound...]

        guard let lkr = objHead.range(of: Data("/Length ".utf8)) else { return nil }
        let la = objHead[lkr.upperBound...]
        guard let le = la.firstIndex(where: { $0 < UInt8(ascii: "0") || $0 > UInt8(ascii: "9") }),
              let lenStr = String(data: la[..<le], encoding: .ascii),
              let streamLen = Int(lenStr) else { return nil }

        guard let skr = objHead.range(of: Data("stream".utf8)) else { return nil }
        var ss = skr.upperBound
        if ss < objHead.endIndex && objHead[ss] == 0x0D { ss += 1 }
        if ss < objHead.endIndex && objHead[ss] == 0x0A { ss += 1 }
        guard ss + streamLen <= objHead.endIndex else { return nil }
        let raw = Data(objHead[ss..<(ss + streamLen)])

        let hasFilter = objHead[..<skr.lowerBound].range(of: Data("/Filter".utf8)) != nil
        return hasFilter ? zlibInflate(raw) : raw
    }

    // MARK: zlib展開

    // zlib (RFC 1950) の展開
    private static func zlibInflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        var result = Data()
        var stream = z_stream()
        var ret = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)
        data.withUnsafeBytes { src in
            stream.next_in  = UnsafeMutablePointer(mutating: src.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            repeat {
                buf.withUnsafeMutableBytes { dst in
                    stream.next_out  = dst.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(bufSize)
                }
                ret = inflate(&stream, Z_NO_FLUSH)
                let produced = bufSize - Int(stream.avail_out)
                if produced > 0 { result.append(contentsOf: buf[0..<produced]) }
            } while ret == Z_OK
        }
        return (ret == Z_STREAM_END || ret == Z_OK) ? result : nil
    }

    // MARK: - バージョンコメントスキャン（高速版 v2：FileHandle + seek）
    //
    // FileHandle で 256KB ずつ読み、行を処理。
    // %%BeginData: N が見つかったら seek で N バイト丸ごとスキップ。
    // 初回ディスク読み込み時も大きな埋め込みデータを実際に読まずに飛ばせる。

    private static let chunkSize = 256 * 1024

    // マーカーバイト列（定数）
    private static let markerCreator:    [UInt8] = Array("%%Creator: ".utf8)
    private static let markerAI8:        [UInt8] = Array("%%AI8_CreatorVersion: ".utf8)
    private static let markerBeginData:  [UInt8] = Array("%%BeginData:".utf8)
    private static let markerEndData:    [UInt8] = Array("%%EndData".utf8)

    private static func scanVersionComments(url: URL, fc: inout AiFileModel,
                                            timeLimit: Double, notDetectEPSCompatibleVer: Bool,
                                            startTotal: Date, sharedFH: FileHandle? = nil) {
        let fh: FileHandle
        let ownsFH: Bool
        if let s = sharedFH {
            fh = s; ownsFH = false
            try? fh.seek(toOffset: 0)
        } else {
            guard let o = try? FileHandle(forReadingFrom: url) else { return }
            fh = o; ownsFH = true
        }
        defer { if ownsFH { try? fh.close() } }

        // pending: 読み込み済みだがまだ処理していないバイト列
        // pendingFileStart: pending の先頭バイトがファイル内で何バイト目か
        var pending = Data()
        var pendingFileStart: UInt64 = 0
        var totalRead: UInt64 = 0
        var t = Date()

        mainLoop: while true {
            // タイムアウトチェック
            if Date().timeIntervalSince(startTotal) > timeLimit {
                fc.isTimeOut = true; break
            }

            // EPS で必要情報がそろったら終了
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty
                && notDetectEPSCompatibleVer { break }

            // pending が空なら次のチャンクを読む
            if pending.isEmpty {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                pending = chunk
                pendingFileStart = totalRead
                totalRead += UInt64(chunk.count)
            }

            // pending から1行分を取り出す
            guard let nlRel = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
                // 改行が見つからない → チャンクを追加して再試行
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    // ファイル末尾：残りを1行として処理
                    processLinePending(&pending, fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)
                    break
                }
                pending.append(chunk)
                totalRead += UInt64(chunk.count)

                // 巨大な1行（バイナリ混入）なら捨てて次へ
                if pending.count > 4 * 1024 * 1024 {
                    pending.removeAll()
                    pendingFileStart = totalRead
                }
                continue
            }

            let lineEnd = nlRel  // pending 内での改行位置
            let lineLen = lineEnd - pending.startIndex

            // 改行をスキップした次の位置を計算
            var afterNl = pending.index(after: lineEnd)
            if pending[lineEnd] == 0x0D, afterNl < pending.endIndex, pending[afterNl] == 0x0A {
                afterNl = pending.index(after: afterNl)
            }
            // afterNl のファイル内オフセット
            let afterNlFileOffset = pendingFileStart + UInt64(afterNl - pending.startIndex)

            // %% で始まらない行は高速スキップ
            if lineLen < 2 || pending[pending.startIndex] != UInt8(ascii: "%")
                            || pending[pending.index(after: pending.startIndex)] != UInt8(ascii: "%") {
                pending = pending[afterNl...]
                pendingFileStart = afterNlFileOffset
                continue
            }

            // %%BeginData: ByteCount … → seek でスキップ
            if matchesPending(&pending, marker: markerBeginData, lineLen: lineLen) {
                let skipBytes = parseBeginDataByteCount(&pending, markerLen: markerBeginData.count, lineEnd: lineEnd)
                if skipBytes > 0 {
                    let seekTo = afterNlFileOffset + UInt64(skipBytes)
                    try? fh.seek(toOffset: seekTo)
                    totalRead = seekTo
                    pending.removeAll()
                    pendingFileStart = seekTo
                    // %%EndData 行を1チャンク読んで消費
                    let endChunk = fh.readData(ofLength: min(chunkSize, 4096))
                    if !endChunk.isEmpty {
                        totalRead += UInt64(endChunk.count)
                        pending = endChunk
                        // %%EndData を含む行まで読み飛ばす
                        if let edNl = findMarkerLine(in: pending, marker: markerEndData) {
                            var nextLine = pending.index(after: edNl)
                            if pending[edNl] == 0x0D, nextLine < pending.endIndex, pending[nextLine] == 0x0A {
                                nextLine = pending.index(after: nextLine)
                            }
                            pendingFileStart = seekTo + UInt64(nextLine - pending.startIndex)
                            pending = pending[nextLine...]
                        } else {
                            pendingFileStart = totalRead
                            pending.removeAll()
                        }
                    }
                    continue
                }
            }

            // 行を解析
            let lineSlice = pending[..<lineEnd]
            processLineData(lineSlice, fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)

            // Ai: 両方そろったら終了
            if fc.kind == "Ai" && !fc.creator1.isEmpty && !fc.ai8CreatorVersion.isEmpty {
                fc.hasCreator2 = false; break mainLoop
            }
            // EPS: creator2 取得済み or hasCreator2=false で終了
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.creator2.isEmpty { break mainLoop }
            if fc.kind == "EPS" && !fc.creator1.isEmpty && !fc.hasCreator2 { break mainLoop }

            pending = pending[afterNl...]
            pendingFileStart = afterNlFileOffset
        }
    }

    // pending の先頭が marker と一致するか
    private static func matchesPending(_ pending: inout Data, marker: [UInt8], lineLen: Int) -> Bool {
        guard lineLen >= marker.count else { return false }
        for (i, b) in marker.enumerated() {
            if pending[pending.startIndex + i] != b { return false }
        }
        return true
    }

    // %%BeginData: の後の最初の整数（バイト数）を取得
    private static func parseBeginDataByteCount(_ pending: inout Data, markerLen: Int, lineEnd: Data.Index) -> Int {
        var i = pending.startIndex + markerLen
        while i < lineEnd && pending[i] == UInt8(ascii: " ") { i += 1 }
        var n = 0
        var found = false
        while i < lineEnd {
            let b = pending[i]
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                n = n * 10 + Int(b - UInt8(ascii: "0"))
                found = true
            } else { break }
            i += 1
        }
        return found ? n : 0
    }

    // Data 内で marker で始まる改行位置を返す（%%EndData 消費用）
    private static func findMarkerLine(in data: Data, marker: [UInt8]) -> Data.Index? {
        var i = data.startIndex
        while i < data.endIndex {
            // 行頭チェック
            if i + marker.count <= data.endIndex {
                var match = true
                for (k, b) in marker.enumerated() {
                    if data[i + k] != b { match = false; break }
                }
                if match {
                    // 行末を探して返す
                    var j = i
                    while j < data.endIndex && data[j] != 0x0A && data[j] != 0x0D { j += 1 }
                    return j < data.endIndex ? j : nil
                }
            }
            // 次の行へ
            while i < data.endIndex && data[i] != 0x0A && data[i] != 0x0D { i += 1 }
            if i < data.endIndex {
                let nl = i
                i = data.index(after: nl)
                if data[nl] == 0x0D, i < data.endIndex, data[i] == 0x0A { i = data.index(after: i) }
            }
        }
        return nil
    }

    // Data スライスを解析してフィールドに格納
    private static func processLineData(_ lineSlice: Data.SubSequence, fc: inout AiFileModel,
                                        t: inout Date, notDetectEPSCompatibleVer: Bool) {
        let lineLen = lineSlice.count
        guard lineLen > 2 else { return }

        // %%Creator:
        if fc.creator1.isEmpty && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator1 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.timeCreator1 = Date().timeIntervalSince(t); t = Date()

        // %%AI8_CreatorVersion:
        } else if fc.ai8CreatorVersion.isEmpty && lineLen > markerAI8.count
            && lineSlice.starts(with: markerAI8) {
            fc.ai8CreatorVersion = extractString(from: lineSlice, offset: markerAI8.count)
            fc.timeAI8CreatorVersion = Date().timeIntervalSince(t); t = Date()

            if fc.kind == "EPS" && !fc.creator1.isEmpty {
                if let ver = illustratorMajorVersion(from: fc.creator1), ver < 9 {
                    fc.hasCreator2 = false
                }
            }

        // EPS: 2回目の %%Creator:（互換バージョン）
        } else if fc.kind == "EPS" && !fc.creator1.isEmpty && fc.creator2.isEmpty
            && lineLen > markerCreator.count
            && lineSlice.starts(with: markerCreator) {
            fc.creator2 = extractString(from: lineSlice, offset: markerCreator.count)
            fc.timeCreator2 = Date().timeIntervalSince(t)
            fc.hasCreator2 = true
        }
    }

    // pending 全体を1行として処理（ファイル末尾用）
    private static func processLinePending(_ pending: inout Data, fc: inout AiFileModel,
                                           t: inout Date, notDetectEPSCompatibleVer: Bool) {
        processLineData(pending[...], fc: &fc, t: &t, notDetectEPSCompatibleVer: notDetectEPSCompatibleVer)
    }

    // Data スライスから文字列を取得（UTF-8 → Latin-1 フォールバック）
    // PostScript 文字列形式 "(value)" の外側カッコも除去する
    private static func extractString(from slice: Data.SubSequence, offset: Int) -> String {
        let sub = slice.dropFirst(offset)
        var s = String(data: sub, encoding: .utf8) ?? String(data: sub, encoding: .isoLatin1) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        // PS 文字列形式: 先頭 "(" 末尾 ")" を除去
        if s.hasPrefix("(") && s.hasSuffix(")") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func illustratorMajorVersion(from creator1: String) -> Int? {
        guard let match = illustratorMajorRegex.firstMatch(
                in: creator1, range: NSRange(creator1.startIndex..., in: creator1)),
              let range = Range(match.range(at: 1), in: creator1) else { return nil }
        return Int(String(creator1[range]).components(separatedBy: ".").first ?? "")
    }

    // MARK: - バージョン判定

    private static func determineVersion(fc: inout AiFileModel) {
        // AI8 以前の旧フォーマット（AI8_CreatorVersion 無し・互換 Creator 無し）
        // 例: Illustrator 5.5J など。creator1 に "Adobe Illustrator(TM) 5.5J 95.01.01"
        // のような文字列が入っており、末尾は日付サフィックスのため versionNumberSuffix では拾えない。
        // この場合は creator1 の Illustrator 直後のバージョントークンを「作成」、互換は空欄とする。
        let isLegacyFormat = fc.ai8CreatorVersion.isEmpty && fc.creator2.isEmpty
            && (fc.kind == "Ai" || fc.kind == "EPS")

        fc.determineCreated = fc.ai8CreatorVersion

        if fc.isIllustratorFile {
            if isLegacyFormat {
                fc.determineCreated = extractLegacyCreatorVersion(fc.creator1)
                fc.determineSaved = ""
            } else if fc.kind == "EPS" {
                fc.determineSaved = fc.hasCreator2
                    ? versionNumberSuffix(fc.creator2)
                    : versionNumberSuffix(fc.creator1)
            } else {
                fc.determineSaved = versionNumberSuffix(fc.creator1)
            }
        }

        let created = Int(fc.determineCreated.components(separatedBy: ".").first ?? "") ?? 0
        let saved   = Int(fc.determineSaved.components(separatedBy:  ".").first ?? "") ?? 0

        if (17...23).contains(created) && saved == 17 {
            fc.isSavedLowerVersion = false
        } else if created >= 24 && saved == 24 {
            fc.isSavedLowerVersion = false
        } else if created > 0 && saved > 0 {
            fc.isSavedLowerVersion = (created != saved)
        }
    }

    private static func versionNumberSuffix(_ s: String) -> String {
        guard let match = versionSuffixRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return "" }
        return String(s[range])
    }

    // creator1 から Illustrator 直後の最初のバージョントークンを抽出する（旧フォーマット用）
    // 例: "Adobe Illustrator(TM) 5.5J 95.01.01" → "5.5J"
    //     "Adobe Illustrator(TM) 7.0"          → "7.0"
    // 末尾の日付サフィックス（95.01.01 など）は対象外。
    private static func extractLegacyCreatorVersion(_ creator1: String) -> String {
        guard let match = legacyCreatorRegex.firstMatch(
                in: creator1, range: NSRange(creator1.startIndex..., in: creator1)),
              let range = Range(match.range(at: 1), in: creator1) else { return "" }
        return String(creator1[range])
    }

    // MARK: - バージョン名変換

    static func versionName(_ ver: String) -> String {
        let parts = ver.components(separatedBy: ".")
        guard let major = Int(parts.first ?? "") else { return ver }
        // minor 部に locale サフィックス（例: "5J"）が付いている場合は数値部と接尾辞を分離する
        let (minor, minorSuffix): (Int, String) = {
            guard parts.count > 1 else { return (0, "") }
            let raw = parts[1]
            let digits = raw.prefix(while: { $0.isNumber })
            let suffix = raw[digits.endIndex...]
            return (Int(digits) ?? 0, String(suffix))
        }()

        switch major {
        case 1...4:  return parts[0]
        case 5:      return minorSuffix.isEmpty ? (minor > 0 ? "5.\(minor)" : "5") : "5"
        case 6...10: return parts[0]
        case 11:     return "CS"
        case 12:     return "CS2"
        case 13:     return "CS3"
        case 14:     return "CS4"
        case 15:     return minor > 0 ? "CS5.\(minor)" : "CS5"
        case 16:     return "CS6"
        case 17:     return "CC"
        case 18:     return "CC 2014"
        case 19:     return "CC 2015"
        case 20:     return "CC 2015.3"
        case 21:     return "CC 2017"
        case 22:     return "CC 2018"
        case 23:     return "CC 2019"
        default:     return major > 23 ? "\(major + 1996)" : ver
        }
    }

    /// Photoshop の psVersion.major → 製品名/年（表示専用）。Photoshop 2020 以降は「major + 1999」。
    static func psVersionName(_ ver: String) -> String {
        let parts = ver.components(separatedBy: ".")
        guard let major = Int(parts.first ?? "") else { return ver }
        let (minor, minorSuffix): (Int, String) = {
            guard parts.count > 1 else { return (0, "") }
            let raw = parts[1]
            let digits = raw.prefix(while: { $0.isNumber })
            let suffix = raw[digits.endIndex...]
            return (Int(digits) ?? 0, String(suffix))
        }()

        switch major {
        case 1...4:  return parts[0]
        case 5:      return minorSuffix.isEmpty ? (minor > 0 ? "5.\(minor)" : "5") : "5"
        case 6...7:  return parts[0]
        case 8:      return "CS"
        case 9:      return "CS2"
        case 10:     return "CS3"
        case 11:     return "CS4"
        case 12:     return minor > 0 ? "CS5.\(minor)" : "CS5"
        case 13:     return "CS6"
        case 14:     return "CC"
        case 15:     return "CC 2014"
        case 16:     return "CC 2015"
        case 17:     return "CC 2015.5"
        case 18:     return "CC 2017"
        case 19:     return "CC 2018"
        case 20:     return "CC 2019"
        default:     return major > 20 ? "\(major + 1999)" : ver
        }
    }
}

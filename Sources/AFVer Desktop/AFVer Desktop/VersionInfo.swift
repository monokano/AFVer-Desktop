//
// バージョン解決ディスパッチャ（HANDOFF §4）。
// 拡張子／コンテンツに応じて Illustrator/Photoshop（AiVersionParser）または
// InDesign（Phase2）の解析を呼び、「バージョン」列の文字列と「種類」列の独自文字列を組み立てる。
//
// 表示文字列は File Ver Ai / File Ver Id の kindText / formatVersion に準拠。
// ※ 文字列はひとまず英語リテラル（ベースローカライズ）。日本語化は後続で Localizable に追加する。
//

import Foundation

/// 作成バージョン表示の対象アプリ系統（行頭のカラードットで識別）。
enum AppFamily: Sendable { case illustrator, photoshop, indesign, pdf, epsOther }

/// バージョン取得の精度モード。
/// - full: 従来どおり詳細取得（InDesign は xref でファイル全体を読み minor.patch まで確定）
/// - fast: ヘッダのみ取得（InDesign は xref をスキップ）。全系統とも表示を `(x.x)` に丸める。
///   CD-R 等で xref のファイル全体読み込みが遅い場合に取得時間を短縮する。
enum VersionDetail: String, Sendable, Hashable { case full, fast }

/// バージョン解決の結果。対象ファイルでないときは resolve が nil を返す。
struct VersionResolution: Sendable {
    /// 「バージョン」列に表示する文字列（取得できない対象は空文字列）
    let version: String
    /// 「種類」列に表示する独自文字列
    let kindOverride: String
    /// 拡張子とコンテンツの種類が一致しない（拡張子偽装）→ 種類列を赤表示
    let extMismatch: Bool
    /// 対象アプリ系統（バージョン列のカラードット色に使う）
    let family: AppFamily
}

nonisolated enum VersionInfo {

    // MARK: - 事前コンパイル済み正規表現
    // 呼び出しごとの NSRegularExpression 生成を避ける（多数ファイルの解析で同じ定数パターンを
    // 繰り返しコンパイルしていた）。パターンは定数なので static に保持して使い回す。

    /// `(major.minor.…)` を `(major.minor)` に丸める用（3桁以上のみマッチ）
    private static let truncateMinorRegex = try! NSRegularExpression(pattern: #"\((\d+)\.(\d+)(?:\.\d+)+\)"#)
    /// ビルド番号 `(a.b.c.d)` → `(a.b.c)` 用（resolveId / aiFormatVersion 共通）
    private static let buildTrimRegex = try! NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+)(?:\.\d+)+\)"#)
    /// ソートキー抽出用（カッコ内 (a.b.c)）
    private static let sortKeyRegex = try! NSRegularExpression(pattern: #"\((\d+)(?:\.(\d+))?(?:\.(\d+))?"#)

    // MARK: - 対象拡張子

    /// Illustrator / Photoshop（File Ver Ai 由来）
    static let aiExtensions: Set<String> = ["ai", "ait", "pdf", "eps", "psd", "psb"]
    /// InDesign（File Ver Id 由来）
    static let idExtensions: Set<String> = ["indd", "indt", "indb", "indl", "idml"]

    /// 解析（重い処理）を走らせる可能性があるか。拡張子なしも中身判定のため対象。
    static func isPotentialTarget(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || aiExtensions.contains(ext) || idExtensions.contains(ext)
    }

    // MARK: - 解決（非同期・バックグラウンド実行）

    /// バックグラウンドで解析する。@MainActor から `await` で呼ぶとメイン外で実行される。
    /// - Parameter detectPsVersion: Photoshop ネイティブ版（PSD/PSB cinf・編集機能保持PDF）を検出するか。
    ///   呼び出し側で「full モード かつ 設定 ON」のときだけ true を渡す（fast/設定OFF を内包した実効値）。
    nonisolated static func resolveAsync(url: URL, detail: VersionDetail = .full,
                                         detectPsVersion: Bool = false) async -> VersionResolution? {
        resolve(url: url, detail: detail, detectPsVersion: detectPsVersion)
    }

    /// 同期解決。対象でなければ nil（＝種類は macOS 任せ・バージョン空）。
    /// fast モードでは、全系統のバージョン表示を `(x.x)` に丸めて表記を統一する。
    static func resolve(url: URL, detail: VersionDetail = .full,
                        detectPsVersion: Bool = false) -> VersionResolution? {
        guard let res = resolveCore(url: url, detail: detail, detectPsVersion: detectPsVersion) else { return nil }
        guard detail == .fast else { return res }
        return VersionResolution(version: truncateToMinor(res.version),
                                 kindOverride: res.kindOverride,
                                 extMismatch: res.extMismatch,
                                 family: res.family)
    }

    private static func resolveCore(url: URL, detail: VersionDetail,
                                    detectPsVersion: Bool) -> VersionResolution? {
        let ext = url.pathExtension.lowercased()

        if idExtensions.contains(ext) {
            return resolveId(url: url, detail: detail)
        }

        if aiExtensions.contains(ext) || ext.isEmpty {
            let fc = AiVersionParser.parse(url: url, timeLimit: 10, notDetectEPSCompatibleVer: true,
                                           fastScan: detail == .fast, detectPsVersion: detectPsVersion)
            // 拡張子なしは Illustrator/Photoshop と判定できたものだけ対象にする
            if ext.isEmpty {
                let isPhotoshop = (fc.appName == "Photoshop")
                guard fc.isIllustratorFile || isPhotoshop else { return nil }
            }
            let kindText = aiKindText(fc)
            // 種類名が確定しない（kind="" 等）ものは対象外として macOS 任せに戻す
            guard !kindText.isEmpty else { return nil }
            // generic EPS（Illustrator/Photoshop 以外）は素性不明として常に警告（Glow Ai と一貫）。
            let isGenericEPS = fc.kind == "EPS" && !fc.isIllustratorFile && fc.appName != "Photoshop"
            return VersionResolution(version: aiFormatVersion(fc),
                                     kindOverride: kindText,
                                     extMismatch: isGenericEPS || aiExtMismatch(kind: fc.kind, ext: ext),
                                     family: aiFamily(fc))
        }

        return nil
    }

    /// バージョン文字列内のカッコを `(major.minor)` に丸める（3桁以上を2桁へ）。
    /// 既に2桁以下（例 `(30.3)`）はマッチせず素通りする。
    private static func truncateToMinor(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return truncateMinorRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "($1.$2)")
    }

    /// 対象アプリ系統を判定する（カラードット色用）。
    private static func aiFamily(_ fc: AiFileModel) -> AppFamily {
        let isPhotoshop = (fc.appName == "Photoshop")
        switch fc.kind {
        case "PSD", "PSB": return .photoshop
        case "Ai":         return .illustrator
        case "EPS":        return fc.isIllustratorFile ? .illustrator : (isPhotoshop ? .photoshop : .epsOther)
        case "PDF":        return .pdf   // 種類がPDFのものは（native data 有無に関わらず）グレー
        default:           return .pdf
        }
    }

    /// 拡張子偽装判定（Illustrator/Photoshop）。kind ごとの期待拡張子と実拡張子を突き合わせる。
    private static func aiExtMismatch(kind: String, ext: String) -> Bool {
        let expected: [String]
        switch kind {
        case "Ai":  expected = ["ai", "ait"]
        case "EPS": expected = ["eps"]
        case "PSD": expected = ["psd"]
        case "PSB": expected = ["psb"]
        case "PDF": expected = ["pdf"]
        default:    expected = []
        }
        return !expected.isEmpty && !ext.isEmpty && !expected.contains(ext)
    }

    // MARK: - InDesign の表示文字列（File Ver Id の ContentView / FileParser より移植）

    /// InDesign（.indd/.indt/.indl/.indb/.idml）の解決。
    private static func resolveId(url: URL, detail: VersionDetail) -> VersionResolution? {
        let parsed = IdVersionParser.parse(url: url, headerOnly: detail == .fast)

        let versionText: String
        if parsed.isValid {
            switch parsed.contentKind {
            case "indd", "indt":
                versionText = parsed.xrefResult.isEmpty ? parsed.headerResult : parsed.xrefResult
            case "indb", "indl":
                versionText = parsed.headerResult
            case "idml":
                versionText = parsed.idmlResult
            default:
                versionText = ""
            }
        } else {
            // 単体版は errorMessage を表示するが、本アプリではバージョン空にする
            versionText = ""
        }

        // 先頭 "InDesign " 除去 ＋ ビルド番号 (a.b.c.d)→(a.b.c)
        var trimmed = versionText.hasPrefix("InDesign ")
            ? String(versionText.dropFirst("InDesign ".count))
            : versionText
        let trimRange = NSRange(trimmed.startIndex..., in: trimmed)
        trimmed = buildTrimRegex.stringByReplacingMatches(in: trimmed, range: trimRange, withTemplate: "($1)")

        // 種類名（コンテンツ判定があればそれ、なければ拡張子から）
        let key = parsed.contentKind.isEmpty ? url.pathExtension.lowercased() : parsed.contentKind
        let kind = idKindText(key)
        guard !kind.isEmpty else { return nil }
        return VersionResolution(version: trimmed, kindOverride: kind,
                                 extMismatch: parsed.isExtMismatch,
                                 family: .indesign)
    }

    /// InDesign 種類名（kind / 拡張子の文字列をキーに）。
    static func idKindText(_ key: String) -> String {
        switch key {
        case "indd": return String(localized: "InDesign Document (.indd)")
        case "indt": return String(localized: "InDesign Template (.indt)")
        case "indl": return String(localized: "InDesign Library (.indl)")
        case "indb": return String(localized: "InDesign Book (.indb)")
        case "idml": return String(localized: "InDesign Markup (.idml)")
        default:     return ""
        }
    }

    // MARK: - Illustrator / Photoshop の表示文字列（File Ver Ai の ContentView より移植）

    /// 種類列の独自文字列を決定する。
    static func aiKindText(_ fc: AiFileModel) -> String {
        let isPhotoshop = (fc.appName == "Photoshop")
        switch fc.kind {
        case "PDF":
            if fc.isPhotoshopEditablePDF {
                return String(localized: "PDF with Photoshop native data (.pdf)")
            }
            return fc.isIllustratorFile
                ? String(localized: "PDF with Illustrator native data (.pdf)")
                : String(localized: "PDF without native data (Ai, Ps) (.pdf)")
        case "Ai":
            return fc.isTemplate
                ? String(localized: "Illustrator Template format (.ait)")
                : String(localized: "Illustrator format (.ai)")
        case "EPS":
            if fc.isIllustratorFile {
                return String(localized: "Illustrator EPS format (.eps)")
            } else if isPhotoshop {
                return String(localized: "Photoshop EPS format (.eps)")
            } else {
                // Illustrator/Photoshop いずれでもない EPS。生成元（creator1）を畳み込む。空なら「生成元不明」。
                let producer = fc.creator1.isEmpty
                    ? String(localized: "Unknown producer")
                    : fc.creator1
                return String(format: String(localized: "EPS format - %@ (.eps)"), producer)
            }
        case "PSD":
            return String(localized: "Photoshop format (.psd)")
        case "PSB":
            return String(localized: "Large Document format (.psb)")
        default:
            return fc.kind
        }
    }

    /// バージョン列の整形（先頭 "Illustrator " 除去・(a.b.c.d)→(a.b.c)）。
    static func aiFormatVersion(_ fc: AiFileModel) -> String {
        if fc.appName == "Photoshop" {
            guard !fc.psVersion.isEmpty else { return "" }
            return "\(AiVersionParser.psVersionName(fc.psVersion)) (\(fc.psVersion))"
        }
        guard fc.isIllustratorFile, !fc.determineCreated.isEmpty else { return "" }

        let alias = AiVersionParser.versionName(fc.determineCreated)
        var text = "\(alias) (\(fc.determineCreated))"
        let range = NSRange(text.startIndex..., in: text)
        text = buildTrimRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "($1)")
        return text
    }

    // MARK: - ソートキー

    /// バージョン文字列のカッコ内 "(a.b.c)" から (major, minor, patch) を抽出する。
    static func versionSortKey(_ version: String) -> (Int, Int, Int) {
        let range = NSRange(version.startIndex..., in: version)
        guard let m = sortKeyRegex.firstMatch(in: version, range: range) else { return (0, 0, 0) }
        func part(_ i: Int) -> Int {
            guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: version) else { return 0 }
            return Int(version[r]) ?? 0
        }
        return (part(1), part(2), part(3))
    }

    /// localizedStandardCompare で正しく並ぶよう、ソートキーをゼロ埋め文字列にする。
    static func versionSortString(_ version: String) -> String {
        let (a, b, c) = versionSortKey(version)
        return String(format: "%06d.%06d.%06d", a, b, c)
    }
}

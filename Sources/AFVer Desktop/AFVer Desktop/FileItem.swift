import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - FileItem

final class FileItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let name: String
    let modifiedDate: Date?
    let fileSize: Int64?      // nil for directories
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    var icon: NSImage

    // 種類列：初期は同期で確定できる値、Ai/Indは後から非同期で埋める
    @Published var kind: String

    // 子アイテム（展開済みの場合のみ非nil）
    var children: [FileItem]?
    // 子の読み込みが必要かどうか
    var needsLoading: Bool

    // グレーアウト（読み込み失敗など）
    var isDimmed: Bool = false

    // MARK: バージョン列（スイッチON時のみ使用）
    enum VersionState { case idle, fetching, resolved }
    /// 取得状態。idle=未着手 / fetching=取得中 / resolved=確定（対象外でも resolved）
    var versionState: VersionState = .idle
    /// 「バージョン」列の値（resolved 後。対象外や取得不可は空）
    var versionText: String = ""
    /// 「種類」列の上書き文字列（対象ファイルのみ非nil。スイッチON時に種類列へ反映）
    var kindOverride: String? = nil
    /// 拡張子とコンテンツの種類が不一致（拡張子偽装）。スイッチON時に種類列を赤表示
    var kindMismatch: Bool = false
    /// 対象アプリ系統（対象ファイルのみ非nil）。バージョン列の行頭カラードット色に使う
    var appFamily: AppFamily? = nil

    init(url: URL, name: String, modifiedDate: Date?, fileSize: Int64?,
         isDirectory: Bool, isPackage: Bool, isSymlink: Bool,
         icon: NSImage, kind: String, needsLoading: Bool) {
        self.url = url
        self.name = name
        self.modifiedDate = modifiedDate
        self.fileSize = fileSize
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.icon = icon
        self.kind = kind
        self.needsLoading = needsLoading
        // ディレクトリ（パッケージ除く）は展開可能なので children を空配列で初期化
        self.children = (isDirectory && !isPackage && !isSymlink) ? [] : nil
    }
}

// MARK: - アプリ系統のブランド色（バージョン列のカラードット）

extension AppFamily {
    /// Adobe ブランド色に準拠。種類列の赤（拡張子偽装）とは別列・別形状なので衝突しない。
    var markerColor: NSColor {
        switch self {
        case .illustrator: return NSColor(red: 1.00, green: 0.60, blue: 0.00, alpha: 1) // #FF9A00
        case .photoshop:   return NSColor(red: 0.19, green: 0.66, blue: 1.00, alpha: 1) // #31A8FF
        case .indesign:    return NSColor(red: 1.00, green: 0.20, blue: 0.40, alpha: 1) // #FF3366
        case .pdf:         return .secondaryLabelColor                                  // 汎用PDF（中立）
        case .epsOther:    return .secondaryLabelColor                                  // generic EPS（中空リングの線色）
        }
    }
}

// MARK: - 拡張子偽装の警告色

extension NSColor {
    /// 拡張子と中身が食い違う（拡張子偽装）行の種類列に使う赤。
    /// systemRed の鮮やかさ（安っぽさ）を避けた落ち着いたレンガ系。ライト/ダークで自動切替し、
    /// ダークは埋もれ防止に明るめ。印刷（白い紙）には固定のライト値 `kindMismatchWarningPrint` を使う。
    static let kindMismatchWarning = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0xE1/255.0, green: 0x67/255.0, blue: 0x5F/255.0, alpha: 1)   // #E1675F
            : NSColor(red: 0xB2/255.0, green: 0x2A/255.0, blue: 0x22/255.0, alpha: 1)   // #B22A22
    }
    /// 印刷用（白い紙固定）のライト値 #B22A22。
    static let kindMismatchWarningPrint = NSColor(red: 0xB2/255.0, green: 0x2A/255.0, blue: 0x22/255.0, alpha: 1)
}

// MARK: - 表示用フォーマット

extension FileItem {
    var displaySize: String {
        guard !isDirectory || isPackage else { return "--" }
        guard let size = fileSize else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayDate: String {
        guard let date = modifiedDate else { return "--" }
        return FileItem.dateFormatter.string(from: date)
    }

    /// 「バージョン」列の表示。取得状態に応じて切り替える。
    var displayVersion: String {
        switch versionState {
        case .idle:     return ""
        case .fetching: return "…"
        case .resolved: return versionText
        }
    }

    /// 「種類」列に表示する文字列。スイッチON の対象ファイルは独自文字列（kindOverride）。
    /// 拡張子とコンテンツが一致（＝拡張子偽装でない／黒表示）なら、末尾の冗長な
    /// " (.xxx)" を省く。不一致（赤表示）のときは本当の種別を示す手がかりなので残す。
    func displayKind(versionMode: Bool) -> String {
        let base = versionMode ? (kindOverride ?? kind) : kind
        if versionMode, kindOverride != nil, !kindMismatch {
            return FileItem.strippingTrailingExtension(base)
        }
        return base
    }

    /// 拡張子偽装の注意喚起記号（種類列の表示専用）。
    /// `⚠` にテキスト表示指定（U+FE0E / VS15）を付け、カラー絵文字化を防いでモノクロ＝赤に
    /// 着色できるようにする。白黒印刷でも形で判別でき、色覚特性があっても伝わる（色＋形の冗長コード）。
    static let kindMismatchWarningPrefix = "\u{26A0}\u{FE0E} "

    /// 種類列の「表示専用」文字列。拡張子偽装のときだけ先頭に警告記号を前置する。
    /// 並べ替え（cellValue）・CSV書き出しには使わない（記号がソート順やデータを汚すため、
    /// それらは素の `displayKind` を使う）。
    func displayKindForList(versionMode: Bool) -> String {
        let base = displayKind(versionMode: versionMode)
        return (versionMode && kindMismatch) ? FileItem.kindMismatchWarningPrefix + base : base
    }

    /// 文字列末尾の " (.xxx)" 括弧（直前の空白含む）を1つ取り除く。無ければそのまま。
    static func strippingTrailingExtension(_ s: String) -> String {
        guard let r = s.range(of: #"\s*\(\.[A-Za-z0-9]+\)\s*$"#,
                              options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
}

// MARK: - FileLoader

enum FileLoadError: Error {
    case accessDenied
    case readFailed(Error)
}

@MainActor
final class FileLoader {

    /// 各アイテム生成に必要なリソースキー（loadChildren とドロップ単体表示の双方で共有）。
    /// 不変・Sendable なので nonisolated（makeItem のデフォルト引数から参照するため）。
    nonisolated static let itemResourceKeys: [URLResourceKey] = [
        .nameKey, .contentModificationDateKey, .fileSizeKey,
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .isHiddenKey, .isVolumeKey, .typeIdentifierKey
    ]

    static func loadChildren(of url: URL) throws -> [FileItem] {
        let keys = Self.itemResourceKeys
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            let nsErr = error as NSError
            if nsErr.code == NSFileReadNoPermissionError ||
               nsErr.code == NSFileReadUnknownError {
                throw FileLoadError.accessDenied
            }
            throw FileLoadError.readFailed(error)
        }

        var items: [FileItem] = []
        for fileURL in contents {
            guard let item = makeItem(url: fileURL, keys: keys) else { continue }
            items.append(item)
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 1 アイテム分の FileItem を生成する。`includeHidden` を true にすると不可視属性でも除外しない
    /// （明示的にドロップされたファイルは、不可視でもそのまま表示するため）。
    static func makeItem(url: URL, keys: [URLResourceKey] = FileLoader.itemResourceKeys,
                         includeHidden: Bool = false) -> FileItem? {
        guard let res = try? url.resourceValues(forKeys: Set(keys)) else { return nil }

        // 不可視ファイルは除外（明示ドロップ時は includeHidden で残す）
        if !includeHidden, res.isHidden == true { return nil }

        let name = res.name ?? url.lastPathComponent
        let modDate = res.contentModificationDate
        let isDir = res.isDirectory ?? false
        let isPkg = res.isPackage ?? false
        let isLink = res.isSymbolicLink ?? false

        // シンボリックリンク・パッケージは1ファイル扱い（サイズ取得）
        let size: Int64?
        if isLink || isPkg {
            size = res.fileSize.map { Int64($0) }
        } else if isDir {
            size = nil
        } else {
            size = res.fileSize.map { Int64($0) }
        }

        let icon = folderAwareIcon(url: url, res: res, isDir: isDir, isPkg: isPkg, isLink: isLink)
        icon.size = NSSize(width: 16, height: 16)

        let kind = initialKind(for: url, res: res, isDir: isDir, isPkg: isPkg, isLink: isLink)
        let needsLoading = isDir && !isPkg && !isLink

        return FileItem(
            url: url, name: name, modifiedDate: modDate, fileSize: size,
            isDirectory: isDir, isPackage: isPkg, isSymlink: isLink,
            icon: icon, kind: kind, needsLoading: needsLoading
        )
    }

    // 種類の初期値（同期・軽量）
    private static func initialKind(
        for url: URL, res: URLResourceValues,
        isDir: Bool, isPkg: Bool, isLink: Bool
    ) -> String {
        if isLink { return String(localized: "Alias") }

        // 展開できる素のフォルダ（パッケージでない）は、UTI に関わらず「フォルダ」。
        // 例: .xcassets は assetcatalog 型だが、Finder でも種類は「フォルダ」と表示される。
        if isDir && !isPkg { return String(localized: "Folder") }

        let ext = url.pathExtension.lowercased()

        // Ai/Ind は後から非同期で上書きするのでプレースホルダ
        if ext == "ai" || ext == "eps" {
            return kindFromUTI(res.typeIdentifier)
                ?? String(localized: "Adobe Illustrator Document")
        }
        if ext == "indd" {
            return "InDesign® Document"
        }
        if ext == "" && !isDir {
            // 拡張子なし：後で非同期判定
            return kindFromUTI(res.typeIdentifier) ?? String(localized: "Document")
        }

        return kindFromUTI(res.typeIdentifier)
            ?? (isDir ? String(localized: "Folder") : String(localized: "Document"))
    }

    /// アイコンを取得する。パッケージでない素のフォルダなのに UTI がフォルダ型でない
    /// （例: .xcassets = assetcatalog）場合、`icon(forFile:)` はドキュメント風アイコンを
    /// 返すため、Finder に合わせてフォルダアイコンへ差し替える。
    /// 通常のフォルダ（public.folder 準拠）はそのまま使い、カスタムフォルダアイコンを保持する。
    private static func folderAwareIcon(
        url: URL, res: URLResourceValues,
        isDir: Bool, isPkg: Bool, isLink: Bool
    ) -> NSImage {
        if isDir && !isPkg && !isLink {
            let type = res.typeIdentifier.flatMap { UTType($0) }
            if type?.conforms(to: .folder) != true {
                return NSWorkspace.shared.icon(for: .folder)
            }
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func kindFromUTI(_ uti: String?) -> String? {
        guard let uti else { return nil }
        guard let type = UTType(uti) else { return nil }
        // localizedDescription は macOS 11+
        return type.localizedDescription
    }
}

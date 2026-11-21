//
// ウインドウのタイトル（標準のタイトルバー）を、表示中のフォルダに合わせる
//
// 2026-11-21：独自のツールバー（NSToolbar）をやめ、標準のタイトルバーにした。
// macOS 26/27 のツールバーは部品を大きく描き直すため、標準の部品のままでは見た目が崩れ、
// 自前の部品で合わせ込むと OS が変わるたびに崩れたため。
// ・タイトルバー：フォルダ名だけ（NSWindow.title。プロキシアイコンは出さない）
// ・フォルダのアイコン＋名前＋⌄（パスのメニュー）：タイトルバーの下のボタンの列の左端（ContentView の ActionBarView）
// ・展開／閉じる／列幅を調整／プリント／バージョンのスイッチ／詳細｜簡易：同じボタンの列の右側
//

import SwiftUI
import AppKit

// MARK: - WindowTitleConfigurator (NSViewRepresentable)

/// ウインドウのタイトルとプロキシアイコンを、表示中のフォルダに合わせる。
/// `WindowSizeMatcher` と同じく、不可視の補助ビューを `background` に置いて使う。
struct WindowTitleConfigurator: NSViewRepresentable {
    /// タイトルに出すルートフォルダ（未ドロップ、またはファイル等のフラット表示なら nil）
    let folderURL: URL?
    /// ファイル等のフラット表示か（true のときタイトルを「ファイル一覧」にする）
    let isFlatList: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TitleHostView()
        view.folderURL = folderURL
        view.isFlatList = isFlatList
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TitleHostView else { return }
        view.folderURL = folderURL
        view.isFlatList = isFlatList
        view.apply()
    }
}

// MARK: - TitleHostView

/// ウインドウに載った時点と値が変わった時点で、タイトルを反映する不可視ビュー。
final class TitleHostView: NSView {
    var folderURL: URL?
    var isFlatList = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        window.titleVisibility = .visible
        if let url = folderURL {
            // 名前だけ。アイコンはタイトルバーの下のボタンの列に大きく出すため、
            // プロキシアイコン（representedURL）は付けない（上下でアイコンが二重になるため）。
            window.title = FileManager.default.displayName(atPath: url.path)
        } else {
            // ファイル等のフラット表示は単一の親が無いので「ファイル一覧」。空のウインドウはアプリ名。
            window.title = isFlatList
                ? String(localized: "File List")
                : (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "")
        }
    }
}

// MARK: - FolderPath（⌄ のパスのメニューの中身）

/// Finder のタイトルの階層に合わせたパスの並び：
/// フォルダ → 親 → … → ボリュームのマウントポイントで止め、最後に「コンピュータ」を足す。
/// /Volumes や起動ボリューム配下の内部構造は Finder では見せないため辿らない。
enum FolderPath {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let icon: NSImage
        let open: () -> Void
    }

    static func entries(of url: URL) -> [Entry] {
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        let volumePath = volumeURL?.standardizedFileURL.path
        var result: [Entry] = []
        var current = url.standardizedFileURL
        while true {
            let target = current
            result.append(Entry(title: FileManager.default.displayName(atPath: target.path),
                                icon: smallIcon(NSWorkspace.shared.icon(forFile: target.path)),
                                open: { NSWorkspace.shared.open(target) }))
            if current.path == volumePath { break }   // ボリュームのマウントポイントで終了
            // ※ URL.deletingLastPathComponent() は "/" に対して "../" を返し続けるので path で判定する
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        // 最後に「コンピュータ」（Mac 本体）。ボリュームを選択した状態で Finder に表示する
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        result.append(Entry(title: Host.current().localizedName ?? "Computer",
                            icon: smallIcon(computerIcon),
                            open: {
                                if let volumeURL {
                                    NSWorkspace.shared.activateFileViewerSelecting([volumeURL])
                                }
                            }))
        return result
    }

    private static func smallIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

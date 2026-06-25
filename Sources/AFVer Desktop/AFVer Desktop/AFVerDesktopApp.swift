import SwiftUI

/// 「新規ウインドウで表示」で開くウインドウへ渡す値。
/// `token` により同じフォルダでも常に新規ウインドウを開く
/// （SwiftUI の値付きウインドウは同値だと既存ウインドウへフォーカスするため）。
struct FolderWindowValue: Codable, Hashable {
    let url: URL
    var token = UUID()
}

/// ドロップされたファイル等（フォルダ以外）を 1 枚のフラットリストで開くウインドウへ渡す値。
/// `token` で常に新規ウインドウを開かせるのは `FolderWindowValue` と同じ理由。
struct DroppedFilesWindowValue: Codable, Hashable {
    let urls: [URL]
    var token = UUID()
}

@main
struct AFVerDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 700, height: 500)
        // メイングループには .handlesExternalEvents(matching: []) を付けない。
        // 付けると Dock ドロップでの「コールド起動時に最初のウインドウまで抑制」されて
        // しまうため。代わりに、アプリアイコンへのドロップ直後に SwiftUI が作る余剰の
        // 空ウインドウは、ContentView 側が猶予期間内に自動で閉じる（下記 AppDelegate と対）。
        .commands {
            // アプリメニューの「設定…」(⌘,)。独自の設定ウインドウを開く（Dock メニューと同経路）。
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(String(localized: "AFVer Desktop Help")) {
                    appDelegate.openHelp()
                }
                .keyboardShortcut("?", modifiers: .command)
                Button(String(localized: "Change Log")) {
                    appDelegate.openChangeLog()
                }
            }
            // 「新規ウインドウ」(⌘N) は WindowGroup 標準の .newItem に任せる
            // （空で replace すると File メニューごと消え、新規ウインドウも作れなくなる）
            FileCommands()
        }

        // リスト行の右クリック「新規ウインドウで表示」用：フォルダ指定付きの新規ウインドウ
        WindowGroup(id: "folder", for: FolderWindowValue.self) { $value in
            ContentView(initialFolder: value?.url)
        }
        .defaultSize(width: 700, height: 500)
        .handlesExternalEvents(matching: [])   // 同上（openWindow による生成には影響しない）

        // Dock へのファイルドロップ用：落とした「フォルダ以外」をまとめて 1 枚のフラットリストで開く
        WindowGroup(id: "files", for: DroppedFilesWindowValue.self) { $value in
            ContentView(initialDroppedFiles: value?.urls)
        }
        .defaultSize(width: 700, height: 500)
        .handlesExternalEvents(matching: [])
    }
}

// MARK: - FileCommands

/// ファイルメニューの追加コマンド。
/// `@FocusedValue` で最前面ウィンドウの `FileListModel` を受け取る
/// （`ContentView` の `.focusedSceneValue(\.fileListModel, model)` とペア）。
struct FileCommands: Commands {
    @FocusedValue(\.fileListModel) private var model
    // メニューのチェックは「最前面ウィンドウの実効精度」に追従させる（光学ディスク自動高速を含む）。
    // ContentView の .focusedSceneValue(\.effectiveVersionDetail, model.versionDetail) が値を流し、
    // model.versionDetail が変わると ContentView 再描画 → この FocusedValue が更新 → Commands 再評価。
    @FocusedValue(\.effectiveVersionDetail) private var effectiveDetail
    // フォーカスが無い（ウィンドウ未表示）ときのフォールバック用に保存値も保持する。
    @AppStorage("versionDetail") private var versionDetailRaw = VersionDetail.full.rawValue
    // ステータスバー表示トグル用。共有設定を監視してメニュー文言（表示/隠す）を追従させる。
    @ObservedObject private var settings = AppSettings.shared

    var body: some Commands {
        // ファイルメニューの並び：
        //   新規ウインドウ / 閉じる / --- / プリント… / CSVとして書き出す… / --- / Finderに表示
        // 表示メニュー（ツールバー項目の上）：すべて展開／すべて閉じる
        CommandGroup(before: .toolbar) {
            Button(String(localized: "Expand All")) {
                model?.expandAll()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])   // ⌥⌘→
            .disabled(model == nil)
            Button(String(localized: "Collapse All")) {
                model?.collapseAll()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])    // ⌥⌘←
            .disabled(model == nil)
            Divider()
            // 列幅を調整：変更日・サイズ・バージョン・種類を内容に合わせ、種類を省略させない
            Button(String(localized: "Adjust Column Widths")) {
                model?.adjustColumnWidths()
            }
            .keyboardShortcut("j", modifiers: .command)   // ⌘J
            .disabled(model == nil)
            Divider()
            // バージョンの精度（詳細=xref / 高速=ヘッダのみ）。CD-R 等で取得が遅いとき高速を選ぶ
            Menu(String(localized: "Version Detail")) {
                Picker(String(localized: "Version Detail"),
                       selection: Binding(
                        get: { effectiveDetail ?? (VersionDetail(rawValue: versionDetailRaw) ?? .full) },
                        set: { newValue in
                            versionDetailRaw = newValue.rawValue   // 保存値（フォールバック）も更新
                            model?.setVersionDetail(newValue)      // 実効値＋保存＋再取得
                        })) {
                    Text(String(localized: "Detailed (x.x.x)")).tag(VersionDetail.full)
                    Text(String(localized: "Simple (x.x)")).tag(VersionDetail.fast)
                }
                .pickerStyle(.inline)
            }
            .disabled(model == nil)
            Divider()
            // ステータスバーの表示/非表示（全ウインドウ共通。Finder と同じ ⌘/）。
            Button(settings.showStatusBar
                   ? String(localized: "Hide Status Bar")
                   : String(localized: "Show Status Bar")) {
                settings.showStatusBar.toggle()
            }
            .keyboardShortcut("/", modifiers: .command)   // ⌘/
            Divider()
        }
        CommandGroup(replacing: .printItem) {
            Divider()
            Button(String(localized: "Print…")) {
                model?.printList()
            }
            .keyboardShortcut("p")   // ⌘P
            .disabled(model == nil)
            Button(String(localized: "Export as CSV…")) {
                model?.exportList()
            }
            .keyboardShortcut("e")   // ⌘E
            .disabled(model == nil)
            Divider()
            Button(String(localized: "Show in Finder")) {
                model?.revealSelectionInFinder()
            }
            .keyboardShortcut("r")   // ⌘R
            .disabled(model == nil)
        }
        // Edit メニュー：標準の「コピー」(⌘C) の直後に「パスをコピー」(⌥⌘C) を追加する。
        // コピー(⌘C, TSV) は標準 Copy をそのまま使い、リストの copy(_:) がレスポンダチェーンで処理する。
        // パスのコピーは標準項目が無いためここで追加し、sendAction でレスポンダチェーン（リスト）へ送る。
        CommandGroup(after: .pasteboard) {
            Button(String(localized: "Copy as Pathname")) {
                // リスト（ShiftedDisclosureOutlineView）は private 型のため #selector で参照できない。
                // メソッド名は安定なので文字列セレクタでレスポンダチェーンへ送る（copyAsPath:）。
                NSApp.sendAction(Selector(("copyAsPath:")), to: nil, from: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])   // ⌥⌘C
            .disabled(model == nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var lastWindowSize: NSSize?
    private var previousMain: NSWindow?
    private var helpWindowController: HelpWindowController?
    private var changeLogWindowController: ChangeLogWindowController?
    private var settingsWindowController: SettingsWindowController?

    // MARK: 設定（独自ウインドウに設定 UI を表示）

    /// アプリメニュー「設定…」・Dock メニュー「設定…」の両方から呼ばれる。
    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    // MARK: ヘルプ（独自ウインドウに HTML ヘルプを表示）

    func openHelp() {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    // MARK: 更新履歴（独自ウインドウにリモートHTMLを表示）

    @objc func openChangeLog() {
        if changeLogWindowController == nil {
            changeLogWindowController = ChangeLogWindowController()
        }
        changeLogWindowController?.show()
    }

    // MARK: Dock メニュー

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        let changeLogItem = NSMenuItem(
            title: String(localized: "Change Log"),
            action: #selector(openChangeLog),
            keyEquivalent: ""
        )
        changeLogItem.target = self
        menu.addItem(changeLogItem)
        return menu
    }

    // MARK: Dockアイコンへのドロップ（Info.plist の CFBundleDocumentTypes で受理）

    /// フォルダを開くハンドラ（最後に現れた ContentView が登録。
    /// 空ウィンドウならそこに表示、そうでなければ新規ウインドウを開く）
    var openDroppedFolder: ((URL) -> Void)?
    /// フォルダ以外（ファイル/パッケージ等）をまとめて 1 枚のフラットリストで開くハンドラ。
    /// 空ウィンドウならそこに表示、そうでなければ新規ウインドウを開く。
    var openDroppedFiles: (([URL]) -> Void)?
    /// ハンドラ登録前（起動直後）に届いた URL の保留キュー（ContentView.onAppear で消化）
    var pendingFolderURLs: [URL] = []
    /// 同上、フォルダ以外の保留（まとめて 1 枚で開くため配列で溜める）
    var pendingDroppedFiles: [URL] = []

    // MARK: ドロップ後の空ウインドウ掃除
    //
    // SwiftUI は「N 個の URL」を含む open イベントに対し、メインウインドウを URL ごとに生成する。
    // フォルダ表示に使われなかった余りは空ウインドウとして残るため、ドロップ後に
    // 「フォルダを受け取っていない空ウインドウ」を閉じる。全ウインドウのモデルを追跡して判定する。

    private final class WeakModel {
        weak var model: FileListModel?
        init(_ model: FileListModel) { self.model = model }
    }
    private var allModels: [WeakModel] = []
    /// ドロップ前から「内容あり」だったウインドウ（カスケード整列の対象外＝既存窓を動かさないため）。
    private var preDropContentWindows: Set<ObjectIdentifier> = []
    /// ドロップ項目が 2 個以上（folders+files >= 2）の Dock ドロップ中だけ真。SwiftUI は URL 1 個につき
    /// 1 ウインドウ作り、こちらは 1 枚だけ再利用するため余剰の空ウインドウ（urls.count-1 枚）が出る
    ///（フォルダ・ファイル・混在いずれも同じ理屈）。整列が終わるまで**バッチ窓を全部 alpha=0 で隠し**、
    /// 内容窓が出そろった瞬間に整列＋一斉表示する（`revealDropBatch`）。空窓は隠れたまま `finalizeDropBatch` で閉じる。
    var suppressingDropWindows = false
    /// 一斉表示（整列＋内容窓表示）を済ませたか。バッチ内で1回だけ実行するためのガード。
    private var dropBatchRevealed = false
    /// 今回のバッチで表示すべき内容ウインドウ数 ＝ `folders.count + (ファイルあり ? 1 : 0)`。
    /// これだけ出そろったら即「一斉表示」する（イベント駆動）。固定遅延に依存しない。
    private var expectedBatchContentCount = 0
    /// バッチ世代。固定遅延フォールバック（`finalizeDropBatch`）が古いバッチに作用しないよう照合する。
    private var currentDropToken = 0

    /// 全 ContentView のモデルを登録する（ContentView.onAppear から）。
    /// onAppear は同一モデルに対して複数回発火しうるため、重複登録を防ぐ
    /// （重複すると contentWindows() に同じウインドウが二重に出てカスケードが1段余分に進む）。
    func registerModel(_ model: FileListModel) {
        allModels.removeAll { $0.model == nil }
        guard !allModels.contains(where: { $0.model === model }) else { return }
        allModels.append(WeakModel(model))
    }

    /// 「Photoshop形式のバージョンを検出する」設定の切替時に、全ウインドウのリストを再取得させる
    /// （`AppSettings.detectPhotoshopVersion` の didSet から呼ぶ）。PSD/PSB・編集PDF の表示が即時に変わる。
    func refetchVersionsAllWindows() {
        for box in allModels { box.model?.refetchLoadedVersions() }
        allModels.removeAll { $0.model == nil }
    }

    /// フォルダを受け取っていない空ウインドウを閉じる。
    private func closeEmptyWindows() {
        for box in allModels {
            if let m = box.model, m.rootURL == nil {
                m.hostWindow?.close()
            }
        }
        allModels.removeAll { $0.model == nil }
    }

    /// 複数項目ドロップの整列中（`suppressingDropWindows`）に新規 mount されたウインドウを `alpha = 0` で隠す。
    /// **内容の有無に関わらず隠す**（`openWindow` 経由の窓で内容確定がフックより先に来ても確実に隠すため）。
    /// 既存ウインドウ（preDrop）は対象外。内容窓は出そろい時に `revealDropBatch()` が一斉表示し、
    /// 空窓は隠れたまま `finalizeDropBatch()` の `closeEmptyWindows()` で閉じる。
    /// `orderOut` ではなく alpha を使うのは SwiftUI のウインドウ並べ替えと競合しないため。
    func hideDuringDropIfNeeded(_ window: NSWindow?, model: FileListModel) {
        guard suppressingDropWindows, let window,
              !preDropContentWindows.contains(ObjectIdentifier(window)) else { return }
        window.alphaValue = 0
    }

    /// `application(open)` 時点で既に存在するバッチ（preDrop 以外）のウインドウを直ちに `alpha = 0` で隠す。
    /// SwiftUI は `application(open)` より前にウインドウを生成・mount するため、view フックだけでは既存分を
    /// 隠せない（フックは suppressing=false のうちに走り終えている）。この時点ではバッチ窓はまだ内容なし。
    private func hideBatchWindowsNow() {
        for box in allModels {
            guard let m = box.model, let w = m.hostWindow else { continue }
            if preDropContentWindows.contains(ObjectIdentifier(w)) { continue }
            w.alphaValue = 0
        }
    }

    /// 現在「内容あり（rootURL != nil）」の FileList ウインドウ（ウインドウ単位で重複排除）。
    /// 同一ウインドウを別モデルが指す等の経路で二重に入っても、カスケードが1段余分に進まないようにする。
    private func contentWindows() -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSWindow] = []
        for box in allModels {
            guard let m = box.model, m.rootURL != nil, let w = m.hostWindow else { continue }
            if seen.insert(ObjectIdentifier(w)).inserted {
                result.append(w)
            }
        }
        return result
    }

    /// Window メニューの並び順（上→下）に対応する NSWindow を返す。
    /// AppKit が自動生成するウインドウ項目は target に該当 NSWindow を持つため、それを拾う
    /// （Minimize/Zoom 等の非ウインドウ項目は target が NSWindow でないので自然に除外される）。
    /// この並びは「ウインドウが最初に前面に出た順」＝実測でドロップ順を反映しており、
    /// windowNumber（生成順）より信頼できる（openWindow 経由の生成順は実機でドロップ順とずれる）。
    private func windowMenuOrder() -> [NSWindow] {
        guard let items = NSApp.windowsMenu?.items else { return [] }
        return items.compactMap { $0.target as? NSWindow }
    }

    /// 今回のバッチ（preDrop を除く内容ありウインドウ）を **Window メニューの並び（＝ドロップ順）**で返す。
    /// windowNumber（生成順）は openWindow 経由だと実機でドロップ順とずれるため、メニュー順を正とする
    /// （allModels 登録順も同様に乱れる。メニュー未登録はフォールバックで windowNumber 昇順）。
    private func batchContentWindows() -> [NSWindow] {
        let menuOrder = windowMenuOrder()
        func menuIndex(_ w: NSWindow) -> Int {
            menuOrder.firstIndex(of: w) ?? Int.max   // メニュー未登録は末尾扱い（フォールバック）
        }
        return contentWindows()
            .filter { !preDropContentWindows.contains(ObjectIdentifier($0)) }
            .sorted {
                let a = menuIndex($0), b = menuIndex($1)
                if a != b { return a < b }
                return $0.windowNumber < $1.windowNumber   // メニューで決まらなければ生成順
            }
    }

    /// バッチの内容ウインドウを「最背面（メニュー先頭＝最初に出た窓）を基準に、同サイズ・右下カスケード」で
    /// 整列し、重なり順もメニュー順（＝ドロップ順）に再設定する（先頭＝最背面 … 末尾＝最前面）。
    private func cascadeBatchWindows() {
        let batch = batchContentWindows()
        guard batch.count >= 2 else { return }   // 1 枚以下ならカスケード不要

        // 位置・サイズ：最背面（メニュー先頭＝最初に出た窓）を基準に、2 枚目以降を同サイズで右下カスケード
        //（基準は動かさない。cascadeTopLeft が画面端で自動折り返し）。
        let anchor = batch[0]
        let size = anchor.contentRect(forFrameRect: anchor.frame).size
        var topLeft = anchor.cascadeTopLeft(from: .zero)
        for window in batch.dropFirst() {
            window.setContentSize(size)
            topLeft = window.cascadeTopLeft(from: topLeft)
        }

        // カスケードでディスプレイ外や Dock に食い込んだ窓を可視領域へ収める（収まっていれば no-op）。
        for window in batch { constrainToVisibleFrame(window) }

        // 重なり順：メニュー順に前面へ送る（先頭＝最背面 … 末尾＝最前面）。最後の窓を key にする。
        for window in batch {
            window.orderFront(nil)
        }
        batch.last?.makeKeyAndOrderFront(nil)
    }

    // MARK: 一斉表示（イベント駆動）

    /// 内容窓が1つ出そろうたび（`rootURL` 確定／`hostWindow` 解決時）に ContentView から呼ぶ。
    /// 想定枚数そろったら即「一斉表示」する。固定遅延に依存しない。
    func noteBatchContentReady() {
        guard suppressingDropWindows, !dropBatchRevealed else { return }
        if batchContentWindows().count >= expectedBatchContentCount {
            revealDropBatch()
        }
    }

    /// 内容確定時に ContentView（`rootURL` の didSet）から呼ぶ。
    /// ・抑制中で未表示 → 出そろい判定（隠したまま）／・抑制中で表示済み → 遅れて来た内容窓を個別表示
    /// ・非抑制（単一項目・通常）→ 即表示（そもそも隠していないので実質 no-op）。
    func noteContentWindowReady(_ window: NSWindow?) {
        guard suppressingDropWindows else { window?.alphaValue = 1; return }
        if dropBatchRevealed {
            window?.alphaValue = 1
        } else {
            noteBatchContentReady()
        }
    }

    /// 隠したまま整列（カスケード）し、内容窓を一斉に表示する。空窓は隠れたまま。バッチ内で1回だけ。
    /// 空の掃除と抑制解除は `finalizeDropBatch`（固定遅延）で行う。
    private func revealDropBatch() {
        guard suppressingDropWindows, !dropBatchRevealed else { return }
        dropBatchRevealed = true
        cascadeBatchWindows()                                  // 隠したまま整列
        for w in batchContentWindows() { w.alphaValue = 1 }    // 整列後に一斉表示
    }

    /// 固定遅延フォールバック兼後始末：未表示なら表示し、隠れた空ウインドウを閉じて抑制を解除する。
    /// 空窓は alpha=0 で見えないため、この遅延の値は見た目に影響しない（保険＋掃除のためだけ）。
    /// `token` で古いバッチのフォールバックが新しいバッチに作用しないよう照合する。
    private func finalizeDropBatch(token: Int) {
        guard token == currentDropToken, suppressingDropWindows else { return }
        if !dropBatchRevealed { revealDropBatch() }    // 出そろい未検出でも保険で表示
        closeEmptyWindows()
        for w in contentWindows() { w.alphaValue = 1 } // 取りこぼし保険（全内容窓を表示）
        suppressingDropWindows = false
        dropBatchRevealed = false
    }

    /// リストの右クリック「新規ウインドウで表示」など、`openWindow` を続けて呼んで複数の内容ウインドウを
    /// 開く処理の**直前**に呼ぶ。Dock ドロップ（`application(_:open:)`）と同じバッチ整列
    /// （新規窓を隠す→出そろい検出→カスケード整列して一斉表示）を programmatic な窓にも働かせる。
    /// - Parameter count: これから開く内容ウインドウの枚数（フォルダ枚数 ＋ ファイル群を出すなら 1）。
    ///   2 未満なら整列不要なので何もしない（単一窓は隠さず即表示）。
    func beginProgrammaticWindowBatch(expectedContentWindowCount count: Int) {
        guard count >= 2 else { return }
        // 既存の内容窓は動かさない（カスケード対象外）。
        preDropContentWindows = Set(contentWindows().map(ObjectIdentifier.init))
        suppressingDropWindows = true
        dropBatchRevealed = false
        expectedBatchContentCount = count
        currentDropToken += 1
        // この時点では openWindow の窓はまだ mount されていない。以降 mount される窓は
        // ContentView の WindowAccessor 経由で hideDuringDropIfNeeded により alpha=0 で隠れ、
        // 出そろった時点で revealDropBatch がカスケード整列して一斉表示する。
        let token = currentDropToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.finalizeDropBatch(token: token)
        }
    }

    /// ドロップ／「このアプリケーションで開く」対象が「素のフォルダ」か。
    private func isPlainFolder(_ url: URL) -> Bool {
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return rv?.isDirectory == true && rv?.isPackage != true
    }

    /// Dockドロップ／Finder の「このアプリケーションで開く」で呼ばれる。
    /// ・素のフォルダ/ボリューム → それぞれ中身を一覧（1つずつウインドウ）
    /// ・それ以外（ファイル/パッケージ/エイリアス等）→ まとめて 1 枚のフラットリスト
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { isPlainFolder($0) }
        let files = urls.filter { !isPlainFolder($0) }
        guard !folders.isEmpty || !files.isEmpty else { return }

        // カスケード整列の基準：このドロップ前から「内容あり」だった窓は対象外（動かさない）。
        preDropContentWindows = Set(contentWindows().map(ObjectIdentifier.init))

        // ドロップ項目が 2 個以上のとき、SwiftUI が作る余剰の空ウインドウ（urls.count-1 枚）を隠す。
        // SwiftUI は URL 1 個につき 1 ウインドウ作り、こちらは 1 枚だけ再利用するため余りが出る
        //（フォルダ・ファイル・混在いずれも同じ）。単一項目では余りが出ないので抑制しない（従来どおり即時表示）。
        suppressingDropWindows = (folders.count + files.count >= 2)

        if suppressingDropWindows {
            // 整列が終わるまで全バッチ窓を隠し、内容が出そろった瞬間に一斉表示する（イベント駆動）。
            // 想定内容数＝フォルダ数＋(ファイルあり?1:0)。SwiftUI の view mount は application(open) より
            // 前に走るので、ここで mount 済みのバッチ窓を隠す（フックは suppressing=false のうちに走り終えている）。
            expectedBatchContentCount = folders.count + (files.isEmpty ? 0 : 1)
            dropBatchRevealed = false
            currentDropToken += 1
            hideBatchWindowsNow()
        }

        // フォルダ：従来通り 1 つずつ
        if let openDroppedFolder {
            folders.forEach(openDroppedFolder)
        } else {
            pendingFolderURLs.append(contentsOf: folders)
        }
        // ファイル等：まとめて 1 枚（ハンドラ未登録なら保留して onAppear で消化）
        if !files.isEmpty {
            if let openDroppedFiles {
                openDroppedFiles(files)
            } else {
                pendingDroppedFiles.append(contentsOf: files)
            }
        }

        if suppressingDropWindows {
            // 再利用窓が同期で内容を持った場合（複数ファイル等）に即座に一斉表示できるよう一度判定。
            noteBatchContentReady()
            // 保険：出そろわない／hostWindow 解決が遅い異常時に備えた固定遅延フォールバック
            //（通常は出そろい時に表示済み。空窓は隠れたままなのでこの遅延は見た目に無関係）。
            let token = currentDropToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.finalizeDropBatch(token: token)
            }
        } else {
            // 単一項目：従来どおり 0.7 秒後に余剰の空ウインドウを掃除する（単一なので整列は実質 no-op）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.closeEmptyWindows()
                self.cascadeBatchWindows()
            }
        }
    }

    override init() {
        super.init()
        AppDelegate.shared = self
        // ウインドウの状態復元を無効化する。本アプリはフォルダ内容を保存しない
        // （スナップショット仕様）ため、SwiftUI の WindowGroup 復元が働くと、
        // 終了時に開いていたウインドウが次回起動で「空のまま」何枚も蘇ってしまう。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 新規ウインドウに適用する基準サイズ。
    /// 直近の主ウインドウサイズ（`lastWindowSize`）があればそれを使う。
    /// 起動直後の初回は `windowDidBecomeMain` による記録がまだ走っておらず nil のため、
    /// フォールバックとして「この新規窓を開いた元の主ウインドウ」の content サイズを使う
    /// （`viewDidMoveToWindow` の時点では新規窓はまだ main ではなく、主ウインドウ＝開いた元の窓）。
    func referenceContentSize(excluding newWindow: NSWindow) -> NSSize? {
        if let size = lastWindowSize { return size }
        if let main = NSApp.mainWindow, main != newWindow {
            return main.contentRect(forFrameRect: main.frame).size
        }
        return nil
    }

    /// ウインドウをそのスクリーンの可視領域（メニューバー・Dock を除く `visibleFrame`）に収める。
    /// サイズが可視領域より大きければ縮め、位置がはみ出していれば内側へ寄せる。新規ウインドウが
    /// ディスプレイ外や Dock に食い込むのを防ぐ（既に収まっていれば `setFrame` を呼ばず実質 no-op）。
    func constrainToVisibleFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var frame = window.frame
        // 可視領域より大きいときは縮める（高さは Dock ぶんを除いた高さに収まる）
        frame.size.width = min(frame.size.width, vis.size.width)
        frame.size.height = min(frame.size.height, vis.size.height)
        // フレーム全体が可視領域に入るよう原点をクランプ（幅・高さは vis 以下なので範囲は必ず有効）
        frame.origin.x = min(max(frame.origin.x, vis.minX), vis.maxX - frame.size.width)
        frame.origin.y = min(max(frame.origin.y, vis.minY), vis.maxY - frame.size.height)
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    @objc func windowDidBecomeMain(_ notification: Notification) {
        guard let newMain = notification.object as? NSWindow else { return }
        if let prev = previousMain, prev != newMain {
            // content サイズで記録する（適用側 WindowSizeView が setContentSize するため）。
            // frame サイズを渡すとタイトルバー＋ツールバーぶん大きくなるずれが毎回乗る。
            lastWindowSize = prev.contentRect(forFrameRect: prev.frame).size
        }
        previousMain = newMain
    }
}
